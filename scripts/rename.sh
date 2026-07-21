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
# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1
TEAMS_DIR="$SCRIPT_DIR/../teams"
DB="$(agmsg_db_path)"
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

# Check old exists
OLD_VAL=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
  "SELECT json_extract(:json, '$.agents.$OLD_NAME');")
if [ -z "$OLD_VAL" ] || [ "$OLD_VAL" = "null" ]; then
  echo "Agent $OLD_NAME not in team $TEAM"
  exit 1
fi

# Check new doesn't exist
NEW_VAL=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
  "SELECT json_extract(:json, '$.agents.$NEW_NAME');")
if [ -n "$NEW_VAL" ] && [ "$NEW_VAL" != "null" ]; then
  echo "Agent $NEW_NAME already exists in team $TEAM"
  exit 1
fi

# Rename: set new key with old value, remove old key
UPDATED=$(agmsg_sqlite_mem ".param set :json '$CONFIG_ESCAPED'" \
  "SELECT json_remove(json_set(:json, '$.agents.$NEW_NAME', json_extract(:json, '$.agents.$OLD_NAME')), '$.agents.$OLD_NAME');")

# Tombstone the old name so a later join/actas can't silently revive it (#360):
# a CLI's slash-command history can resubmit `/agmsg actas <old_name>` well
# after this rename, and without this record join.sh would happily
# re-materialize <old_name>, rolling the rename back with no warning.
# Stored as an array of {from,to,at} entries (rather than keying an object by
# the old name) so a name containing a single quote can't break the JSON path
# expression the way `$.agents.$OLD_NAME` above requires it not to — from/to
# are bound as ordinary SQL string values, never spliced into a path.
OLD_NAME_SQL=$(agmsg_sqlesc "$OLD_NAME")
NEW_NAME_SQL=$(agmsg_sqlesc "$NEW_NAME")
RENAMED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
UPDATED_ESCAPED=$(printf '%s' "$UPDATED" | sed "s/'/''/g")
UPDATED=$(agmsg_sqlite_mem ".param set :json '$UPDATED_ESCAPED'" \
  "SELECT json_set(:json, '\$.renamed',
     json_insert(
       CASE WHEN json_type(json_extract(:json, '\$.renamed')) = 'array'
            THEN json_extract(:json, '\$.renamed') ELSE json('[]') END,
       '\$[#]', json_object('from', '$OLD_NAME_SQL', 'to', '$NEW_NAME_SQL', 'at', '$RENAMED_AT')
     )
   );")

agmsg_write_atomic "$TEAM_CONFIG" "$UPDATED"

# --- Update messages in DB ---
# Rewrite the agent name in BOTH stores: the event log (where storage_send now
# writes) and the legacy messages table (pre-event-log installs). Without the
# events update a rename would orphan every message sent after the storage flip
# (mirrors rename-team.sh's team-name rewrite for the same reason).
# Escape every interpolated value as a SQL string literal (#223, #87): an agent
# or team name may contain a single quote, which would otherwise break the UPDATE
# and is an injection surface (e.g. a name widening the WHERE predicate).
if [ -f "$DB" ]; then
  TEAM_LIT=$(agmsg_sqlesc "$TEAM")
  OLD_LIT=$(agmsg_sqlesc "$OLD_NAME")
  NEW_LIT=$(agmsg_sqlesc "$NEW_NAME")
  RENAME_SQL=""
  if [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='events';" | tr -d '\r')" = 1 ]; then
    RENAME_SQL="$RENAME_SQL
      UPDATE events SET from_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND from_agent='$OLD_LIT';
      UPDATE events SET to_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND to_agent='$OLD_LIT';
      UPDATE events SET agent='$NEW_LIT' WHERE type='message_read' AND team='$TEAM_LIT' AND agent='$OLD_LIT';"
  fi
  if [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='read_cursors';" | tr -d '\r')" = 1 ]; then
    RENAME_SQL="$RENAME_SQL
      UPDATE read_cursors SET agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND agent='$OLD_LIT';"
  fi
  if [ "$(agmsg_sqlite "$DB" "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='sync_read_members';" | tr -d '\r')" = 1 ]; then
    RENAME_SQL="$RENAME_SQL
      UPDATE sync_read_members SET agent='$NEW_LIT',
        name_mismatch=CASE WHEN remote_agent='$NEW_LIT' THEN 0 ELSE 1 END
        WHERE local_team='$TEAM_LIT' AND agent='$OLD_LIT';
      UPDATE sync_read_aliases SET agent='$NEW_LIT' WHERE local_team='$TEAM_LIT' AND agent='$OLD_LIT';"
  fi
  agmsg_sqlite "$DB" "BEGIN IMMEDIATE;
    UPDATE messages SET from_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND from_agent='$OLD_LIT';
    UPDATE messages SET to_agent='$NEW_LIT' WHERE team='$TEAM_LIT' AND to_agent='$OLD_LIT';
    $RENAME_SQL
    COMMIT;"
fi

if [ "$(agmsg_storage_driver)" = jsonl ]; then
  agmsg_storage_load
  storage_rename_agent "$TEAM" "$OLD_NAME" "$NEW_NAME" >/dev/null
fi

agmsg_lock_release
echo "Renamed $OLD_NAME → $NEW_NAME in team $TEAM"
