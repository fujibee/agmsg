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

echo "Team: $TEAM"
echo ""

COUNT=0
while IFS='	' read -r name type project; do
  echo "  $name ($type) — $project"
  COUNT=$((COUNT + 1))
done < <(sqlite3 -separator '	' :memory: \
  ".param set :json '$(sed "s/'/''/g" "$CONFIG")'" \
  "SELECT key, json_extract(value, '$.type'), json_extract(value, '$.project') FROM json_each(json_extract(:json, '$.agents'));")

echo ""
echo "$COUNT member(s)"
