#!/usr/bin/env bash
set -euo pipefail
umask 077
unset CODEX_APP_SERVER_WS_URL

# LaunchAgent entry point. ctl writes private capabilities/endpoints before the
# job starts. The token values are read by the relay process from 0600 files and
# never appear in argv, the plist, status, or logs.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="${AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR:-$SKILL_DIR/run}"

# shellcheck source=../../../lib/node.sh
source "$SCRIPT_DIR/../../../lib/node.sh"

HOST="${AGMSG_CODEX_DESKTOP_RELAY_HOST:-127.0.0.1}"
PORT="${AGMSG_CODEX_DESKTOP_RELAY_PORT:-49643}"
NODE_BIN="$(agmsg_resolve_node)"

mkdir -p "$RUN_DIR"

child_pid=""
stopping=0
stop_child() {
  stopping=1
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    kill -TERM "$child_pid" 2>/dev/null || true
  fi
}
trap stop_child INT TERM

delay=2
while :; do
  started_at="$(date +%s)"
  set +e
  "$NODE_BIN" "$SCRIPT_DIR/codex-desktop-relay.js" \
    --host "$HOST" \
    --port "$PORT" \
    --desktop-token-file "$RUN_DIR/codex-desktop-relay.desktop-token" \
    --bridge-token-file "$RUN_DIR/codex-desktop-relay.bridge-token" \
    --health "$RUN_DIR/codex-desktop-relay.health" \
    --port-file "$RUN_DIR/codex-desktop-relay.port" \
    --pid-file "$RUN_DIR/codex-desktop-relay.pid" \
    --parent-pid "$$" &
  child_pid=$!
  wait "$child_pid"
  status=$?
  child_pid=""
  set -e
  [ "$stopping" = "0" ] || exit 0
  # EX_USAGE/configuration errors need a corrected install, not a two-second
  # restart loop. Transient app-server exits are retried with capped backoff.
  [ "$status" -ne 64 ] || exit 0
  if [ $(( $(date +%s) - started_at )) -ge 300 ]; then
    delay=2
  fi
  sleep "$delay"
  [ "$delay" -ge 60 ] || delay=$((delay * 2))
  [ "$delay" -le 60 ] || delay=60
done
