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

python3 -c "
import json, os, glob

teams_dir = '$TEAMS_DIR'
project = '$PROJECT_PATH'
agent_type = '$AGENT_TYPE'

# Collect all matches: (agent_name, team)
matches = []
all_teams = []

for config_path in sorted(glob.glob(os.path.join(teams_dir, '*/config.json'))):
    with open(config_path) as f:
        config = json.load(f)
    team = config.get('name', '')
    all_teams.append(team)
    for name, info in config.get('agents', {}).items():
        if info.get('project', '') == project and info.get('type', '') == agent_type:
            matches.append((name, team))

if not matches:
    available = ','.join(all_teams) if all_teams else 'none'
    print(f'not_joined=true available_teams={available}')
else:
    # Group by unique agent names
    agent_names = list(dict.fromkeys(m[0] for m in matches))
    team_names = list(dict.fromkeys(m[1] for m in matches))

    if len(agent_names) == 1:
        print(f'agent={agent_names[0]} teams={','.join(team_names)} type={agent_type} project={project}')
    else:
        print(f'multiple=true agents={','.join(agent_names)} teams={','.join(team_names)} type={agent_type} project={project}')
"
