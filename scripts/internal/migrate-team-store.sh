#!/usr/bin/env bash
# migrate-team-store.sh <team> — move ONE team out of the shared store into its
# own, and record that choice on the team.
#
# Called when a team connects to a remote, which is the only thing that requires
# the move: a connected team's rows carry ids where a local team's carry names,
# and one column cannot hold both. Teams that never connect stay in the shared
# store, which is what every external reader of the database depends on.
#
# It copies, verifies containment, publishes the partition, then removes the
# source rows. Persistent maintenance barriers keep cooperating consumers out
# until both sides are finalized; an exact rerun resumes an interrupted move.

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
# The lock covers admission/copy/publication/deletion, not only config flip.
agmsg_lock_acquire "$CONNECTION_ROOT/teams/$TEAM" manual-recovery || exit 1
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/delivery-maintenance.sh"
agmsg_dm_load || exit 1

SHARED="$(_agmsg_runtime_db_path)"
DEST="$(agmsg_storage_dir)/teams/$TEAM/messages.db"

# Drop the team's rows from the shared store. Runs after the copy is verified,
# and again on re-entry, which is what makes a crashed migration recoverable:
# the partition is recorded before this, so an interrupted run leaves rows in both
# stores — readable, but stale in the one external programs watch.
_drop_from_shared() {
  local lit; lit="$(agmsg_sqlesc "$TEAM")"
  local guard
  guard=$(agmsg_dm_guard_sql "$DESCRIPTOR" "$SOURCE_TOKEN" main "$TEAM") || return 1
  local sql="BEGIN IMMEDIATE; $guard"
  local t
  for t in events messages read_cursors; do
    printf '%s\n' "$src_tables" | grep -qx "$t" || continue
    sql="$sql DELETE FROM $t WHERE team='$lit';"
  done
  sql="$sql $(agmsg_dm_discard_claims_sql "$TEAM") COMMIT;"
  agmsg_sqlite_warm
  _sqlite_exec_stdin "$SHARED" "$sql" >/dev/null
}

[ -f "$SHARED" ] || { echo "team store: no shared store to move from" >&2; exit 1; }
src_tables="$(agmsg_sqlite "$SHARED" \
  "SELECT name FROM sqlite_master WHERE type='table';" 2>/dev/null || true)"
has_table() { printf '%s\n' "$src_tables" | grep -qx "$1"; }

# Every column of events that moves, ASKED OF THE STORE rather than listed
# here. The copy and the containment check below both use this, and they have to
# agree: a column carried by one and not the other is either a row that compares
# equal while differing, or a row the check reports missing forever.
#
# A hand-written list is what went wrong. It omitted legacy_id -- the column
# that links an event to its row in the legacy messages table (#689) -- so every
# moved message arrived unlinked. That is not a cosmetic loss: the two readers
# that UNION the two tables list it twice, and the legacy projection in
# sqlite-sync, whose entire guard is `events.legacy_id = messages.id`, matches
# nothing and projects the message a SECOND time, which is then pushed to the
# server and on to every other machine (#710). The containment check carried the
# same omission, so both sides compared equal and the migration verified clean
# while dropping the column.
#
# Deriving it means the next column added to events is carried without anyone
# remembering to come here. The destination schema is replayed from this store's
# own sqlite_master further down, so both stores always have exactly this set --
# including a shared store old enough to predate legacy_id, which then has no
# column to lose.
#
# Empty is a failure, not "no columns": PRAGMA answering nothing for a table
# sqlite_master lists means the schema could not be read, and continuing would
# copy nothing, compare nothing, find nothing missing, and delete the originals.
#
# The names are quoted as identifiers before they are interpolated. Nothing in
# this schema needs it -- agmsg creates the table -- but a name that did would
# otherwise land in the statement as syntax. `PRAGMA ... | cut -d'|'` is the
# extraction this repo already uses (drivers/storage/sqlite-sync.sh); a name
# containing the separator would survive it as two fragments, and quoting turns
# that into a "no such column" error instead of a statement that means something
# else.
EVENT_COLS=""
if has_table events; then
  EVENT_COLS="$(agmsg_sqlite "$SHARED" "PRAGMA table_info(events);" \
    | cut -d'|' -f2 | tr -d '\r' \
    | sed 's/"/""/g; s/^/"/; s/$/"/' | paste -sd, -)"
  [ -n "$EVENT_COLS" ] || {
    echo "team store: could not read the events schema in the shared store" >&2
    exit 1
  }
fi

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
      events)   sql="SELECT $EVENT_COLS
                       FROM $t WHERE team='$lit'
                     EXCEPT
                     SELECT $EVENT_COLS
                       FROM dst.$t WHERE team='$lit';" ;;
      messages) sql="SELECT id,team,from_agent,to_agent,body,created_at,read_at
                       FROM $t WHERE team='$lit'
                     EXCEPT
                     SELECT id,team,from_agent,to_agent,body,created_at,read_at
                       FROM dst.$t WHERE team='$lit';" ;;
      # A cursor is a POSITION, and positions only move forward: the writer
      # updates them with MAX(local_position, ...). So the destination's cursor
      # being AHEAD of the shared one is the normal state after the config
      # flips — reads go to the destination from then on, while the shared copy
      # stays frozen at the moment of the move.
      #
      # Requiring the rows to be identical would refuse re-entry as soon as
      # anyone reads once, which in a recovery window that stays open for a
      # while is close to always. What has to be refused is a cursor that has
      # gone BACKWARDS, or one that is absent: either would resume that agent
      # earlier than they had already read.
      # A position that is not stored as an integer counts as MISSING, not as
      # a position to compare. sqlite orders integers before text, so
      # `'abc' < 5` is false: a text cursor in the destination would answer
      # "not behind" to the very comparison meant to catch being behind, this
      # check would report nothing, and the shared cursor — the agent's real
      # read position — would be deleted on the strength of it.
      #
      # Both sides are checked. The contract here is that the destination is
      # deleted only once containment has been PROVEN, and a comparison whose
      # operands are not numbers has proven nothing, whichever side is wrong.
      #
      # Not CAST. `CAST('abc' AS INTEGER)` is 0, which reads as a position at
      # the very beginning and would be quietly accepted as "behind" — a
      # damaged value painted over as a normal comparison. Refusing keeps the
      # data and asks a person to look.
      *)        sql="SELECT s.agent FROM $t s
                       LEFT JOIN dst.$t d ON d.team = s.team AND d.agent = s.agent
                      WHERE s.team='$lit'
                        AND (d.agent IS NULL
                             OR typeof(d.local_position) <> 'integer'
                             OR typeof(s.local_position) <> 'integer'
                             OR d.local_position < s.local_position);" ;;
    esac
    # A destination that cannot be read, or lacks the table, makes the query
    # fail. Preserve that error separately from a successful comparison that
    # actually found missing rows; neither outcome permits source deletion.
    agmsg_sqlite_warm
    out="$(printf '%s\n' "ATTACH DATABASE '$dest_lit' AS dst; $sql" \
      | agmsg_sqlite "$SHARED")" || {
      echo "team store: could not verify destination containment ($t); source retained" >&2
      return 13
    }
    [ -z "$out" ] || { echo "$t"; return 0; }
  done
  return 0
}

CANONICAL_DEST="$DEST"
PARTITION=$(agmsg_driver_for_team partition "$TEAM" shared)
agmsg_dm_find "$TEAM" migrate-team-store per-team "$SHARED" "$DEST" || exit 1
FRESH=false
if [ "${AGMSG_DM_FOUND:?maintenance result missing}" = false ]; then
  # Keep the legacy re-entry safety checks before any admission/schema write.
  if [ "$PARTITION" = per-team ]; then
    [ -f "$DEST" ] || {
      echo "team store: '$TEAM' is recorded as moved, but $DEST does not exist." >&2
      echo "team store: the shared store has NOT been touched." >&2
      exit 1
    }
    incomplete=$(_missing_from_dest) || exit 1
    [ -z "$incomplete" ] || { echo "team store: '$TEAM' is recorded as moved, but $DEST is missing rows ($incomplete)." >&2; exit 1; }
    remaining=0
    for table in events messages read_cursors; do
      has_table "$table" || continue
      remaining=$((remaining + $(agmsg_sqlite "$SHARED" "SELECT count(*) FROM $table WHERE team='$(agmsg_sqlesc "$TEAM")';")))
    done
    if [ "$remaining" = 0 ]; then
      agmsg_lock_release
      echo "team store: '$TEAM' already has its own store; shared copy cleared"
      exit 0
    fi
  elif [ -e "${DEST%/*}" ] || [ -L "${DEST%/*}" ]; then
    echo "team store: a store already exists at $DEST; refusing to merge" >&2
    echo "team store: inspect the existing destination and its owner before retrying; no files were removed." >&2
    exit 1
  fi
  if has_table read_cursors; then
    bad_agent=$(agmsg_sqlite "$SHARED" "SELECT agent FROM read_cursors WHERE team='$(agmsg_sqlesc "$TEAM")' AND typeof(local_position) <> 'integer' LIMIT 1;")
    [ -z "$bad_agent" ] || { echo "team store: '$TEAM' has a non-integer read cursor for '$bad_agent'; refusing to migrate" >&2; exit 1; }
  fi
  CONFIG_BEFORE=$(agmsg_dm_hash "$CONFIG")
  UPDATED=$(agmsg_sqlite_mem "SELECT json_set(CAST(readfile('$(agmsg_sql_readfile_path "$CONFIG")') AS TEXT), '\$.drivers.partition', 'per-team');")
  CONFIG_AFTER=$(printf '%s\n' "$UPDATED" | agmsg_sha256)
  DESCRIPTOR=$(agmsg_sqlite_mem "SELECT json_object(
    'version',1,'nonce',lower(hex(randomblob(32))),'operation','migrate-team-store',
    'team','$(agmsg_sqlesc "$TEAM")','argument','per-team',
    'source','$(agmsg_sqlesc "$SHARED")','target','$(agmsg_sqlesc "$DEST")',
    'config_before','$CONFIG_BEFORE','config_after','$CONFIG_AFTER');")
  agmsg_dm_begin "$SHARED" "$DESCRIPTOR" "$TEAM" || exit 1
  SOURCE_TOKEN="${AGMSG_DM_TOKEN:?maintenance result missing}"
  FRESH=true
  if [ "$PARTITION" = per-team ]; then
    if ! agmsg_dm_begin "$DEST" "$DESCRIPTOR" "$TEAM"; then
      _sqlite_delivery_maintenance_finish_db "$SHARED" "$DESCRIPTOR" "$SOURCE_TOKEN" "$TEAM" >/dev/null || exit 1
      exit 1
    fi
  fi
else
  DESCRIPTOR="${AGMSG_DM_DESCRIPTOR:?maintenance result missing}"
  [ "$(agmsg_dm_field "$DESCRIPTOR" source)" = "$SHARED" ] &&
    [ "$(agmsg_dm_field "$DESCRIPTOR" target)" = "$DEST" ] || { agmsg_dm_error 'migration paths changed'; exit 1; }
fi
CONFIG_BEFORE=$(agmsg_dm_field "$DESCRIPTOR" config_before)
CONFIG_AFTER=$(agmsg_dm_field "$DESCRIPTOR" config_after)
CONFIG_NOW=$(agmsg_dm_hash "$CONFIG")
[ "$CONFIG_NOW" = "$CONFIG_BEFORE" ] || [ "$CONFIG_NOW" = "$CONFIG_AFTER" ] || {
  agmsg_dm_error 'team identity/configuration differs from the migration'; exit 1;
}
SOURCE_RECORD=$(agmsg_dm_get "$SHARED" "$TEAM")
SOURCE_TOKEN=""
if [ -n "$SOURCE_RECORD" ]; then
  SOURCE_TOKEN=$(agmsg_dm_verify_keys "$SHARED" "$DESCRIPTOR" '' "$TEAM")
else
  # Only the source-first finalization window may lack the source barrier.
  [ "$CONFIG_NOW" = "$CONFIG_AFTER" ] && [ -f "$DEST" ] || exit 1
fi
# Begin may add canonical columns to an old source. Refresh both schema and
# column list after admission so copy and containment compare the same values.
src_tables=$(agmsg_sqlite "$SHARED" "SELECT name FROM sqlite_master WHERE type='table';")
if has_table events; then
  EVENT_COLS=$(agmsg_sqlite "$SHARED" 'PRAGMA table_info(events);' | cut -d'|' -f2 | tr -d '\r' | sed 's/"/""/g; s/^/"/; s/$/"/' | paste -sd, -)
  [ -n "$EVENT_COLS" ] || exit 1
fi

STAGE=""
if [ -n "$SOURCE_TOKEN" ]; then STAGE="$(dirname "${CANONICAL_DEST%/*}")/.delivery-migrate-$SOURCE_TOKEN"; fi
if [ -f "$CANONICAL_DEST" ]; then
  DEST_TOKEN=$(agmsg_dm_verify_keys "$CANONICAL_DEST" "$DESCRIPTOR" '' "$TEAM")
  [ -z "$STAGE" ] || { [ ! -e "$STAGE" ] && [ ! -L "$STAGE" ]; } || {
    agmsg_dm_error 'both staged and published stores exist'; exit 1;
  }
else
  [ -n "$SOURCE_TOKEN" ] && [ "$CONFIG_NOW" = "$CONFIG_BEFORE" ] || exit 1
  [ ! -e "${CANONICAL_DEST%/*}" ] && [ ! -L "${CANONICAL_DEST%/*}" ] || {
    agmsg_dm_error 'unexpected destination directory'; exit 1;
  }
  mkdir -p "$(dirname "$STAGE")"
  if [ ! -e "$STAGE" ] && [ ! -L "$STAGE" ]; then ( umask 077; mkdir "$STAGE" ); fi
  [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || { agmsg_dm_error 'invalid staging directory'; exit 1; }
  for stage_file in "$STAGE"/* "$STAGE"/.[!.]* "$STAGE"/..?*; do
    [ -e "$stage_file" ] || [ -L "$stage_file" ] || continue
    case "${stage_file##*/}" in messages.db|messages.db-journal|messages.db-wal|messages.db-shm) ;; *) agmsg_dm_error 'unexpected staging content'; exit 1 ;; esac
    [ -f "$stage_file" ] && [ ! -L "$stage_file" ] || { agmsg_dm_error 'nonregular staging content'; exit 1; }
  done
  DEST="$STAGE/messages.db"
  STAGED_RECORD=""
  if [ -f "$DEST" ]; then
    [ "$(agmsg_sqlite "$DEST" 'PRAGMA integrity_check;')" = ok ] || exit 1
    USER_OBJECTS=$(agmsg_sqlite "$DEST" "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%';")
    if [ "$USER_OBJECTS" = 0 ]; then
      [ "$(agmsg_sqlite "$DEST" 'PRAGMA user_version;')" = 0 ] || exit 1
    else
      STAGED_RECORD=$(agmsg_dm_get "$DEST" "$TEAM")
      [ -n "$STAGED_RECORD" ] || { agmsg_dm_error 'unbound partial staged schema'; exit 1; }
    fi
  else
    for stage_file in "$STAGE"/*; do [ ! -e "$stage_file" ] || { agmsg_dm_error 'sidecar without staged database'; exit 1; }; done
  fi
  if [ -z "$STAGED_RECORD" ]; then
    schema=$(agmsg_sqlite "$SHARED" "SELECT group_concat(sql, ';') || ';' FROM sqlite_master WHERE type IN ('table','index') AND sql IS NOT NULL AND name NOT LIKE 'sqlite_%';")
    [ -n "$schema" ] || exit 1
    src_lit="$(agmsg_sql_readfile_path "$SHARED")"
    team_lit="$(agmsg_sqlesc "$TEAM")"

    # seq and id are copied verbatim rather than reassigned. read_cursors record
    # positions in the events.seq space, so renumbering would silently move every
    # cursor; preserving them keeps a copied cursor pointing where it did.
    guard=$(agmsg_dm_guard_sql "$DESCRIPTOR" "$SOURCE_TOKEN" src "$TEAM") || exit 1
    copy="BEGIN IMMEDIATE; $guard $schema"
    if has_table events; then
      copy="$copy
        INSERT OR IGNORE INTO events($EVENT_COLS)
          SELECT $EVENT_COLS
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
    # #695: a read cursor copied above lives in the SHARED store's global
    # events.seq space -- every team's traffic advances it, not just this one's.
    # events.seq/id are copied verbatim by design (renumbering would move every
    # cursor), but sqlite_sequence is deliberately excluded from the schema copy
    # above (sqlite owns it; the AUTOINCREMENT columns "bring it back on their
    # own first insert" per the comment there) -- so the destination's high-water
    # becomes MAX(this team's OWN copied seqs), which can sit far below a cursor
    # that reflects every team's combined traffic. A new message then receives a
    # seq below the cursor and is permanently invisible to storage_list_unread /
    # storage_watch_after (delivery_tip is read from sqlite_sequence directly,
    # see sqlite.sh's _sqlite_highwater) -- production symptom: history shows the
    # read marker, inbox says nothing new, monitor and turn are both silent.
    #
    # The fix raises the floor, not the cursor: advance the destination's
    # sqlite_sequence for 'events' to at least the greatest copied cursor, so the
    # NEXT event (assigned floor+1) always sorts above every preserved cursor.
    # Not "set cursors to 0" -- that would make every already-read message look
    # unread again for a team migrating WITH real history; 0 is only correct for
    # repairing a store already caught by this bug (a separate, one-off fix, not
    # this one). Two statements because sqlite_sequence has no row for a table
    # until its first AUTOINCREMENT insert -- a team with zero copied events (the
    # empty-event case the issue calls out by name) has no existing row to
    # UPDATE, only one to INSERT.
    if has_table events && has_table read_cursors; then
      copy="$copy
        UPDATE sqlite_sequence SET seq = (SELECT MAX(local_position) FROM read_cursors WHERE team='$team_lit')
          WHERE name = 'events'
            AND seq < (SELECT MAX(local_position) FROM read_cursors WHERE team='$team_lit');
        INSERT INTO sqlite_sequence(name, seq)
          SELECT 'events', (SELECT MAX(local_position) FROM read_cursors WHERE team='$team_lit')
          WHERE (SELECT MAX(local_position) FROM read_cursors WHERE team='$team_lit') IS NOT NULL
            AND NOT EXISTS (SELECT 1 FROM sqlite_sequence WHERE name = 'events');"
    fi
    if has_table storage_metadata; then
      copy="$copy
        INSERT OR IGNORE INTO storage_metadata(key,value) SELECT key,value FROM src.storage_metadata;"
    fi
    copy="$copy
      INSERT INTO delivery_maintenance(team,descriptor,token,created_at)
        VALUES('$team_lit','$(agmsg_sqlesc "$DESCRIPTOR")',lower(hex(randomblob(32))),CAST(strftime('%s','now') AS INTEGER));
      PRAGMA user_version=${_AGMSG_STORAGE_SCHEMA_REV};
      COMMIT;"
    ( umask 077; _sqlite_exec_stdin "$DEST" "ATTACH DATABASE '$src_lit' AS src; $copy" ) >/dev/null
  fi
  DEST_TOKEN=$(agmsg_dm_verify_keys "$DEST" "$DESCRIPTOR" '' "$TEAM")
  incomplete=$(_missing_from_dest) || exit 1
  [ -z "$incomplete" ] || { echo "team store: staged store is missing rows ($incomplete); source retained" >&2; exit 1; }
  [ "$(agmsg_sqlite "$DEST" 'PRAGMA integrity_check;')" = ok ] || exit 1
  CHECKPOINT=$(agmsg_sqlite "$DEST" 'PRAGMA wal_checkpoint(TRUNCATE);')
  [ "${CHECKPOINT%%|*}" = 0 ] || { agmsg_dm_error 'staged checkpoint is busy'; exit 1; }
  [ "$(agmsg_sqlite "$DEST" 'PRAGMA journal_mode=DELETE;')" = delete ] || exit 1
  # Each SQLite process has closed. Never unlink WAL/SHM by hand. Both dirs
  # share a parent/filesystem; the registry lock excludes other publishers.
  agmsg_dm_reservations_clear "$TEAM" || exit 1
  [ ! -e "${CANONICAL_DEST%/*}" ] && [ ! -L "${CANONICAL_DEST%/*}" ] || exit 1
  mv "$STAGE" "${CANONICAL_DEST%/*}"
  [ ! -e "$STAGE" ] && [ ! -L "$STAGE" ] || exit 1
  DEST="$CANONICAL_DEST"
  DEST_TOKEN=$(agmsg_dm_verify_keys "$DEST" "$DESCRIPTOR" "$DEST_TOKEN" "$TEAM")
fi
DEST="$CANONICAL_DEST"
# DELETE is only a transport mode. The driver's revision fast path does not
# restore WAL, so this explicit, checked step also runs on published recovery.
[ "$(agmsg_sqlite "$DEST" 'PRAGMA journal_mode=WAL;')" = wal ] || { agmsg_dm_error 'could not restore WAL on published destination'; exit 1; }
[ "$(agmsg_sqlite "$DEST" 'PRAGMA journal_mode; PRAGMA integrity_check;')" = $'wal\nok' ] || exit 1
DEST_TOKEN=$(agmsg_dm_verify_keys "$DEST" "$DESCRIPTOR" "$DEST_TOKEN" "$TEAM")
incomplete=$(_missing_from_dest) || exit 1
[ -z "$incomplete" ] || { echo "team store: destination is missing rows ($incomplete); source retained" >&2; exit 1; }
agmsg_dm_reservations_clear "$TEAM" || exit 1
if [ "$(agmsg_dm_hash "$CONFIG")" != "$CONFIG_AFTER" ]; then
  UPDATED=$(agmsg_sqlite_mem "SELECT json_set(CAST(readfile('$(agmsg_sql_readfile_path "$CONFIG")') AS TEXT), '\$.drivers.partition', 'per-team');")
  [ "$(printf '%s\n' "$UPDATED" | agmsg_sha256)" = "$CONFIG_AFTER" ] || exit 1
  agmsg_write_atomic "$CONFIG" "$UPDATED"
fi
# Repeat containment immediately before deleting source rows. Ordinary sends
# remain outside this claim-admission protocol; this is not an all-writer move.
incomplete=$(_missing_from_dest) || exit 1
[ -z "$incomplete" ] || { echo "team store: destination is missing rows ($incomplete); source retained" >&2; exit 1; }
if [ -n "$SOURCE_TOKEN" ]; then
  _drop_from_shared
  for table in events messages read_cursors; do
    has_table "$table" || continue
    [ "$(agmsg_sqlite "$SHARED" "SELECT count(*) FROM $table WHERE team='$(agmsg_sqlesc "$TEAM")';")" = 0 ] || exit 1
  done
  _sqlite_delivery_maintenance_finish_db "$SHARED" "$DESCRIPTOR" "$SOURCE_TOKEN" "$TEAM" >/dev/null
else
  for table in events messages read_cursors; do
    has_table "$table" || continue
    [ "$(agmsg_sqlite "$SHARED" "SELECT count(*) FROM $table WHERE team='$(agmsg_sqlesc "$TEAM")';")" = 0 ] || exit 1
  done
fi
guard=$(agmsg_dm_guard_sql "$DESCRIPTOR" "$DEST_TOKEN" main "$TEAM") || exit 1
_sqlite_exec_stdin "$DEST" "BEGIN IMMEDIATE; $guard
  $(agmsg_dm_discard_claims_sql "$TEAM")
  $(_sqlite_delivery_maintenance_finish_sql "$DESCRIPTOR" "$DEST_TOKEN" "$TEAM") COMMIT;"
agmsg_lock_release
if [ "$PARTITION" = per-team ]; then
  echo "team store: '$TEAM' already has its own store; shared copy cleared"
else
  echo "team store: '$TEAM' -> $DEST; removed from the shared store"
fi
