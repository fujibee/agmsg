#!/usr/bin/env bash
set -euo pipefail

# Usage: rename.sh <team> <old_name> <new_name>
#
# Renames an agent in team config and updates all messages in DB.

TEAM="${1:?Usage: rename.sh <team> <old_name> <new_name>}"
OLD_NAME="${2:?Missing old agent name}"
NEW_NAME="${3:?Missing new agent name}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"
DB="$SCRIPT_DIR/../db/messages.db"
TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

# --- Update team config ---
python3 -c "
import json, sys

config_path = '$TEAM_CONFIG'
with open(config_path) as f:
    config = json.load(f)

agents = config.get('agents', {})
if '$OLD_NAME' not in agents:
    print('Agent $OLD_NAME not in team $TEAM')
    sys.exit(1)
if '$NEW_NAME' in agents:
    print('Agent $NEW_NAME already exists in team $TEAM')
    sys.exit(1)

agents['$NEW_NAME'] = agents.pop('$OLD_NAME')

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
    f.write('\n')
"

# --- Update messages in DB ---
if [ -f "$DB" ]; then
  sqlite3 "$DB" "UPDATE messages SET from_agent='$NEW_NAME' WHERE team='$TEAM' AND from_agent='$OLD_NAME';"
  sqlite3 "$DB" "UPDATE messages SET to_agent='$NEW_NAME' WHERE team='$TEAM' AND to_agent='$OLD_NAME';"
fi

echo "Renamed $OLD_NAME → $NEW_NAME in team $TEAM"
