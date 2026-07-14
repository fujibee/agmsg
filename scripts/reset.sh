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

wait_for_codex_receiver_exit() {
  local pid="$1" check=0 state
  while [ "$check" -lt 30 ] && kill -0 "$pid" 2>/dev/null; do
    state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "$state" in Z*) return 0 ;; esac
    sleep 0.1
    check=$((check + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
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
  [ "$AGENT_TYPE" = "codex" ] || return 0

  for kind in codex-bridge codex-app-monitor; do
    base="$SKILL_DIR/run/$kind.$team.$name"
    pidfile="$base.pid"
    metafile="$base.meta"
    plist="$base.plist"
    label=""
    if [ "$kind" = "codex-app-monitor" ]; then
      if [ -f "$metafile" ]; then
        label="$(sed -n 's/^launch_label=//p' "$metafile" | head -1)"
      fi
      if [ -z "$label" ] && [ -f "$plist" ]; then
        label="$(awk '/<key>Label<\/key>/{getline; sub(/^[[:space:]]*<string>/, ""); sub(/<\/string>[[:space:]]*$/, ""); print; exit}' "$plist")"
      fi
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
        cmd="$(compat_get_cmdline "$pid" 2>/dev/null || true)"
        case "$kind:$cmd" in
          codex-bridge:*codex-bridge.js*|codex-app-monitor:*codex-app-monitor.sh*)
            kill "$pid" 2>/dev/null || true
            if ! wait_for_codex_receiver_exit "$pid"; then
              echo "reset: Codex receiver pid $pid did not stop; preserving its run files" >&2
              return 1
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
