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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# Reject team names that would escape teams/ as a path segment, on either side
# of the rename (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$OLD_TEAM" || exit 1
agmsg_validate_team_name "$NEW_TEAM" || exit 1
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

# Serialize against concurrent join/leave/reset on the old team while we move it
# (#141). Lock the old team dir, then move it — the lock dir (teams/<old>/.config
# .lock) travels with the dir, so repoint the held-lock handle to its new path so
# release/the trap cleans it up.
agmsg_lock_acquire "$OLD_DIR" || exit 1

# --- Move directory ---
mv "$OLD_DIR" "$NEW_DIR"
AGMSG_TEAM_LOCK="$NEW_DIR/.config.lock"

# --- Update name in config.json ---
NEW_CONFIG="$NEW_DIR/config.json"
if [ -f "$NEW_CONFIG" ]; then
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$NEW_CONFIG")
  UPDATED=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
    "SELECT json_set(:json, '\$.name', '$NEW_TEAM');")
  agmsg_write_atomic "$NEW_CONFIG" "$UPDATED"
fi

# --- Update messages in DB ---
if [ -f "$DB" ]; then
  agmsg_sqlite "$DB" "UPDATE messages SET team='$NEW_TEAM' WHERE team='$OLD_TEAM';"
fi

agmsg_lock_release
echo "Renamed team $OLD_TEAM → $NEW_TEAM"
echo
echo "Note: existing members in other projects/sessions still see the old"
echo "team name cached. Each member should re-run whoami in their project"
echo "to pick up the new name:"
echo
echo "  ~/.agents/skills/<skill>/scripts/whoami.sh \"\$(pwd)\" <type>"
