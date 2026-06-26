#!/usr/bin/env bash
set -euo pipefail

# Usage: leave.sh <team> <agent_id>
#
# Removes an agent from a team. Removes the team if empty.

TEAM="${1:?Usage: leave.sh <team> <agent_id>}"
AGENT_ID="${2:?Missing agent_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
agmsg_validate_team_name "$TEAM" || exit 1

TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

# Serialize the read-modify-write so a concurrent join/leave/reset on this team
# can't be clobbered (#141). The team dir exists (checked above); read the config
# under the lock.
agmsg_lock_acquire "$TEAMS_DIR/$TEAM" || exit 1
CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

# Check if agent exists
EXISTS=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
  "SELECT json_extract(:json, '$.agents.$AGENT_ID');")
if [ -z "$EXISTS" ] || [ "$EXISTS" = "null" ]; then
  echo "Agent $AGENT_ID not in team $TEAM"
  exit 1
fi

# Remove agent
UPDATED=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
  "SELECT json_remove(:json, '$.agents.$AGENT_ID');")

# Check if agents is now empty
AGENT_COUNT=$(agmsg_sqlite_mem \
  "SELECT count(*) FROM json_each(json_extract('$(echo "$UPDATED" | sed "s/'/''/g")', '$.agents'));")

if [ "$AGENT_COUNT" -eq 0 ]; then
  rm -f "$TEAM_CONFIG"
  agmsg_lock_release
  rmdir "$TEAMS_DIR/$TEAM" 2>/dev/null || true
  echo "Left team $TEAM (team removed — no members left)"
else
  agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"
  agmsg_lock_release
  echo "Left team $TEAM"
fi
