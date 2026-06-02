#!/usr/bin/env bash
set -euo pipefail

# Usage: rename-team.sh <old_team> <new_team>
#
# Renames a team:
#   1. moves teams/<old>/ to teams/<new>/
#   2. updates "name" field in the moved config.json
#   3. updates messages.db: UPDATE messages SET team=<new> WHERE team=<old>

OLD_TEAM="${1:?Usage: rename-team.sh <old_team> <new_team>}"
NEW_TEAM="${2:?Missing new team name}"

if [ "$OLD_TEAM" = "$NEW_TEAM" ]; then
  echo "Old and new team names are the same: $OLD_TEAM"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
TEAMS_DIR="$SCRIPT_DIR/../teams"
DB="$(agmsg_db_path)"
OLD_DIR="$TEAMS_DIR/$OLD_TEAM"
NEW_DIR="$TEAMS_DIR/$NEW_TEAM"

if [ ! -d "$OLD_DIR" ]; then
  echo "Team not found: $OLD_TEAM"
  exit 1
fi

if [ -e "$NEW_DIR" ]; then
  echo "Team already exists: $NEW_TEAM"
  exit 1
fi

# --- Move directory ---
mv "$OLD_DIR" "$NEW_DIR"

# --- Update name in config.json ---
NEW_CONFIG="$NEW_DIR/config.json"
if [ -f "$NEW_CONFIG" ]; then
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$NEW_CONFIG")
  UPDATED=$(sqlite3 :memory: ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_set(:json, '\$.name', '$NEW_TEAM');")
  echo "$UPDATED" > "$NEW_CONFIG"
fi

# --- Update messages in DB ---
if [ -f "$DB" ]; then
  sqlite3 "$DB" "UPDATE messages SET team='$NEW_TEAM' WHERE team='$OLD_TEAM';"
fi

echo "Renamed team $OLD_TEAM → $NEW_TEAM"
echo
echo "Note: existing members in other projects/sessions still see the old"
echo "team name cached. Each member should re-run whoami in their project"
echo "to pick up the new name:"
echo
echo "  ~/.agents/skills/<skill>/scripts/whoami.sh \"\$(pwd)\" <type>"
