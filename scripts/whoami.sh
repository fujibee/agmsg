#!/usr/bin/env bash
set -euo pipefail

# Show agent identity in id(1) style.
# Single match:    agent=<name> teams=<t1,t2,...> type=<type> project=<path>
# Multiple match:  multiple=true agents=<n1,n2,...> teams=<t1,t2,...> type=<type> project=<path>
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
MATCHES=""
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
    MATCHES="${MATCHES:+$MATCHES
}$agent_name	$TEAM_NAME"
  done < <(sqlite3 -separator '	' :memory: ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT key FROM json_each(json_extract(:json, '$.agents'))
     WHERE json_extract(value, '$.project') = '$PROJECT_PATH'
       AND json_extract(value, '$.type') = '$AGENT_TYPE';")
done

if [ -z "$MATCHES" ]; then
  echo "not_joined=true available_teams=${ALL_TEAMS:-none}"
  exit 0
fi

# Deduplicate agent names and team names
AGENT_NAMES=$(echo "$MATCHES" | cut -f1 | awk '!seen[$0]++' | paste -sd, -)
TEAM_NAMES=$(echo "$MATCHES" | cut -f2 | awk '!seen[$0]++' | paste -sd, -)

# Count unique agent names
AGENT_COUNT=$(echo "$MATCHES" | cut -f1 | sort -u | wc -l | tr -d ' ')

if [ "$AGENT_COUNT" -eq 1 ]; then
  echo "agent=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH"
else
  echo "multiple=true agents=$AGENT_NAMES teams=$TEAM_NAMES type=$AGENT_TYPE project=$PROJECT_PATH"
fi
