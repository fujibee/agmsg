#!/usr/bin/env bash
set -euo pipefail

# Usage: leave.sh <team> <agent_id>
#
# Removes an agent from a team. Removes the team if empty.

TEAM="${1:?Usage: leave.sh <team> <agent_id>}"
AGENT_ID="${2:?Missing agent_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Reject team names that would escape teams/ as a path segment (#140), and
# agent names that would misroute the $.agents.<name> JSON path below (#87
# cluster — '.', '/', '\', '"', '[', ']' all have path meaning to json1).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/roster-journal.sh"
agmsg_validate_team_name "$TEAM" || exit 1
agmsg_validate_agent_name "$AGENT_ID" || exit 1

# Escape as a SQL string literal (parity with join.sh/rename.sh): concatenated
# into the JSON path below as `'$.agents.' || '<escaped>'` rather than spliced
# into the path text, so a single quote in the name can't break the statement
# (#87 cluster).
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
AGENT_ID_SQL=$(_agmsg_sqlesc "$AGENT_ID")

TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

# Serialize the read-modify-write so a concurrent join/leave/reset on this team
# can't be clobbered (#141). The team dir exists (checked above); read the config
# under the lock.
agmsg_lock_acquire "$TEAMS_DIR/$TEAM" || exit 1
agmsg_roster_ensure "$TEAMS_DIR/$TEAM" "$TEAM_CONFIG"
agmsg_roster_project_config "$TEAMS_DIR/$TEAM" "$TEAM_CONFIG"
CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

# Check if agent exists.
# CONFIG_ESCAPED is spliced as a genuine SQL string literal here, NOT bound
# via `.param set`: the sqlite3 shell's dot-command tokenizer does not honour
# SQL '' escaping (unlike a real SQL statement's string literals), so
# `.param set :json '$CONFIG_ESCAPED'` silently mis-parses as soon as the
# config contains any single quote — e.g. an existing agent name like
# "al'ice" — corrupting :json for every query below it (#87 cluster; see
# resolve-project.sh's `resolve_team` for the same caveat).
EXISTS=$(agmsg_sqlite_mem \
  "SELECT json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$AGENT_ID_SQL');")
if [ -z "$EXISTS" ] || [ "$EXISTS" = "null" ]; then
  echo "Agent $AGENT_ID not in team $TEAM"
  exit 1
fi

# An id-bearing team's identity history survives its last local placement.
# Append the authority event first, then replace the derived config cache while
# the same registry lock is still held. A retry after an interrupted cache write
# reprojects the already-durable event instead of minting another identity.
if agmsg_roster_has_journal "$TEAMS_DIR/$TEAM"; then
  MEMBER_ID=$(agmsg_sqlite_mem \
    "SELECT COALESCE(json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$AGENT_ID_SQL' || '.member_id'),'');")
  [ -n "$MEMBER_ID" ] || {
    echo "agmsg: journaled member '$AGENT_ID' has no member_id" >&2
    exit 1
  }
  agmsg_roster_append_left "$TEAMS_DIR/$TEAM" "$MEMBER_ID" "$AGENT_ID" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  agmsg_roster_project_config "$TEAMS_DIR/$TEAM" "$TEAM_CONFIG"
  CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")
  AGENT_COUNT=$(agmsg_sqlite_mem \
    "SELECT count(*) FROM json_each(json_extract('$CONFIG_ESCAPED', '\$.agents'));")
  agmsg_lock_release
  if [ "$AGENT_COUNT" -eq 0 ]; then
    echo "Left team $TEAM (team retained — identity history is preserved)"
  else
    echo "Left team $TEAM"
  fi
  exit 0
fi

# Remove agent
UPDATED=$(agmsg_sqlite_mem \
  "SELECT json_remove('$CONFIG_ESCAPED', '\$.agents.' || '$AGENT_ID_SQL');")

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
