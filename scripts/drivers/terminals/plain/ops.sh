#!/usr/bin/env bash
# plain terminal driver — an emulator-backed OS terminal, and detection fallback.
#
# Sourced by the terminals registry into the caller's context. terminal_* only;
# no set -e/-u. Spawn keeps the existing OS-terminal launchers. Addressed
# peek/poke are runtime capabilities supplied only by measured emulator adapters;
# an unqualified legacy record or an unmeasured emulator fails loudly.
#
# The launch template comes from AGMSG_TERMINAL (its EXISTING meaning — an
# OS-terminal command template, distinct from the resolver's driver override
# AGMSG_TERMINAL_DRIVER) or, if the caller passes it, config spawn.terminal.

terminal_check() { echo ok; return 0; }

# ABI hook: is <id> an emulator-qualified tty or the legacy '-' sentinel?
_plain_parse_id() {
  local id="$1"
  _PLAIN_EMULATOR=""; _PLAIN_TTY=""
  case "$id" in
    iterm:/dev/ttys[0-9]*|terminal:/dev/ttys[0-9]*)
      _PLAIN_EMULATOR="${id%%:*}"
      _PLAIN_TTY="${id#*:}"
      case "${_PLAIN_TTY#/dev/ttys}" in ''|*[!0-9]*) return 1 ;; esac
      return 0 ;;
    *) return 1 ;;
  esac
}

# Keep '-' valid for legacy records. New addressable refs use emulator + tty.
terminal_id_ok() {
  [ "$1" = '-' ] && return 0
  _plain_parse_id "$1"
}

terminal_describe() {
  printf 'name=plain\n'
  printf 'backend=emulator-backed OS terminal\n'
  printf 'capabilities=spawn despawn peek poke\n'
}

_plain_adapter_script() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
  printf '%s/adapters/%s.applescript\n' "$here" "$1"
}

_plain_adapter_probe() {
  local emulator="$1" tty="$2" script out rc=0
  [ "$(uname -s)" = Darwin ] || {
    printf 'unsupported: plain emulator adapter %s is only implemented on macOS\n' "$emulator" >&2
    return 1
  }
  command -v osascript >/dev/null 2>&1 || {
    printf 'unknown: osascript is unavailable; cannot inspect plain emulator %s\n' "$emulator" >&2
    return 2
  }
  script="$(_plain_adapter_script "$emulator")"
  [ -r "$script" ] || {
    printf 'unsupported: no measured adapter is implemented yet for plain emulator %s (may become supported or unknown once one is added)\n' "$emulator" >&2
    return 1
  }
  out="$(osascript "$script" probe "$tty" 2>/dev/null)" || rc=$?
  case "$out" in
    supported) return 0 ;;
    unsupported:*) printf '%s\n' "$out" >&2; return 1 ;;
    unknown:*) printf '%s\n' "$out" >&2; return 2 ;;
  esac
  printf 'unknown: %s adapter probe failed (rc=%s)\n' "$emulator" "$rc" >&2
  return 2
}

# Runtime narrowing hook. A positive result only makes this instance eligible;
# each operation probes again immediately before touching the emulator.
terminal_capability() {
  local capability="$1" id="${2:-}"
  case "$capability" in
    spawn) return 0 ;;
    despawn)
      printf 'unsupported: plain window teardown needs an owner process witness\n' >&2
      return 1 ;;
    peek|poke) ;;
    *) printf 'unsupported: plain capability %s is not implemented\n' "$capability" >&2; return 1 ;;
  esac
  _plain_parse_id "$id" || {
    printf 'unsupported: plain %s needs an emulator-qualified tty reference\n' "$capability" >&2
    return 1
  }
  _plain_adapter_probe "$_PLAIN_EMULATOR" "$_PLAIN_TTY"
}

terminal_where() {
  echo unsupported
  echo "plain: no addressable pane has a container" >&2
  return 13
}

terminal_arrange() {
  echo unsupported
  echo "plain: no addressable panes can be arranged" >&2
  return 13
}

# record op: the fallback always "matches" but has no addressable pane, so the
# self id is '-'. Detection order puts plain last.
terminal_detect() { printf '%s\n' '-'; return 0; }

_plain_has_template() { case "$1" in *'{cmd}'*) return 0 ;; *) return 1 ;; esac; }

# record op: open an OS terminal window and run <boot> in it. Faithful move of
# spawn.sh's place_and_launch OS-terminal branch: a {cmd} template wins on any
# OS; else macOS uses the current terminal (TERM_PROGRAM) or a bare app hint;
# Linux/Windows require a {cmd} template for a custom command and reject headless
# / a template-without-{cmd}; an unknown OS is refused. No addressable pane
# results, so the placement id is '-' (record op: id on stdout, exit 0).
#   terminal_spawn <name> <project> <target> <boot...>   (<target> ignored)
terminal_spawn() {
  local name="$1" project="$2" target="$3"; shift 3
  local boot="$1"
  local tmpl="${AGMSG_TERMINAL:-}"
  # This is a RECORD op: its stdout must be the placement id ('-') and NOTHING else.
  # Every backend below (a {cmd} template's bash -c, `open`, a Linux emulator, wt)
  # can write to stdout — a custom template especially — and that would be captured
  # by the caller as the placement id. So each backend's STDOUT is redirected to
  # stderr (kept as a diagnostic, not swallowed), leaving only the '-' this function
  # prints on stdout.
  if [ -n "$tmpl" ] && _plain_has_template "$tmpl"; then
    local q_boot; q_boot="$(printf '%q' "$boot")"
    local cmd="${tmpl//\{cmd\}/$q_boot}"
    bash -c "$cmd" 1>&2 || return 13
    printf '%s\n' '-'; return 0
  fi
  case "$(uname -s)" in
    Darwin)
      local app="$tmpl"
      if [ -z "$app" ]; then
        case "${TERM_PROGRAM:-}" in iTerm.app) app=iterm ;; *) app=Terminal ;; esac
      fi
      case "$app" in
        iterm|iterm2|iTerm|iTerm2) open -g -a iTerm "$boot" 1>&2 || return 13 ;;
        *)                         open -g -a Terminal "$boot" 1>&2 || return 13 ;;
      esac ;;
    Linux)
      if [ -n "$tmpl" ]; then
        printf 'unsupported: AGMSG_TERMINAL must contain a {cmd} placeholder on Linux (got: %s)\n' "$tmpl" >&2
        return 13
      fi
      if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        printf 'unsupported: headless (no tmux, no display) — run inside tmux/herdr or set a {cmd} AGMSG_TERMINAL\n' >&2
        return 13
      fi
      local term
      for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal xterm; do
        command -v "$term" >/dev/null 2>&1 || continue
        case "$term" in
          gnome-terminal) gnome-terminal --working-directory="$project" -- "$boot" 1>&2 || return 13 ;;
          konsole)        konsole --workdir "$project" -e "$boot" 1>&2 || return 13 ;;
          *)              "$term" -e "$boot" 1>&2 || return 13 ;;
        esac
        printf '%s\n' '-'; return 0
      done
      printf 'unsupported: no terminal emulator found; set a {cmd} AGMSG_TERMINAL or run inside tmux/herdr\n' >&2
      return 13 ;;
    MINGW*|MSYS*|CYGWIN*)
      if [ -n "$tmpl" ]; then
        printf 'unsupported: AGMSG_TERMINAL must contain a {cmd} placeholder on Windows (got: %s)\n' "$tmpl" >&2
        return 13
      fi
      if command -v wt.exe >/dev/null 2>&1; then wt.exe new-tab bash -l "$boot" 1>&2 || return 13
      elif command -v wt >/dev/null 2>&1; then wt new-tab bash -l "$boot" 1>&2 || return 13
      else printf 'unsupported: Windows Terminal (wt) not found; set a {cmd} AGMSG_TERMINAL\n' >&2; return 13; fi ;;
    *)
      printf 'unsupported: platform %s (run inside tmux/herdr or set a {cmd} AGMSG_TERMINAL)\n' "$(uname -s)" >&2
      return 13 ;;
  esac
  printf '%s\n' '-'
  return 0
}

# control op: an OS terminal window has no addressable handle (the placement id
# is '-'), so there is nothing to kill from here — it closes when its process
# exits, exactly as before the axis (OS-terminal members were never force-
# killable). Report ok (nothing to tear down) rather than a spurious error.
# plain has no addressable pane, so it cannot be asked whether one is still
# there. 13 is that answer, and it is a real answer rather than a failure — the
# caller must not read it as "closed".
terminal_pane_state() { echo unknown; return 13; }

terminal_despawn() { echo ok; return 0; }

_plain_unsupported() {
  printf 'unsupported: plain terminal has no addressable pane (%s)\n' "$1" >&2
  return 13
}
# Legacy unqualified records retain the native-channel guidance. New qualified
# records use an emulator adapter and never fall back to messaging silently.
_plain_no_pane_but_maybe_native() {
  printf 'unsupported: plain terminal has no addressable pane (%s) — not a dead end: the member'\''s agent type may offer a native channel; the type template says which\n' "$1" >&2
  return 13
}
terminal_peek() {
  local id="$1" lines="" script rc=0
  shift
  [ "$id" = '-' ] && { _plain_unsupported "peek"; return $?; }
  if [ "${1:-}" = --lines ]; then lines="${2:-}"; fi
  terminal_capability peek "$id" || rc=$?
  case "$rc" in 0) ;; 1) return 13 ;; *) return 10 ;; esac
  rc=0
  _plain_parse_id "$id" || return 13
  script="$(_plain_adapter_script "$_PLAIN_EMULATOR")"
  osascript "$script" peek "$_PLAIN_TTY" "$lines" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  printf 'plain: %s adapter could not read %s\n' "$_PLAIN_EMULATOR" "$_PLAIN_TTY" >&2
  return 10
}

terminal_team_observe() {
  printf 'n/a:unsupported\tn/a:no_addressable_pane\tn/a:no_addressable_pane\tn/a:no_addressable_pane\n'
}
terminal_poke() {
  local id="$1" text="$2" script rc=0
  [ "$id" = '-' ] && { _plain_no_pane_but_maybe_native "poke"; return $?; }
  terminal_capability poke "$id" || rc=$?
  case "$rc" in 0) ;; 1) return 13 ;; *) return 10 ;; esac
  rc=0
  _plain_parse_id "$id" || return 13
  script="$(_plain_adapter_script "$_PLAIN_EMULATOR")"
  osascript "$script" poke "$_PLAIN_TTY" "$text" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  printf 'plain: %s adapter could not write %s\n' "$_PLAIN_EMULATOR" "$_PLAIN_TTY" >&2
  return 10
}
# plain has no panes to label, so it can never answer this. 13 = unsupported,
# the same word it uses for every other addressable-pane op.
terminal_find_by_label() { _plain_unsupported "find_by_label"; }
terminal_label_of() { _plain_unsupported "label_of"; }
terminal_name() { _plain_unsupported "name"; }

# NO terminal_pane_process_observe HERE, deliberately.
#
# The plain driver has no pane and no process to bind to, so there is nothing for
# it to observe. Its ABSENCE is the answer: the coordinator reads a missing op as
# `unsupported:driver_no_process_binding` -- a configuration in which the question
# has no answer -- rather than as a failure to retry. A stub that returned
# "nothing found" would be indistinguishable from a pane whose processes we could
# not read, and the two must not land in the same bucket (#1152).
