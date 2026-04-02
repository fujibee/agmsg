#!/usr/bin/env bash
set -euo pipefail

# Show agent identity in id(1) style.
# If in a team:  agent=<name> teams=<t1,t2,...> type=<type> project=<path>
# If not:        not_joined=true available_teams=<t1,t2,...> (or "none")
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

python3 -c "
import json, os, glob

teams_dir = '$TEAMS_DIR'
project = '$PROJECT_PATH'
agent_type = '$AGENT_TYPE'

agent_name = None
my_teams = []
all_teams = []

for config_path in sorted(glob.glob(os.path.join(teams_dir, '*/config.json'))):
    with open(config_path) as f:
        config = json.load(f)
    team = config.get('name', '')
    all_teams.append(team)
    for name, info in config.get('agents', {}).items():
        if info.get('project', '') == project and info.get('type', '') == agent_type:
            if agent_name is None:
                agent_name = name
            my_teams.append(team)

if agent_name and my_teams:
    print(f'agent={agent_name} teams={','.join(my_teams)} type={agent_type} project={project}')
else:
    available = ','.join(all_teams) if all_teams else 'none'
    print(f'not_joined=true available_teams={available}')
"
