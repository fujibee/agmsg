#!/usr/bin/env bash
set -euo pipefail

# Usage: leave.sh <team> <agent_id>
#
# Removes an agent from a team. Removes the team if empty.

TEAM="${1:?Usage: leave.sh <team> <agent_id>}"
AGENT_ID="${2:?Missing agent_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"
TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

python3 -c "
import json, sys, os

config_path = '$TEAM_CONFIG'
with open(config_path) as f:
    config = json.load(f)

agents = config.get('agents', {})
if '$AGENT_ID' not in agents:
    print('Agent $AGENT_ID not in team $TEAM')
    sys.exit(1)

del agents['$AGENT_ID']

if not agents:
    # Team is empty, remove it
    os.remove(config_path)
    os.rmdir(os.path.dirname(config_path))
    print('Left team $TEAM (team removed — no members left)')
else:
    config['agents'] = agents
    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write('\n')
    print('Left team $TEAM')
"
