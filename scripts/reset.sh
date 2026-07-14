#!/usr/bin/env bash
set -euo pipefail

# Usage: reset.sh <project_path> <type> [agent_id] [session_id]
#
# Removes registrations for the given project/type across all teams.
# If agent_id is omitted, it is resolved from whoami.sh for the current project/type.
# If session_id is given, any actas exclusivity locks owned by that session_id
# for the touched (team, agent_id) pairs are released too — this is how `drop`
# returns the role to the pool so peer sessions can pick it up immediately
# without waiting for stale-lock GC.

PROJECT_PATH="${1:?Usage: reset.sh <project_path> <type> [agent_id] [session_id]}"
AGENT_TYPE="${2:?Usage: reset.sh <project_path> <type> [agent_id] [session_id]}"
TARGET_AGENT="${3:-}"
SESSION_ID="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEAMS_DIR="$SKILL_DIR/teams"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hash.sh"

# Resolve the session's real project root (see #92) so a drop issued from a
# subdir/worktree clears the registration on the project the session lives in.
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"
# Equivalent path spellings (#268) — a drop must remove a registration stored
# in any Windows/MSYS form, not just the exact resolved string.
PROJECT_SQL_IN=$(agmsg_project_sql_in_list "$PROJECT_PATH")

# A drop releases the actas lock keyed under this session's per-process instance
# id (#93). The template passes a bare $CLAUDE_CODE_SESSION_ID; normalize to the
# same composite the watcher/claim used so the release matches the real owner
# token (and doesn't no-op against a bare key). Empty stays empty (lock release
# is then skipped, as before).
if [ -n "$SESSION_ID" ]; then
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$AGENT_TYPE")"
fi

if [ -z "$TARGET_AGENT" ]; then
  WHOAMI=$(bash "$SCRIPT_DIR/whoami.sh" "$PROJECT_PATH" "$AGENT_TYPE")
  if echo "$WHOAMI" | grep -q '^agent='; then
    TARGET_AGENT=$(echo "$WHOAMI" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')
  elif echo "$WHOAMI" | grep -q '^multiple=true'; then
    echo "Multiple identities match this project/type. Pass an agent_id explicitly." >&2
    exit 1
  else
    echo "No registered identity found for this project/type." >&2
    exit 1
  fi
fi

if [ ! -d "$TEAMS_DIR" ]; then
  echo "No team registrations found."
  exit 0
fi

REMOVED=0
TOUCHED_TEAMS=0
LOCK_FAILED=0

codex_current_bridge_pid_matches() {
  local pid="$1" base="$2" project="$3" team="$4" name="$5" thread="$6"
  local state_key expected cmd
  state_key="${base##*/codex-bridge.}"
  [ -n "$project" ] && [ -n "$team" ] && [ -n "$name" ] && [ -n "$thread" ] || return 1
  case "$state_key" in *[!A-Za-z0-9._%-]*) return 1 ;; esac
  case "$thread" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  expected="$SKILL_DIR/scripts/drivers/types/codex/codex-bridge.js --project $project --type codex --team $team --name $name --state-key $state_key --app-server-file $base.appserver --thread $thread"
  cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  case " $cmd " in *" $expected "*) return 0 ;; esac
  return 1
}

codex_legacy_bridge_pid_matches() {
  local pid="$1" project="$2" team="$3" name="$4" thread="$5" app_server="$6" expected cmd
  [ -n "$project" ] && [ -n "$team" ] && [ -n "$name" ] \
    && [ -n "$thread" ] && [ -n "$app_server" ] || return 1
  case "$thread" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  expected="$SKILL_DIR/scripts/drivers/types/codex/codex-bridge.js --project $project --type codex --team $team --name $name --thread $thread --app-server $app_server"
  cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  case " $cmd " in *" $expected "*) return 0 ;; esac
  return 1
}

codex_app_monitor_pid_matches() {
  local pid="$1" project="$2" team="$3" name="$4" thread="$5" expected cmd
  [ -n "$project" ] && [ -n "$team" ] && [ -n "$name" ] && [ -n "$thread" ] || return 1
  case "$thread" in *[!A-Za-z0-9._-]*) return 1 ;; esac
  expected="$SKILL_DIR/scripts/drivers/types/codex/codex-app-monitor.sh $project codex $team $name $thread"
  cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
  case " $cmd " in *" $expected "*) return 0 ;; esac
  return 1
}

wait_for_codex_receiver_exit() {
  local pid="$1" matcher="$2" check=0 state
  shift 2
  while [ "$check" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$state" in Z*) return 0 ;; esac
    sleep 0.1
    check=$((check + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    "$matcher" "$pid" "$@" || return 0
    kill -KILL "$pid" 2>/dev/null || return 1
    check=0
    while [ "$check" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
      state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
      case "$state" in Z*) return 0 ;; esac
      sleep 0.1
      check=$((check + 1))
    done
  fi
  ! kill -0 "$pid" 2>/dev/null
}

stop_codex_role_receiver() {
  local team="$1" name="$2" kind base pidfile metafile pid cmd label thread plist check domain
  local scoped_meta scoped_project scoped_type scoped_team scoped_name scoped_thread chat project_hash safe_team safe_name state_key
  local app_server app_safe_team app_safe_name
  local seat saved_project saved_type saved_team saved_name saved_thread _saved_at
  [ "$AGENT_TYPE" = "codex" ] || return 0

  project_hash="$(printf '%s' "$PROJECT_PATH" | agmsg_sha1)"
  safe_team="$(_actas_lock_encode "$team")"
  safe_name="$(_actas_lock_encode "$name")"
  state_key="$project_hash.$safe_team.$safe_name"
  seat="$(codex_seat_path "$team" "$name")"
  if [ -f "$seat" ]; then
    IFS=$'\t' read -r saved_project saved_type saved_team saved_name saved_thread _saved_at < "$seat" || true
    if [ "$saved_project" = "$PROJECT_PATH" ] && [ "$saved_type" = "$AGENT_TYPE" ] \
        && [ "$saved_team" = "$team" ] && [ "$saved_name" = "$name" ]; then
      actas_codex_seat_release "$saved_team" "$saved_name" "$saved_project" "$saved_thread"
    fi
  fi
  actas_codex_release_role_marker "$team" "$name" "$PROJECT_PATH"
  base="$SKILL_DIR/run/codex-bridge.$state_key"
  label="com.agmsg.codex-bridge.$state_key"
  if command -v launchctl >/dev/null 2>&1; then
    domain="gui/$(id -u)"
    launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
  fi
  pid="$(cat "$base.pid" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    scoped_meta="$base.meta"
    scoped_project="$(sed -n 's/^project=//p' "$scoped_meta" 2>/dev/null | head -1)"
    scoped_type="$(sed -n 's/^type=//p' "$scoped_meta" 2>/dev/null | head -1)"
    scoped_team="$(sed -n 's/^team=//p' "$scoped_meta" 2>/dev/null | head -1)"
    scoped_name="$(sed -n 's/^name=//p' "$scoped_meta" 2>/dev/null | head -1)"
    scoped_thread="$(sed -n 's/^thread=//p' "$scoped_meta" 2>/dev/null | head -1)"
    if [ "$scoped_type" = "codex" ] \
        && [ "$(agmsg_canonical_path "$scoped_project")" = "$(agmsg_canonical_path "$PROJECT_PATH")" ] \
        && [ "$scoped_team" = "$team" ] && [ "$scoped_name" = "$name" ] \
        && codex_current_bridge_pid_matches "$pid" "$base" \
          "$scoped_project" "$scoped_team" "$scoped_name" "$scoped_thread"; then
      kill "$pid" 2>/dev/null || true
      wait_for_codex_receiver_exit "$pid" codex_current_bridge_pid_matches "$base" \
        "$scoped_project" "$scoped_team" "$scoped_name" "$scoped_thread" || return 1
    fi
  fi
  rm -f "$base.pid" "$base.meta" "$base.appserver" "$base.log" \
    "$base.plist" "$base.health" "$base.last-ids" "$base.binding"
  rm -f "$base".wake.*.json "$base.relay-wake.json"
  rm -f "$SKILL_DIR/run/codex-chat-visible.$state_key.meta"

  # Current bridge artifacts include the project hash. Match their owned meta
  # fields so dropping one role never removes the same team/name in another
  # project.
  for scoped_meta in "$SKILL_DIR/run"/codex-bridge.*.meta; do
    [ -f "$scoped_meta" ] || continue
    scoped_project="$(sed -n 's/^project=//p' "$scoped_meta" | head -1)"
    scoped_type="$(sed -n 's/^type=//p' "$scoped_meta" | head -1)"
    scoped_team="$(sed -n 's/^team=//p' "$scoped_meta" | head -1)"
    scoped_name="$(sed -n 's/^name=//p' "$scoped_meta" | head -1)"
    scoped_thread="$(sed -n 's/^thread=//p' "$scoped_meta" | head -1)"
    [ "$(agmsg_canonical_path "$scoped_project")" = "$(agmsg_canonical_path "$PROJECT_PATH")" ] || continue
    [ "$scoped_type" = "codex" ] || continue
    [ "$scoped_team" = "$team" ] && [ "$scoped_name" = "$name" ] || continue
    base="${scoped_meta%.meta}"
    case "${base##*/codex-bridge.}" in
      ""|*[!A-Za-z0-9._%-]*) label="" ;;
      *) label="com.agmsg.codex-bridge.${base##*/codex-bridge.}" ;;
    esac
    if [ -n "$label" ] && command -v launchctl >/dev/null 2>&1; then
      domain="gui/$(id -u)"
      launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
    fi
    pid="$(cat "$base.pid" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      if codex_current_bridge_pid_matches "$pid" "$base" \
          "$scoped_project" "$scoped_team" "$scoped_name" "$scoped_thread"; then
        kill "$pid" 2>/dev/null || true
        if ! wait_for_codex_receiver_exit "$pid" codex_current_bridge_pid_matches "$base" \
            "$scoped_project" "$scoped_team" "$scoped_name" "$scoped_thread"; then
          echo "reset: Codex receiver pid $pid did not stop; preserving its run files" >&2
          return 1
        fi
      fi
    fi
    rm -f "$base.pid" "$base.meta" "$base.appserver" "$base.log" \
      "$base.plist" "$base.health" "$base.last-ids" "$base.binding"
    rm -f "$base".wake.*.json "$base.relay-wake.json"
  done
  for chat in "$SKILL_DIR/run"/codex-chat-visible.*.meta; do
    [ -f "$chat" ] || continue
    scoped_project="$(sed -n 's/^project=//p' "$chat" | head -1)"
    scoped_team="$(sed -n 's/^team=//p' "$chat" | head -1)"
    scoped_name="$(sed -n 's/^name=//p' "$chat" | head -1)"
    [ "$(agmsg_canonical_path "$scoped_project")" = "$(agmsg_canonical_path "$PROJECT_PATH")" ] || continue
    [ "$scoped_team" = "$team" ] && [ "$scoped_name" = "$name" ] || continue
    rm -f "$chat"
  done

  for kind in codex-bridge codex-app-monitor; do
    base="$SKILL_DIR/run/$kind.$team.$name"
    pidfile="$base.pid"
    metafile="$base.meta"
    plist="$base.plist"
    label=""
    if [ "$kind" = "codex-app-monitor" ]; then
      app_safe_team="$(printf '%s' "$team" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
      app_safe_name="$(printf '%s' "$name" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-')"
      [ -n "$app_safe_team" ] && [ -n "$app_safe_name" ] \
        && label="com.agmsg.codex-app-monitor.$project_hash.$app_safe_team.$app_safe_name"
      if [ -n "$label" ] && command -v launchctl >/dev/null 2>&1; then
        domain="gui/$(id -u)"
        launchctl bootout "$domain/$label" >/dev/null 2>&1 || true
        check=0
        while [ "$check" -lt 20 ] && launchctl print "$domain/$label" >/dev/null 2>&1; do
          sleep 0.1
          check=$((check + 1))
        done
      fi
    fi
    if [ -f "$pidfile" ]; then
      pid="$(cat "$pidfile" 2>/dev/null || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        scoped_project="$(sed -n 's/^project=//p' "$metafile" 2>/dev/null | head -1)"
        scoped_type="$(sed -n 's/^type=//p' "$metafile" 2>/dev/null | head -1)"
        scoped_team="$(sed -n 's/^team=//p' "$metafile" 2>/dev/null | head -1)"
        scoped_name="$(sed -n 's/^name=//p' "$metafile" 2>/dev/null | head -1)"
        scoped_thread="$(sed -n 's/^thread=//p' "$metafile" 2>/dev/null | head -1)"
        app_server="$(cat "$base.appserver" 2>/dev/null || true)"
        case "$kind" in
          codex-bridge)
            if [ "$scoped_type" = "codex" ] \
                && [ "$(agmsg_canonical_path "$scoped_project")" = "$(agmsg_canonical_path "$PROJECT_PATH")" ] \
                && [ "$scoped_team" = "$team" ] && [ "$scoped_name" = "$name" ] \
                && codex_legacy_bridge_pid_matches "$pid" "$scoped_project" \
                  "$scoped_team" "$scoped_name" "$scoped_thread" "$app_server"; then
              kill "$pid" 2>/dev/null || true
              if ! wait_for_codex_receiver_exit "$pid" codex_legacy_bridge_pid_matches \
                  "$scoped_project" "$scoped_team" "$scoped_name" "$scoped_thread" "$app_server"; then
                echo "reset: Codex receiver pid $pid did not stop; preserving its run files" >&2
                return 1
              fi
            fi
            ;;
          codex-app-monitor)
            if [ "$scoped_type" = "codex" ] \
                && [ "$(agmsg_canonical_path "$scoped_project")" = "$(agmsg_canonical_path "$PROJECT_PATH")" ] \
                && [ "$scoped_team" = "$team" ] && [ "$scoped_name" = "$name" ] \
                && codex_app_monitor_pid_matches "$pid" "$scoped_project" \
                  "$scoped_team" "$scoped_name" "$scoped_thread"; then
            kill "$pid" 2>/dev/null || true
              if ! wait_for_codex_receiver_exit "$pid" codex_app_monitor_pid_matches \
                  "$scoped_project" "$scoped_team" "$scoped_name" "$scoped_thread"; then
              echo "reset: Codex receiver pid $pid did not stop; preserving its run files" >&2
              return 1
            fi
            fi
            ;;
        esac
      fi
    fi
    if [ "$kind" = "codex-app-monitor" ] && [ -f "$metafile" ]; then
      thread="$(sed -n 's/^thread=//p' "$metafile" | head -1)"
      if [ -n "$thread" ]; then
        "$SCRIPT_DIR/drivers/types/codex/codex-monitor-lease.sh" disarm \
          "$PROJECT_PATH" "$team" "$name" "$thread" >/dev/null 2>&1 || true
      fi
    fi
    rm -f "$pidfile" "$metafile" "$base.appserver" "$base.log" "$plist" \
      "$base.health" "$base.preflight.log" "$base.last-prompt.txt" \
      "$base.last-message.txt" "$base.last-status" "$base.last-ids" \
      "$base.watch-output"
    rm -f "$base".wake.*.json "$base.relay-wake.json"
  done
  rm -f "$SKILL_DIR/run/codex-chat-visible.$team.$name.meta"
}

for TEAM_CONFIG in "$TEAMS_DIR"/*/config.json; do
  [ -f "$TEAM_CONFIG" ] || continue
  TEAM_DIR="$(dirname "$TEAM_CONFIG")"
  TEAM_NAME="$(basename "$TEAM_DIR")"

  # Serialize this team's read-modify-write so a concurrent join/leave/rename on
  # the same team can't be clobbered (#141). Per team, released before moving on.
  # A lock timeout is NOT silently skipped: flag it and fail at the end, so a
  # `drop`/reset never reports success while leaving a team unprocessed.
  if ! agmsg_lock_acquire "$TEAM_DIR"; then
    echo "Warning: could not lock $TEAM_NAME, skipped" >&2
    LOCK_FAILED=1
    continue
  fi
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

  AGENT_JSON=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_extract(:json, '$.agents.$TARGET_AGENT');")
  if [ -z "$AGENT_JSON" ] || [ "$AGENT_JSON" = "null" ]; then
    agmsg_lock_release
    continue
  fi

  AGENT_ESCAPED=$(printf '%s' "$AGENT_JSON" | sed "s/'/''/g")
  NORMALIZED=$(agmsg_sqlite_mem "
    WITH agent(a) AS (SELECT '$AGENT_ESCAPED')
    SELECT CASE
      WHEN json_type(json_extract(a, '\$.registrations')) = 'array' THEN a
      ELSE json_object(
        'registrations',
        json_array(json_object(
          'type', json_extract(a, '\$.type'),
          'project', json_extract(a, '\$.project')
        ))
      )
    END
    FROM agent;
  ")
  NORMALIZED_ESCAPED=$(printf '%s' "$NORMALIZED" | sed "s/'/''/g")

  MATCH_COUNT=$(agmsg_sqlite_mem "
    SELECT count(*)
    FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
    WHERE json_extract(value, '\$.type') = '$AGENT_TYPE'
      AND json_extract(value, '\$.project') IN ($PROJECT_SQL_IN);
  ")
  if [ "$MATCH_COUNT" -eq 0 ]; then
    agmsg_lock_release
    continue
  fi

  FILTERED=$(agmsg_sqlite_mem "
    SELECT json_object(
      'registrations',
      COALESCE((
        SELECT json_group_array(json(value))
        FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
        WHERE NOT (
          json_extract(value, '\$.type') = '$AGENT_TYPE'
          AND json_extract(value, '\$.project') IN ($PROJECT_SQL_IN)
        )
      ), json('[]'))
    );
  ")
  FILTERED_ESCAPED=$(printf '%s' "$FILTERED" | sed "s/'/''/g")
  REMAINING=$(agmsg_sqlite_mem "
    SELECT json_array_length(json_extract('$FILTERED_ESCAPED', '\$.registrations'));
  ")

  if [ "$REMAINING" -eq 0 ]; then
    UPDATED=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
      "SELECT json_remove(:json, '$.agents.$TARGET_AGENT');")
  else
    UPDATED=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
      "SELECT json_set(:json, '$.agents.$TARGET_AGENT', json('$FILTERED_ESCAPED'));")
  fi

  AGENT_COUNT=$(agmsg_sqlite_mem "
    SELECT count(*)
    FROM json_each(json_extract('$(printf '%s' "$UPDATED" | sed "s/'/''/g")', '\$.agents'));
  ")

  if [ "$AGENT_COUNT" -eq 0 ]; then
    rm -f "$TEAM_CONFIG"
    agmsg_lock_release
    rmdir "$TEAM_DIR" 2>/dev/null || true
  else
    agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"
    agmsg_lock_release
  fi

  REMOVED=$((REMOVED + MATCH_COUNT))
  TOUCHED_TEAMS=$((TOUCHED_TEAMS + 1))
  echo "Cleared $MATCH_COUNT registration(s) for $TARGET_AGENT from $TEAM_NAME"

  # A dropped Codex role must stop receiving immediately. Mode-level teardown
  # handles whole projects; reset is role-scoped, so remove only this role's
  # bridge/background receiver and leave peer identities untouched.
  stop_codex_role_receiver "$TEAM_NAME" "$TARGET_AGENT"

  # Release the actas lock for this (team, agent) pair so peer sessions can
  # claim it without waiting for owner-session-end / stale GC.
  if [ -n "$SESSION_ID" ]; then
    actas_lock_release "$TEAM_NAME" "$TARGET_AGENT" "$SESSION_ID" 2>/dev/null || true
  fi
done

if [ "$REMOVED" -eq 0 ]; then
  echo "No registrations removed."
else
  echo "Reset complete: removed $REMOVED registration(s) across $TOUCHED_TEAMS team(s)"
fi

# A team we couldn't lock was left unprocessed — surface that as a failure rather
# than reporting partial success.
if [ "$LOCK_FAILED" -ne 0 ]; then
  echo "Reset incomplete: one or more teams could not be locked." >&2
  exit 1
fi
