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

# Resolve the session's real project root (see #92) so a drop issued from a
# subdir/worktree clears the registration on the project the session lives in.
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

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

for TEAM_CONFIG in "$TEAMS_DIR"/*/config.json; do
  [ -f "$TEAM_CONFIG" ] || continue
  TEAM_DIR="$(dirname "$TEAM_CONFIG")"
  TEAM_NAME="$(basename "$TEAM_DIR")"
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

  AGENT_JSON=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_extract(:json, '$.agents.$TARGET_AGENT');")
  if [ -z "$AGENT_JSON" ] || [ "$AGENT_JSON" = "null" ]; then
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
      AND json_extract(value, '\$.project') = '$PROJECT_PATH';
  ")
  if [ "$MATCH_COUNT" -eq 0 ]; then
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
          AND json_extract(value, '\$.project') = '$PROJECT_PATH'
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
    rmdir "$TEAM_DIR" 2>/dev/null || true
  else
    echo "$UPDATED" > "$TEAM_CONFIG"
  fi

  REMOVED=$((REMOVED + MATCH_COUNT))
  TOUCHED_TEAMS=$((TOUCHED_TEAMS + 1))
  echo "Cleared $MATCH_COUNT registration(s) for $TARGET_AGENT from $TEAM_NAME"

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
