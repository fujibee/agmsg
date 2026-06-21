#!/usr/bin/env bash
set -euo pipefail

# Launch Codex with agmsg's app-server bridge enabled.
#
# This is a beta convenience wrapper: it hides the shared app-server socket and
# lets session-start.sh launch codex-bridge.js in the background once Codex
# exposes CODEX_THREAD_ID to hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck source=lib/hash.sh
source "$SCRIPT_DIR/lib/hash.sh"

PROJECT="$(pwd)"
SOCKET_PATH=""
CODEX_COMMAND="resume"
CODEX_ARGS=()
REAL_CODEX="${AGMSG_REAL_CODEX:-codex}"

usage() {
  cat <<EOF
Usage: codex-monitor.sh [--project <path>] [--codex-command <codex|resume>] [-- <args...>]

Starts/reuses an agmsg-managed Codex app-server on a loopback ws:// port,
enables agmsg Codex bridge delivery for this project, then execs:
  codex resume --remote ws://127.0.0.1:<port>

(--socket-path is accepted for compatibility but ignored: codex 0.141+ requires
a ws:// transport for --remote. See #170.)
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --project)
      PROJECT="${2:?--project requires a path}"
      shift 2
      ;;
    --socket-path)
      SOCKET_PATH="${2:?--socket-path requires a path}"
      shift 2
      ;;
    --codex-command)
      CODEX_COMMAND="${2:?--codex-command requires codex or resume}"
      shift 2
      ;;
    --)
      shift
      CODEX_ARGS=("$@")
      break
      ;;
    *)
      CODEX_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$CODEX_COMMAND" in
  codex|resume) ;;
  *)
    echo "codex-monitor: --codex-command must be 'codex' or 'resume'" >&2
    exit 1
    ;;
esac

PROJECT="$(cd "$PROJECT" && pwd)"
PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
SERVER_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.log"
SERVER_PID="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"
PORT_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.port"

mkdir -p "$RUN_DIR"

# codex 0.141+ accepts only ws:// (not unix://) for the TUI's --remote, so the
# shared app-server listens on a loopback ws port instead of a unix socket. The
# port is recorded per project so a second monitor reuses a live server. See #170.
port_alive() {  # $1 = port; succeeds if something is accepting on 127.0.0.1:$1
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

PORT=""
if [ -f "$PORT_FILE" ] && [ -f "$SERVER_PID" ]; then
  existing_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
  existing_pid="$(cat "$SERVER_PID" 2>/dev/null || true)"
  # Reuse only when OUR recorded app-server is still alive AND its port answers,
  # so a foreign process that grabbed the same port after ours died is not
  # mistaken for the bridge app-server.
  if [ -n "$existing_port" ] && [ -n "$existing_pid" ] \
    && kill -0 "$existing_pid" 2>/dev/null && port_alive "$existing_port"; then
    PORT="$existing_port"
  fi
fi

if [ -z "$PORT" ]; then
  # Let the app-server pick a free loopback port (--listen ws://127.0.0.1:0) and
  # report it ("listening on: ws://127.0.0.1:<port>"). This keeps codex-monitor.sh
  # free of any Node dependency — only the bridge (codex-bridge.js) needs Node, and
  # it degrades on its own if Node is missing rather than taking down the TUI. See #170.
  : > "$SERVER_LOG"
  "$REAL_CODEX" app-server --listen "ws://127.0.0.1:0" >>"$SERVER_LOG" 2>&1 &
  echo "$!" > "$SERVER_PID"
  for _ in $(seq 1 100); do
    PORT="$(sed -n 's#.*listening on: ws://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' "$SERVER_LOG" | head -1)"
    [ -n "$PORT" ] && break
    sleep 0.1
  done
  if [ -z "$PORT" ]; then
    echo "codex-monitor: app-server did not report a listening port" >&2
    echo "codex-monitor: see $SERVER_LOG" >&2
    exit 1
  fi
  printf '%s' "$PORT" > "$PORT_FILE"
fi

if ! port_alive "$PORT"; then
  echo "codex-monitor: app-server did not start on ws://127.0.0.1:$PORT" >&2
  echo "codex-monitor: see $SERVER_LOG" >&2
  exit 1
fi
SOCKET_URL="ws://127.0.0.1:$PORT"

"$SCRIPT_DIR/delivery.sh" set monitor codex "$PROJECT" >/dev/null

export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
export AGMSG_CODEX_BRIDGE_LAUNCHER=1

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" >/dev/null 2>&1 &

cd "$PROJECT"
case "$CODEX_COMMAND" in
  codex)
    exec "$REAL_CODEX" --remote "$SOCKET_URL" "${CODEX_ARGS[@]}"
    ;;
  resume)
    exec "$REAL_CODEX" resume --remote "$SOCKET_URL" "${CODEX_ARGS[@]}"
    ;;
esac
