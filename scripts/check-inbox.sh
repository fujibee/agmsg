#!/usr/bin/env bash
set -euo pipefail

# Check inbox across all teams with cooldown. Skips if last check was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Prevent infinite loop: if stop hook is already active, exit silently
INPUT=$(cat 2>/dev/null || true)
if echo "$INPUT" | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if d.get('stop_hook_active') else 1)" 2>/dev/null; then
  exit 0
fi

# Identify agent and teams
WHOAMI=$("$SCRIPT_DIR/whoami.sh" "$PROJECT" "$TYPE")
if echo "$WHOAMI" | grep -q "not_joined=true"; then
  exit 0
fi

# Handle multiple identities: use first agent name
if echo "$WHOAMI" | grep -q "multiple=true"; then
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agents=\([^,]*\).*/\1/p')
else
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')
fi
TEAMS=$(echo "$WHOAMI" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')

if [ -z "$AGENT" ] || [ -z "$TEAMS" ]; then
  exit 0
fi

# Cooldown check
MARKER="$SKILL_DIR/db/.lastcheck-$AGENT"

if [ -f "$MARKER" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    last=$(stat -f %m "$MARKER")
  else
    last=$(stat -c %Y "$MARKER")
  fi
  now=$(date +%s)
  if [ $(( now - last )) -lt 60 ]; then
    exit 0
  fi
fi

touch "$MARKER"

# Check inbox for all teams, collect output
OUTPUT=""
IFS=',' read -ra TEAM_LIST <<< "$TEAMS"
for team in "${TEAM_LIST[@]}"; do
  RESULT=$(bash "$SCRIPT_DIR/inbox.sh" "$team" "$AGENT" --quiet 2>&1) || true
  if [ -n "$RESULT" ]; then
    OUTPUT+="$RESULT"$'\n'
  fi
done

# Exit 0 + JSON block decision = shown to model without "error" label
if [ -n "$OUTPUT" ]; then
  ESCAPED=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")
  cat <<ENDJSON
{
  "decision": "block",
  "reason": $ESCAPED
}
ENDJSON
  exit 0
fi
