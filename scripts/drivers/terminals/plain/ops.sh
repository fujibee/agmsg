#!/usr/bin/env bash
# plain terminal driver — an OS terminal window (iTerm/Terminal/gnome-terminal/
# wt/template), the detection fallback.
#
# Sourced by the terminals registry into the caller's context. terminal_* only;
# no set -e/-u. plain CAN spawn (open a window and run the boot script) but the
# result is NOT an addressable pane, so despawn/peek/poke/name are unsupported
# (status 13, reason on stderr — §1.4). terminal_spawn returns '-' as the placement
# id (there is nothing to address later), matching terminal_detect's fallback id.

terminal_check() { echo ok; return 0; }

terminal_describe() {
  printf 'name=plain\n'
  printf 'backend=OS terminal window (no addressable pane)\n'
  printf 'capabilities=spawn\n'
}

# record op: the fallback always "matches" but has no addressable pane, so the
# self id is '-'. (Detection order puts plain last, so it wins only when neither
# tmux nor herdr claimed the session.)
terminal_detect() { printf '%s\n' '-'; return 0; }

# record op: open an OS terminal window and run the boot command in it. Faithful
# driver-ification of the pre-axis spawn.sh OS-terminal launchers. There is no
# addressable pane afterwards, so the placement id is '-' (record op: id on
# stdout, exit 0; failure exits non-zero with a message on stderr).
#   terminal_spawn <name> <project> <target> <boot...>
# <target> is ignored (an OS terminal has no pane/window split); <boot> is a
# single executable path (the boot script). The command template is the existing
# AGMSG_TERMINAL env (NOT the driver override, which is AGMSG_TERMINAL_DRIVER).
terminal_spawn() {
  local name="$1" project="$2" target="$3"; shift 3
  local boot="$1"
  local tmpl="${AGMSG_TERMINAL:-}"
  if [ -n "$tmpl" ]; then
    local q_boot; q_boot="$(printf '%q' "$boot")"
    local cmd
    case "$tmpl" in
      *'{cmd}'*) cmd="${tmpl//\{cmd\}/$q_boot}" ;;
      *)         cmd="$tmpl $q_boot" ;;
    esac
    bash -c "$cmd" || return 13
  else
    case "$(uname -s)" in
      Darwin)
        case "${AGMSG_MACOS_TERMINAL:-Terminal}" in
          iterm|iterm2|iTerm|iTerm2) open -g -a iTerm "$boot" || return 13 ;;
          *)                         open -g -a Terminal "$boot" || return 13 ;;
        esac ;;
      MINGW*|MSYS*|CYGWIN*)
        if command -v wt.exe >/dev/null 2>&1; then wt.exe new-tab bash -l "$boot" || return 13
        elif command -v wt >/dev/null 2>&1; then wt new-tab bash -l "$boot" || return 13
        else printf 'unsupported: Windows Terminal (wt) not found; set AGMSG_TERMINAL\n' >&2; return 13; fi ;;
      *)
        local term
        for term in x-terminal-emulator gnome-terminal konsole xfce4-terminal xterm; do
          command -v "$term" >/dev/null 2>&1 || continue
          case "$term" in
            gnome-terminal) gnome-terminal --working-directory="$project" -- "$boot" || return 13 ;;
            konsole)        konsole --workdir "$project" -e "$boot" || return 13 ;;
            *)              "$term" -e "$boot" || return 13 ;;
          esac
          printf '%s\n' '-'; return 0
        done
        printf 'unsupported: no terminal emulator found; set AGMSG_TERMINAL or run inside tmux/herdr\n' >&2
        return 13 ;;
    esac
  fi
  printf '%s\n' '-'
  return 0
}

_plain_unsupported() {
  printf 'unsupported: plain terminal has no addressable pane (%s)\n' "$1" >&2
  return 13
}
terminal_peek()    { _plain_unsupported "peek"; }
terminal_poke()    { _plain_unsupported "poke"; }
terminal_despawn() { _plain_unsupported "despawn"; }
terminal_name()    { _plain_unsupported "name"; }
