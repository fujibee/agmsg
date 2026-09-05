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
  printf 'capabilities=spawn despawn peek poke where arrange name\n'
  printf 'syntax_help=tmux list-commands\n'
  printf 'intent.place_below=tmux move-pane -s SOURCE -t TARGET -v\n'
  printf 'intent.place_right=tmux move-pane -s SOURCE -t TARGET -h\n'
}

# READ op: print the window containing <id>. This answers WHERE only and never
# treats an unresolved location as proof that the pane is gone.
terminal_where() {
  local id="$1" out container
  command -v tmux >/dev/null 2>&1 || { echo unknown; return 10; }
  # A window placement (@N) is its own container.
  case "$id" in @*) printf '%s\n' "$id"; return 0 ;; %*) : ;; *) echo unsupported; return 13 ;; esac
  out="$(tmux list-panes -a -F '#{pane_id}|#{window_id}' 2>/dev/null)" \
    || { echo unknown; return 10; }
  container="$(printf '%s\n' "$out" | awk -F '|' -v id="$id" '$1 == id { print $2; exit }')"
  if [ -z "$container" ]; then
    echo unknown
    echo "tmux: the pane listing answered but did not contain '$id'; pane existence must be checked separately" >&2
    return 10
  fi
  printf '%s\n' "$container"
  return 0
}

# True iff source already occupies the exact split that the native move would
# create. tmux exposes geometry, not a split tree, so this is intentionally a
# visible-rectangle predicate. The +1 is tmux's separator cell.
_tmux_arranged() {
  local intent="$1" st="$2" sl="$3" sw="$4" sh="$5" tt="$6" tl="$7" tw="$8" th="$9"
  case "$intent" in
    place_below) [ "$sl" -eq "$tl" ] && [ "$sw" -eq "$tw" ] && [ "$st" -eq $((tt + th + 1)) ] ;;
    place_right) [ "$st" -eq "$tt" ] && [ "$sh" -eq "$th" ] && [ "$sl" -eq $((tl + tw + 1)) ] ;;
    *) return 2 ;;
  esac
}

_tmux_layout_numbers_ok() {
  local value
  for value in "$@"; do case "$value" in ''|*[!0-9]*) return 1 ;; esac; done
  return 0
}

terminal_arrange() {
  local source="$1" intent="$2" target="$3" out srow trow
  local sid swin st sl sw sh tid twin tt tl tw th
  command -v tmux >/dev/null 2>&1 || { echo runtime_error; return 10; }
  case "$source:$target" in %*:%*) : ;; *) echo unsupported; return 13 ;; esac
  case "$intent" in place_below|place_right) : ;; *) echo unsupported; return 13 ;; esac
  out="$(tmux list-panes -a -F '#{pane_id}|#{window_id}|#{pane_top}|#{pane_left}|#{pane_width}|#{pane_height}' 2>/dev/null)" \
    || { echo runtime_error; return 10; }
  srow="$(printf '%s\n' "$out" | awk -F '|' -v id="$source" '$1 == id { print; exit }')"
  trow="$(printf '%s\n' "$out" | awk -F '|' -v id="$target" '$1 == id { print; exit }')"
  [ -n "$srow" ] && [ -n "$trow" ] || { echo unknown; return 10; }
  IFS='|' read -r sid swin st sl sw sh <<< "$srow"
  IFS='|' read -r tid twin tt tl tw th <<< "$trow"
  _tmux_layout_numbers_ok "$st" "$sl" "$sw" "$sh" "$tt" "$tl" "$tw" "$th" \
    || { echo runtime_error; return 10; }
  [ "$swin" = "$twin" ] && _tmux_arranged "$intent" "$st" "$sl" "$sw" "$sh" "$tt" "$tl" "$tw" "$th" \
    && { echo unchanged; return 0; }
  case "$intent" in
    place_below) tmux move-pane -s "$source" -t "$target" -v >/dev/null 2>&1 ;;
    place_right) tmux move-pane -s "$source" -t "$target" -h >/dev/null 2>&1 ;;
  esac || { echo runtime_error; return 12; }
  echo moved
  return 0
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
      # no -t, tmux resolves the target from the ATTACHED client, so a spawn from one
      # agent's pane can land in ANOTHER agent's window when several share the server.
      # $TMUX_PANE is the caller's pane (tmux sets it in every pane; the tmux
      # equivalent of herdr's $HERDR_PANE_ID). Require it and target it EXPLICITLY —
      # not observing the caller's pane is NOT evidence the ambient target is the
      # caller, so fail closed rather than guess (positive-proof; co1). A window
      # target does not need it and is handled above.
      [ -n "${TMUX_PANE:-}" ] \
        || { printf 'unsupported: a tmux split needs $TMUX_PANE to target the caller pane (#990)\n' >&2; return 13; }
      id="$(tmux split-window "$dir" -t "$TMUX_PANE" -P -F '#{pane_id}' -c "$project" "$@")" || return 13
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
  # peek exit taxonomy, SHARED with herdr so the template reads one meaning across
  # every peek-capable driver (co1): the terminal being UNREACHABLE (tmux not on
  # PATH — no server to talk to) is 10; an answered-but-no-content failure (the pane
  # is gone / capture failed) is 12. 13 is reserved for a driver with no peek path at
  # all (plain's permanent "no addressable pane") — a different message to the user,
  # so a tmux pane's transient loss must NOT borrow it. Errors go to stderr; peek's
  # stdout stays content-only (capture-pane streams straight through, no rewrapping).
  command -v tmux >/dev/null 2>&1 \
    || { echo "tmux: not on PATH — cannot reach the terminal to peek pane '$id'" >&2; return 10; }
  if [ -n "$lines" ]; then
    tmux capture-pane -p -t "$id" -S "-$lines" \
      || { echo "tmux: could not capture pane '$id' (it may no longer exist)" >&2; return 12; }
  else
    tmux capture-pane -p -t "$id" \
      || { echo "tmux: could not capture pane '$id' (it may no longer exist)" >&2; return 12; }
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
  # Same exit taxonomy as peek (tl/co1): tmux not on PATH (unreachable) is 10; a
  # send-keys failure (the pane is gone) is 12. 13 stays reserved for a driver with no
  # poke path at all (plain) — a tmux pane's transient loss must not borrow it.
  command -v tmux >/dev/null 2>&1 \
    || { echo runtime_error; echo "tmux: not on PATH — cannot reach the terminal to poke pane '$id'" >&2; return 10; }
  tmux send-keys -l -t "$id" -- "$text" \
    || { echo runtime_error; echo "tmux: could not send to pane '$id' (it may no longer exist)" >&2; return 12; }
  sleep 0.3 2>/dev/null || true
  tmux send-keys -t "$id" Right Enter \
    || { echo runtime_error; echo "tmux: could not send Enter to pane '$id' (it may no longer exist)" >&2; return 12; }
  echo ok
  return 0
}

# control op: name the pane. The RESOLVABLE key is a pane user option
# @agmsg_agent = <team>:<agent> (scope Naming: tmux is never targeted by name —
# '-t a:b' is session:window to tmux — so peek/poke scan @agmsg_agent instead).
# select-pane -T sets the human-visible title as a copy. Canonical separator is
# ':' (both team and agent commonly contain '-'). Idempotent (safe to re-apply on
# SessionStart).
# <mode> is `key` or absent — see the herdr driver for the split. Here the
# `@agmsg_agent` pane option is the resolvable one and the window name / pane
# title is the decoration, so `key` sets the option and stops.
terminal_name() {
  local id="$1" team="$2" name="$3" mode="${4:-}" label
  label="$team:$name"
  tmux set-option -p -t "$id" @agmsg_agent "$label" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  if [ "$mode" = key ]; then echo ok; return 0; fi
  case "$id" in
    @*) tmux rename-window -t "$id" "$label" >/dev/null 2>&1 || true ;;
    *)  tmux select-pane  -t "$id" -T "$label" >/dev/null 2>&1 || true ;;
  esac
  echo ok
  return 0
}
