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

# record op: report TWO facts and decide nothing (tl 2026-08-31). PRESENCE — are
# we under tmux — is the exit code: 0 iff $TMUX is set (we ARE in tmux, whether or
# not we can name our own pane). SELF-ID is stdout: $TMUX_PANE, which may be EMPTY
# — that is the third value "could not resolve", NOT "not tmux"; the reason goes
# to stderr so a caller that needs the id (resolve-for-name) can report WHY. A
# caller that only needs the terminal (resolve-for-placement) uses the exit code
# and ignores the id. A missing tmux BINARY is a terminal_check concern (we are
# still under tmux). The session id arg is unused — tmux reports via the env.
terminal_detect() {
  [ -n "${TMUX:-}" ] || return 1
  if [ -n "${TMUX_PANE:-}" ]; then
    printf '%s\n' "$TMUX_PANE"
  else
    echo "tmux: \$TMUX_PANE is unset — cannot identify this pane" >&2
  fi
  return 0
}

# Positive proof that a captured id is a tmux id of the expected KIND: a pane is
# %<n>, a window is @<n>, n a non-negative integer (tmux docs). Without this the
# driver would accept whatever tmux printed — exit-0 garbage, a wrong-kind id, or a
# value with a newline — and the caller would record `tmux:<raw>`, breaking the
# <terminal>:<id> record framing (newline) or leaving despawn unable to act
# (wrong-kind/garbage). $1 = id, $2 = expected sigil ('%' or '@').
_tmux_id_ok() {
  local id="$1" sigil="$2" rest="${1#"$2"}"
  [ "$rest" != "$id" ] || return 1               # id actually started with the sigil
  case "$rest" in ''|*[!0-9]*) return 1 ;; esac   # >=1 char after it, all decimal
  return 0
}

# record op: create a pane/window, launch the boot command, print the new bare
# id (%N for a pane, @N for a window). Usage:
#   terminal_spawn <name> <project> <target> <boot...>
# <target> fully specifies the placement (no ambient config): 'window', or
# 'pane-h' / 'pane-v' for a horizontal / vertical split. Mirrors spawn.sh's tmux
# placement faithfully. The captured id is validated against its expected kind
# BEFORE it is named or returned, so a garbage/wrong-kind/newline id fails closed.
terminal_spawn() {
  local name="$1" project="$2" target="$3"; shift 3
  local id dir
  case "$target" in
    window)
      id="$(tmux new-window -P -F '#{window_id}' -n "$name" -c "$project" "$@")" || return 13
      _tmux_id_ok "$id" '@' || return 13
      tmux set-window-option -t "$id" automatic-rename off >/dev/null 2>&1 || true
      ;;
    pane-h|pane-v)
      case "$target" in pane-h) dir=-h ;; *) dir=-v ;; esac
      # #990: split the CALLER's pane, not the attached client's active window. With
      # no -t, tmux resolves the target from the attached client, so a spawn from one
      # agent's pane can land in ANOTHER agent's window when several share the server.
      # $TMUX_PANE is the caller's pane — the tmux equivalent of herdr's $HERDR_PANE_ID
      # (which this driver's herdr sibling already targets explicitly). Name it when we
      # have it; fall back to the ambient target only if it is somehow unset.
      if [ -n "${TMUX_PANE:-}" ]; then
        id="$(tmux split-window "$dir" -t "$TMUX_PANE" -P -F '#{pane_id}' -c "$project" "$@")" || return 13
      else
        id="$(tmux split-window "$dir" -P -F '#{pane_id}' -c "$project" "$@")" || return 13
      fi
      _tmux_id_ok "$id" '%' || return 13
      tmux select-pane -t "$id" -T "$name" >/dev/null 2>&1 || true
      ;;
    *) printf 'unsupported: unknown target: %s (window|pane-h|pane-v)\n' "$target" >&2; return 13 ;;
  esac
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
