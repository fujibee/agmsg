#!/usr/bin/env bash
set -euo pipefail

# SessionStart hook for delivery modes `monitor` and `both`.
#
# Usage: session-start.sh <type> <project_path>
#
# Reads the hook input JSON from stdin to extract the session_id, then emits
# an instruction telling Claude to invoke the Monitor tool against watch.sh.
# The hook input includes session_id for SessionStart events.
#
# Before emitting the directive, this script also takes care of preventing
# duplicate watchers across `/clear` (and similar) re-fires of SessionStart
# within the same Claude Code instance. State is kept in
# `~/.agents/agmsg/run/cc-instance.<cc_pid>`, which records the last
# session_id this CC instance attached to. On each fire we kill the watcher
# for the previous session_id, then record the new one. Multiple CC
# instances of the same project get their own cc_pid, so they never step
# on each other.
#
# Quietly exits 0 when delivery.mode is not monitor/both, when whoami says
# the agent isn't joined to anything yet, etc.

TYPE="${1:?Usage: session-start.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"

MODE=$("$SCRIPT_DIR/config.sh" get delivery.mode "off" 2>/dev/null || echo off)
case "$MODE" in monitor|both) ;; *) exit 0 ;; esac

# Identity sanity check — no point launching a watcher with an empty pair set.
PAIRS=$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)
[ -n "$PAIRS" ] || exit 0

# Read hook input JSON from stdin. session_id field is sent for SessionStart.
INPUT=$(cat 2>/dev/null || true)
SESSION_ID=""
if [ -n "$INPUT" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
fi
# Fallback so the instruction is still actionable even outside CC's hook flow.
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-$$"

mkdir -p "$RUN_DIR" 2>/dev/null || true

# --- Identify the enclosing Claude Code process. ---
# Walk the parent chain looking for a process whose argv contains "claude".
# Stop at PID 1 or after a bounded number of hops. Returns empty when no
# match — in that case we skip the dedup step entirely.
find_cc_pid() {
  local pid="$$"
  local hops=0
  while [ "$pid" -gt 1 ] && [ "$hops" -lt 20 ]; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && return 1
    [ "$pid" = "0" ] && return 1
    local cmd
    cmd=$(ps -o args= -p "$pid" 2>/dev/null || true)
    # Match the actual claude binary, not e.g. "/bin/zsh -c '...claude...'"
    # by requiring the basename of the first token to be exactly "claude".
    local first
    first=$(printf '%s' "$cmd" | awk '{print $1}')
    if [ "$(basename -- "${first:-}")" = "claude" ]; then
      echo "$pid"
      return 0
    fi
    hops=$((hops + 1))
  done
  return 1
}

CC_PID=$(find_cc_pid 2>/dev/null || true)

# --- Best-effort cleanup of stale cc-instance files. ---
# Any cc-instance.<pid> whose pid is dead is left over from a previous CC
# run and can be removed safely.
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  pid=${f##*.}
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$pid" 2>/dev/null || rm -f "$f"
done

# --- Dedup against the previous watcher in this CC instance. ---
if [ -n "$CC_PID" ]; then
  STATE="$RUN_DIR/cc-instance.$CC_PID"
  if [ -f "$STATE" ]; then
    prev=$(cat "$STATE" 2>/dev/null || true)
    if [ -n "$prev" ] && [ "$prev" != "$SESSION_ID" ]; then
      prev_pidfile="$RUN_DIR/watch.$prev.pid"
      if [ -f "$prev_pidfile" ]; then
        prev_pid=$(cat "$prev_pidfile" 2>/dev/null || true)
        if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then
          kill "$prev_pid" 2>/dev/null || true
        fi
      fi
    fi
  fi
  printf '%s\n' "$SESSION_ID" > "$STATE"
fi

WATCH="$SKILL_DIR/scripts/watch.sh"

cat <<EOF
AGMSG monitor mode: invoke the Monitor tool now with the following parameters,
before any other action in this session.

  command: $WATCH $SESSION_ID $PROJECT $TYPE
  description: agmsg inbox stream
  persistent: true

This streams incoming agmsg messages into the session in real time. Each
output line is one message: \`<ts> | <team> | <from> → <to> | <body>\`.
React to messages as they arrive; reply with \`send.sh\`.

Note: On a /clear or --continue/--resume re-fire, you may shortly see a
"Monitor … stopped" notification for an earlier 'agmsg inbox stream'
task. That is the previous watcher being cleaned up to avoid duplicates
— it is expected. Do NOT relaunch it; the Monitor you invoke from this
directive replaces it.
EOF
