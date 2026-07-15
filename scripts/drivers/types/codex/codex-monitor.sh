#!/usr/bin/env bash
set -euo pipefail

# Launch Codex with agmsg's app-server bridge enabled.
#
# This is a beta convenience wrapper: it hides the shared app-server socket and
# lets SessionStart publish its stdin session_id to the out-of-sandbox launcher
# as the exact app-server thread route.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/compat.sh
source "$SCRIPT_DIR/../../../lib/compat.sh"
# shellcheck source=../../../lib/codex-lease.sh
source "$SCRIPT_DIR/../../../lib/codex-lease.sh"

PROJECT="$(pwd)"
SOCKET_PATH=""
CODEX_COMMAND="resume"
CODEX_ARGS=()
REAL_CODEX="${AGMSG_REAL_CODEX:-codex}"
IDENTITY_TEAM="${AGMSG_CODEX_TEAM:-}"
IDENTITY_NAME="${AGMSG_CODEX_NAME:-}"

usage() {
  cat <<EOF
Usage: codex-monitor.sh [--project <path>] [--team <team> --name <agent>] [--codex-command <codex|resume>] [-- <args...>]

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
    --team)
      IDENTITY_TEAM="${2:?--team requires a team}"
      shift 2
      ;;
    --name)
      IDENTITY_NAME="${2:?--name requires an agent name}"
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

if { [ -n "$IDENTITY_TEAM" ] && [ -z "$IDENTITY_NAME" ]; } \
  || { [ -z "$IDENTITY_TEAM" ] && [ -n "$IDENTITY_NAME" ]; }; then
  echo "codex-monitor: --team and --name must be provided together" >&2
  exit 1
fi

PROJECT="$(cd "$PROJECT" && pwd -P)"

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
SERVER_PID="$RUN_DIR/codex-app-server.$PROJECT_HASH.pid"
PORT_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.port"
# Records the codex version that launched the reusable app-server. A TUI from a
# newer/older codex can't speak to an app-server from a different build, so a
# stale server left running across a codex upgrade must not be reused.
VERSION_FILE="$RUN_DIR/codex-app-server.$PROJECT_HASH.version"
SERVER_RECORD="$(codex_appserver_record_path "$PROJECT_HASH")"
CODEX_VERSION="$("$REAL_CODEX" --version 2>/dev/null || true)"

mkdir -p "$RUN_DIR"
codex_appserver_ref_gc "$PROJECT_HASH" || true

# codex 0.141+ accepts only ws:// (not unix://) for the TUI's --remote, so the
# shared app-server listens on a loopback ws port instead of a unix socket. The
# port is recorded per project so a second monitor reuses a live server. See #170.
port_alive() {  # $1 = port; succeeds if something is accepting on 127.0.0.1:$1
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

PORT=""
SERVER_GENERATION=""
SERVER_LOG=""

publish_ready_record() { # generation pid-domain pid port
  local generation="$1" domain="$2" pid="$3" port="$4"
  codex_record_write_ready "$PROJECT_HASH" "$generation" "$CODEX_VERSION" "$domain" "$pid" "$port"
  printf '%s' "$pid" >"$SERVER_PID"
  printf '%s' "$port" >"$PORT_FILE"
  printf '%s' "$CODEX_VERSION" >"$VERSION_FILE"
}

for lifecycle_attempt in 1 2 3 4; do
  mode=""
  codex_lifecycle_lock_acquire "$PROJECT_HASH" || exec_plain_codex

  # Upgrade compatibility: import a verified legacy pid/port/version tuple into
  # the new record once, without changing the old files yet.
  if [ ! -f "$SERVER_RECORD" ] && [ -f "$SERVER_PID" ] && [ -f "$PORT_FILE" ]; then
    legacy_pid="$(cat "$SERVER_PID" 2>/dev/null || true)"
    legacy_port="$(cat "$PORT_FILE" 2>/dev/null || true)"
    legacy_version="$(cat "$VERSION_FILE" 2>/dev/null || true)"
    legacy_cmd="$(compat_get_cmdline "$legacy_pid" 2>/dev/null || true)"
    if [ -n "$legacy_pid" ] && [ -n "$legacy_port" ] \
      && compat_pid_alive_msys "$legacy_pid" && port_alive "$legacy_port" \
      && [ -z "$CODEX_VERSION" -o "$legacy_version" = "$CODEX_VERSION" ]; then
      case "$legacy_cmd" in
        *codex*app-server*) publish_ready_record "legacy-$legacy_pid" msys "$legacy_pid" "$legacy_port" ;;
      esac
    fi
  fi

  status="$(codex_lease_field "$SERVER_RECORD" status 2>/dev/null || true)"
  record_generation="$(codex_lease_field "$SERVER_RECORD" generation 2>/dev/null || true)"
  record_version="$(codex_lease_field "$SERVER_RECORD" version 2>/dev/null || true)"

  if [ "$status" = ready ]; then
    record_pid="$(codex_lease_field "$SERVER_RECORD" pid 2>/dev/null || true)"
    record_domain="$(codex_lease_field "$SERVER_RECORD" pid_domain 2>/dev/null || true)"
    record_port="$(codex_lease_field "$SERVER_RECORD" port 2>/dev/null || true)"
    record_creation="$(codex_lease_field "$SERVER_RECORD" pid_creation 2>/dev/null || true)"
    current_creation="$(codex_pid_creation_domain "$record_domain" "$record_pid" 2>/dev/null || true)"
    record_pid_state="$(codex_pid_state_domain "$record_domain" "$record_pid")"
    record_cmd="$(codex_pid_cmdline_domain "$record_domain" "$record_pid" 2>/dev/null || true)"
    if [ -n "$record_pid" ] && [ "$record_pid_state" = unknown ]; then
      codex_lifecycle_lock_release "$PROJECT_HASH"
      echo "codex-monitor: app-server liveness is unknown; keeping its record and refusing a duplicate" >&2
      exec_plain_codex
    fi
    if [ -n "$record_pid" ] && [ -n "$record_port" ] \
      && [ "$record_pid_state" = alive ] && port_alive "$record_port" \
      && { { [ -n "$record_creation" ] && [ -z "$current_creation" ]; } || [ -z "$record_cmd" ]; }; then
      codex_lifecycle_lock_release "$PROJECT_HASH"
      echo "codex-monitor: app-server identity is unknown; keeping its record and refusing a duplicate" >&2
      exec_plain_codex
    fi
    if [ -n "$record_pid" ] && [ -n "$record_port" ] \
      && [ "$record_pid_state" = alive ] && port_alive "$record_port" \
      && { [ -z "$record_creation" ] || { [ -n "$current_creation" ] && [ "$record_creation" = "$current_creation" ]; }; } \
      && { [ -z "$CODEX_VERSION" ] || [ "$record_version" = "$CODEX_VERSION" ]; }; then
      case "$record_cmd" in
        *codex*app-server*)
          PORT="$record_port"; SERVER_GENERATION="$record_generation"
          codex_lifecycle_lock_release "$PROJECT_HASH"
          break
          ;;
      esac
    fi

    refs_dir="$(codex_appserver_refs_dir "$PROJECT_HASH")"
    if find "$refs_dir" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
      codex_lifecycle_lock_release "$PROJECT_HASH"
      echo "codex-monitor: incompatible app-server is still referenced by another TUI" >&2
      exec_plain_codex
    fi
    case "$record_cmd" in
      *codex*app-server*) codex_pid_kill_domain "$record_domain" "$record_pid" || true ;;
    esac
    rm -f "$SERVER_RECORD" "$SERVER_PID" "$PORT_FILE" "$VERSION_FILE"
    status=""
  fi

  if [ "$status" = starting ]; then
    starter_pid="$(codex_lease_field "$SERVER_RECORD" starter_msys_pid 2>/dev/null || true)"
    if [ -n "$starter_pid" ] && compat_pid_alive_msys "$starter_pid"; then
      mode=wait
      SERVER_GENERATION="$record_generation"
    else
      marker="$(codex_appserver_marker_path "$PROJECT_HASH" "$record_generation")"
      if [ -f "$marker" ] && { [ -z "$CODEX_VERSION" ] || [ "$record_version" = "$CODEX_VERSION" ]; }; then
        mode=adopt
        SERVER_GENERATION="$record_generation"
        # Claim the abandoned reservation without changing generation. A
        # second successor now sees this adopter as the live starter and waits
        # instead of racing a second adopt/publish path.
        codex_record_write_starting "$PROJECT_HASH" "$SERVER_GENERATION" "$record_version" "$$"
      fi
    fi
  fi

  if [ -z "$mode" ]; then
    mode=start
    SERVER_GENERATION="$(codex_lease_generation)"
    codex_record_write_starting "$PROJECT_HASH" "$SERVER_GENERATION" "$CODEX_VERSION" "$$"
  fi
  codex_lifecycle_lock_release "$PROJECT_HASH"

  if [ "$mode" = wait ]; then
    for _ in $(seq 1 100); do
      [ "$(codex_lease_field "$SERVER_RECORD" status 2>/dev/null || true)" = ready ] && break
      compat_pid_alive_msys "$starter_pid" || break
      sleep 0.1
    done
    continue
  fi

  if [ "$mode" = adopt ]; then
    marker_pid="$(codex_lease_field "$marker" spawned_pid 2>/dev/null || true)"
    marker_domain="$(codex_lease_field "$marker" spawned_pid_domain 2>/dev/null || true)"
    marker_creation="$(codex_lease_field "$marker" spawned_creation 2>/dev/null || true)"
    SERVER_LOG="$(codex_lease_field "$marker" log_path 2>/dev/null || true)"
    for _ in $(seq 1 100); do
      [ "$(codex_lease_field "$SERVER_RECORD" generation 2>/dev/null || true)" = "$SERVER_GENERATION" ] || break
      codex_pid_alive_domain "$marker_domain" "$marker_pid" || break
      current_creation="$(codex_pid_creation_domain "$marker_domain" "$marker_pid" 2>/dev/null || true)"
      { [ -z "$marker_creation" ] || { [ -n "$current_creation" ] && [ "$marker_creation" = "$current_creation" ]; }; } || break
      marker_cmd="$(codex_pid_cmdline_domain "$marker_domain" "$marker_pid" 2>/dev/null || true)"
      case "$marker_cmd" in *codex*app-server*) ;; *) break ;; esac
      PORT="$(sed -n 's#.*listening on: ws://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' "$SERVER_LOG" 2>/dev/null | head -1)"
      [ -n "$PORT" ] && port_alive "$PORT" && break
      PORT=""
      sleep 0.1
    done
    if [ -n "$PORT" ]; then
      codex_lifecycle_lock_acquire "$PROJECT_HASH" || exec_plain_codex
      if [ "$(codex_lease_field "$SERVER_RECORD" generation 2>/dev/null || true)" = "$SERVER_GENERATION" ]; then
        publish_ready_record "$SERVER_GENERATION" "$marker_domain" "$marker_pid" "$PORT"
        rm -f "$marker"
      else
        PORT=""
      fi
      codex_lifecycle_lock_release "$PROJECT_HASH"
      [ -n "$PORT" ] && break
    fi
    # Failed adoption: the next loop claims a fresh generation after removing
    # only the still-matching abandoned reservation.
    codex_lifecycle_lock_acquire "$PROJECT_HASH" || exec_plain_codex
    if [ "$(codex_lease_field "$SERVER_RECORD" generation 2>/dev/null || true)" = "$SERVER_GENERATION" ]; then
      rm -f "$SERVER_RECORD"
    fi
    codex_lifecycle_lock_release "$PROJECT_HASH"
    PORT=""
    continue
  fi

  SERVER_LOG="$RUN_DIR/codex-app-server.$PROJECT_HASH.$SERVER_GENERATION.log"
  : >"$SERVER_LOG"
  "$REAL_CODEX" app-server --listen "ws://127.0.0.1:0" >>"$SERVER_LOG" 2>&1 &
  server_bg="$!"
  codex_marker_write "$PROJECT_HASH" "$SERVER_GENERATION" msys "$server_bg" "$SERVER_LOG"
  for _ in $(seq 1 100); do
    PORT="$(sed -n 's#.*listening on: ws://127\.0\.0\.1:\([0-9][0-9]*\).*#\1#p' "$SERVER_LOG" | head -1)"
    [ -n "$PORT" ] && port_alive "$PORT" && break
    PORT=""
    compat_pid_alive_msys "$server_bg" || break
    sleep 0.1
  done
  if [ -z "$PORT" ]; then
    codex_pid_kill_domain msys "$server_bg" || true
    codex_lifecycle_lock_acquire "$PROJECT_HASH" || true
    [ "$(codex_lease_field "$SERVER_RECORD" generation 2>/dev/null || true)" = "$SERVER_GENERATION" ] && rm -f "$SERVER_RECORD"
    codex_lifecycle_lock_release "$PROJECT_HASH" || true
    rm -f "$(codex_appserver_marker_path "$PROJECT_HASH" "$SERVER_GENERATION")"
    continue
  fi
  codex_lifecycle_lock_acquire "$PROJECT_HASH" || exec_plain_codex
  if [ "$(codex_lease_field "$SERVER_RECORD" generation 2>/dev/null || true)" = "$SERVER_GENERATION" ]; then
    publish_ready_record "$SERVER_GENERATION" msys "$server_bg" "$PORT"
    rm -f "$(codex_appserver_marker_path "$PROJECT_HASH" "$SERVER_GENERATION")"
  else
    codex_pid_kill_domain msys "$server_bg" || true
    PORT=""
  fi
  codex_lifecycle_lock_release "$PROJECT_HASH"
  [ -n "$PORT" ] && break
done

if [ -z "$PORT" ]; then
  echo "codex-monitor: app-server lifecycle did not reach ready; starting codex without the agmsg bridge" >&2
  [ -n "$SERVER_LOG" ] && echo "codex-monitor: see $SERVER_LOG" >&2
  exec_plain_codex
fi

if ! port_alive "$PORT"; then
  echo "codex-monitor: app-server not reachable on ws://127.0.0.1:$PORT; starting codex without the agmsg bridge" >&2
  echo "codex-monitor: see $SERVER_LOG" >&2
  exec_plain_codex
fi
SOCKET_URL="ws://127.0.0.1:$PORT"

release_unclaimed_appserver() {
  # No TUI ref has been published yet. The normal last-ref cleanup is safe here:
  # it leaves a server used by another TUI alone and removes only this matching
  # generation when the immutable ref set is empty.
  codex_appserver_ref_remove_and_cleanup "$PROJECT_HASH" \
    "$(codex_appserver_refs_dir "$PROJECT_HASH")/.unclaimed-$$" "$SERVER_GENERATION" || true
}

if ! "$SCRIPT_DIR/../../../delivery.sh" set monitor codex "$PROJECT" >/dev/null; then
  echo "codex-monitor: could not install/confirm monitor hooks for this project" >&2
  release_unclaimed_appserver
  exec_plain_codex
fi

export AGMSG_CODEX_BRIDGE=1
export AGMSG_CODEX_BRIDGE_APP_SERVER="$SOCKET_URL"
export AGMSG_CODEX_BRIDGE_LAUNCHER=1
TUI_GENERATION="$(codex_lease_generation)"
REQUEST_FILE="$(codex_monitor_request_path "$PROJECT_HASH" "$TUI_GENERATION")"
STATE_FILE="$(codex_monitor_state_path "$PROJECT_HASH" "$TUI_GENERATION")"
PROVISIONAL_REF_NAME="codex-startup-ref.$TUI_GENERATION"
if ! PROVISIONAL_REF="$(codex_appserver_ref_add_provisional \
  "$PROJECT_HASH" "$PROVISIONAL_REF_NAME" "$SERVER_GENERATION" "$TUI_GENERATION" "$$")"; then
  echo "codex-monitor: could not reserve the ready app-server for this TUI" >&2
  release_unclaimed_appserver
  exec_plain_codex
fi
export AGMSG_CODEX_TUI_GENERATION="$TUI_GENERATION"
export AGMSG_CODEX_BRIDGE_REQUEST_FILE="$REQUEST_FILE"
export AGMSG_CODEX_MONITOR_STATE_FILE="$STATE_FILE"
export AGMSG_CODEX_TEAM="$IDENTITY_TEAM"
export AGMSG_CODEX_NAME="$IDENTITY_NAME"

# Native Node cannot execute an MSYS /usr/bin/bash path and a bare `bash` may
# resolve to Windows' WSL launcher.  Publish the exact Git Bash executable used
# by this wrapper so every bridge helper stays in the same runtime.
if [ -z "${GIT_BASH:-}" ] && [ -z "${AGMSG_BASH:-}" ] && command -v cygpath >/dev/null 2>&1; then
  AGMSG_BASH="$(cygpath -w "$(command -v bash)" 2>/dev/null || true)"
  export AGMSG_BASH
fi
codex_monitor_state_write "$STATE_FILE" waiting_first_turn

launcher_cmd="${AGMSG_CODEX_BRIDGE_LAUNCHER_CMD:-$SCRIPT_DIR/codex-bridge-launcher.sh}"
launcher_log="$RUN_DIR/codex-bridge-launcher.$PROJECT_HASH.$TUI_GENERATION.log"
"$launcher_cmd" codex "$PROJECT" "$SOCKET_URL" "$$" "$TUI_GENERATION" "$REQUEST_FILE" \
  "$IDENTITY_TEAM" "$IDENTITY_NAME" "$STATE_FILE" "$PROVISIONAL_REF" >>"$launcher_log" 2>&1 &

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
