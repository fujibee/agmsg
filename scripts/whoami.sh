#!/usr/bin/env bash
set -euo pipefail

# Show agent identity in id(1) style.
# Single match:    agent=<name> teams=<t1,t2,...> type=<type> project=<path>
# Multiple match:  multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=<type> project=<path>
# Suggestions:     suggest=true agents=<n1,n2,...> teams=<t1,t2,...> type=<type> project=<path> available_teams=<...>
# Not joined:      not_joined=true available_teams=<t1,t2,...> (or "none")
#
# Usage: whoami.sh <project_path> <type>
#   type: claude-code, codex, gemini, etc.

PROJECT_PATH="${1:?Usage: whoami.sh <project_path> <type>}"
AGENT_TYPE="${2:?Usage: whoami.sh <project_path> <type>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

if [ ! -d "$TEAMS_DIR" ]; then
  echo "not_joined=true available_teams=none"
  exit 0
fi

# Scan all team configs
EXACT_MATCHES=""
SUGGESTED_MATCHES=""
ALL_TEAMS=""

for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$config_file")
  TEAM_NAME=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_extract(:json, '$.name');")
  ALL_TEAMS="${ALL_TEAMS:+$ALL_TEAMS,}$TEAM_NAME"

  # Find agents matching project and type
  while IFS='	' read -r agent_name; do
    [ -n "$agent_name" ] || continue
    EXACT_MATCHES="${EXACT_MATCHES:+$EXACT_MATCHES
}$agent_name	$TEAM_NAME"
  done < <(sqlite3 -separator '	' :memory: ".param set :json '$CONFIG_ESCAPED'" "
    WITH agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
      FROM json_each(json_extract(:json, '\$.agents'))
    )
    SELECT DISTINCT name
    FROM agents, json_each(agents.registrations) AS r
    WHERE json_extract(r.value, '\$.project') = '$PROJECT_PATH'
      AND json_extract(r.value, '\$.type') = '$AGENT_TYPE';
  ")

  # Find agents with same type registered elsewhere for suggestion purposes
  while IFS='	' read -r agent_name; do
    [ -n "$agent_name" ] || continue
    SUGGESTED_MATCHES="${SUGGESTED_MATCHES:+$SUGGESTED_MATCHES
}$agent_name	$TEAM_NAME"
  done < <(sqlite3 -separator '	' :memory: ".param set :json '$CONFIG_ESCAPED'" "
    WITH agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
      FROM json_each(json_extract(:json, '\$.agents'))
    )
    SELECT DISTINCT name
    FROM agents, json_each(agents.registrations) AS r
    WHERE json_extract(r.value, '\$.type') = '$AGENT_TYPE';
  ")
done

if [ -z "$EXACT_MATCHES" ] && [ -z "$SUGGESTED_MATCHES" ]; then
  echo "not_joined=true available_teams=${ALL_TEAMS:-none}"
  exit 0
fi

if [ -z "$EXACT_MATCHES" ]; then
  AGENT_NAMES=$(echo "$SUGGESTED_MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
  TEAM_NAMES=$(echo "$SUGGESTED_MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)
  echo "suggest=true agents=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH available_teams=${ALL_TEAMS:-none}"
  exit 0
fi

# Deduplicate agent names and team names
AGENT_NAMES=$(echo "$EXACT_MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
TEAM_NAMES=$(echo "$EXACT_MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)

# Count unique agent names
AGENT_COUNT=$(echo "$EXACT_MATCHES" | cut -f1 | sort -u | wc -l | tr -d ' ')

if [ "$AGENT_COUNT" -eq 1 ]; then
  echo "agent=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH"
else
  echo "multiple=true agents=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH"
fi
