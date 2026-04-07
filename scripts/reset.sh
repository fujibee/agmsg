#!/usr/bin/env bash
set -euo pipefail

# Usage: reset.sh <project_path> <type> [agent_id]
#
# Removes registrations for the given project/type across all teams.
# If agent_id is omitted, it is resolved from whoami.sh for the current project/type.

PROJECT_PATH="${1:?Usage: reset.sh <project_path> <type> [agent_id]}"
AGENT_TYPE="${2:?Usage: reset.sh <project_path> <type> [agent_id]}"
TARGET_AGENT="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

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

  AGENT_JSON=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_extract(:json, '$.agents.$TARGET_AGENT');")
  if [ -z "$AGENT_JSON" ] || [ "$AGENT_JSON" = "null" ]; then
    continue
  fi

  AGENT_ESCAPED=$(printf '%s' "$AGENT_JSON" | sed "s/'/''/g")
  NORMALIZED=$(sqlite3 :memory: "
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

  MATCH_COUNT=$(sqlite3 :memory: "
    SELECT count(*)
    FROM json_each(json_extract('$NORMALIZED_ESCAPED', '\$.registrations'))
    WHERE json_extract(value, '\$.type') = '$AGENT_TYPE'
      AND json_extract(value, '\$.project') = '$PROJECT_PATH';
  ")
  if [ "$MATCH_COUNT" -eq 0 ]; then
    continue
  fi

  FILTERED=$(sqlite3 :memory: "
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
  REMAINING=$(sqlite3 :memory: "
    SELECT json_array_length(json_extract('$FILTERED_ESCAPED', '\$.registrations'));
  ")

  if [ "$REMAINING" -eq 0 ]; then
    UPDATED=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
      "SELECT json_remove(:json, '$.agents.$TARGET_AGENT');")
  else
    UPDATED=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
      "SELECT json_set(:json, '$.agents.$TARGET_AGENT', json('$FILTERED_ESCAPED'));")
  fi

  AGENT_COUNT=$(sqlite3 :memory: "
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
done

if [ "$REMOVED" -eq 0 ]; then
  echo "No registrations removed."
else
  echo "Reset complete: removed $REMOVED registration(s) across $TOUCHED_TEAMS team(s)"
fi
