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
# The id's two halves for the locator grammar: "<emulator>\t<tty>". The legacy
# '-' sentinel names no place and is refused -- a locator must carry one.
terminal_id_split() {   # <id>
  _plain_parse_id "$1" || return 1
  printf '%s\t%s\n' "$_PLAIN_EMULATOR" "$_PLAIN_TTY"
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
  local emulator="$1" tty="$2" capability="${3:-peek}" operation=probe script out rc=0
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
  [ "$capability" = despawn ] && operation=probe_despawn
  out="$(osascript "$script" "$operation" "$tty" 2>/dev/null)" || rc=$?
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
    despawn|peek|poke) ;;
    *) printf 'unsupported: plain capability %s is not implemented\n' "$capability" >&2; return 1 ;;
  esac
  _plain_parse_id "$id" || {
    printf 'unsupported: plain %s needs an emulator-qualified tty reference\n' "$capability" >&2
    return 1
  }
  _plain_adapter_probe "$_PLAIN_EMULATOR" "$_PLAIN_TTY" "$capability"
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

# A measured macOS emulator can identify the current seat by its controlling
# tty. Other plain environments retain the explicit legacy '-' sentinel: they
# are structurally present, but this implementation has no addressable locator.
terminal_detect() {
  local emulator="" tty=""
  case "${TERM_PROGRAM:-}" in
    iTerm.app) emulator=iterm ;;
    Apple_Terminal) emulator=terminal ;;
    *) printf '%s\n' '-'; return 0 ;;
  esac
  tty="$(command tty 2>/dev/null)" || tty=""
  case "$tty" in /dev/ttys[0-9]*) ;; *)
    printf 'plain: controlling tty is unavailable; cannot produce an emulator-qualified locator\n' >&2
    printf '%s\n' '-'
    return 0 ;;
  esac
  printf '%s:%s\n' "$emulator" "$tty"
  return 0
}

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
    _plain_spawn_locator; return $?
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
        _plain_spawn_locator; return $?
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
  _plain_spawn_locator
}

# The new window is the first process that can observe its tty. spawn.sh embeds
# a one-shot witness writer in the boot script and hands this driver its result
# path. Wait for that positive observation; never turn a timeout or malformed
# row into the legacy '-' sentinel after a window has already been created.
_plain_spawn_locator() {
  local witness="${AGMSG_PLAIN_SPAWN_WITNESS:-}" emulator tty pid start extra tries=0
  local limit="${AGMSG_TEST_PLAIN_WITNESS_TRIES:-100}"
  case "$limit" in ''|*[!0-9]*) limit=100 ;; esac
  [ -n "$witness" ] || {
    printf 'plain: spawn witness path is unavailable; the created window cannot be recorded\n' >&2
    return 13
  }
  if [ -n "${AGMSG_TEST_PLAIN_WITNESS_ROW:-}" ] && [ ! -s "$witness" ]; then
    printf '%s\n' "$AGMSG_TEST_PLAIN_WITNESS_ROW" > "$witness"
  fi
  while [ "$tries" -lt "$limit" ]; do
    [ -s "$witness" ] && break
    sleep 0.1 2>/dev/null || true
    tries=$((tries + 1))
  done
  [ -s "$witness" ] || {
    printf 'plain: spawned window did not report its tty and owner before the handshake deadline\n' >&2
    return 13
  }
  IFS=$'\t' read -r emulator tty pid start extra < "$witness"
  [ -n "$emulator" ] && [ -n "$tty" ] && [ -n "$pid" ] && [ -n "$start" ] && [ -z "$extra" ] || {
    printf 'plain: spawned window returned an incomplete owner witness\n' >&2
    return 13
  }
  _plain_parse_id "$emulator:$tty" || {
    printf 'plain: spawned window returned an unsupported emulator or tty\n' >&2
    return 13
  }
  case "$pid" in *[!0-9]*|'')
    printf 'plain: spawned window returned an invalid owner pid\n' >&2
    return 13 ;;
  esac
  case "$start" in *[!0-9A-Za-z_:]*)
    printf 'plain: spawned window returned an invalid owner start time\n' >&2
    return 13 ;;
  esac
  printf '%s:%s\n' "$emulator" "$tty"
  return 0
}

# A tty reference does not provide a read-only existence authority for the
# process-bound placement, so pane_state remains unknown. Despawn is stronger:
# it receives the record's owner witness, revalidates it, then closes the exact
# emulator session through the measured adapter.
terminal_pane_state() { echo unknown; return 13; }

_plain_process_witness_matches() {   # <pid> <start> <tty> <kind>
  local pid="$1" start="$2" tty="$3" kind="$4" observed current_start
  case "$pid" in ''|*[!0-9]*)
    printf 'plain: %s process witness is malformed\n' "$kind" >&2
    return 10 ;;
  esac
  observed="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
  case "$observed" in /dev/*) ;; ''|'?'|'??'|'-') observed="" ;; *) observed="/dev/$observed" ;; esac
  [ "$observed" = "$tty" ] || {
    printf 'plain: %s process no longer controls %s\n' "$kind" "$tty" >&2
    return 10
  }
  current_start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//' | tr ' ' '_')"
  [ -n "$current_start" ] && [ "$current_start" = "$start" ] || {
    printf 'plain: %s process witness no longer matches pid %s\n' "$kind" "$pid" >&2
    return 10
  }
  return 0
}

terminal_despawn() {   # <id> <fence=instance:anchor>
  local id="$1" fence="${2:-}" emulator tty anchor remaining witness_tty="" pid="" start="" boot="" boot_start="" kv script
  _plain_parse_id "$id" || {
    printf 'unsupported: plain window teardown needs an emulator-qualified tty reference\n' >&2
    return 13
  }
  emulator="$_PLAIN_EMULATOR"; tty="$_PLAIN_TTY"
  case "$fence" in fence=*:*) ;; *)
    printf 'unsupported: plain window teardown needs an owner process witness\n' >&2
    return 13 ;;
  esac
  anchor="${fence#fence=*:}"
  [ "${fence#fence=}" = "$emulator:$anchor" ] || {
    printf 'plain: owner witness emulator does not match the placement locator\n' >&2
    return 10
  }
  remaining="$anchor"
  while :; do
    kv="${remaining%%,*}"
    case "$kv" in
      tty=*) [ -z "$witness_tty" ] || { printf 'plain: duplicate tty in owner witness\n' >&2; return 10; }; witness_tty="${kv#tty=}" ;;
      pid=*) [ -z "$pid" ] || { printf 'plain: duplicate pid in owner witness\n' >&2; return 10; }; pid="${kv#pid=}" ;;
      start=*) [ -z "$start" ] || { printf 'plain: duplicate start in owner witness\n' >&2; return 10; }; start="${kv#start=}" ;;
      boot=*) [ -z "$boot" ] || { printf 'plain: duplicate boot pid in owner witness\n' >&2; return 10; }; boot="${kv#boot=}" ;;
      boot_start=*) [ -z "$boot_start" ] || { printf 'plain: duplicate boot start in owner witness\n' >&2; return 10; }; boot_start="${kv#boot_start=}" ;;
      *) : ;; # Forward-compatible: only known keys are evidence for this reader.
    esac
    case "$remaining" in *,*) remaining="${remaining#*,}" ;; *) break ;; esac
  done
  [ "$witness_tty" = "$tty" ] || {
    printf 'plain: owner witness tty does not match the placement locator\n' >&2
    return 10
  }
  if { [ -n "$pid" ] && [ -z "$start" ]; } || { [ -z "$pid" ] && [ -n "$start" ]; }; then
    printf 'plain: CLI process witness is incomplete\n' >&2
    return 10
  fi
  if { [ -n "$boot" ] && [ -z "$boot_start" ]; } || { [ -z "$boot" ] && [ -n "$boot_start" ]; }; then
    printf 'plain: boot process witness is incomplete\n' >&2
    return 10
  fi
  [ -n "$pid" ] || [ -n "$boot" ] || {
    printf 'plain: owner process witness carries no known process identity\n' >&2
    return 10
  }
  [ -z "$pid" ] || _plain_process_witness_matches "$pid" "$start" "$tty" CLI || return $?
  [ -z "$boot" ] || _plain_process_witness_matches "$boot" "$boot_start" "$tty" boot || return $?
  [ "$(uname -s)" = Darwin ] || {
    printf 'unsupported: plain window teardown adapters are only implemented on macOS\n' >&2
    return 13
  }
  command -v osascript >/dev/null 2>&1 || {
    printf 'unknown: osascript is unavailable; cannot close plain emulator %s\n' "$emulator" >&2
    return 10
  }
  script="$(_plain_adapter_script "$emulator")"
  osascript "$script" despawn "$tty" >/dev/null || {
    printf 'plain: %s adapter could not close %s\n' "$emulator" "$tty" >&2
    return 10
  }
  echo ok
  return 0
}

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

# Fence for a self-write (#1152, #1149). A plain seat is record-only: it can
# write the placement record for the locator it was handed, and nothing else
# (no label, key or session op exists in this implementation -- see the
# capability hook, which says so in #1163's words). What it CAN verify before
# writing is that the locator's tty is the tty of the seat's own CLI process,
# observed through that process, never through the environment (launcher-
# inherited session ids were measured colliding across seats, so the emulator
# half of the locator is carried as delivered and treated as NO evidence).
#
# Prints "<emulator>\t<anchor>" where the anchor is the tty plus something that
# changes when the tty is reused -- /dev/ttysNNN is handed to the next session
# when this one ends -- namely the owning pid and its start time:
#   iterm\ttty=/dev/ttys040,pid=12345,start=Sat_Sep_13_02:10:11_2026
# Every failure is a named unknown in the anchor half, and the writer writes
# nothing on any of them:
#   unknown:no_seat_pid        the caller gave no pid to observe
#   unknown:tty_unobservable   the process has no controlling tty (a daemon,
#                              a background job), or ps could not answer
#   unknown:tty_mismatch:<observed>  the process sits on a different tty than
#                              the locator names -- the leader typed into one
#                              window and this seat lives in another
#   unknown:invalid_id         the id is not <emulator>:<tty>
terminal_fence() {   # <id> [<seat-pid>]
  local id="$1" pid="${2:-}" observed start
  _plain_parse_id "$id" || { printf 'unknown:invalid_id\tunknown:invalid_id\n'; return 2; }
  local emulator="$_PLAIN_EMULATOR" tty="$_PLAIN_TTY"
  case "$pid" in ''|*[!0-9]*) printf '%s\tunknown:no_seat_pid\n' "$emulator"; return 2 ;; esac
  observed="$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')"
  case "$observed" in ''|'??'|'-'|'?') printf '%s\tunknown:tty_unobservable\n' "$emulator"; return 2 ;; esac
  case "$observed" in /dev/*) ;; *) observed="/dev/$observed" ;; esac
  [ "$observed" = "$tty" ] || { printf '%s\tunknown:tty_mismatch:%s\n' "$emulator" "$observed"; return 2; }
  start="$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//' | tr ' ' '_')"
  [ -n "$start" ] || { printf '%s\tunknown:tty_unobservable\n' "$emulator"; return 2; }
  printf '%s\ttty=%s,pid=%s,start=%s\n' "$emulator" "$tty" "$pid" "$start"
  return 0
}

# NO terminal_pane_process_observe HERE, deliberately.
#
# The plain driver has no pane and no process to bind to, so there is nothing for
# it to observe. Its ABSENCE is the answer: the coordinator reads a missing op as
# `unsupported:driver_no_process_binding` -- a configuration in which the question
# has no answer -- rather than as a failure to retry. A stub that returned
# "nothing found" would be indistinguishable from a pane whose processes we could
# not read, and the two must not land in the same bucket (#1152).
