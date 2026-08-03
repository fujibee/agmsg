#!/usr/bin/env bash
# migrate-team-store.sh <team> — move ONE team out of the shared store into its
# own, and record that choice on the team.
#
# Called when a team connects to a remote, which is the only thing that requires
# the move: a connected team's rows carry ids where a local team's carry names,
# and one column cannot hold both. Teams that never connect stay in the shared
# store, which is what every external reader of the database depends on.
#
# It COPIES. The shared store keeps its rows, so a migration that goes wrong
# costs nothing but disk — delete the per-team store, clear the partition field,
# and the team is back where it was. Reclaiming the copied rows is a separate,
# later decision that wants confidence this one does not.

set -euo pipefail

TEAM="${1:?Usage: migrate-team-store.sh <team>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# The team config and its lock live under the connection root, exactly where
# remote.sh connect wrote them — AGMSG_SYNC_CONNECTION_DIR when set, the skill
# dir otherwise. Resolving them from the skill dir alone would miss the config a
# connect with a custom connection dir just created.
CONNECTION_ROOT="${AGMSG_SYNC_CONNECTION_DIR:-$SKILL_DIR}"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/validate.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/registry-lock.sh"
# The partition lookup lives here; storage.sh only pulls it in lazily.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/driver-registry.sh"

agmsg_validate_team_name "$TEAM" || exit 1

CONFIG="$CONNECTION_ROOT/teams/$TEAM/config.json"
[ -f "$CONFIG" ] || { echo "Team not found: $TEAM" >&2; exit 1; }

SHARED="$(_agmsg_runtime_db_path)"
DEST="$(agmsg_storage_dir)/teams/$TEAM/messages.db"

# Drop the team's rows from the shared store. Runs after the copy is verified,
# and again on re-entry, which is what makes a crashed migration recoverable:
# the partition is recorded before this, so an interrupted run leaves rows in both
# stores — readable, but stale in the one external programs watch.
_drop_from_shared() {
  local lit; lit="$(agmsg_sqlesc "$TEAM")"
  local sql="BEGIN;"
  local t
  for t in events messages read_cursors; do
    printf '%s\n' "$src_tables" | grep -qx "$t" || continue
    sql="$sql DELETE FROM $t WHERE team='$lit';"
  done
  sql="$sql COMMIT;"
  printf '%s\n' "$sql" | agmsg_sqlite "$SHARED" >/dev/null
}

[ -f "$SHARED" ] || { echo "team store: no shared store to move from" >&2; exit 1; }
src_tables="$(agmsg_sqlite "$SHARED" \
  "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null || true)"
has_table() { printf '%s\n' "$src_tables" | grep -qx "$1"; }

# Every row of this team that the shared store holds, compared by VALUE.
#
# Not a count: equal totals can be different rows. Not a key either: the same
# seq or id can name different content once a destination has been recreated.
# What has to be proven before deleting anything is that each shared row exists
# in the destination as the same row.
_missing_from_dest() {
  local lit; lit="$(agmsg_sqlesc "$TEAM")"
  local dest_lit; dest_lit="$(agmsg_sql_readfile_path "$DEST")"
  local t sql out
  for t in events messages read_cursors; do
    printf '%s\n' "$src_tables" | grep -qx "$t" || continue
    # Every column the copy carries, not just the key.
    #
    # A key alone proves too little here. After the destination is removed the
    # config still says per-team, so the next write creates a NEW database at
    # that path, AUTOINCREMENT restarts, and its first event takes seq 1 — the
    # same seq a different shared event already has. Measured: two stores, both
    # holding seq 1, entirely different bodies, and a key-only comparison
    # reports nothing missing.
    #
    # The copy uses INSERT OR IGNORE, so a key collision leaves the existing row
    # untouched rather than replacing it. Whatever is under that key in the
    # destination may be someone else's row, and deleting the shared original on
    # the strength of a matching number would lose it.
    case "$t" in
      events)   sql="SELECT seq,type,id,team,from_agent,to_agent,body,msg_id,agent,at
                       FROM $t WHERE team='$lit'
                     EXCEPT
                     SELECT seq,type,id,team,from_agent,to_agent,body,msg_id,agent,at
                       FROM dst.$t WHERE team='$lit';" ;;
      messages) sql="SELECT id,team,from_agent,to_agent,body,created_at,read_at
                       FROM $t WHERE team='$lit'
                     EXCEPT
                     SELECT id,team,from_agent,to_agent,body,created_at,read_at
                       FROM dst.$t WHERE team='$lit';" ;;
      *)        sql="SELECT team,agent,local_position FROM $t WHERE team='$lit'
                     EXCEPT
                     SELECT team,agent,local_position FROM dst.$t WHERE team='$lit';" ;;
    esac
    # A destination that cannot be read, or lacks the table, makes the query
    # fail — which is reported as "not proven complete", never as "nothing is
    # missing". Being unable to check is not the same as having checked.
    out="$(printf '%s\n' "ATTACH DATABASE '$dest_lit' AS dst; $sql" \
      | agmsg_sqlite "$SHARED" 2>/dev/null)" || { echo "$t"; return 0; }
    [ -z "$out" ] || { echo "$t"; return 0; }
  done
  return 0
}

if [ "$(agmsg_driver_for_team partition "$TEAM" shared)" = per-team ]; then
  # Already moved. Finish the job if a previous run died between recording the
  # partition and clearing the shared copy — otherwise external readers keep seeing
  # this team's history frozen at the moment it moved, which looks like nothing
  # is wrong.
  #
  # But only after proving the destination HAS what is about to be deleted.
  # Reaching this branch means the config says "moved"; it does not mean the
  # store still exists. Deleting on the strength of a flag is how a destination
  # removed by hand takes the shared history with it — the flag survives, the
  # data does not, and the run reports success.
  #
  # Note the direction: the destination legitimately holds MORE than the shared
  # store, because new arrivals land there from the moment the config flips.
  # What has to hold is containment, not equality.
  if [ ! -e "$DEST" ]; then
    echo "team store: '$TEAM' is recorded as moved, but $DEST does not exist." >&2
    echo "team store: the shared store still holds its history and has NOT been touched." >&2
    echo "team store: restore $DEST from a backup, or move the team back before retrying." >&2
    exit 1
  fi
  incomplete="$(_missing_from_dest)"
  if [ -n "$incomplete" ]; then
    echo "team store: '$TEAM' is recorded as moved, but $DEST is missing rows ($incomplete)." >&2
    echo "team store: the shared store still holds its history and has NOT been touched." >&2
    echo "team store: restore or remove $DEST and re-run, rather than leaving both partial." >&2
    exit 1
  fi
  _drop_from_shared
  echo "team store: '$TEAM' already has its own store; shared copy cleared"
  exit 0
fi

if [ -e "$DEST" ]; then
  # Never merge into a store that already exists. Its rows carry their own
  # seq/id values, and copying the shared ones on top would either collide or be
  # silently ignored — losing history in the case that looks like success.
  echo "team store: a store already exists at $DEST; refusing to merge" >&2
  # The same situation as the verification failure below, which does say what to
  # do about it. Saying it in one place and not the other leaves the reader to
  # guess in the case that reached them first.
  #
  # Safe here because this branch runs BEFORE the partition is recorded: the
  # team still resolves to the shared store, so removing the destination throws
  # away only the failed attempt. Once a team is recorded as moved, the same
  # advice would destroy the live store — hence the caveat, which is not padding.
  echo "team store: remove $DEST before retrying — but only while '$TEAM' is NOT yet" >&2
  echo "team store: recorded as moved; after that, $DEST holds its live history." >&2
  exit 1
fi

agmsg_storage_load

# Build the destination directly rather than through storage_init: the team
# still resolves to the SHARED store until the last line of this script, which
# is deliberate (see below), so an init here would initialize the wrong file.
# sqlite_sequence is excluded: sqlite creates and owns it, and replaying its
# CREATE is an error rather than a no-op. The AUTOINCREMENT columns that need it
# bring it back on their own first insert.
mkdir -p "$(dirname "$DEST")"
agmsg_sqlite "$DEST" "$(agmsg_sqlite "$SHARED" \
  "SELECT group_concat(sql, ';') || ';' FROM sqlite_master
    WHERE type IN ('table','index') AND sql IS NOT NULL
      AND name NOT LIKE 'sqlite_%';")" >/dev/null

src_lit="$(agmsg_sql_readfile_path "$SHARED")"
team_lit="$(agmsg_sqlesc "$TEAM")"

# seq and id are copied verbatim rather than reassigned. read_cursors record
# positions in the events.seq space, so renumbering would silently move every
# cursor; preserving them keeps a copied cursor pointing where it did.
copy="BEGIN;"
if has_table events; then
  copy="$copy
    INSERT OR IGNORE INTO events(seq,type,id,team,from_agent,to_agent,body,msg_id,agent,at)
      SELECT seq,type,id,team,from_agent,to_agent,body,msg_id,agent,at
        FROM src.events WHERE team='$team_lit';"
fi
if has_table messages; then
  copy="$copy
    INSERT OR IGNORE INTO messages(id,team,from_agent,to_agent,body,created_at,read_at)
      SELECT id,team,from_agent,to_agent,body,created_at,read_at
        FROM src.messages WHERE team='$team_lit';"
fi
if has_table read_cursors; then
  copy="$copy
    INSERT OR IGNORE INTO read_cursors(team,agent,local_position)
      SELECT team,agent,local_position FROM src.read_cursors WHERE team='$team_lit';"
fi
if has_table storage_metadata; then
  copy="$copy
    INSERT OR IGNORE INTO storage_metadata(key,value) SELECT key,value FROM src.storage_metadata;"
fi
copy="$copy
  COMMIT;"

printf '%s\n' "ATTACH DATABASE '$src_lit' AS src;
$copy" | agmsg_sqlite "$DEST" >/dev/null

# Verify the copy BEFORE anything becomes irreversible. Counted per table
# against the source rather than by a total, so a table that copied nothing
# cannot be hidden by another that copied extra.
rows=0
for t in events messages read_cursors; do
  has_table "$t" || continue
  want="$(agmsg_sqlite "$SHARED" "SELECT COUNT(*) FROM $t WHERE team='$team_lit';")"
  got="$(agmsg_sqlite "$DEST" "SELECT COUNT(*) FROM $t WHERE team='$team_lit';")"
  if [ "$want" != "$got" ]; then
    echo "team store: $t copied $got of $want rows; leaving '$TEAM' where it is" >&2
    echo "team store: remove $DEST before retrying" >&2
    exit 1
  fi
  [ "$t" = read_cursors ] || rows=$(( rows + got ))
done

# Point the team at its new store, under the lock every other config writer
# takes. This is the ordering that matters: until it lands the team still
# resolves to the shared store, so everything above is a copy nothing reads.
agmsg_lock_acquire "$CONNECTION_ROOT/teams/$TEAM" || exit 1
updated="$(agmsg_sqlite_mem "SELECT json_set(CAST(readfile('$(agmsg_sql_readfile_path "$CONFIG")') AS TEXT),
  '\$.drivers.partition', 'per-team');")"
agmsg_write_atomic "$CONFIG" "$updated"
agmsg_lock_release

# Only now drop the shared copy. Leaving it would freeze this team's history at
# today's date for every program that reads the shared store directly — present,
# plausible, and never updated again. Gone is worse to look at and far better to
# notice. A crash between the line above and this one is recoverable: re-running
# lands in the already-moved branch, which clears it.
_drop_from_shared

echo "team store: '$TEAM' -> $DEST ($rows messages); removed from the shared store"
