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

# Fast pre-check (re-checked authoritatively under the lock below): a real team
# has a config.json. An inert empty dir — e.g. left by an aborted rename — is not
# an existing team.
if [ -f "$NEW_DIR/config.json" ]; then
  echo "Team already exists: $NEW_TEAM"
  exit 1
fi

# Serialize against concurrent join/leave/reset/rename on BOTH the source and the
# target team (#141). A per-team lock can't reserve a not-yet-existent target by
# name, so we create the target dir and hold its lock too — a concurrent join to
# the new team then blocks on teams/<new>/.config.lock until the rename finishes.
# Acquire the two locks in a canonical (sorted) order so two crossing renames
# (a->b and b->a) can't deadlock.
mkdir -p "$OLD_DIR" "$NEW_DIR"
LOCK_A=$(printf '%s\n%s\n' "$OLD_DIR" "$NEW_DIR" | LC_ALL=C sort | sed -n 1p)
LOCK_B=$(printf '%s\n%s\n' "$OLD_DIR" "$NEW_DIR" | LC_ALL=C sort | sed -n 2p)
agmsg_lock_acquire "$LOCK_A" || exit 1
agmsg_lock_acquire "$LOCK_B" || exit 1

# Authoritative target check now that the target is locked: if it became a real
# team between the pre-check and the lock, abort.
if [ -f "$NEW_DIR/config.json" ]; then
  echo "Team already exists: $NEW_TEAM"
  exit 1
fi

# Move the config into the locked, reserved target dir. Move the file (not the
# dir) because the target dir already exists — we created and locked it.
mv "$OLD_DIR/config.json" "$NEW_DIR/config.json"

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
# The old dir no longer holds a team (its config moved out); best-effort remove
# the now-empty dir. A concurrent join to the old name after this point
# legitimately creates a fresh team there.
rmdir "$OLD_DIR" 2>/dev/null || true
echo "Renamed team $OLD_TEAM → $NEW_TEAM"
echo
echo "Note: existing members in other projects/sessions still see the old"
echo "team name cached. Each member should re-run whoami in their project"
echo "to pick up the new name:"
echo
echo "  ~/.agents/skills/<skill>/scripts/whoami.sh \"\$(pwd)\" <type>"
