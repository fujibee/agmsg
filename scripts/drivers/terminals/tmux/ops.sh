#!/usr/bin/env bash
# tmux terminal driver — a pane/window inside a tmux server.
#
# Sourced by the terminals registry into the caller's context. terminal_* only,
# no set -e/-u. Faithful to the pre-axis inline calls in spawn.sh / despawn.sh /
# watch.sh so the migration is a drop-in.

# control op: tmux binary present?
terminal_check() {
  if command -v tmux >/dev/null 2>&1; then echo ok; return 0; fi
  printf 'AGMSG-DIRECTIVE: {"type":"install_deps","driver":"terminals/tmux","reason":"tmux not found"}\n'
  echo missing_deps
  return 10
}

terminal_describe() {
  printf 'name=tmux\n'
  printf 'backend=tmux pane/window\n'
  printf 'capabilities=spawn despawn peek poke name\n'
}

# record op: we are under tmux iff $TMUX is set AND $TMUX_PANE names our pane.
# Both are required: $TMUX alone with an empty $TMUX_PANE cannot yield a valid
# pane id, so it is NOT a match (returning an empty id would mint an invalid
# 'tmux:' record). The session id arg is unused — tmux reports the pane through
# the environment, not a lookup. A missing tmux BINARY is a terminal_check
# concern, not a detection one (we still ARE under tmux).
terminal_detect() {
  [ -n "${TMUX:-}" ] || return 1
  [ -n "${TMUX_PANE:-}" ] || return 1
  printf '%s\n' "$TMUX_PANE"
  return 0
}

# record op: create a pane/window, launch the boot command, print the new bare
# id (%N for a pane, @N for a window). Usage:
#   terminal_spawn <name> <project> <target> <boot...>
# <target> fully specifies the placement (no ambient config): 'window', or
# 'pane-h' / 'pane-v' for a horizontal / vertical split. Mirrors spawn.sh's tmux
# placement faithfully.
terminal_spawn() {
  local name="$1" project="$2" target="$3"; shift 3
  local id dir
  case "$target" in
    window)
      id="$(tmux new-window -P -F '#{window_id}' -n "$name" -c "$project" "$@")" || return 13
      tmux set-window-option -t "$id" automatic-rename off >/dev/null 2>&1 || true
      ;;
    pane-h|pane-v)
      case "$target" in pane-h) dir=-h ;; *) dir=-v ;; esac
      id="$(tmux split-window "$dir" -P -F '#{pane_id}' -c "$project" "$@")" || return 13
      tmux select-pane -t "$id" -T "$name" >/dev/null 2>&1 || true
      ;;
    *) printf 'unsupported: unknown target: %s (window|pane-h|pane-v)\n' "$target" >&2; return 13 ;;
  esac
  [ -n "$id" ] || return 13
  printf '%s\n' "$id"
  return 0
}

# control op: kill the pane (%N) or window (@N) named by the bare id.
terminal_despawn() {
  local id="$1"
  case "$id" in
    %*) tmux kill-pane   -t "$id" >/dev/null 2>&1 || { echo runtime_error; return 13; } ;;
    @*) tmux kill-window -t "$id" >/dev/null 2>&1 || { echo runtime_error; return 13; } ;;
    *)  printf 'unsupported: not a tmux pane/window id: %s\n' "$id" >&2; return 13 ;;
  esac
  echo ok
  return 0
}

# record op: print the visible pane buffer verbatim (NOT parsed). --lines N
# starts N lines back into the scrollback (default: just the visible screen).
terminal_peek() {
  local id="$1"; shift
  local lines=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --lines) lines="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$lines" in ''|*[!0-9]*) lines="" ;; esac
  if [ -n "$lines" ]; then
    tmux capture-pane -p -t "$id" -S "-$lines" || return 13
  else
    tmux capture-pane -p -t "$id" || return 13
  fi
  return 0
}

# control op: type <text> into the pane and submit it — in TWO bursts.
# #619: text and Enter in the SAME send-keys burst are read as a paste by Codex,
# and the Enter becomes a literal newline instead of submitting. A Right arrow in
# a SEPARATE burst decisively ends paste detection (a no-op for the cursor at
# end-of-line), so the following Enter submits. The brief gap lets the terminal
# finish the text burst before the arrow; it is part of the behavior, not a tunable
# — no env seam.
terminal_poke() {
  local id="$1" text="$2"
  tmux send-keys -l -t "$id" -- "$text" || { echo runtime_error; return 13; }
  sleep 0.3 2>/dev/null || true
  tmux send-keys -t "$id" Right Enter || { echo runtime_error; return 13; }
  echo ok
  return 0
}

# control op: name the pane. The RESOLVABLE key is a pane user option
# @agmsg_agent = <team>:<agent> (scope Naming: tmux is never targeted by name —
# '-t a:b' is session:window to tmux — so peek/poke scan @agmsg_agent instead).
# select-pane -T sets the human-visible title as a copy. Canonical separator is
# ':' (both team and agent commonly contain '-'). Idempotent (safe to re-apply on
# SessionStart).
terminal_name() {
  local id="$1" team="$2" name="$3" label
  label="$team:$name"
  tmux set-option -p -t "$id" @agmsg_agent "$label" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  case "$id" in
    @*) tmux rename-window -t "$id" "$label" >/dev/null 2>&1 || true ;;
    *)  tmux select-pane  -t "$id" -T "$label" >/dev/null 2>&1 || true ;;
  esac
  echo ok
  return 0
}
