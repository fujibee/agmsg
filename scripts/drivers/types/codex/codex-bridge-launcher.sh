#!/usr/bin/env bash
set -euo pipefail

# Runs outside Codex's tool sandbox and owns the app-server connection: it starts
# codex-bridge.js for this project's single codex identity.
#
# This legacy launcher is fail-closed: it launches only when its request file
# contains one exact thread id. Loaded-thread discovery and thread creation can
# select a different visible task and are forbidden.

TYPE="${1:?Usage: codex-bridge-launcher.sh <type> <project_path> <app_server> <parent_pid>}"
PROJECT="${2:?Missing project_path}"
APP_SERVER="${3:?Missing app_server}"
PARENT_PID="${4:?Missing parent_pid}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
REQUEST_FILE="$RUN_DIR/codex-bridge-request.$PROJECT_HASH"

# shellcheck source=../../../lib/node.sh
source "$SCRIPT_DIR/../../../lib/node.sh"
NODE_BIN="$(agmsg_resolve_node)"
TAB="$(printf '\t')"

mkdir -p "$RUN_DIR"

resolve_identity() {  # prints "team<TAB>name" lines for the project's codex roles
  "$SCRIPT_DIR/../../../identities.sh" "$PROJECT" "$TYPE" 2>/dev/null \
    | awk -v t="$TAB" 'NF >= 2 { print $1 t $2 }' \
    | sort -u
}

# actas may register the role a moment after launch, so retry while the parent
# (codex-monitor.sh) is alive. Proceed only when exactly one identity resolves.
team="" name=""
while kill -0 "$PARENT_PID" 2>/dev/null; do
  ids="$(resolve_identity || true)"
  count="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [ "$count" = "1" ]; then
    IFS="$TAB" read -r team name <<EOF
$ids
EOF
    [ -n "$team" ] && [ -n "$name" ] && break
    team="" name=""
  fi
  sleep 0.3
done
[ -n "$team" ] && [ -n "$name" ] || exit 0

pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
log="$RUN_DIR/codex-bridge.$team.$name.log"
: >"$log"
chmod 600 "$log"
# Records the app-server URL the live bridge was launched against, so a later
# launcher instance can tell a bridge bound to a stale app-server (old port,
# from before a codex upgrade) from one bound to the current server. See #197/#237.
appserver_file="$RUN_DIR/codex-bridge.$team.$name.appserver"
# An explicit AGMSG_CODEX_BRIDGE_CMD is a complete runnable (tests, custom
# wrappers) — run it as-is. Only the default codex-bridge.js is launched through
# a resolved Node, since its env-node shebang fails where a version-manager Node
# is not on PATH (#170).
if [ -n "${AGMSG_CODEX_BRIDGE_CMD:-}" ]; then
  bridge_run=("$AGMSG_CODEX_BRIDGE_CMD")
else
  bridge_run=("$NODE_BIN" "$SCRIPT_DIR/codex-bridge.js")
fi

bridge_pid_matches() {
  local pid="$1" app_server="$2" thread="$3" expected cmd
  [ -n "$app_server" ] && [ -n "$thread" ] || return 1
  case "$thread" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  expected="$SCRIPT_DIR/codex-bridge.js --project $PROJECT --type $TYPE --team $team --name $name --thread $thread --app-server $app_server"
  cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  case " $cmd " in *" $expected "*) return 0 ;; esac
  return 1
}

while kill -0 "$PARENT_PID" 2>/dev/null; do
  # Resolve an exact thread before the reuse check. Missing, reserved, or unsafe
  # values leave the launcher idle without creating another Codex task.
  thread_id=""
  req_app_server="$APP_SERVER"
  if [ -f "$REQUEST_FILE" ]; then
    request="$(cat "$REQUEST_FILE" 2>/dev/null || true)"
    if [ -n "$request" ]; then
      IFS="$TAB" read -r _rtype _rteam _rname _rthread _rapp <<EOF
$request
EOF
      case "${_rthread:-}" in
        ""|loaded|current|unresolved|*[!A-Za-z0-9._-]*) thread_id="" ;;
        *) thread_id="$_rthread" ;;
      esac
      [ -n "${_rapp:-}" ] && req_app_server="$_rapp"
    fi
  fi
  if [ -z "$thread_id" ]; then
    sleep 0.3
    continue
  fi

  if [ -f "$pidfile" ]; then
    bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null; then
      # Reuse only when the live bridge is bound to the CURRENT app-server. A
      # codex upgrade makes codex-monitor.sh kill the stale app-server and start a
      # fresh one on a new port (#237); a bridge still bound to the old URL stays
      # alive but delivers nothing. The bridge's own exit-on-close covers most of
      # this, but guard the race where the old bridge has not exited yet by the
      # time a new launcher re-checks: an app-server mismatch means tear it down.
      bound_url="$(cat "$appserver_file" 2>/dev/null || true)"
      bound_thread="$(sed -n 's/^thread=//p' "${pidfile%.pid}.meta" 2>/dev/null | head -1)"
      if bridge_pid_matches "$bridge_pid" "$bound_url" "$bound_thread" \
          && [ "$bound_url" = "$req_app_server" ] && [ "$bound_thread" = "$thread_id" ]; then
        sleep 0.3
        continue
      fi
      if bridge_pid_matches "$bridge_pid" "$bound_url" "$bound_thread"; then
        kill "$bridge_pid" 2>/dev/null || true
      fi
      rm -f "$pidfile" "$appserver_file"
    fi
  fi

  nohup "${bridge_run[@]}" \
    --project "$PROJECT" \
    --type "$TYPE" \
    --team "$team" \
    --name "$name" \
    --thread "$thread_id" \
    --app-server "$req_app_server" \
    >>"$log" 2>&1 &
  # Record what this bridge is bound to so a later launcher can detect staleness.
  printf '%s' "$req_app_server" > "$appserver_file"
  sleep 1
done

# The launcher owns only the exact legacy bridge recorded for this parent.
# Never signal a recycled pid or another project's bridge during TUI teardown.
bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
bound_url="$(cat "$appserver_file" 2>/dev/null || true)"
bound_thread="$(sed -n 's/^thread=//p' "${pidfile%.pid}.meta" 2>/dev/null | head -1)"
if [ -n "$bridge_pid" ] && kill -0 "$bridge_pid" 2>/dev/null \
    && bridge_pid_matches "$bridge_pid" "$bound_url" "$bound_thread"; then
  kill "$bridge_pid" 2>/dev/null || true
fi
