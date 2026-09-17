#!/usr/bin/env bash
set -euo pipefail

# Usage: rename.sh <team> <old_name> <new_name>
#
# Renames an agent in team config and updates all messages in DB.
#
# It deliberately does NOT touch run/. Those files are runtime state, not a
# record of the team: `actas.<team>__<agent>.session` (the exclusivity lock),
# `role-session.<team>__<agent>`, `ready.<team>__<agent>`, and the codex bridge's
# `codex-bridge.<team>.<agent>.*`. Thirteen files read them between them, and
# rewriting the state of a process that is currently running, because its name
# changed, is a good way to break the one thing that was working.
#
# What that leaves behind is orphans under the old name. They are harmless:
# nothing is running under that name to read them, and the next start writes
# fresh ones. The exclusivity lock is the one worth clearing by hand — a lock
# held by a name that no longer exists is the kind of thing a future reuse check
# trips over.
#
# Written down because two renames in a row produced the same leftovers and the
# second person asked whether it was intended. It is. A bulk rename would
# multiply them, and nobody should have to rediscover that it was a choice.

TEAM="${1:?Usage: rename.sh <team> <old_name> <new_name>}"
OLD_NAME="${2:?Missing old agent name}"
NEW_NAME="${3:?Missing new agent name}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/roster-journal.sh"
# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1
agmsg_validate_agent_name "$OLD_NAME" || exit 1
agmsg_validate_agent_name "$NEW_NAME" || exit 1
TEAMS_DIR="$SCRIPT_DIR/../teams"
DB="$(agmsg_db_path "$TEAM")"
OLD_NAME_SQL=$(agmsg_sqlesc "$OLD_NAME")
NEW_NAME_SQL=$(agmsg_sqlesc "$NEW_NAME")
TEAM_CONFIG="$TEAMS_DIR/$TEAM/config.json"

if [ ! -f "$TEAM_CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

# Serialize the read-modify-write so a concurrent join/leave/reset on this team
# can't be clobbered (#141). The team dir exists (checked above).
agmsg_lock_acquire "$TEAMS_DIR/$TEAM" || exit 1

# --- Update team config ---
agmsg_roster_ensure "$TEAMS_DIR/$TEAM" "$TEAM_CONFIG"
agmsg_roster_project_config "$TEAMS_DIR/$TEAM" "$TEAM_CONFIG"
CONFIG_ESCAPED=$(sed "s/'/''/g" "$TEAM_CONFIG")

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

if agmsg_roster_has_journal "$TEAMS_DIR/$TEAM"; then
  MEMBER_ID=$(agmsg_sqlite_mem \
    "SELECT COALESCE(json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$OLD_NAME_SQL' || '.member_id'),'');")
  [ -n "$MEMBER_ID" ] || {
    echo "agmsg: journaled member '$OLD_NAME' has no member_id" >&2
    exit 1
  }
  NAME_OWNER=$(agmsg_roster_name_owner "$TEAMS_DIR/$TEAM" "$NEW_NAME")
  if [ -n "$NAME_OWNER" ] && [ "$NAME_OWNER" != "$MEMBER_ID" ]; then
    echo "Agent name $NEW_NAME belongs to another identity in team $TEAM" >&2
    exit 1
  fi
  RENAMED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  agmsg_roster_append_renamed "$TEAMS_DIR/$TEAM" "$MEMBER_ID" \
    "$OLD_NAME" "$NEW_NAME" "$RENAMED_AT"
  agmsg_roster_project_config "$TEAMS_DIR/$TEAM" "$TEAM_CONFIG"
  UPDATED=$(cat "$TEAM_CONFIG")
else
  # Name-only legacy teams keep the pre-journal cache mutation.
  UPDATED=$(agmsg_sqlite_mem \
    "SELECT json_remove(json_set('$CONFIG_ESCAPED', '\$.agents.' || '$NEW_NAME_SQL', json_extract('$CONFIG_ESCAPED', '\$.agents.' || '$OLD_NAME_SQL')), '\$.agents.' || '$OLD_NAME_SQL');")
  RENAMED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# Tombstone the old name so a later join/actas can't silently revive it (#360):
# a CLI's slash-command history can resubmit `/agmsg actas <old_name>` well
# after this rename, and without this record join.sh would happily
# re-materialize <old_name>, rolling the rename back with no warning.
# Stored as an array of {from,to,at} entries (rather than keying an object by
# the old name) so a name containing a single quote can't break the JSON path
# expression the way `$.agents.$OLD_NAME` above requires it not to — from/to
# are bound as ordinary SQL string values, never spliced into a path.
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
