#!/usr/bin/env bash
# sqlite storage driver (built-in, default).
#
# Implements the storage contract (docs/spec/driver-interface.md §2, ADR 0003)
# over SQLite. Sourced by the storage facade (lib/storage.sh, agmsg_storage_load),
# so agmsg_db_path / agmsg_sqlite / agmsg_sql_readfile_path from storage.sh are in
# scope. State is an append-only `events` log (canonical JSONL: message_sent /
# message_read). The legacy `messages` table is read **read-only** and UNIONed
# into list_unread / history so an existing store keeps its inbox and history
# after #206 switches call sites onto the contract (§2.4); legacy rows are never
# migrated or mutated here.
#
# Framing (§1.4 / ADR 0003): record-returning ops write data only to stdout and
# fail with a non-zero exit; control ops (check/init/mark_read_batch/compact)
# print a §1.4 status name on stdout. The delivery cursor (§2.2) is the events.seq
# autoincrement, returned as an opaque decimal string. Read-marking is
# recipient-scoped ((team, agent)) and idempotent.

# --- helpers ---------------------------------------------------------------

_sqlite_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
# <team> is the storage selector (see agmsg_db_path). Passed explicitly rather
# than held in a driver-wide variable: these run inside command substitutions,
# where an assignment made by a caller would not be visible anyway.
_sqlite_db() { agmsg_db_path "$1"; }
# The quote is a variable, not a \' in the pattern: bash 3.2 keeps the
# backslash of a \' REPLACEMENT and would double a quote into \'\' there while
# producing '' on bash 4+. tests/test_sqlpath.bats holds this equal to the
# forking form it replaces, on the inputs that matter to SQL quoting.
_sqlite_lit() { local q="'"; printf '%s' "${1//$q/$q$q}"; }

# Run a record-returning query: strip CR but PRESERVE the sqlite exit status
# (pipefail), so a backend failure surfaces as a non-zero return instead of
# being swallowed by tr's exit 0. The backend's error text goes to stderr (a
# separate fd — it never pollutes the JSONL on stdout) so failures are
# debuggable, per §2.1 framing (#203 (1) / review).
_sqlite_data() {
  ( set -o pipefail; agmsg_sqlite "$(_sqlite_db "$1")" "$2" | tr -d '\r' )
}

# The same query, handed over stdin instead of on the command line (#882).
#
# FOR SQL WHOSE LENGTH GROWS WITH THE DATA, and only for that. A command line
# has an operating-system limit and stdin does not, so any statement carrying a
# list of ids -- one `IN (...)` entry per pulled message, per acked message, per
# roster member -- has to arrive this way or it stops working at a size nobody
# chose.
#
# The size that stops it is not large. Windows' CreateProcess caps the command
# line at 32,767 characters; measured on a Windows machine, sqlite3 took 827
# uuids as arguments and refused 837. A pull page carrying its ids twice
# reaches that at about 400 messages, which is under half a default page, so a
# team that had grown past it simply could not be pulled -- the failure the
# report in #882 arrived as.
#
# `-batch` because this is a script rather than a session: without it sqlite3
# reading a non-tty is still willing to treat a malformed line as an
# interactive prompt, and the point of this path is that nobody is watching.
_sqlite_data_stdin() {
  # Outside the subshell on purpose: a probe run inside it would be discarded.
  agmsg_sqlite_warm
  ( set -o pipefail; printf '%s\n' "$2" | agmsg_sqlite -batch "$(_sqlite_db "$1")" | tr -d '\r' )
}

# The same, for a statement whose output nobody reads. Takes a database PATH
# rather than a team, because its callers are inside the driver and hold one.
# -bail as at the two driver sites this replaced: the stdin form must stop at
# the first error so a busy call has written nothing of a transaction that
# never began, which is what lets the engine retry it. The warm call sits on
# the line above the pipe, where the #462 scan looks for it.
_sqlite_exec_stdin() {
  agmsg_sqlite_warm
  printf '%s\n' "$2" | agmsg_sqlite -bail -batch "$1"
}

# IN (...) list of "team:agent" pairs.
_sqlite_pair_in() {
  local out="" p t a
  for p in "$@"; do
    t="${p%%:*}"; a="${p#*:}"
    out="${out:+$out,}'$(_sqlite_lit "$t:$a")'"
  done
  printf '%s' "${out:-''}"
}

# --- contract: lifecycle (control ops, §1.4 status on stdout) ---------------

storage_check() {
  if ! command -v sqlite3 >/dev/null 2>&1; then
    echo missing_deps
    return 10
  fi
  echo ok
}

storage_describe() {
  # The selector is optional HERE and only here: describe reports driver
  # metadata, and the capabilities caller has no team to name. The path line
  # is the only team-dependent part, so it is reported only when a specific
  # store was asked about. This is not a second way to reach the store.
  printf 'name=sqlite\n'
  printf 'backend=SQLite (WAL) event log + legacy messages table\n'
  printf 'capabilities=stage1-sync,stage1-resync,stage2-read-state\n'
  [ -z "${1-}" ] || printf 'db=%s\n' "$(_sqlite_db "$1")"
}

# Does a store already exist? (does NOT create one — lets a read call-site answer
# "no messages yet" without lazily initializing a store in a storeless project.)
storage_store_exists() { [ -f "$(_sqlite_db "$1")" ]; }

# Bumped whenever the init batch below changes shape: it is what lets a store
# that already carries revision N skip the batch entirely (#1001). The number
# is stamped INSIDE the same transaction as the schema statements, so a store
# can never hold the new number over an old schema.
_AGMSG_STORAGE_SCHEMA_REV=1

storage_init() {
  local db; db="$(_sqlite_db "$1")"
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  # Fast path (#1001): a store already at the current schema revision needs
  # nothing from this function -- and the check is a READ, which WAL serves
  # even while another process holds the write lock. Without this, every
  # storage call re-ran the write batch below, and under a busy sync engine
  # each of those waited the full busy timeout and then failed with
  # SQLITE_BUSY, silently: 21 sqlite3 calls per inbox.sh, measured 106 s of
  # nothing but this. A failed read falls through to the full init -- an
  # observation failure must not skip the schema.
  if [ -f "$db" ]; then
    local schema_rev
    schema_rev="$(agmsg_sqlite "$db" "PRAGMA user_version;" 2>/dev/null | tr -d '[:space:]')" || schema_rev=""
    if [ "$schema_rev" = "$_AGMSG_STORAGE_SCHEMA_REV" ]; then
      echo ok
      return 0
    fi
  fi
  # CREATE TABLE IF NOT EXISTS does nothing to a store that already has the
  # table, so an existing events table never gains legacy_id from the schema
  # below. SQLite has no ADD COLUMN IF NOT EXISTS, and a failing statement
  # aborts the whole batch, so this runs on its own and its failure ("duplicate
  # column name") is the expected outcome on every run after the first.
  if [ -f "$db" ]; then
    agmsg_sqlite "$db" "ALTER TABLE events ADD COLUMN legacy_id INTEGER;" \
      >/dev/null 2>&1 || true
  fi
  # journal_mode cannot run inside a transaction, so it stays outside the one
  # below -- and its RESULT is checked, not assumed. The pragma answers with
  # the mode now in effect; anything but "wal" (a transient writer making it
  # BUSY, a filesystem refusing the side files) must stop here, because the
  # stamp below would otherwise record a non-WAL store as current and the
  # fast path would never retry the switch -- reads would queue behind
  # writers for the full busy timeout again, with a stamp saying all is well
  # (review finding). Only a store that is actually in WAL proceeds to the
  # schema transaction and can be stamped.
  local journal_mode
  journal_mode="$(agmsg_sqlite "$db" "PRAGMA journal_mode=WAL;" 2>/dev/null | tr -d '[:space:]')" || journal_mode=""
  if [ "$journal_mode" != wal ]; then
    echo runtime_error
    return 13
  fi
  # One transaction, stopped at the first error (-bail), with the revision
  # stamp as its LAST statement: either every schema statement landed and the
  # store says so, or none of it is visible and the store still says the old
  # revision. A crash or failure in the middle cannot leave a new stamp over
  # an old schema, which is the one way the fast path above could lie.
  agmsg_sqlite -bail "$db" "
    BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS events (
      seq        INTEGER PRIMARY KEY AUTOINCREMENT,
      type       TEXT NOT NULL,
      id         TEXT NOT NULL,
      team       TEXT,
      from_agent TEXT,
      to_agent   TEXT,
      body       TEXT,
      msg_id     TEXT,
      agent      TEXT,
      at         TEXT NOT NULL,
      -- The rowid of this event's copy in the legacy messages table, when one
      -- was written. That table is a read interface other software still opens,
      -- so every message is written to both; this column is what lets a reader
      -- tell that the two rows are one message. Without it the UNION queries
      -- below list the same message twice, because the two tables number their
      -- rows in different spaces (UUID vs rowid) and nothing connects them.
      -- (#689. No backticks in here: this SQL sits inside a double-quoted shell
      -- string, where they are command substitution, not quoting.)
      legacy_id  INTEGER
    );
    CREATE INDEX IF NOT EXISTS events_sent ON events(type, team, to_agent, seq);
    CREATE INDEX IF NOT EXISTS events_read ON events(type, team, agent, msg_id);
    -- legacy_id is looked up by value from the other side: every reader that
    -- unions the two tables asks NOT EXISTS(events.legacy_id = messages.id)
    -- per legacy row, and the one-time push projection asks the same question
    -- for every message in the team. Without this index each of those is a
    -- full scan of events, so the cost is messages x events: on a 17,369-message
    -- store with 28,568 events the projection ran 155 s inside one write
    -- transaction (#919) -- holding the store's write lock for the whole of it,
    -- which is what killed the unlock reprocess in #910 -- to insert nothing.
    -- The ALTER above runs first on purpose, so an older store has the column
    -- before this asks for the index on it.
    CREATE INDEX IF NOT EXISTS events_legacy ON events(legacy_id);
    -- id is the value every cross-reference to an event carries, but the
    -- table's key is seq, so a lookup by id is otherwise a full scan of a
    -- table that holds every message body. The sync import pays that scan
    -- once per imported message (the sync_messages projection selects
    -- FROM events WHERE id=...), which made the import batch grow with the
    -- store: 24.6 ms per message on a 21,471-event store, against ~0 with
    -- this index (#910's remaining reprocess drift, measured statement by
    -- statement on a captured import batch).
    CREATE INDEX IF NOT EXISTS events_id ON events(id);
    CREATE TABLE IF NOT EXISTS read_cursors (
      team TEXT NOT NULL,
      agent TEXT NOT NULL,
      local_position INTEGER NOT NULL DEFAULT 0 CHECK(local_position >= 0),
      PRIMARY KEY(team, agent)
    );
    CREATE TABLE IF NOT EXISTS storage_metadata (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );
    -- Legacy store (read-only here). Created so the UNION queries always parse
    -- even on a brand-new install with no pre-event-log data.
    CREATE TABLE IF NOT EXISTS messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      team TEXT NOT NULL,
      from_agent TEXT NOT NULL,
      to_agent TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
      read_at TEXT
    );
    -- Phase-3 adoption is intentionally storm-proof. Everything that existed
    -- before the cursor model is treated as already delivered. Legacy rows get
    -- an exact audit marker without mutating read_at; event-log recipients start
    -- at the current global high-water. Fresh stores have no rows, so they start
    -- naturally at cursor zero.
    INSERT INTO events(type,id,team,agent,msg_id,at)
      SELECT 'message_read',
             'read-cursor-v1:' || m.team || ':' || m.to_agent || ':' || m.id,
             m.team,m.to_agent,CAST(m.id AS TEXT),
             strftime('%Y-%m-%dT%H:%M:%SZ','now')
        FROM messages m
       WHERE NOT EXISTS(SELECT 1 FROM storage_metadata
                         WHERE key='read_cursor_v1')
         AND NOT EXISTS(SELECT 1 FROM events r
                         WHERE r.type='message_read' AND r.team=m.team
                           AND r.agent=m.to_agent
                           AND r.msg_id=CAST(m.id AS TEXT));
    INSERT INTO read_cursors(team,agent,local_position)
      SELECT recipients.team,recipients.agent,
             COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)
        FROM (
          SELECT team,to_agent AS agent FROM events
           WHERE type='message_sent' AND team IS NOT NULL AND to_agent IS NOT NULL
          UNION
          SELECT team,to_agent AS agent FROM messages
        ) recipients
       WHERE NOT EXISTS(SELECT 1 FROM storage_metadata
                         WHERE key='read_cursor_v1')
      ON CONFLICT(team,agent) DO UPDATE SET local_position=MAX(
        read_cursors.local_position,excluded.local_position);
    INSERT OR IGNORE INTO storage_metadata(key,value)
      VALUES('read_cursor_v1','1');
    PRAGMA user_version=${_AGMSG_STORAGE_SCHEMA_REV};
    COMMIT;
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# --- contract: messages ----------------------------------------------------

# The one place a message becomes rows. Every caller that records a
# message_sent goes through this, including the one that lands messages pulled
# from a remote -- mirroring only what this machine sends would leave a reader
# of the legacy table able to see half a conversation, and the half it could not
# see is the one that made this worth doing (#689).
#
# WHAT THIS DOES NOT COVER. Worth stating where the code is, because "we write
# to the legacy table" invites the reading that any external viewer will keep
# working, and three kinds of store are outside it:
#
#   * A team on the jsonl driver has no legacy table to mirror into -- that
#     table is created here and in internal/init-db.sh and nowhere else. Such a
#     team is invisible to those readers and this cannot change that. Measured,
#     not assumed: the jsonl driver's only `messages` references are a field of
#     the sync pull payload.
#   * A team moved to its own store (drivers.partition=per-team) writes to a
#     different file. A viewer pointed at the shared store sees nothing for it,
#     mirrored or not.
#   * Rows that predate this are unmirrored in the other direction -- they exist
#     only in the legacy table -- which is what the UNION in list_unread and
#     history is still for.
#
# WHEN IT ENDS. Not on a date, and not "once everyone upgrades": the readers are
# other people's software and we cannot enumerate them. It ends when someone can
# show that nothing reads the table any more, and until someone does that work
# this is a supported interface rather than a migration step. Written down
# because an unbounded compatibility write with no stated exit becomes permanent
# by default, and then nobody knows whether it is load-bearing.
#
# Both tables in one transaction, and the legacy rowid recorded on the event.
# The correspondence is not bookkeeping: it is what every reader that unions the
# two tables uses to recognise one message rather than list it twice.
_sqlite_message_sent_sql() {
  local team="$1" from="$2" to="$3" body="$4" id="$5" at="$6"
  local tl fl ol bl il al
  tl="$(_sqlite_lit "$team")"; fl="$(_sqlite_lit "$from")"; ol="$(_sqlite_lit "$to")"
  # The body is the one value here that can end in a newline, and a command
  # substitution eats every trailing newline it is given. `_sqlite_lit` emits
  # the right bytes -- they are lost on the way back. The `printf x` sentinel
  # holds them, and is stripped again immediately. The other five values are
  # team and agent names, a UUID and a timestamp: all validated, none able to
  # end in a newline, so they do not need it.
  bl="$(_sqlite_lit "$body"; printf x)"; bl="${bl%x}"
  il="$(_sqlite_lit "$id")"; al="$(_sqlite_lit "$at")"
  printf '%s\n' "
    BEGIN IMMEDIATE;
    INSERT INTO messages (team,from_agent,to_agent,body,created_at)
    VALUES ('$tl','$fl','$ol','$bl','$al');
    INSERT INTO events (type,id,team,from_agent,to_agent,body,at,legacy_id)
    VALUES ('message_sent','$il','$tl','$fl','$ol','$bl','$al',last_insert_rowid());
    COMMIT;
  "
}

storage_send() {
  local team="$1" from="$2" to="$3" body="$4"
  local id at db; id="$(compat_uuid7)"; at="$(_sqlite_now)"; db="$(_sqlite_db "$team")"
  local insert; insert="$(_sqlite_message_sent_sql "$team" "$from" "$to" "$body" "$id" "$at")"
  # Try the INSERT first and only fall back to storage_init on failure (the #114
  # pattern). Running storage_init — which issues PRAGMA journal_mode=WAL and the
  # CREATE TABLE/INDEX statements — on EVERY send serializes badly under a
  # concurrent first-write fan-out and lost rows past the busy_timeout. The common
  # path is now a single INSERT; only a missing table pays the init + retry.
  # Keep message bodies out of argv. Linux can impose a much smaller effective
  # argv ceiling than macOS, so a valid large local message must travel on
  # sqlite3's stdin rather than as the final command-line SQL argument.
  # -bail, because this is now more than one statement. The CLI's default is to
  # report an error and keep going, so a batch whose second INSERT fails still
  # reaches its COMMIT and commits the first one. Measured: the retry below then
  # inserted the message a second time, leaving one row in the legacy table that
  # no event points at -- exactly the unlinked copy the correspondence exists to
  # prevent.
  agmsg_sqlite_warm
  if ! printf '%s\n' "$insert" | agmsg_sqlite -bail "$db" >/dev/null 2>&1; then
    storage_init "$team" >/dev/null
    agmsg_sqlite_warm
    printf '%s\n' "$insert" | agmsg_sqlite -bail "$db" >/dev/null 2>&1 || return 1
  fi
  printf '%s\n' "$id"
}

# storage_read_cursor_get <team> <agent> — opaque local read frontier.
storage_read_cursor_get() {
  local team="$1" agent="$2"
  storage_init "$team" >/dev/null || return 13
  _sqlite_data "$team" "SELECT COALESCE((SELECT local_position FROM read_cursors
    WHERE team='$(_sqlite_lit "$team")' AND agent='$(_sqlite_lit "$agent")'),0);"
}

# Advance one recipient's local read frontier after a successful driver scan.
# Exact IDs are recorded first; the frontier is then capped immediately before
# the first still-unread addressed message, so a stale/malformed caller cannot
# skip an unseen row merely by presenting a later cursor.
storage_read_cursor_consume() {
  local team="$1" agent="$2" target="$3"; shift 3
  case "$target" in ''|*[!0-9]*) echo runtime_error; return 13 ;; esac
  storage_init "$team" >/dev/null || { echo runtime_error; return 13; }
  local db tl al at id sql=""
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  at="$(_sqlite_now)"
  for id in "$@"; do
    sql="$sql
      INSERT INTO events(type,id,team,agent,msg_id,at)
      SELECT 'message_read','$(_sqlite_lit "$(compat_uuid7)")','$tl','$al',
             '$(_sqlite_lit "$id")','$(_sqlite_lit "$at")'
       WHERE NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team='$tl' AND r.agent='$al' AND r.msg_id='$(_sqlite_lit "$id")');
      -- Mirror the read into the legacy table, through the correspondence
      -- rather than by guessing an id. Without this an external viewer shows
      -- every message unread forever, which is a worse thing to hand someone
      -- than the disagreement it costs (#689).
      UPDATE messages SET read_at='$(_sqlite_lit "$at")'
       WHERE read_at IS NULL
         AND id = (SELECT e.legacy_id FROM events e
                    WHERE e.type='message_sent' AND e.team='$tl'
                      AND e.id='$(_sqlite_lit "$id")' AND e.legacy_id IS NOT NULL);"
  done
  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    $sql
    INSERT OR IGNORE INTO read_cursors(team,agent,local_position)
      VALUES('$tl','$al',0);
    UPDATE read_cursors SET local_position=MAX(local_position,COALESCE((
      SELECT MIN(e.seq)-1 FROM events e
       WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
         AND e.seq>read_cursors.local_position
         AND e.seq<=MIN($target,$(_sqlite_highwater))
         AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
           AND r.team=e.team AND r.agent='$al' AND r.msg_id=e.id)
    ),MIN($target,$(_sqlite_highwater))))
    WHERE team='$tl' AND agent='$al';
    COMMIT;" >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# storage_list_unread <team> <agent> [--limit N]
# The local cursor is the fast contiguous boundary; exact message_read events
# cover safe out-of-order reads. Legacy rows remain a frozen compatibility path.
storage_list_unread() {
  local team="$1" agent="$2" limit=""
  shift 2
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init "$team" >/dev/null
  local tl al; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  _sqlite_data "$team" "
    SELECT j FROM (
      SELECT json_object('type','message_sent','id',e.id,'team',e.team,
               'from',e.from_agent,'to',e.to_agent,'body',e.body,'at',e.at) AS j,
             e.at AS ts, 1 AS src, e.seq AS ord
      FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.to_agent='$al'
        AND e.seq>COALESCE((SELECT local_position FROM read_cursors
          WHERE team='$tl' AND agent='$al'),0)
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=e.team AND r.agent='$al' AND r.msg_id=e.id)
      UNION ALL
      SELECT json_object('type','message_sent','id',CAST(m.id AS TEXT),'team',m.team,
               'from',m.from_agent,'to',m.to_agent,'body',m.body,'at',m.created_at) AS j,
             m.created_at AS ts, 0 AS src, m.id AS ord
      FROM messages m
      WHERE m.team='$tl' AND m.to_agent='$al' AND m.read_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read'
                        AND r.team=m.team AND r.agent='$al' AND r.msg_id=CAST(m.id AS TEXT))
        -- Skip the copy of a message that is already in the event log. Every
        -- message is written to both tables so external readers of the legacy
        -- one keep working (#689); without this the union lists it twice, and
        -- marking one read leaves the other behind because the two branches
        -- number rows in different spaces.
        --
        -- Live space only (seq > 0). A legacy row that was PROJECTED for push
        -- also carries an event, but at a negative seq, deliberately below every
        -- read cursor -- so the events branch above can never return it. Skipping
        -- the legacy row on account of that event would remove the message from
        -- the inbox entirely while history still showed it. Measured: the first
        -- version of this dedupe did exactly that.
        AND NOT EXISTS (SELECT 1 FROM events e2
                         WHERE e2.legacy_id = m.id AND e2.seq > 0)
    )
    ORDER BY ts, src, ord ${limit:+LIMIT $limit};
  "
}

# storage_mark_read_batch <team> <agent> <id> [<id> ...]  (control op)
storage_mark_read_batch() {
  local team="$1" agent="$2"; shift 2
  [ $# -gt 0 ] || { echo ok; return 0; }
  local tip; tip=$(storage_watch_tip "$team:$agent") || { echo runtime_error; return 13; }
  storage_read_cursor_consume "$team" "$agent" "$tip" "$@"
}

# --- contract: delivery cursor ---------------------------------------------

# The delivery tip is the monotonic AUTOINCREMENT high-water (largest rowid ever
# assigned to `events`), read from sqlite_sequence — NOT MAX(seq) over live rows.
# A DELETE-based storage_compact can lower MAX(seq) (e.g. by coalescing the
# tail message_read) but never the high-water, so a cursor issued before a
# compaction stays valid and a fresh tip never moves backwards (§2.7 cursor-safe).
_sqlite_highwater() {
  printf "COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'),0)"
}

storage_watch_tip() {
  local team; team="$(agmsg_pair_team "$@")" || return 13
  storage_init "$team" >/dev/null
  _sqlite_data "$team" "SELECT $(_sqlite_highwater);"
}

storage_watch_after() {
  local cursor="$1"; shift
  local team; team="$(agmsg_pair_team "$@")" || return 13
  case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
  local pairs; pairs="$(_sqlite_pair_in "$@")"
  # The message scan and the trailing-cursor (high-water) read MUST observe the
  # same snapshot, or a row inserted between the two statements would advance the
  # cursor past a message the scan never returned — a silent skip. A deferred read
  # transaction pins one WAL snapshot across both SELECTs, so the emitted cursor
  # never runs ahead of what the scan saw (§2.2 "never skip").
  _sqlite_data "$team" "
    BEGIN;
    SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                       'to',to_agent,'body',body,'at',at)
    FROM events
    WHERE type='message_sent' AND seq > $cursor
      AND (team || ':' || to_agent) IN ($pairs)
      AND NOT EXISTS(SELECT 1 FROM events r
        WHERE r.type='message_read' AND r.team=events.team
          AND r.agent=events.to_agent AND r.msg_id=events.id)
    ORDER BY seq ASC;
    SELECT json_object('type','cursor','cursor',
                       CAST(MAX($cursor, $(_sqlite_highwater)) AS TEXT));
    COMMIT;
  "
}

# --- contract: history -----------------------------------------------------

# storage_history <team> [agent] [--limit N]  — events ∪ legacy in time order.
# With <agent>, only rows where that agent is sender or recipient; omit it (empty)
# for the whole team (§2.1 G3 — an additive widening, existing callers unchanged).
storage_history() {
  local team="$1"; shift
  local agent="" limit=""
  # <agent> is optional: consume a leading NON-flag argument as the agent (an
  # empty string is allowed and also means team-wide). A leading --flag means no
  # agent was given. This is what makes `storage_history <team> --limit N` and
  # `storage_history <team>` parse correctly per the §2.1 contract (review).
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then agent="$1"; shift; fi
  while [ $# -gt 0 ]; do case "$1" in --limit) limit="$2"; shift 2 ;; *) shift ;; esac; done
  case "$limit" in ''|*[!0-9]*) limit="" ;; esac
  storage_init "$team" >/dev/null
  local tl al afilter; tl="$(_sqlite_lit "$team")"; al="$(_sqlite_lit "$agent")"
  if [ -n "$agent" ]; then
    afilter="AND (to_agent='$al' OR from_agent='$al')"
  else
    afilter=""
  fi
  # --limit returns the most RECENT N (inner DESC + LIMIT), re-sorted to
  # chronological order for output — the intuitive "recent history" semantics,
  # not the oldest N.
  _sqlite_data "$team" "
    SELECT j FROM (
      SELECT j, ts, src, ord FROM (
        SELECT json_object('type','message_sent','id',id,'team',team,'from',from_agent,
                 'to',to_agent,'body',body,'at',at) AS j, at AS ts, 1 AS src, seq AS ord
        FROM events
        WHERE type='message_sent' AND team='$tl' $afilter
        UNION ALL
        SELECT json_object('type','message_sent','id',CAST(id AS TEXT),'team',team,
                 'from',from_agent,'to',to_agent,'body',body,'at',created_at) AS j,
               created_at AS ts, 0 AS src, id AS ord
        FROM messages
        WHERE team='$tl' $afilter
          -- The event log already carries the mirrored copy (#689); listing
          -- both shows one message twice.
          AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id = messages.id)
      )
      ORDER BY ts DESC, src DESC, ord DESC ${limit:+LIMIT $limit}
    )
    ORDER BY ts ASC, src ASC, ord ASC;
  "
}

# --- contract: export / import / compact -----------------------------------

storage_export() {
  local team="$1" file="$2"
  storage_init "$team" >/dev/null
  # Forward-compat (§2.3): only the v1 event types are projected. A WHERE filter
  # (not just a CASE) keeps unknown-type rows out entirely, so they never surface
  # as a NULL → blank line on stdout, matching list_unread/history/watch_after.
  _sqlite_data "$team" "
    SELECT CASE type
      WHEN 'message_sent' THEN json_object('type','message_sent','id',id,'team',team,
             'from',from_agent,'to',to_agent,'body',body,'at',at)
      WHEN 'message_read' THEN json_object('type','message_read','id',id,'team',team,
             'agent',agent,'msg_id',msg_id,'at',at)
    END
    FROM events
    WHERE type IN ('message_sent','message_read')
    ORDER BY seq ASC;
  " > "$file"
}

storage_import() {
  # `selector`, not `team`: the loop below reuses `team` for the team named by
  # each imported RECORD, which is a different thing from the store being
  # written to. Sharing one name here would read as if they had to match.
  local selector="$1" file="$2" db; db="$(_sqlite_db "$selector")"
  [ -f "$file" ] || return 1
  storage_init "$selector" >/dev/null
  local line t id team frm to body msg_id agent at
  j() { sqlite3 :memory: "SELECT COALESCE(json_extract('$(_sqlite_lit "$line")','\$.$1'),'')" 2>/dev/null | tr -d '\r'; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    t=$(j type); id=$(j id); team=$(j team); at=$(j at)
    if [ "$t" = message_sent ]; then
      frm=$(j from); to=$(j to); body=$(j body)
      # Same utility as a live send, so an imported store presents the same
      # legacy view as the store it came from (#689).
      agmsg_sqlite_warm
      printf '%s\n' "$(_sqlite_message_sent_sql "$team" "$frm" "$to" "$body" "$id" "$at")" \
        | agmsg_sqlite -bail "$db" >/dev/null 2>&1
    elif [ "$t" = message_read ]; then
      agent=$(j agent); msg_id=$(j msg_id)
      agmsg_sqlite "$db" "INSERT INTO events (type,id,team,agent,msg_id,at)
        VALUES ('message_read','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
                '$(_sqlite_lit "$agent")','$(_sqlite_lit "$msg_id")','$(_sqlite_lit "$at")');
        UPDATE messages SET read_at='$(_sqlite_lit "$at")'
         WHERE read_at IS NULL
           AND id = (SELECT e.legacy_id FROM events e
                      WHERE e.type='message_sent' AND e.team='$(_sqlite_lit "$team")'
                        AND e.id='$(_sqlite_lit "$msg_id")' AND e.legacy_id IS NOT NULL);" \
        >/dev/null 2>&1
    fi
  done < "$file"
}

# Internal (§2.7): coalesce duplicate message_read markers, keeping the earliest. (control op)
storage_compact() {
  local db; db="$(_sqlite_db "$1")"
  agmsg_sqlite "$db" "
    DELETE FROM events WHERE type='message_read' AND seq NOT IN (
      SELECT MIN(seq) FROM events WHERE type='message_read'
      GROUP BY team, agent, msg_id);
  " >/dev/null 2>&1 || { echo runtime_error; return 13; }
  echo ok
}

# Optional Stage-1 remote synchronization extension. Keep the
# implementation separate from the local storage ABI so local-only callers do
# not pay its jq/base64 dependency cost.
# shellcheck disable=SC1090
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sqlite-sync.sh"
