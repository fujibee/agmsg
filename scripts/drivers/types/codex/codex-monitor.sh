#!/usr/bin/env bash
set -euo pipefail

# Launch Codex with agmsg's app-server bridge enabled.
#
# This is a convenience wrapper: it hides the shared app-server socket and
# lets session-start.sh launch codex-bridge.js in the background once Codex
# exposes CODEX_THREAD_ID to hooks.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# This starts the codex app-server and the bridge launcher, both of which
# outlive it. The `3>&- 4>&-` on those spawn lines closes the two descriptors
# we can name; the harness's is not one of them. See lib/close-fds.sh.
# shellcheck source=../../../lib/close-fds.sh
source "$SCRIPT_DIR/../../../lib/close-fds.sh"
agmsg_close_inherited_fds
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/compat.sh
source "$SCRIPT_DIR/../../../lib/compat.sh"
# _agmsg_pid_alive for the app-server reuse decision below.
# shellcheck source=../../../lib/instance-id.sh
source "$SCRIPT_DIR/../../../lib/instance-id.sh"
# agmsg_write_atomic: the port file is published, not just written — a reader
# turns its contents into a URL, and a numeric PREFIX of a real port is itself
# a valid port, so no reader-side check can tell a half-written file from a
# good one. Only the writer can make that state unobservable.
# shellcheck source=../../../lib/registry-lock.sh
source "$SCRIPT_DIR/../../../lib/registry-lock.sh"

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

# Fail-open: never let a broken bridge block codex. If the agmsg app-server can't
# be brought up — e.g. a codex release changes the app-server interface and the
# launch/port detection fails — hand off to a plain codex session (no --remote
# bridge) instead of erroring out. The user keeps a working codex; only the
# agmsg monitor delivery is skipped for this launch.
#
# This is a LOUD fallback: it only runs on UNEXPECTED failure (the explicit
# AGMSG_CODEX_SHIM_DISABLE=1 bypass is handled in codex-shim.sh and never reaches
# here), so it must tell the user, on screen, that real-time delivery is off —
# otherwise message receipt stops silently. The earlier echoes give the specific
# reason + log path; this prints the one-line summary just before handoff.
exec_plain_codex() {
  echo "agmsg: Codex monitor bridge unavailable - launching plain Codex. Real-time agmsg delivery is OFF this session (messages still queue; check your inbox manually). Likely cause: the Codex app-server interface changed in 0.142+. Fix in progress." >&2
  cd "$PROJECT" 2>/dev/null || true
  case "$CODEX_COMMAND" in
    codex)  exec "$REAL_CODEX" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} ;;
    resume) exec "$REAL_CODEX" resume ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"} ;;
  esac
}

PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
SERVER_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.log"
SERVER_PID="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"
PORT_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.port"
# Records the codex version that launched the reusable app-server. A TUI from a
# newer/older codex can't speak to an app-server from a different build, so a
# stale server left running across a codex upgrade must not be reused.
VERSION_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.version"
CODEX_VERSION="$("$REAL_CODEX" --version 2>/dev/null || true)"

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
  existing_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
  # Reuse only when OUR recorded app-server is still alive AND its port answers,
  # so a foreign process that grabbed the same port after ours died is not
  # mistaken for the bridge app-server.
  #
  # _local for the same reason as the wait loop below: this file records $! (see
  # the `> "$SERVER_PID"` further down), and reading it back through a pidfile
  # does not move the number into the Windows pid space. Asking tasklist about it
  # never matches, so a live app-server reads as dead and every launch starts
  # another one beside it.
  if [ -n "$existing_port" ] && [ -n "$existing_pid" ] \
    && _agmsg_pid_alive_local "$existing_pid" && port_alive "$existing_port"; then
    # Confirm the recorded pid is actually OUR codex app-server before trusting OR
    # killing it: a recycled pid could belong to an unrelated process while the
    # recorded port happens to answer via something else. Only reuse/kill when the
    # cmdline proves it.
    existing_cmd="$(compat_get_cmdline "$existing_pid" 2>/dev/null || true)"
    case "$existing_cmd" in
      *codex*app-server*)
        # ...and only when it was launched by THIS codex build. A codex upgrade
        # leaves the old app-server running on the recorded port; the port still
        # answers, but a new TUI's --remote can't speak to the old server and dies
        # with "failed to connect to remote app server". Treat a version mismatch
        # as stale: kill the (confirmed-ours) old server and start fresh. If we
        # can't read the current version, fall back to liveness-only reuse.
        if [ -z "$CODEX_VERSION" ] || [ "$existing_version" = "$CODEX_VERSION" ]; then
          PORT="$existing_port"
        else
          kill "$existing_pid" 2>/dev/null || true
          rm -f "$PORT_FILE" "$SERVER_PID" "$VERSION_FILE"
        fi
        ;;
      *)
        # Can't confirm it's our app-server (pid reuse / a foreign listener on the
        # recorded port): do NOT kill it. Drop the stale artifacts and start a
        # fresh server of our own.
        rm -f "$PORT_FILE" "$SERVER_PID" "$VERSION_FILE"
        ;;
    esac
  fi
fi

if [ -z "$PORT" ]; then
  # Let the app-server pick a free loopback port (--listen ws://127.0.0.1:0) and
  # report it ("listening on: ws://127.0.0.1:<port>"). This keeps codex-monitor.sh
  # free of any Node dependency — only the bridge (codex-bridge.js) needs Node, and
  # it degrades on its own if Node is missing rather than taking down the TUI. See #170.
  : > "$SERVER_LOG"
  # fds 3 and 4 are closed for the same reason remote.sh closes them around the
  # sync engine: under bats, fd 3 is the TAP pipe, and a daemon that inherits it
  # holds the whole test file open until the CI timeout. This app-server is
  # built to outlive its caller -- that is what the pidfile and the reuse checks
  # below are for -- so it is exactly the shape that keeps the pipe open.
  "$REAL_CODEX" app-server --listen "ws://127.0.0.1:0" >>"$SERVER_LOG" 2>&1 3>&- 4>&- &
  server_bg="$!"
  echo "$server_bg" > "$SERVER_PID"
  # codex 0.144+ colorizes this banner even when stdout is a redirected file
  # (NO_COLOR is ignored), so strip ANSI SGR sequences before matching.
  ansi_esc="$(printf '\033')"
  for _ in $(seq 1 100); do
    PORT="$(sed -n -e "s/${ansi_esc}\[[0-9;]*m//g" -e 's#.*listening on: ws://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' "$SERVER_LOG" | head -1)"
    [ -n "$PORT" ] && break
    # Stop waiting the moment the app-server exits (e.g. a codex release dropped
    # `app-server --listen ws://`): no point burning the full timeout before we
    # fail open.
    #
    # _local, deliberately: this pid came from $! in this shell, so it is numbered
    # in the MSYS pid space, and `tasklist` -- which is what the plain helper asks
    # under MSYSTEM -- has no record of it. It answered "dead" on the first pass
    # here, seconds before the banner, and every Windows launch since 1.1.12 fell
    # back to plain codex with no bridge (#567). Not a bare `kill -0` either: the
    # EPERM reading still has to hold, or a sandbox that cannot signal our own
    # child fails us open the same way (#505).
    _agmsg_pid_alive_local "$server_bg" || break
    sleep 0.1
  done
  if [ -z "$PORT" ]; then
    echo "codex-monitor: app-server did not report a listening port; starting codex without the agmsg bridge" >&2
    echo "codex-monitor: see $SERVER_LOG" >&2
    kill "$server_bg" 2>/dev/null || true
    rm -f "$SERVER_PID" "$VERSION_FILE"
    exec_plain_codex
  fi
  agmsg_write_atomic "$PORT_FILE" "$PORT"
  # Stamp the version that owns this server so a later launch from a different
  # codex build recreates it instead of reusing a stale one.
  printf '%s' "$CODEX_VERSION" > "$VERSION_FILE"
fi

if ! port_alive "$PORT"; then
  echo "codex-monitor: app-server not reachable on ws://127.0.0.1:$PORT; starting codex without the agmsg bridge" >&2
  echo "codex-monitor: see $SERVER_LOG" >&2
  exec_plain_codex
fi
SOCKET_URL="ws://127.0.0.1:$PORT"

"$SCRIPT_DIR/../../../delivery.sh" set monitor codex "$PROJECT" >/dev/null

export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
export AGMSG_CODEX_BRIDGE_LAUNCHER=1

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
# Same guard: the launcher is detached on purpose and outlives this script, so
# an inherited fd 3 would outlive the test file that started it.
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" >/dev/null 2>&1 3>&- 4>&- &

cd "$PROJECT"
# Guard the array expansion: under bash 3.2 + `set -u`, "${CODEX_ARGS[@]}" on an
# empty array errors with "unbound variable" (a no-arg `codex`/`codex resume`).
case "$CODEX_COMMAND" in
  codex)
    exec "$REAL_CODEX" --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
  resume)
    exec "$REAL_CODEX" resume --remote "$SOCKET_URL" ${CODEX_ARGS[@]+"${CODEX_ARGS[@]}"}
    ;;
esac
