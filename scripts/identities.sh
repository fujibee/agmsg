#!/usr/bin/env bash
set -euo pipefail

# List (team, agent) pairs registered for a given (project_path, agent_type).
#
# Usage: identities.sh <project_path> <agent_type>
#
# Output: one "<team>\t<agent>" line per registered pair, tab-separated.
# Empty output (and exit 0) when no pair matches. Pairs are deduplicated.
#
# Used by:
#   - whoami.sh        — exact-match enumeration for identity resolution
#   - watch.sh         — subscription set for the monitor delivery mode
#   - check-inbox.sh   — turn-mode fallback enumeration

PROJECT_PATH="${1:?Usage: identities.sh <project_path> <agent_type>}"
AGENT_TYPE="${2:?Missing agent_type}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

[ -d "$TEAMS_DIR" ] || exit 0

for config_file in "$TEAMS_DIR"/*/config.json; do
  [ -f "$config_file" ] || continue
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$config_file")
  TEAM_NAME=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_extract(:json, '\$.name');")
  [ -z "$TEAM_NAME" ] && continue
  [ "$TEAM_NAME" = "null" ] && continue

  sqlite3 -separator $'\t' :memory: ".param set :json '$CONFIG_ESCAPED'" "
    WITH agents AS (
      SELECT
        key AS name,
        CASE
          WHEN json_type(json_extract(value, '\$.registrations')) = 'array' THEN json_extract(value, '\$.registrations')
          ELSE json_array(json_object('type', json_extract(value, '\$.type'), 'project', json_extract(value, '\$.project')))
        END AS registrations
      FROM json_each(json_extract(:json, '\$.agents'))
    )
    SELECT DISTINCT '$TEAM_NAME' AS team, name
    FROM agents, json_each(agents.registrations) AS r
    WHERE json_extract(r.value, '\$.project') = '$PROJECT_PATH'
      AND json_extract(r.value, '\$.type') = '$AGENT_TYPE'
    ORDER BY team, name;
  "
done
