#!/usr/bin/env bash
set -euo pipefail

# Usage: team.sh <team>
# Shows team members.

TEAM="${1:?Usage: team.sh <team>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

python3 -c "
import json
with open('$CONFIG') as f:
    config = json.load(f)
print(f\"Team: {config['name']}\")
print()
agents = config.get('agents', {})
for name, info in agents.items():
    t = info.get('type', '?')
    desc = info.get('description', info.get('project', ''))
    print(f'  {name} ({t}) — {desc}')
print()
print(f'{len(agents)} member(s)')
"
