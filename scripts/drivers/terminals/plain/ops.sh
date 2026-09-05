#!/usr/bin/env bash
# plain terminal driver — an OS terminal window, the detection fallback.
#
# Sourced by the terminals registry into the caller's context. terminal_* only;
# no set -e/-u. Per the v1 scope, plain IMPLEMENTS spawn/despawn (the existing
# OS-terminal launchers, moved here faithfully) and returns "unsupported: <why>"
# for peek/poke/name — it has no addressable pane, so an op that cannot run says
# so, it does not exit 0 quietly.
#
# The launch template comes from AGMSG_TERMINAL (its EXISTING meaning — an
# OS-terminal command template, distinct from the resolver's driver override
# AGMSG_TERMINAL_DRIVER) or, if the caller passes it, config spawn.terminal.

terminal_check() { echo ok; return 0; }

terminal_describe() {
  printf 'name=plain\n'
  printf 'backend=OS terminal window (no addressable pane)\n'
  printf 'capabilities=spawn despawn\n'
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
  # prints on stdout (co1).
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
# poke — and ONLY poke — gets the third value, by design: still non-zero,
# because as a terminal answer "no pane" is correct and stays, but the refusal
# must not end the conversation: the member's agent TYPE may have a native
# channel (Claude Code's SendMessage), and the type template is where that
# question is answered. Deliberately said WITHOUT asking who the caller is:
# "which terminal am I in" is this driver's question, "does this agent have
# native messaging" is the type's — mixing them here would rebuild the
# presence-vs-binary confusion this axis just removed.
#
# peek stays a plain dead end ON PURPOSE — the asymmetry is measured, not an
# oversight: a native WRITE path exists (SendMessage), but there is no native
# READ path in today's CLI (`claude logs <id>` serves background jobs only —
# interactive ids answer "No job matching" — and `claude agents --json` lists
# status, never screen content). If a read endpoint ever appears, this is the
# line to change.
_plain_no_pane_but_maybe_native() {
  printf 'unsupported: plain terminal has no addressable pane (%s) — not a dead end: the member'\''s agent type may offer a native channel; the type template says which\n' "$1" >&2
  return 13
}
terminal_peek() { _plain_unsupported "peek"; }
terminal_poke() { _plain_no_pane_but_maybe_native "poke"; }
terminal_name() { _plain_unsupported "name"; }
