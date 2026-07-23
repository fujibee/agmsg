#!/usr/bin/env bash
set -euo pipefail

# Usage: rename.sh <team> <old_name> <new_name>
#
# Renames an agent in team config and updates all messages in DB.

TEAM="${1:?Usage: rename.sh <team> <old_name> <new_name>}"
OLD_NAME="${2:?Missing old agent name}"
NEW_NAME="${3:?Missing new agent name}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# Reject team names that would escape teams/ as a path segment (#140), and
# agent names that would misroute the $.agents.<name> JSON path below (#87
# cluster — '.', '/', '\', '"', '[', ']' all have path meaning to json1).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1
agmsg_validate_agent_name "$OLD_NAME" || exit 1
agmsg_validate_agent_name "$NEW_NAME" || exit 1
TEAMS_DIR="$SCRIPT_DIR/../teams"
DB="$(agmsg_db_path)"
# Escape interpolated identifiers as SQL string literals (parity with
# send.sh): a team/agent name with a single quote would break the UPDATE.
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
# Computed up front: every $.agents.<name> path lookup below concatenates
# these as escaped SQL string literals (`'$.agents.' || '<escaped>'`) rather
# than splicing the raw name into the path text, so a name containing a
# single quote can't break out of the surrounding SQL statement (#87 cluster
# — join.sh's PR272 fix for the same bug class, applied here).
OLD_NAME_SQL=$(_agmsg_sqlesc "$OLD_NAME")
NEW_NAME_SQL=$(_agmsg_sqlesc "$NEW_NAME")
TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

# Serialize the read-modify-write so a concurrent join/leave/reset on this team
# can't be clobbered (#141). The team dir exists (checked above).
agmsg_lock_acquire "$TEAMS_DIR/$TEAM" || exit 1

# --- Update team config ---
CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

# CONFIG_ESCAPED/UPDATED_ESCAPED are spliced as genuine SQL string literals
# below, NOT bound via `.param set`: the sqlite3 shell's dot-command
# tokenizer does not honour SQL '' escaping (unlike a real SQL statement's
# string literals), so `.param set :json '...'` silently mis-parses as soon
# as the JSON contains any single quote — e.g. an agent name like "al'ice"
# — corrupting :json for every query below it (#87 cluster; see
# resolve-project.sh's `resolve_team` for the same caveat).

# Check old exists
OLD_VAL=$(agmsg_sqlite_mem \
  "SELECT json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$OLD_NAME_SQL');")
if [ -z "$OLD_VAL" ] || [ "$OLD_VAL" = "null" ]; then
  echo "Agent $OLD_NAME not in team $TEAM"
  exit 1
fi

# Check new doesn't exist
NEW_VAL=$(agmsg_sqlite_mem \
  "SELECT json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$NEW_NAME_SQL');")
if [ -n "$NEW_VAL" ] && [ "$NEW_VAL" != "null" ]; then
  echo "Agent $NEW_NAME already exists in team $TEAM"
  exit 1
fi

# Rename: set new key with old value, remove old key
UPDATED=$(agmsg_sqlite_mem \
  "SELECT json_remove(json_set('$CONFIG_ESCAPED', '\$.agents.' || '$NEW_NAME_SQL', json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$OLD_NAME_SQL')), '\$.agents.' || '$OLD_NAME_SQL');")

# Tombstone the old name so a later join/actas can't silently revive it (#360):
# a CLI's slash-command history can resubmit `/agmsg actas <old_name>` well
# after this rename, and without this record join.sh would happily
# re-materialize <old_name>, rolling the rename back with no warning.
# Stored as an array of {from,to,at} entries (rather than keying an object by
# the old name) so a name containing a single quote can't break the JSON path
# expression the way a raw `$.agents.$OLD_NAME` splice would — from/to are
# bound as ordinary SQL string values, never spliced into a path.
# (OLD_NAME_SQL/NEW_NAME_SQL already computed above.)
RENAMED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
UPDATED_ESCAPED=$(printf '%s' "$UPDATED" | sed "s/'/''/g")
UPDATED=$(agmsg_sqlite_mem \
  "SELECT json_set('$UPDATED_ESCAPED', '\$.renamed',
     json_insert(
       CASE WHEN json_type(json_extract('$UPDATED_ESCAPED', '\$.renamed')) = 'array'
            THEN json_extract('$UPDATED_ESCAPED', '\$.renamed') ELSE json('[]') END,
       '\$[#]', json_object('from', '$OLD_NAME_SQL', 'to', '$NEW_NAME_SQL', 'at', '$RENAMED_AT')
     )
   );")

agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"

# --- Update messages in DB ---
if [ -f "$DB" ]; then
  agmsg_sqlite "$DB" "UPDATE messages SET from_agent='$(_agmsg_sqlesc "$NEW_NAME")' WHERE team='$(_agmsg_sqlesc "$TEAM")' AND from_agent='$(_agmsg_sqlesc "$OLD_NAME")';"
  agmsg_sqlite "$DB" "UPDATE messages SET to_agent='$(_agmsg_sqlesc "$NEW_NAME")' WHERE team='$(_agmsg_sqlesc "$TEAM")' AND to_agent='$(_agmsg_sqlesc "$OLD_NAME")';"
fi

agmsg_lock_release
echo "Renamed $OLD_NAME → $NEW_NAME in team $TEAM"
