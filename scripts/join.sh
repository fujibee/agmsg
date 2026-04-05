#!/usr/bin/env bash
set -euo pipefail

# Usage: join.sh <team> <agent_id> <type> <project_path>
#
# Adds an agent to a team. Creates the team if it doesn't exist.

TEAM="${1:?Usage: join.sh <team> <agent_id> <type> <project_path>}"
AGENT_ID="${2:?Missing agent_id}"
AGENT_TYPE="${3:?Missing type (claude-code, codex, etc.)}"
PROJECT_PATH="${4:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"
TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

# --- Ensure team config exists ---
mkdir -p "$TEAMS_DIR/$TEAM"
if [ ! -f "$TEAM_CONFIG" ]; then
  cat > "$TEAM_CONFIG" <<EOF
{
  "name": "$TEAM",
  "agents": {},
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  echo "Created team: $TEAM"
fi

# --- Add agent ---
AGENT_OBJ="{\"type\":\"$AGENT_TYPE\",\"project\":\"$PROJECT_PATH\"}"
UPDATED=$(sqlite3 :memory: \
  ".param set :json '$(sed "s/'/''/g" "$TEAM_CONFIG")'" \
  "SELECT json_set(:json, '$.agents.$AGENT_ID', json('$AGENT_OBJ'));")
echo "$UPDATED" > "$TEAM_CONFIG"

echo "Joined team $TEAM as $AGENT_ID"
