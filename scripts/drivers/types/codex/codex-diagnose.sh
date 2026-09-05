#!/usr/bin/env bash
set -euo pipefail

# Read-only three-layer Codex monitor diagnosis.
PROJECT="${1:?Usage: codex-diagnose.sh <project> <team> <agent>}"
TEAM="${2:?Missing team}"
AGENT="${3:?Missing agent}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
source "$SCRIPT_DIR/../../../lib/hash.sh"
source "$SCRIPT_DIR/../../../lib/role-session.sh"
source "$SCRIPT_DIR/../../../lib/node.sh"

PROJECT="$(cd "$PROJECT" && pwd)"
HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
PORT_FILE="$RUN_DIR/codex-app-server.$HASH.port"
SERVER_PID_FILE="$RUN_DIR/codex-app-server.$HASH.pid"
BASE="$RUN_DIR/codex-bridge.$TEAM.$AGENT"
BASELINE_FILE="$RUN_DIR/codex-app-server.$HASH.loaded-baseline"
BRIDGE_PID="$(cat "$BASE.pid" 2>/dev/null || true)"
BRIDGE_THREAD="$(cat "$BASE.thread" 2>/dev/null || true)"
BRIDGE_APP="$(cat "$BASE.appserver" 2>/dev/null || true)"
META="$BASE.meta"
PORT="$(cat "$PORT_FILE" 2>/dev/null || true)"
SERVER_PID="$(cat "$SERVER_PID_FILE" 2>/dev/null || true)"

agmsg_role_session_load "$TEAM" "$AGENT" 2>/dev/null || true
SEAT_THREAD="${AGMSG_ROLE_SESSION_UUID:-}"
NODE_BIN="$(agmsg_resolve_node 2>/dev/null || true)"
LOADED=""
if [ -n "$PORT" ] && [ -n "$NODE_BIN" ] && { command -v "$NODE_BIN" >/dev/null 2>&1 || [ -x "$NODE_BIN" ]; }; then
  LOADED="$("$NODE_BIN" "$SCRIPT_DIR/codex-bridge.js" --app-server "ws://127.0.0.1:$PORT" --print-loaded-threads --connect-timeout-ms 1500 --request-timeout-ms 1500 2>/dev/null || true)"
fi

# Normalize the app-server response into sets. A multi-thread app-server is not
# evidence of the current TUI: retained threads are normal after resume/close.
DIAG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-codex-diagnose.XXXXXX")"
trap 'rm -rf "$DIAG_TMP"' EXIT
printf '%s\n' "$LOADED" | grep -E '^[[:alnum:]-]+$' | sort -u >"$DIAG_TMP/current" || true
if [ -f "$BASELINE_FILE" ] && ! grep -Fxq '# probe-unavailable' "$BASELINE_FILE"; then
  grep -E '^[[:alnum:]-]+$' "$BASELINE_FILE" | sort -u >"$DIAG_TMP/baseline" || true
  comm -13 "$DIAG_TMP/baseline" "$DIAG_TMP/current" >"$DIAG_TMP/new" || true
  baseline_state="AVAILABLE"
else
  : >"$DIAG_TMP/baseline"
  : >"$DIAG_TMP/new"
  baseline_state="UNKNOWN"
fi
loaded_count="$(grep -c . "$DIAG_TMP/current" 2>/dev/null || true)"
baseline_count="$(grep -c . "$DIAG_TMP/baseline" 2>/dev/null || true)"
new_count="$(grep -c . "$DIAG_TMP/new" 2>/dev/null || true)"
loaded_only="$(cat "$DIAG_TMP/current" 2>/dev/null || true)"
new_thread="$(cat "$DIAG_TMP/new" 2>/dev/null || true)"

TUI_PIDS=""
if [ -n "$PORT" ] && command -v ss >/dev/null 2>&1; then
  TUI_PIDS="$(ss -tnp 2>/dev/null | awk -v p=":$PORT" '$0 ~ p { print }' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -nu | tr '\n' ' ')"
fi
if [ -z "$TUI_PIDS" ]; then
  TUI_PIDS="$(ps -eo pid=,args= 2>/dev/null | awk -v p="--remote ws://127.0.0.1:$PORT" '$0 ~ /codex/ && $0 ~ p && $0 !~ /codex-bridge/ { print $1 }' | tr '\n' ' ')"
fi
TUI_PIDS="$(printf '%s' "$TUI_PIDS" | sed "s/\b$SERVER_PID\b//g; s/\b$BRIDGE_PID\b//g" | xargs 2>/dev/null || true)"

process_state="UNKNOWN"
[ -n "$TUI_PIDS" ] && process_state="MATCH"
app_state="UNKNOWN"
if [ -n "$PORT" ] && [ "$BRIDGE_APP" = "ws://127.0.0.1:$PORT" ] && [ -n "$SERVER_PID" ]; then
  app_state="MATCH"
elif [ -n "$BRIDGE_APP" ] || [ -n "$PORT" ]; then
  app_state="MISMATCH"
fi
thread_state="UNKNOWN"
thread_reason="no-unique-current-thread"
if [ "$loaded_count" -eq 1 ] && [ "$BRIDGE_THREAD" = "$loaded_only" ] \
  && [ "$SEAT_THREAD" = "$BRIDGE_THREAD" ]; then
  thread_state="MATCH"
  thread_reason="single-loaded-thread-and-seat-bridge-match"
elif [ "$baseline_state" = "AVAILABLE" ] && [ "$new_count" -eq 1 ] \
  && [ "$BRIDGE_THREAD" = "$new_thread" ] \
  && { [ -z "$SEAT_THREAD" ] || [ "$SEAT_THREAD" = "$BRIDGE_THREAD" ]; }; then
  thread_state="MATCH"
  thread_reason="unique-baseline-delta-and-seat-bridge-match"
elif [ -n "$BRIDGE_THREAD" ] && [ -n "$SEAT_THREAD" ] \
  && [ "$BRIDGE_THREAD" != "$SEAT_THREAD" ] \
  && grep -Fxq "$BRIDGE_THREAD" "$DIAG_TMP/current"; then
  thread_state="MISMATCH"
  thread_reason="bridge-seat-mismatch"
fi
overall="MATCH"
for state in "$process_state" "$app_state" "$thread_state"; do
  [ "$state" = "MATCH" ] || { overall="$state"; [ "$state" = "MISMATCH" ] && break; }
done

echo "codex diagnosis: $overall"
echo "process: $process_state tui_pids=${TUI_PIDS:-unknown} app_server_pid=${SERVER_PID:-unknown} bridge_pid=${BRIDGE_PID:-unknown}"
echo "app-server: $app_state port=${PORT:-unknown} bridge_app=${BRIDGE_APP:-unknown}"
echo "thread: $thread_state seat=${SEAT_THREAD:-unknown} bridge=${BRIDGE_THREAD:-unknown}"
echo "loaded_threads: ${LOADED:-unknown}"
echo "thread-evidence: baseline_state=$baseline_state baseline_count=$baseline_count current_count=$loaded_count new_count=$new_count candidate=${new_thread:-unknown} reason=$thread_reason"
if [ -f "$META" ]; then
  awk -F= '/^(resume_error|self_test|self_test_status)=/ { print "meta: " $0 }' "$META"
fi
if [ -f "$BASE.log" ]; then
  echo "latest_bridge_log:"
  tail -n 5 "$BASE.log"
fi
[ "$overall" = "MATCH" ]
