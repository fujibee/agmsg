#!/usr/bin/env bash
set -euo pipefail

# Runs outside Codex's tool sandbox and owns the app-server connection: it starts
# codex-bridge.js for this project's single codex identity.
#
# Before the first turn there is no SessionStart payload. The launcher waits
# instead of guessing from the app-server's project-wide loaded set, which may
# contain an older same-project task. On the first turn, current Codex hooks
# provide stdin session_id as a generation-scoped exact route. See #170, #41.

TYPE="${1:?Usage: codex-bridge-launcher.sh <type> <project_path> <app_server> <parent_pid> [generation request_file team name state_file provisional_ref]}"
PROJECT="${2:?Missing project_path}"
APP_SERVER="${3:?Missing app_server}"
PARENT_PID="${4:?Missing parent_pid}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck source=../../../lib/hash.sh
source "$SCRIPT_DIR/../../../lib/hash.sh"
# shellcheck source=../../../lib/codex-lease.sh
source "$SCRIPT_DIR/../../../lib/codex-lease.sh"
PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"
TUI_GENERATION="${5:-$(codex_lease_generation)}"
REQUEST_FILE="${6:-$(codex_monitor_request_path "$PROJECT_HASH" "$TUI_GENERATION")}"
REQUESTED_TEAM="${7:-}"
REQUESTED_NAME="${8:-}"
STATE_FILE="${9:-$(codex_monitor_state_path "$PROJECT_HASH" "$TUI_GENERATION")}"
PROVISIONAL_REF="${10:-}"
DISABLED_FILE="$RUN_DIR/codex-monitor-disabled.$PROJECT_HASH"
EXPECTED_REQUEST_FILE="$(codex_monitor_request_path "$PROJECT_HASH" "$TUI_GENERATION")"
if [ "$REQUEST_FILE" != "$EXPECTED_REQUEST_FILE" ]; then
  codex_monitor_state_write "$STATE_FILE" request_invalid path_mismatch
  exit 1
fi

# shellcheck source=../../../lib/node.sh
source "$SCRIPT_DIR/../../../lib/node.sh"
TAB="$(printf '\t')"

# shellcheck source=../../../lib/resolve-project.sh
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# Canonicalize once so the record's project (stored from the codex actas flow's
# cwd) compares equal to this launcher's project even across a symlinked path.
PROJECT_PHYS="$(agmsg_canonical_path "$PROJECT" 2>/dev/null || printf '%s' "$PROJECT")"

mkdir -p "$RUN_DIR"

resolve_identity() {  # prints "team<TAB>name" lines for the project's codex roles
  "$SCRIPT_DIR/../../../identities.sh" "$PROJECT" "$TYPE" 2>/dev/null \
    | awk -v t="$TAB" 'NF >= 2 { print $1 t $2 }' \
    | sort -u
}

current_tui_lease=""
current_appserver_ref=""
appserver_generation=""
resolved_request_thread=""
if [ -n "$PROVISIONAL_REF" ]; then
  expected_refs_dir="$(codex_appserver_refs_dir "$PROJECT_HASH")"
  case "$PROVISIONAL_REF" in "$expected_refs_dir"/*) ;; *) PROVISIONAL_REF="" ;; esac
  if [ -n "$PROVISIONAL_REF" ] && [ -f "$PROVISIONAL_REF" ] \
    && [ "$(codex_lease_field "$PROVISIONAL_REF" ref_kind 2>/dev/null || true)" = startup ] \
    && [ "$(codex_lease_field "$PROVISIONAL_REF" lease_generation 2>/dev/null || true)" = "$TUI_GENERATION" ]; then
    current_appserver_ref="$PROVISIONAL_REF"
    appserver_generation="$(codex_lease_field "$PROVISIONAL_REF" generation 2>/dev/null || true)"
  else
    codex_monitor_state_write "$STATE_FILE" startup_ref_invalid
    exit 1
  fi
fi

cleanup_tui_lease() {
  codex_lease_compare_delete "$REQUEST_FILE" "$TUI_GENERATION"
  [ -n "$current_tui_lease" ] && codex_lease_compare_delete "$current_tui_lease" "$TUI_GENERATION"
  if [ -n "$current_appserver_ref" ] && [ -n "$appserver_generation" ]; then
    codex_appserver_ref_remove_and_cleanup "$PROJECT_HASH" "$current_appserver_ref" "$appserver_generation" || true
  fi
  codex_monitor_state_write "$STATE_FILE" stopped
}
trap cleanup_tui_lease EXIT
trap 'exit 0' INT TERM

# Resolve Node only after installing the provisional-ref cleanup trap. A broken
# runtime must not strand the app-server reservation made for this TUI.
NODE_BIN="$(agmsg_resolve_node)"

request_field() { codex_lease_field "$REQUEST_FILE" "$1" 2>/dev/null || true; }

request_valid() {
  [ -f "$REQUEST_FILE" ] || return 1
  [ "$(request_field format_version)" = 2 ] || return 1
  [ "$(request_field generation)" = "$TUI_GENERATION" ] || return 1
  [ "$(request_field type)" = "$TYPE" ] || return 1
  [ "$(request_field app_server)" = "$APP_SERVER" ] || return 1
  local request_project request_project_phys created now age
  request_project="$(request_field project)"
  request_project_phys="$(agmsg_canonical_path "$request_project" 2>/dev/null || printf '%s' "$request_project")"
  [ "$request_project_phys" = "$PROJECT_PHYS" ] || return 1
  created="$(request_field created_at)"
  case "$created" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"; age=$((now - created))
  [ "$age" -ge 0 ] && [ "$age" -le "${AGMSG_CODEX_REQUEST_MAX_AGE:-300}" ] || return 1
  [ -n "$(request_field team)" ] && [ -n "$(request_field name)" ] && [ -n "$(request_field thread)" ]
}

# actas may register the role a moment after launch, so retry while the parent
# is alive.  An explicit pair or a generation-valid hook request disambiguates
# multi-role projects; otherwise exactly one identity is required.
team="" name=""
while kill -0 "$PARENT_PID" 2>/dev/null && [ ! -f "$DISABLED_FILE" ]; do
  ids="$(resolve_identity || true)"
  count="$(printf '%s\n' "$ids" | grep -c . || true)"
  candidate_team="$REQUESTED_TEAM"; candidate_name="$REQUESTED_NAME"
  if [ -z "$candidate_team" ] && [ -z "$candidate_name" ] && request_valid; then
    candidate_team="$(request_field team)"; candidate_name="$(request_field name)"
  fi
  if [ -n "$candidate_team" ] || [ -n "$candidate_name" ]; then
    if [ -n "$candidate_team" ] && [ -n "$candidate_name" ] \
      && printf '%s\n' "$ids" | grep -Fxq "$(printf '%s\t%s' "$candidate_team" "$candidate_name")"; then
      team="$candidate_team"; name="$candidate_name"; break
    fi
    codex_monitor_state_write "$STATE_FILE" identity_invalid
  elif [ "$count" = "1" ]; then
    IFS="$TAB" read -r team name <<EOF
$ids
EOF
    [ -n "$team" ] && [ -n "$name" ] && break
    team="" name=""
  elif [ "$count" = "0" ]; then
    codex_monitor_state_write "$STATE_FILE" waiting_identity
  else
    codex_monitor_state_write "$STATE_FILE" identity_ambiguous explicit_team_name_required
  fi
  sleep 0.3
done
[ -n "$team" ] && [ -n "$name" ] || { codex_monitor_state_write "$STATE_FILE" stopped no_identity; exit 0; }

pidfile="$RUN_DIR/codex-bridge.$team.$name.pid"
log="$RUN_DIR/codex-bridge.$team.$name.log"
# Records the app-server URL the live bridge was launched against, so a later
# launcher instance can tell a bridge bound to a stale app-server (old port,
# from before a codex upgrade) from one bound to the current server. See #197/#237.
appserver_file="$RUN_DIR/codex-bridge.$team.$name.appserver"
# Records the thread a live bridge was bound to (#350), so a later launcher can
# rebind when the resolved thread changes -- e.g. once a role-session record
# appears for a bridge first launched on "loaded", it is torn down and relaunched
# on the recorded thread instead of clinging to the ambiguous "loaded" one.
thread_file="$RUN_DIR/codex-bridge.$team.$name.thread"
bridge_lease="$(codex_bridge_lease_path "$team" "$name")"
# An explicit AGMSG_CODEX_BRIDGE_CMD is a complete runnable (tests, custom
# wrappers) — run it as-is. Only the default codex-bridge.js is launched through
# a resolved Node, since its env-node shebang fails where a version-manager Node
# is not on PATH (#170).
if [ -n "${AGMSG_CODEX_BRIDGE_CMD:-}" ]; then
  bridge_run=("$AGMSG_CODEX_BRIDGE_CMD")
else
  bridge_run=("$NODE_BIN" "$SCRIPT_DIR/codex-bridge.js")
fi

while kill -0 "$PARENT_PID" 2>/dev/null && [ ! -f "$DISABLED_FILE" ]; do
  monitor_phase="$(codex_lease_field "$STATE_FILE" phase 2>/dev/null || true)"
  if [ -n "$resolved_request_thread" ] \
    && [ "$monitor_phase" = route_invalid ]; then
    resolved_request_thread=""
    codex_monitor_state_write "$STATE_FILE" waiting_thread fresh_session_request_required
  fi
  # A request is accepted once, only from this TUI generation, and never gets
  # to override the monitor's app-server URL.  Keep the accepted exact thread in
  # memory after compare-and-delete. Without an exact request, stay idle: a
  # project-wide loaded thread is not proof that it belongs to this TUI.
  if request_valid \
    && [ "$(request_field team)" = "$team" ] && [ "$(request_field name)" = "$name" ]; then
    resolved_request_thread="$(request_field thread)"
    codex_lease_compare_delete "$REQUEST_FILE" "$TUI_GENERATION"
    codex_monitor_state_write "$STATE_FILE" route_resolved exact_request
  elif [ -f "$REQUEST_FILE" ]; then
    codex_monitor_state_write "$STATE_FILE" request_invalid rejected
    # This path is generation-specific and was derived/validated above, so a
    # malformed payload cannot belong to another live TUI.
    rm -f "$REQUEST_FILE"
  fi
  if [ -z "$resolved_request_thread" ]; then
    codex_monitor_state_write "$STATE_FILE" waiting_first_turn exact_hook_session_required
    sleep 0.3
    continue
  fi
  thread_id="$resolved_request_thread"
  req_app_server="$APP_SERVER"

  # Publish the producer lease before a bridge is started or reused.  When the
  # resolved thread changes, remove only this launcher's previous generation-
  # matched file; another live TUI's lease is never touched.
  next_tui_lease="$(codex_tui_lease_path "$team" "$name" "$thread_id" "$TUI_GENERATION")"
  if [ -n "$current_tui_lease" ] && [ "$current_tui_lease" != "$next_tui_lease" ]; then
    codex_lease_compare_delete "$current_tui_lease" "$TUI_GENERATION"
  fi
  current_tui_lease="$(codex_write_tui_lease "$team" "$name" "$thread_id" "$TUI_GENERATION" "$PROJECT" "$req_app_server" "$PARENT_PID")"
  appserver_record="$(codex_appserver_record_path "$PROJECT_HASH")"
  next_appserver_generation="$(codex_lease_field "$appserver_record" generation 2>/dev/null || true)"
  if [ -n "$next_appserver_generation" ]; then
    ref_name="$(basename "$current_tui_lease")"
    if next_appserver_ref="$(codex_appserver_ref_replace "$PROJECT_HASH" "$current_appserver_ref" "$ref_name" "$next_appserver_generation")"; then
      current_appserver_ref="$next_appserver_ref"
      appserver_generation="$next_appserver_generation"
    fi
  fi

  if [ -f "$pidfile" ]; then
    bridge_pid="$(cat "$pidfile" 2>/dev/null || true)"
    bridge_state="$(compat_pid_state_native "$bridge_pid")"
    if [ "$bridge_state" = unknown ]; then
      codex_monitor_state_write "$STATE_FILE" bridge_liveness_unknown
      sleep 0.3
      continue
    fi
    if [ -n "$bridge_pid" ] && [ "$bridge_state" = alive ]; then
      bridge_meta="${pidfile%.pid}.meta"
      meta_pid="$(codex_lease_field "$bridge_meta" pid 2>/dev/null || true)"
      meta_project="$(codex_lease_field "$bridge_meta" project 2>/dev/null || true)"
      meta_project_phys="$(agmsg_canonical_path "$meta_project" 2>/dev/null || printf '%s' "$meta_project")"
      meta_team="$(codex_lease_field "$bridge_meta" team 2>/dev/null || true)"
      meta_name="$(codex_lease_field "$bridge_meta" name 2>/dev/null || true)"
      meta_type="$(codex_lease_field "$bridge_meta" type 2>/dev/null || true)"
      bridge_cmd="$(codex_pid_cmdline_domain native "$bridge_pid" 2>/dev/null || true)"
      lease_pid="$(codex_lease_field "$bridge_lease" owner_winpid 2>/dev/null || true)"
      if [ "$meta_pid" != "$bridge_pid" ] || [ "$meta_project_phys" != "$PROJECT_PHYS" ] \
        || [ "$meta_team" != "$team" ] || [ "$meta_name" != "$name" ] \
        || [ "$meta_type" != "$TYPE" ] || [ "$lease_pid" != "$bridge_pid" ]; then
        codex_monitor_state_write "$STATE_FILE" bridge_unverified metadata_or_lease_mismatch
        sleep 0.3
        continue
      fi
      case "$bridge_cmd" in
        *codex-bridge.js*) ;;
        *)
          codex_monitor_state_write "$STATE_FILE" bridge_unverified command_line_mismatch
          sleep 0.3
          continue
          ;;
      esac
      # Reuse only when the live bridge is bound to the CURRENT app-server. A
      # codex upgrade makes codex-monitor.sh kill the stale app-server and start a
      # fresh one on a new port (#237); a bridge still bound to the old URL stays
      # alive but delivers nothing. The bridge's own exit-on-close covers most of
      # this, but guard the race where the old bridge has not exited yet by the
      # time a new launcher re-checks: an app-server mismatch means tear it down.
      # Reuse only when the live bridge is bound to BOTH the current app-server
      # AND the current thread. The thread guard (#350) is what lets a bridge
      # first launched on the ambiguous "loaded" thread rebind once this role's
      # recorded thread becomes known -- otherwise the app-server match alone
      # would keep the wrong-thread bridge alive indefinitely.
      bound_url="$(cat "$appserver_file" 2>/dev/null || true)"
      bound_thread="$(cat "$thread_file" 2>/dev/null || true)"
      bound_generation="$(codex_lease_field "$bridge_lease" bound_generation 2>/dev/null || true)"
      if [ "$bound_url" = "$req_app_server" ] && [ "$bound_thread" = "$thread_id" ] \
        && [ "$bound_generation" = "$TUI_GENERATION" ]; then
        codex_monitor_state_write "$STATE_FILE" healthy
        sleep 0.3
        continue
      fi
      if [ -n "$bound_generation" ] && [ "$bound_generation" != "$TUI_GENERATION" ] \
        && codex_tui_generation_fresh "$team" "$name" "$bound_generation"; then
        codex_monitor_state_write "$STATE_FILE" identity_conflict another_tui_owns_bridge
        sleep 0.3
        continue
      fi
      if ! codex_pid_kill_domain native "$bridge_pid"; then
        codex_monitor_state_write "$STATE_FILE" bridge_stop_failed
        sleep 0.3
        continue
      fi
      rm -f "$pidfile" "$appserver_file" "$thread_file"
    fi
  fi

  nohup "${bridge_run[@]}" \
    --project "$PROJECT" \
    --type "$TYPE" \
    --team "$team" \
    --name "$name" \
    --thread "$thread_id" \
    --app-server "$req_app_server" \
    --tui-lease "$current_tui_lease" \
    --bridge-lease "$bridge_lease" \
    --bound-generation "$TUI_GENERATION" \
    --monitor-state "$STATE_FILE" \
    --inline-inbox \
    >>"$log" 2>&1 &
  codex_monitor_state_write "$STATE_FILE" bridge_starting "$thread_id"
  # Record what this bridge is bound to so a later launcher can detect staleness.
  printf '%s' "$req_app_server" > "$appserver_file"
  printf '%s' "$thread_id" > "$thread_file"
  sleep 1
done
