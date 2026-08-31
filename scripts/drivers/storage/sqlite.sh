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
_sqlite_lit() {
  local q="'"
  printf '%s' "${1//$q/$q$q}"
}

# Unlike _sqlite_lit, this returns a COMPLETE SQL text expression. It exists
# only for values whose trailing LF must survive command substitution; changing
# _sqlite_lit itself would break its public byte-for-byte quoting contract.
_sqlite_text_expr() {
  local quote="'" newline=$'\n' value
  value="${1//$quote/$quote$quote}"
  value="${value//$newline/$quote || char(10) || $quote}"
  printf "'%s'" "$value"
}

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
  ( set -o pipefail; printf '%s\n' "$2" | agmsg_sqlite -bail -batch "$(_sqlite_db "$1")" | tr -d '\r' )
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
  printf 'capabilities=stage1-sync,stage1-resync,stage2-read-state,lifecycle-v1\n'
  [ -z "${1-}" ] || printf 'db=%s\n' "$(_sqlite_db "$1")"
}

# Does a store already exist? (does NOT create one — lets a read call-site answer
# "no messages yet" without lazily initializing a store in a storeless project.)
storage_store_exists() { [ -f "$(_sqlite_db "$1")" ]; }

# Bumped whenever the init batch below changes shape: it is what lets a store
# that already carries revision N skip the batch entirely (#1001). The number
# is stamped INSIDE the same transaction as the schema statements, so a store
# can never hold the new number over an old schema.
_AGMSG_STORAGE_SCHEMA_REV=2

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
    CREATE TABLE IF NOT EXISTS lifecycle_messages (
      team          TEXT NOT NULL,
      sender        TEXT NOT NULL,
      operation_key TEXT NOT NULL,
      message_id    TEXT NOT NULL UNIQUE,
      recipient     TEXT NOT NULL,
      kind          TEXT NOT NULL CHECK(kind IN ('info','action','terminal')),
      wake_target   TEXT NOT NULL,
      created_at    TEXT NOT NULL,
      PRIMARY KEY(team,sender,operation_key)
    );
    CREATE INDEX IF NOT EXISTS lifecycle_messages_recipient
      ON lifecycle_messages(team,recipient,created_at,message_id);
    CREATE TABLE IF NOT EXISTS lifecycle_events (
      seq           INTEGER PRIMARY KEY AUTOINCREMENT,
      id            TEXT NOT NULL UNIQUE,
      type          TEXT NOT NULL,
      team          TEXT NOT NULL,
      operation_key TEXT NOT NULL,
      message_id    TEXT,
      actor         TEXT,
      result        TEXT,
      reason        TEXT,
      target        TEXT,
      work_key      TEXT,
      state         TEXT,
      generation    INTEGER,
      origin        TEXT,
      wake_target   TEXT,
      stall_deadline INTEGER,
      at            TEXT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_delivery_once
      ON lifecycle_events(type,message_id) WHERE type='delivery_receipt';
    CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_ack_once
      ON lifecycle_events(type,message_id) WHERE type='application_ack';
    CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_work_operation_once
      ON lifecycle_events(team,operation_key) WHERE type='work_event';
    CREATE INDEX IF NOT EXISTS lifecycle_events_operation
      ON lifecycle_events(team,operation_key,seq);
    CREATE TABLE IF NOT EXISTS lifecycle_processing_leases (
      message_id       TEXT PRIMARY KEY,
      consumer         TEXT NOT NULL,
      expires_at       INTEGER NOT NULL,
      attempt          INTEGER NOT NULL CHECK(attempt > 0),
      read_receipt_id  TEXT NOT NULL,
      updated_at       TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS lifecycle_outbox (
      seq              INTEGER PRIMARY KEY AUTOINCREMENT,
      id               TEXT NOT NULL UNIQUE,
      team             TEXT NOT NULL,
      operation_key    TEXT NOT NULL,
      kind             TEXT NOT NULL CHECK(kind IN ('wake','cleanup','launch')),
      target           TEXT NOT NULL,
      message_id       TEXT,
      status           TEXT NOT NULL DEFAULT 'pending'
                         CHECK(status IN ('pending','leased','done')),
      available_at     INTEGER NOT NULL,
      lease_owner      TEXT,
      lease_expires_at INTEGER,
      attempt          INTEGER NOT NULL DEFAULT 0 CHECK(attempt >= 0),
      last_error       TEXT,
      created_at       TEXT NOT NULL,
      updated_at       TEXT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_outbox_message_once
      ON lifecycle_outbox(team,operation_key,kind,target,message_id)
      WHERE message_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS lifecycle_outbox_work_once
      ON lifecycle_outbox(team,operation_key,kind,target)
      WHERE message_id IS NULL;
    CREATE INDEX IF NOT EXISTS lifecycle_outbox_ready
      ON lifecycle_outbox(status,available_at,lease_expires_at,seq);
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
_sqlite_message_sent_sql_expr() {
  local team="$1" from="$2" to="$3" body_expr="$4" id="$5" at="$6"
  local tl fl ol il al
  tl="$(_sqlite_lit "$team")"; fl="$(_sqlite_lit "$from")"; ol="$(_sqlite_lit "$to")"
  il="$(_sqlite_lit "$id")"; al="$(_sqlite_lit "$at")"
  printf '%s\n' "BEGIN IMMEDIATE;"
  _sqlite_message_sent_statements_expr "$team" "$from" "$to" "$body_expr" "$id" "$at"
  printf '%s\n' "COMMIT;"
}

_sqlite_message_sent_statements_expr() {
  local team="$1" from="$2" to="$3" body_expr="$4" id="$5" at="$6"
  local tl fl ol il al
  tl="$(_sqlite_lit "$team")"; fl="$(_sqlite_lit "$from")"; ol="$(_sqlite_lit "$to")"
  il="$(_sqlite_lit "$id")"; al="$(_sqlite_lit "$at")"
  printf '%s\n' "
    INSERT INTO messages (team,from_agent,to_agent,body,created_at)
    VALUES ('$tl','$fl','$ol',$body_expr,'$al');
    INSERT INTO events (type,id,team,from_agent,to_agent,body,at,legacy_id)
    VALUES ('message_sent','$il','$tl','$fl','$ol',$body_expr,'$al',last_insert_rowid());
  "
}

_sqlite_message_sent_sql() {
  local body_expr
  body_expr="'$(_sqlite_lit "$4")'"
  _sqlite_message_sent_sql_expr "$1" "$2" "$3" "$body_expr" "$5" "$6"
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

# --- optional lifecycle-v1 extension ---------------------------------------

storage_capabilities() {
  printf '%s\n' '{"schema":"agmsg-lifecycle-capabilities/v1","driver":"sqlite","capabilities":{"operation_key":"supported","delivery_receipt":"supported","read_receipt":"supported","processing_lease_renewal":"supported","application_ack":"supported","work_registration":"supported","work_event":"supported","outbox":"supported","history_query":"supported"}}'
}

_sqlite_lifecycle_kind_valid() {
  case "$1" in info|action|terminal) return 0 ;; *) return 1 ;; esac
}

_sqlite_lifecycle_result_valid() {
  case "$1" in applied|rejected|failed) return 0 ;; *) return 1 ;; esac
}

_sqlite_lifecycle_work_state_valid() {
  case "$1" in registered|running|blocked|terminal|closed|attention|error) return 0 ;; *) return 1 ;; esac
}

_sqlite_lifecycle_token_valid() {
  local without_controls unicode_controls
  [ -n "$1" ] || return 1
  without_controls="$(printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:]')"
  [ "$without_controls" = "$1" ] || return 1
  unicode_controls="$(sqlite3 :memory: "
    WITH RECURSIVE input(value) AS (SELECT $(_sqlite_text_expr "$1")),
      positions(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM positions,input WHERE n<length(input.value))
    SELECT EXISTS(
      SELECT 1 FROM input,positions
       WHERE unicode(substr(input.value,n,1)) BETWEEN 1 AND 31
          OR unicode(substr(input.value,n,1)) BETWEEN 127 AND 159);" 2>/dev/null)" || return 1
  [ "$unicode_controls" = 0 ]
}

storage_work_register() {
  local team="$1" work_key="$2" operation_key="$3" actor="$4" generation="$5"
  local origin="$6" launch_target="$7" wake_target="$8" stall_deadline="${9-}"
  case "$generation:$stall_deadline" in
    *[!0-9:]*|:*|*:) echo "agmsg: invalid work registration" >&2; return 13 ;;
  esac
  if ! _sqlite_lifecycle_token_valid "$work_key" || ! _sqlite_lifecycle_token_valid "$operation_key" \
    || ! _sqlite_lifecycle_token_valid "$actor" || ! _sqlite_lifecycle_token_valid "$origin" \
    || ! _sqlite_lifecycle_token_valid "$launch_target" || ! _sqlite_lifecycle_token_valid "$wake_target" \
    || [ "$generation" -le 0 ] || [ "$stall_deadline" -le 0 ]; then
    echo "agmsg: invalid work registration" >&2
    return 13
  fi
  storage_init "$team" >/dev/null || return 13

  local event_id outbox_id at output
  event_id="$(compat_uuid7)"; outbox_id="$(compat_uuid7)"; at="$(_sqlite_now)"
  output="$(_sqlite_data_stdin "$team" "
    BEGIN IMMEDIATE;
    CREATE TEMP TABLE lifecycle_work_new(inserted INTEGER NOT NULL);
    INSERT OR IGNORE INTO lifecycle_events
      (id,type,team,operation_key,actor,target,work_key,state,generation,origin,wake_target,stall_deadline,at)
    VALUES
      ('$(_sqlite_lit "$event_id")','work_event','$(_sqlite_lit "$team")',
       '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$actor")',
       '$(_sqlite_lit "$launch_target")','$(_sqlite_lit "$work_key")','registered',
       $generation,'$(_sqlite_lit "$origin")','$(_sqlite_lit "$wake_target")',
       $stall_deadline,'$(_sqlite_lit "$at")');
    INSERT INTO lifecycle_work_new VALUES(changes());
    INSERT INTO lifecycle_outbox
      (id,team,operation_key,kind,target,status,available_at,created_at,updated_at)
      SELECT '$(_sqlite_lit "$outbox_id")','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$operation_key")','launch','$(_sqlite_lit "$launch_target")',
             'pending',CAST(strftime('%s','now') AS INTEGER),
             '$(_sqlite_lit "$at")','$(_sqlite_lit "$at")'
       WHERE (SELECT inserted FROM lifecycle_work_new)=1;
    INSERT INTO lifecycle_events
      (id,type,team,operation_key,actor,result,work_key,generation,origin,wake_target,stall_deadline,at)
      SELECT '$(_sqlite_lit "$outbox_id")','outbox_pending','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$launch_target")','launch',
             '$(_sqlite_lit "$work_key")',$generation,'$(_sqlite_lit "$origin")',
             '$(_sqlite_lit "$wake_target")',$stall_deadline,'$(_sqlite_lit "$at")'
       WHERE (SELECT inserted FROM lifecycle_work_new)=1;
    DROP TABLE lifecycle_work_new;
    COMMIT;
    SELECT json_object('type','work_registration','id',le.id,'team',le.team,
      'operation_key',le.operation_key,'work_key',le.work_key,'actor',le.actor,
      'state',le.state,'generation',le.generation,'origin',le.origin,
      'launch_target',le.target,'wake_target',le.wake_target,
      'stall_deadline',le.stall_deadline,'at',le.at,'launch_outbox_id',o.id)
      FROM lifecycle_events le JOIN lifecycle_outbox o
        ON o.team=le.team AND o.operation_key=le.operation_key
       AND o.kind='launch' AND o.target=le.target
     WHERE le.type='work_event' AND le.team='$(_sqlite_lit "$team")'
       AND le.operation_key='$(_sqlite_lit "$operation_key")'
       AND le.work_key='$(_sqlite_lit "$work_key")' AND le.actor='$(_sqlite_lit "$actor")'
       AND le.state='registered' AND le.generation=$generation
       AND le.origin='$(_sqlite_lit "$origin")' AND le.target='$(_sqlite_lit "$launch_target")'
       AND le.wake_target='$(_sqlite_lit "$wake_target")'
       AND le.stall_deadline=$stall_deadline;")" || return 13
  if [ -z "$output" ]; then
    echo "agmsg: operation_key_conflict" >&2
    return 13
  fi
  printf '%s\n' "$output"
}

storage_work_event() {
  local team="$1" work_key="$2" operation_key="$3" actor="$4" state="$5"
  local result="${6-}" reason="${7-}"
  if ! _sqlite_lifecycle_token_valid "$work_key" || ! _sqlite_lifecycle_token_valid "$operation_key" \
      || ! _sqlite_lifecycle_token_valid "$actor" || ! _sqlite_lifecycle_work_state_valid "$state"; then
    echo "agmsg: invalid work event" >&2
    return 13
  fi
  storage_init "$team" >/dev/null || return 13
  local event_id at output
  event_id="$(compat_uuid7)"; at="$(_sqlite_now)"
  output="$(_sqlite_data_stdin "$team" "
    BEGIN IMMEDIATE;
    INSERT OR IGNORE INTO lifecycle_events
      (id,type,team,operation_key,actor,result,reason,work_key,state,at)
    VALUES
      ('$(_sqlite_lit "$event_id")','work_event','$(_sqlite_lit "$team")',
       '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$actor")',
       '$(_sqlite_lit "$result")','$(_sqlite_lit "$reason")',
       '$(_sqlite_lit "$work_key")','$(_sqlite_lit "$state")','$(_sqlite_lit "$at")');
    COMMIT;
    SELECT json_object('type','work_event','id',id,'team',team,
      'operation_key',operation_key,'work_key',work_key,'actor',actor,
      'state',state,'result',result,'reason',reason,'at',at)
      FROM lifecycle_events
     WHERE type='work_event' AND team='$(_sqlite_lit "$team")'
       AND operation_key='$(_sqlite_lit "$operation_key")'
       AND work_key='$(_sqlite_lit "$work_key")' AND actor='$(_sqlite_lit "$actor")'
       AND state='$(_sqlite_lit "$state")' AND COALESCE(result,'')='$(_sqlite_lit "$result")'
       AND COALESCE(reason,'')='$(_sqlite_lit "$reason")';")" || return 13
  if [ -z "$output" ]; then
    echo "agmsg: operation_key_conflict" >&2
    return 13
  fi
  printf '%s\n' "$output"
}

storage_operation_send() {
  local team="$1" sender="$2" recipient="$3" kind="$4" operation_key="$5"
  local wake_target="$6" body="$7"
  if ! _sqlite_lifecycle_token_valid "$sender" || ! _sqlite_lifecycle_token_valid "$recipient" \
      || ! _sqlite_lifecycle_kind_valid "$kind" || ! _sqlite_lifecycle_token_valid "$operation_key" \
      || ! _sqlite_lifecycle_token_valid "$wake_target"; then
    echo "agmsg: invalid lifecycle send request" >&2
    return 13
  fi
  storage_init "$team" >/dev/null || return 13

  local message_id receipt_id outbox_id at sql output
  message_id="$(compat_uuid7)"; receipt_id="$(compat_uuid7)"; outbox_id="$(compat_uuid7)"
  at="$(_sqlite_now)"
  sql="
    BEGIN IMMEDIATE;
    CREATE TEMP TABLE lifecycle_new(inserted INTEGER NOT NULL);
    INSERT OR IGNORE INTO lifecycle_messages
      (team,sender,operation_key,message_id,recipient,kind,wake_target,created_at)
    VALUES
      ('$(_sqlite_lit "$team")','$(_sqlite_lit "$sender")','$(_sqlite_lit "$operation_key")',
       '$(_sqlite_lit "$message_id")','$(_sqlite_lit "$recipient")','$(_sqlite_lit "$kind")',
       '$(_sqlite_lit "$wake_target")','$(_sqlite_lit "$at")');
    INSERT INTO lifecycle_new VALUES(changes());
    INSERT INTO messages(team,from_agent,to_agent,body,created_at)
      SELECT '$(_sqlite_lit "$team")','$(_sqlite_lit "$sender")',
             '$(_sqlite_lit "$recipient")',$(_sqlite_text_expr "$body"),'$(_sqlite_lit "$at")'
       WHERE (SELECT inserted FROM lifecycle_new)=1;
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id)
      SELECT 'message_sent','$(_sqlite_lit "$message_id")','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$sender")','$(_sqlite_lit "$recipient")',
             $(_sqlite_text_expr "$body"),'$(_sqlite_lit "$at")',last_insert_rowid()
       WHERE (SELECT inserted FROM lifecycle_new)=1;
    INSERT INTO lifecycle_events
      (id,type,team,operation_key,message_id,actor,at)
      SELECT '$(_sqlite_lit "$receipt_id")','delivery_receipt','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$message_id")',
             '$(_sqlite_lit "$recipient")','$(_sqlite_lit "$at")'
       WHERE (SELECT inserted FROM lifecycle_new)=1;
    INSERT INTO lifecycle_outbox
      (id,team,operation_key,kind,target,message_id,status,available_at,created_at,updated_at)
      SELECT '$(_sqlite_lit "$outbox_id")','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$operation_key")','wake','$(_sqlite_lit "$wake_target")',
             '$(_sqlite_lit "$message_id")','pending',CAST(strftime('%s','now') AS INTEGER),
             '$(_sqlite_lit "$at")','$(_sqlite_lit "$at")'
       WHERE (SELECT inserted FROM lifecycle_new)=1;
    INSERT INTO lifecycle_events
      (id,type,team,operation_key,message_id,actor,result,at)
      SELECT '$(_sqlite_lit "$outbox_id")','outbox_pending','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$message_id")',
             '$(_sqlite_lit "$wake_target")','wake','$(_sqlite_lit "$at")'
       WHERE (SELECT inserted FROM lifecycle_new)=1;
    DROP TABLE lifecycle_new;
    COMMIT;
    SELECT json_object(
      'type','message_sent','id',lm.message_id,'team',lm.team,'from',lm.sender,
      'to',lm.recipient,'kind',lm.kind,'operation_key',lm.operation_key,
      'body',e.body,'at',lm.created_at,'delivery_receipt_id',lr.id)
    FROM lifecycle_messages lm
    JOIN events e ON e.type='message_sent' AND e.id=lm.message_id
    JOIN lifecycle_events lr ON lr.type='delivery_receipt' AND lr.message_id=lm.message_id
    WHERE lm.team='$(_sqlite_lit "$team")' AND lm.sender='$(_sqlite_lit "$sender")'
      AND lm.operation_key='$(_sqlite_lit "$operation_key")'
      AND lm.recipient='$(_sqlite_lit "$recipient")' AND lm.kind='$(_sqlite_lit "$kind")'
      AND lm.wake_target='$(_sqlite_lit "$wake_target")' AND e.body=$(_sqlite_text_expr "$body");"
  output="$(_sqlite_data_stdin "$team" "$sql")" || return 13
  if [ -z "$output" ]; then
    echo "agmsg: operation_key_conflict" >&2
    return 13
  fi
  printf '%s\n' "$output"
}

storage_operation_fetch() {
  local team="$1" recipient="$2" consumer="$3" lease_seconds="$4"
  if ! _sqlite_lifecycle_token_valid "$recipient" || ! _sqlite_lifecycle_token_valid "$consumer"; then
    echo "agmsg: invalid lifecycle fetch request" >&2
    return 13
  fi
  case "$lease_seconds" in ''|*[!0-9]*) echo "agmsg: invalid lifecycle lease" >&2; return 13 ;; esac
  [ "$lease_seconds" -gt 0 ] || { echo "agmsg: invalid lifecycle lease" >&2; return 13; }
  storage_init "$team" >/dev/null || return 13

  local receipt_id read_event_id at sql output
  receipt_id="$(compat_uuid7)"; read_event_id="$(compat_uuid7)"; at="$(_sqlite_now)"
  sql="
    BEGIN IMMEDIATE;
    CREATE TEMP TABLE processing_expired AS
      SELECT p.message_id,p.attempt FROM lifecycle_processing_leases p
      JOIN lifecycle_messages lm ON lm.message_id=p.message_id
      WHERE lm.team='$(_sqlite_lit "$team")' AND lm.recipient='$(_sqlite_lit "$recipient")'
        AND p.expires_at<=CAST(strftime('%s','now') AS INTEGER);
    UPDATE lifecycle_outbox SET status='pending',
      available_at=CAST(strftime('%s','now') AS INTEGER)+(
        SELECT CASE
          WHEN p.attempt<=1 THEN 5 WHEN p.attempt=2 THEN 10
          WHEN p.attempt=3 THEN 20 WHEN p.attempt=4 THEN 40
          WHEN p.attempt=5 THEN 80 ELSE 300 END
        FROM processing_expired p WHERE p.message_id=lifecycle_outbox.message_id),
      lease_owner=NULL,lease_expires_at=NULL,updated_at='$(_sqlite_lit "$at")'
      WHERE team='$(_sqlite_lit "$team")' AND kind='wake'
        AND message_id IN (SELECT message_id FROM processing_expired);
    INSERT OR IGNORE INTO lifecycle_events
      (id,type,team,operation_key,message_id,actor,result,reason,at)
      SELECT o.id || ':processing-expired:' || p.attempt,'outbox_pending',o.team,
             o.operation_key,o.message_id,o.target,'wake','processing_lease_expired',
             '$(_sqlite_lit "$at")'
        FROM lifecycle_outbox o JOIN processing_expired p ON p.message_id=o.message_id
       WHERE o.team='$(_sqlite_lit "$team")' AND o.kind='wake';
    DELETE FROM lifecycle_processing_leases
      WHERE message_id IN (SELECT message_id FROM processing_expired);
    CREATE TEMP TABLE lifecycle_chosen AS
      SELECT lm.message_id,lm.operation_key,lm.kind,lm.sender,lm.recipient,lm.created_at,e.body,
             1+(SELECT COUNT(*) FROM lifecycle_events rr
                 WHERE rr.type='read_receipt' AND rr.message_id=lm.message_id) AS attempt
        FROM lifecycle_messages lm
        JOIN events e ON e.type='message_sent' AND e.id=lm.message_id
       WHERE lm.team='$(_sqlite_lit "$team")' AND lm.recipient='$(_sqlite_lit "$recipient")'
         AND (lm.kind!='info' OR NOT EXISTS(SELECT 1 FROM lifecycle_events ir
               WHERE ir.type='read_receipt' AND ir.message_id=lm.message_id))
         AND NOT EXISTS(SELECT 1 FROM lifecycle_events a
                         WHERE a.type='application_ack' AND a.message_id=lm.message_id)
         AND NOT EXISTS(SELECT 1 FROM lifecycle_processing_leases p
                         WHERE p.message_id=lm.message_id)
       ORDER BY lm.created_at,lm.message_id LIMIT 1;
    INSERT INTO lifecycle_processing_leases
      (message_id,consumer,expires_at,attempt,read_receipt_id,updated_at)
      SELECT message_id,'$(_sqlite_lit "$consumer")',
             CAST(strftime('%s','now') AS INTEGER)+$lease_seconds,attempt,
             '$(_sqlite_lit "$receipt_id")','$(_sqlite_lit "$at")'
        FROM lifecycle_chosen WHERE kind IN ('action','terminal');
    INSERT INTO lifecycle_events
      (id,type,team,operation_key,message_id,actor,result,at)
      SELECT '$(_sqlite_lit "$receipt_id")','read_receipt','$(_sqlite_lit "$team")',
             operation_key,message_id,'$(_sqlite_lit "$consumer")',kind,'$(_sqlite_lit "$at")'
        FROM lifecycle_chosen;
    INSERT INTO events(type,id,team,agent,msg_id,at)
      SELECT 'message_read','$(_sqlite_lit "$read_event_id")','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$recipient")',message_id,'$(_sqlite_lit "$at")'
        FROM lifecycle_chosen
       WHERE NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
                         AND r.team='$(_sqlite_lit "$team")'
                         AND r.agent='$(_sqlite_lit "$recipient")'
                         AND r.msg_id=lifecycle_chosen.message_id);
    UPDATE messages SET read_at='$(_sqlite_lit "$at")'
     WHERE read_at IS NULL AND id IN (
       SELECT e.legacy_id FROM events e JOIN lifecycle_chosen c ON c.message_id=e.id
        WHERE e.type='message_sent' AND e.legacy_id IS NOT NULL);
    UPDATE lifecycle_outbox SET status='done',lease_owner=NULL,lease_expires_at=NULL,
      updated_at='$(_sqlite_lit "$at")'
      WHERE kind='wake' AND message_id IN (SELECT message_id FROM lifecycle_chosen);
    SELECT json_object(
      'type','message_sent','id',c.message_id,'team','$(_sqlite_lit "$team")',
      'from',c.sender,'to',c.recipient,'kind',c.kind,'operation_key',c.operation_key,
      'body',c.body,'at',c.created_at,'read_receipt_id','$(_sqlite_lit "$receipt_id")',
      'attempt',c.attempt,'lease_expires_at',
      CASE WHEN c.kind IN ('action','terminal')
           THEN CAST(strftime('%s','now') AS INTEGER)+$lease_seconds ELSE NULL END)
      FROM lifecycle_chosen c;
    DROP TABLE processing_expired;
    DROP TABLE lifecycle_chosen;
    COMMIT;"
  output="$(_sqlite_data_stdin "$team" "$sql")" || return 13
  [ -z "$output" ] || printf '%s\n' "$output"
}

storage_operation_renew() {
  local team="$1" recipient="$2" message_id="$3" operation_key="$4"
  local consumer="$5" lease_seconds="$6" at output
  if ! _sqlite_lifecycle_token_valid "$recipient" || ! _sqlite_lifecycle_token_valid "$message_id" \
      || ! _sqlite_lifecycle_token_valid "$operation_key" || ! _sqlite_lifecycle_token_valid "$consumer"; then
    echo "agmsg: invalid processing lease renewal" >&2
    return 13
  fi
  case "$lease_seconds" in ''|*[!0-9]*) echo "agmsg: invalid lifecycle lease" >&2; return 13 ;; esac
  [ "$lease_seconds" -gt 0 ] || { echo "agmsg: invalid lifecycle lease" >&2; return 13; }
  storage_init "$team" >/dev/null || return 13
  at="$(_sqlite_now)"
  output="$(_sqlite_data_stdin "$team" "
    BEGIN IMMEDIATE;
    UPDATE lifecycle_processing_leases SET
      expires_at=CAST(strftime('%s','now') AS INTEGER)+$lease_seconds,
      updated_at='$(_sqlite_lit "$at")'
      WHERE message_id='$(_sqlite_lit "$message_id")'
        AND consumer='$(_sqlite_lit "$consumer")'
        AND expires_at>CAST(strftime('%s','now') AS INTEGER)
        AND EXISTS(SELECT 1 FROM lifecycle_messages lm
          WHERE lm.message_id=lifecycle_processing_leases.message_id
            AND lm.team='$(_sqlite_lit "$team")'
            AND lm.recipient='$(_sqlite_lit "$recipient")'
            AND lm.operation_key='$(_sqlite_lit "$operation_key")'
            AND lm.kind IN ('action','terminal'));
    SELECT json_object('type','processing_lease','message_id',p.message_id,
      'team',lm.team,'operation_key',lm.operation_key,'recipient',lm.recipient,
      'consumer',p.consumer,'expires_at',p.expires_at,'attempt',p.attempt,
      'updated_at',p.updated_at)
      FROM lifecycle_processing_leases p JOIN lifecycle_messages lm
        ON lm.message_id=p.message_id
      WHERE changes()=1 AND p.message_id='$(_sqlite_lit "$message_id")';
    COMMIT;")" || return 13
  if [ -z "$output" ]; then
    echo "agmsg: processing_lease_conflict" >&2
    return 13
  fi
  printf '%s\n' "$output"
}

storage_operation_ack() {
  local team="$1" recipient="$2" message_id="$3" operation_key="$4"
  local consumer="$5" result="$6" cleanup_target="$7" reason="${8-}"
  if ! _sqlite_lifecycle_token_valid "$recipient" || ! _sqlite_lifecycle_token_valid "$message_id" \
      || ! _sqlite_lifecycle_token_valid "$operation_key" || ! _sqlite_lifecycle_token_valid "$consumer" \
      || ! _sqlite_lifecycle_result_valid "$result" || ! _sqlite_lifecycle_token_valid "$cleanup_target"; then
    echo "agmsg: invalid lifecycle acknowledgement" >&2
    return 13
  fi
  storage_init "$team" >/dev/null || return 13

  local ack_id outbox_id at sql output
  ack_id="$(compat_uuid7)"; outbox_id="$(compat_uuid7)"; at="$(_sqlite_now)"
  sql="
    BEGIN IMMEDIATE;
    CREATE TEMP TABLE lifecycle_ack_allowed AS
      SELECT lm.message_id FROM lifecycle_messages lm
       WHERE lm.team='$(_sqlite_lit "$team")' AND lm.recipient='$(_sqlite_lit "$recipient")'
         AND lm.message_id='$(_sqlite_lit "$message_id")'
         AND lm.operation_key='$(_sqlite_lit "$operation_key")'
         AND (EXISTS(SELECT 1 FROM lifecycle_events a
                      WHERE a.type='application_ack' AND a.message_id=lm.message_id
                        AND a.actor='$(_sqlite_lit "$consumer")'
                        AND a.result='$(_sqlite_lit "$result")'
                        AND COALESCE(a.reason,'')='$(_sqlite_lit "$reason")'
                        AND a.target='$(_sqlite_lit "$cleanup_target")')
              OR EXISTS(SELECT 1 FROM lifecycle_processing_leases p
                         WHERE p.message_id=lm.message_id AND p.consumer='$(_sqlite_lit "$consumer")'
                           AND p.expires_at>CAST(strftime('%s','now') AS INTEGER)));
    INSERT OR IGNORE INTO lifecycle_events
      (id,type,team,operation_key,message_id,actor,result,reason,target,at)
      SELECT '$(_sqlite_lit "$ack_id")','application_ack','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$message_id")',
             '$(_sqlite_lit "$consumer")','$(_sqlite_lit "$result")',
             '$(_sqlite_lit "$reason")','$(_sqlite_lit "$cleanup_target")','$(_sqlite_lit "$at")'
        FROM lifecycle_ack_allowed;
    INSERT OR IGNORE INTO lifecycle_outbox
      (id,team,operation_key,kind,target,message_id,status,available_at,created_at,updated_at)
      SELECT '$(_sqlite_lit "$outbox_id")','$(_sqlite_lit "$team")',
             '$(_sqlite_lit "$operation_key")','cleanup','$(_sqlite_lit "$cleanup_target")',
             '$(_sqlite_lit "$message_id")','pending',CAST(strftime('%s','now') AS INTEGER),
             '$(_sqlite_lit "$at")','$(_sqlite_lit "$at")'
        FROM lifecycle_ack_allowed;
    INSERT OR IGNORE INTO lifecycle_events
      (id,type,team,operation_key,message_id,actor,result,at)
      SELECT o.id,'outbox_pending',o.team,o.operation_key,o.message_id,o.target,o.kind,o.created_at
        FROM lifecycle_outbox o JOIN lifecycle_ack_allowed a ON a.message_id=o.message_id
       WHERE o.kind='cleanup';
    DELETE FROM lifecycle_processing_leases
      WHERE message_id IN (SELECT message_id FROM lifecycle_ack_allowed)
        AND consumer='$(_sqlite_lit "$consumer")';
    DROP TABLE lifecycle_ack_allowed;
    COMMIT;
    SELECT json_object('type','application_ack','id',id,'team',team,
      'operation_key',operation_key,'message_id',message_id,'consumer',actor,
      'result',result,'reason',reason,'at',at)
      FROM lifecycle_events
     WHERE type='application_ack' AND team='$(_sqlite_lit "$team")'
       AND message_id='$(_sqlite_lit "$message_id")'
       AND operation_key='$(_sqlite_lit "$operation_key")'
       AND actor='$(_sqlite_lit "$consumer")' AND result='$(_sqlite_lit "$result")'
       AND COALESCE(reason,'')='$(_sqlite_lit "$reason")'
       AND target='$(_sqlite_lit "$cleanup_target")';"
  output="$(_sqlite_data_stdin "$team" "$sql")" || return 13
  if [ -z "$output" ]; then
    echo "agmsg: acknowledgement_conflict" >&2
    return 13
  fi
  printf '%s\n' "$output"
}

storage_outbox_claim() {
  local team="$1" owner="$2" lease_seconds="$3"
  _sqlite_lifecycle_token_valid "$owner" || { echo "agmsg: invalid outbox owner" >&2; return 13; }
  case "$lease_seconds" in ''|*[!0-9]*) echo "agmsg: invalid outbox lease" >&2; return 13 ;; esac
  [ "$lease_seconds" -gt 0 ] || { echo "agmsg: invalid outbox lease" >&2; return 13; }
  storage_init "$team" >/dev/null || return 13
  local at output; at="$(_sqlite_now)"
  output="$(_sqlite_data_stdin "$team" "
    BEGIN IMMEDIATE;
    CREATE TEMP TABLE processing_expired AS
      SELECT p.message_id,p.attempt FROM lifecycle_processing_leases p
      JOIN lifecycle_messages lm ON lm.message_id=p.message_id
      WHERE lm.team='$(_sqlite_lit "$team")'
        AND p.expires_at<=CAST(strftime('%s','now') AS INTEGER);
    UPDATE lifecycle_outbox SET status='pending',
      available_at=CAST(strftime('%s','now') AS INTEGER)+(
        SELECT CASE
          WHEN p.attempt<=1 THEN 5 WHEN p.attempt=2 THEN 10
          WHEN p.attempt=3 THEN 20 WHEN p.attempt=4 THEN 40
          WHEN p.attempt=5 THEN 80 ELSE 300 END
        FROM processing_expired p WHERE p.message_id=lifecycle_outbox.message_id),
      lease_owner=NULL,lease_expires_at=NULL,updated_at='$(_sqlite_lit "$at")'
      WHERE team='$(_sqlite_lit "$team")' AND kind='wake'
        AND message_id IN (SELECT message_id FROM processing_expired);
    INSERT OR IGNORE INTO lifecycle_events
      (id,type,team,operation_key,message_id,actor,result,reason,at)
      SELECT o.id || ':processing-expired:' || p.attempt,'outbox_pending',o.team,
             o.operation_key,o.message_id,o.target,'wake','processing_lease_expired',
             '$(_sqlite_lit "$at")'
        FROM lifecycle_outbox o JOIN processing_expired p ON p.message_id=o.message_id
       WHERE o.team='$(_sqlite_lit "$team")' AND o.kind='wake';
    DELETE FROM lifecycle_processing_leases
      WHERE message_id IN (SELECT message_id FROM processing_expired);
    CREATE TEMP TABLE outbox_chosen AS
      SELECT id FROM lifecycle_outbox
       WHERE team='$(_sqlite_lit "$team")' AND available_at<=CAST(strftime('%s','now') AS INTEGER)
         AND (status='pending' OR (status='leased' AND lease_expires_at<=CAST(strftime('%s','now') AS INTEGER)))
       ORDER BY seq LIMIT 1;
    UPDATE lifecycle_outbox SET status='leased',lease_owner='$(_sqlite_lit "$owner")',
      lease_expires_at=CAST(strftime('%s','now') AS INTEGER)+$lease_seconds,
      attempt=attempt+1,updated_at='$(_sqlite_lit "$at")'
      WHERE id IN (SELECT id FROM outbox_chosen);
    SELECT json_object('type','outbox','id',id,'team',team,'operation_key',operation_key,
      'kind',kind,'target',target,'message_id',message_id,'status',status,
      'lease_owner',lease_owner,'lease_expires_at',lease_expires_at,'attempt',attempt)
      FROM lifecycle_outbox WHERE id IN (SELECT id FROM outbox_chosen);
    DROP TABLE processing_expired;
    DROP TABLE outbox_chosen;
    COMMIT;")" || return 13
  [ -z "$output" ] || printf '%s\n' "$output"
}

storage_outbox_complete() {
  local team="$1" outbox_id="$2" owner="$3" at output event_id
  _sqlite_lifecycle_token_valid "$outbox_id" && _sqlite_lifecycle_token_valid "$owner" || { echo runtime_error; return 13; }
  storage_init "$team" >/dev/null || { echo runtime_error; return 13; }
  at="$(_sqlite_now)"
  event_id="$(compat_uuid7)"
  output="$(agmsg_sqlite -bail -batch "$(_sqlite_db "$team")" "BEGIN IMMEDIATE;
    UPDATE lifecycle_outbox SET
      status=CASE WHEN kind='wake' THEN 'pending' ELSE 'done' END,
      available_at=CASE WHEN kind='wake' THEN CAST(strftime('%s','now') AS INTEGER)+300 ELSE available_at END,
      lease_owner=NULL,lease_expires_at=NULL,last_error=NULL,
      updated_at='$(_sqlite_lit "$at")'
      WHERE team='$(_sqlite_lit "$team")' AND id='$(_sqlite_lit "$outbox_id")'
        AND status='leased' AND lease_owner='$(_sqlite_lit "$owner")'
        AND lease_expires_at>CAST(strftime('%s','now') AS INTEGER);
    INSERT INTO lifecycle_events(id,type,team,operation_key,message_id,actor,result,at)
      SELECT '$(_sqlite_lit "$event_id")','outbox_sent',team,operation_key,message_id,
             '$(_sqlite_lit "$owner")',kind,'$(_sqlite_lit "$at")'
        FROM lifecycle_outbox WHERE changes()=1 AND team='$(_sqlite_lit "$team")'
          AND id='$(_sqlite_lit "$outbox_id")';
    SELECT CASE WHEN changes()=1 THEN 'ok' ELSE 'runtime_error' END;
    COMMIT;" | tr -d '\r')" || { echo runtime_error; return 13; }
  printf '%s\n' "$output"
  [ "$output" = ok ] || return 13
}

storage_outbox_retry() {
  local team="$1" outbox_id="$2" owner="$3" delay="$4" error="${5-}" at output event_id
  _sqlite_lifecycle_token_valid "$outbox_id" && _sqlite_lifecycle_token_valid "$owner" \
    && _sqlite_lifecycle_token_valid "$error" || { echo runtime_error; return 13; }
  case "$delay" in ''|*[!0-9]*) echo runtime_error; return 13 ;; esac
  storage_init "$team" >/dev/null || { echo runtime_error; return 13; }
  at="$(_sqlite_now)"
  event_id="$(compat_uuid7)"
  output="$(agmsg_sqlite -bail -batch "$(_sqlite_db "$team")" "BEGIN IMMEDIATE;
    UPDATE lifecycle_outbox SET status='pending',available_at=CAST(strftime('%s','now') AS INTEGER)+$delay,
      lease_owner=NULL,lease_expires_at=NULL,last_error='$(_sqlite_lit "$error")',
      updated_at='$(_sqlite_lit "$at")'
      WHERE team='$(_sqlite_lit "$team")' AND id='$(_sqlite_lit "$outbox_id")'
        AND status='leased' AND lease_owner='$(_sqlite_lit "$owner")'
        AND lease_expires_at>CAST(strftime('%s','now') AS INTEGER);
    INSERT INTO lifecycle_events(id,type,team,operation_key,message_id,actor,result,reason,target,at)
      SELECT '$(_sqlite_lit "$event_id")','outbox_error',team,operation_key,message_id,
             '$(_sqlite_lit "$owner")',kind,'$(_sqlite_lit "$error")',target,'$(_sqlite_lit "$at")'
        FROM lifecycle_outbox WHERE changes()=1 AND team='$(_sqlite_lit "$team")'
          AND id='$(_sqlite_lit "$outbox_id")';
    SELECT CASE WHEN changes()=1 THEN 'ok' ELSE 'runtime_error' END;
    COMMIT;" | tr -d '\r')" || { echo runtime_error; return 13; }
  printf '%s\n' "$output"
  [ "$output" = ok ] || return 13
}

storage_lifecycle_history() {
  local team="$1" operation_key=""; shift
  while [ $# -gt 0 ]; do
    case "$1" in --operation-key) operation_key="$2"; shift 2 ;; *) echo "agmsg: unknown lifecycle history option" >&2; return 13 ;; esac
  done
  storage_init "$team" >/dev/null || return 13
  local filter=""; [ -z "$operation_key" ] || filter=" AND operation_key='$(_sqlite_lit "$operation_key")'"
  _sqlite_data "$team" "
    SELECT record FROM (
      SELECT lm.created_at AS at,0 AS source,0 AS ord,
        json_object('type','message_sent','id',lm.message_id,'team',lm.team,
          'from',lm.sender,'to',lm.recipient,'kind',lm.kind,
          'operation_key',lm.operation_key,'body',e.body,'at',lm.created_at) AS record
        FROM lifecycle_messages lm JOIN events e ON e.id=lm.message_id
       WHERE lm.team='$(_sqlite_lit "$team")' ${filter/operation_key/lm.operation_key}
      UNION ALL
      SELECT le.at,1,le.seq,
        json_object('type',le.type,'id',le.id,'team',le.team,
          'operation_key',le.operation_key,'message_id',le.message_id,
          'actor',le.actor,'result',le.result,'reason',le.reason,'target',le.target,
          'work_key',le.work_key,'state',le.state,'generation',le.generation,
          'origin',le.origin,'wake_target',le.wake_target,
          'stall_deadline',le.stall_deadline,'at',le.at)
        FROM lifecycle_events le
       WHERE le.team='$(_sqlite_lit "$team")' ${filter/operation_key/le.operation_key}
    ) ORDER BY at,source,ord;"
}

storage_lifecycle_active() {
  local team="$1" recipient="${2-}"
  storage_init "$team" >/dev/null || return 13
  local recipient_filter="" outbox_recipient_filter=""
  if [ -n "$recipient" ]; then
    recipient_filter=" AND lm.recipient='$(_sqlite_lit "$recipient")'"
    outbox_recipient_filter=" AND lm.recipient='$(_sqlite_lit "$recipient")'"
  fi
  _sqlite_data "$team" "
    SELECT record FROM (
      SELECT lm.created_at AS at,lm.message_id AS sort_id,
        json_object('type','lifecycle_active','id',lm.message_id,'team',lm.team,
          'operation_key',lm.operation_key,'kind',lm.kind,'recipient',lm.recipient,
          'state',CASE
            WHEN a.result IN ('rejected','failed') THEN 'attention'
            WHEN a.result='applied' THEN 'cleanup_pending'
            WHEN p.message_id IS NOT NULL THEN 'processing'
            ELSE 'pending' END) AS record
      FROM lifecycle_messages lm
      LEFT JOIN lifecycle_processing_leases p ON p.message_id=lm.message_id
        AND p.expires_at>CAST(strftime('%s','now') AS INTEGER)
      LEFT JOIN lifecycle_events a ON a.type='application_ack' AND a.message_id=lm.message_id
      WHERE lm.team='$(_sqlite_lit "$team")' $recipient_filter
        AND ((lm.kind='info' AND NOT EXISTS(
               SELECT 1 FROM lifecycle_events r
                WHERE r.type='read_receipt' AND r.message_id=lm.message_id))
          OR (lm.kind IN ('action','terminal') AND (
               a.id IS NULL OR a.result IN ('rejected','failed')
               OR (a.result='applied' AND NOT EXISTS(
                    SELECT 1 FROM lifecycle_outbox o
                     WHERE o.message_id=lm.message_id AND o.kind='cleanup' AND o.status='done')))))
      UNION ALL
      SELECT le.at,le.id,
        json_object('type','work_active','id',le.id,'team',le.team,
          'operation_key',le.operation_key,'work_key',le.work_key,
          'actor',le.actor,'state',le.state,'result',le.result,'reason',le.reason,
          'generation',COALESCE(le.generation,registration.generation),
          'origin',COALESCE(le.origin,registration.origin),
          'wake_target',COALESCE(le.wake_target,registration.wake_target),
          'stall_deadline',COALESCE(le.stall_deadline,registration.stall_deadline))
      FROM lifecycle_events le
      LEFT JOIN lifecycle_events registration ON registration.seq=(
        SELECT MAX(r.seq) FROM lifecycle_events r
         WHERE r.type='work_event' AND r.team=le.team AND r.work_key=le.work_key
           AND r.state='registered' AND r.seq<=le.seq)
      WHERE le.type='work_event' AND le.team='$(_sqlite_lit "$team")'
        AND le.state!='closed'
        AND NOT EXISTS(SELECT 1 FROM lifecycle_events newer
          WHERE newer.type='work_event' AND newer.team=le.team
            AND newer.work_key=le.work_key AND newer.seq>le.seq)
      UNION ALL
      SELECT o.updated_at,o.id,
        json_object('type','delivery_error','id',o.id,'team',o.team,
          'operation_key',o.operation_key,'message_id',o.message_id,
          'kind',o.kind,'target',o.target,'state','attention',
          'reason',o.last_error,'attempt',o.attempt,'at',o.updated_at)
      FROM lifecycle_outbox o
      LEFT JOIN lifecycle_messages lm ON lm.message_id=o.message_id
      WHERE o.team='$(_sqlite_lit "$team")' AND o.status!='done'
        AND o.last_error IS NOT NULL AND o.last_error!='' $outbox_recipient_filter
    ) ORDER BY at,sort_id;"
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
    BEGIN;
    SELECT CASE type
      WHEN 'message_sent' THEN json_object('type','message_sent','id',id,'team',team,
             'from',from_agent,'to',to_agent,'body',body,'at',at)
      WHEN 'message_read' THEN json_object('type','message_read','id',id,'team',team,
             'agent',agent,'msg_id',msg_id,'at',at)
    END
    FROM events
    WHERE type IN ('message_sent','message_read')
    ORDER BY seq ASC;
    SELECT json_object('type','lifecycle_message','team',team,'sender',sender,
      'operation_key',operation_key,'message_id',message_id,'recipient',recipient,
      'kind',kind,'wake_target',wake_target,'created_at',created_at)
      FROM lifecycle_messages
      ORDER BY created_at,message_id;
    SELECT json_object('type','lifecycle_event','id',id,'event_type',type,
      'team',team,'operation_key',operation_key,'message_id',message_id,
      'actor',actor,'result',result,'reason',reason,'target',target,
      'work_key',work_key,'state',state,'generation',generation,'origin',origin,
      'wake_target',wake_target,'stall_deadline',stall_deadline,'at',at)
      FROM lifecycle_events ORDER BY seq;
    SELECT json_object('type','lifecycle_outbox','id',id,'team',team,
      'operation_key',operation_key,'kind',kind,'target',target,
      'message_id',message_id,'status',status,'available_at',available_at,
      'lease_owner',lease_owner,'lease_expires_at',lease_expires_at,
      'attempt',attempt,'last_error',last_error,'created_at',created_at,
      'updated_at',updated_at)
      FROM lifecycle_outbox ORDER BY seq;
    SELECT json_object('type','lifecycle_processing_lease','message_id',p.message_id,
      'consumer',p.consumer,'expires_at',p.expires_at,'attempt',p.attempt,
      'read_receipt_id',p.read_receipt_id,'updated_at',p.updated_at)
      FROM lifecycle_processing_leases p JOIN lifecycle_messages lm
        ON lm.message_id=p.message_id
      ORDER BY p.message_id;
    COMMIT;
  " > "$file"
}

_sqlite_import_required_fields_valid() {
  local line="$1" type="$2" predicate
  case "$type" in
    message_sent)
      predicate="json_type(record,'\$.type')='text' AND json_type(record,'\$.id')='text' AND json_type(record,'\$.team')='text' AND json_type(record,'\$.from')='text' AND json_type(record,'\$.to')='text' AND json_type(record,'\$.body')='text' AND json_type(record,'\$.at')='text'"
      ;;
    message_read)
      predicate="json_type(record,'\$.type')='text' AND json_type(record,'\$.id')='text' AND json_type(record,'\$.team')='text' AND json_type(record,'\$.agent')='text' AND json_type(record,'\$.msg_id')='text' AND json_type(record,'\$.at')='text'"
      ;;
    lifecycle_message)
      predicate="json_type(record,'\$.type')='text' AND json_type(record,'\$.team')='text' AND json_type(record,'\$.sender')='text' AND json_type(record,'\$.operation_key')='text' AND json_type(record,'\$.message_id')='text' AND json_type(record,'\$.recipient')='text' AND json_type(record,'\$.kind')='text' AND json_type(record,'\$.wake_target')='text' AND json_type(record,'\$.created_at')='text'"
      ;;
    lifecycle_event)
      predicate="json_type(record,'\$.type')='text' AND json_type(record,'\$.id')='text' AND json_type(record,'\$.event_type')='text' AND json_type(record,'\$.team')='text' AND json_type(record,'\$.operation_key')='text' AND json_type(record,'\$.at')='text' AND COALESCE(json_type(record,'\$.message_id') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.actor') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.result') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.reason') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.target') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.work_key') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.state') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.generation') IN ('integer','null'),1) AND COALESCE(json_type(record,'\$.origin') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.wake_target') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.stall_deadline') IN ('integer','null'),1)"
      ;;
    lifecycle_outbox)
      predicate="json_type(record,'\$.type')='text' AND json_type(record,'\$.id')='text' AND json_type(record,'\$.team')='text' AND json_type(record,'\$.operation_key')='text' AND json_type(record,'\$.kind')='text' AND json_type(record,'\$.target')='text' AND json_type(record,'\$.status')='text' AND json_type(record,'\$.available_at')='integer' AND json_type(record,'\$.attempt')='integer' AND json_type(record,'\$.created_at')='text' AND json_type(record,'\$.updated_at')='text' AND COALESCE(json_type(record,'\$.message_id') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.lease_owner') IN ('text','null'),1) AND COALESCE(json_type(record,'\$.lease_expires_at') IN ('integer','null'),1) AND COALESCE(json_type(record,'\$.last_error') IN ('text','null'),1)"
      ;;
    lifecycle_processing_lease)
      predicate="json_type(record,'\$.type')='text' AND json_type(record,'\$.message_id')='text' AND json_type(record,'\$.consumer')='text' AND json_type(record,'\$.expires_at')='integer' AND json_type(record,'\$.attempt')='integer' AND json_type(record,'\$.read_receipt_id')='text' AND json_type(record,'\$.updated_at')='text'"
      ;;
    *) return 0 ;;
  esac
  [ "$(sqlite3 :memory: "WITH input(record) AS (SELECT '$(_sqlite_lit "$line")') SELECT $predicate FROM input;" 2>/dev/null)" = 1 ]
}

storage_import() {
  # `selector`, not `team`: the loop below reuses `team` for the team named by
  # each imported RECORD, which is a different thing from the store being
  # written to. Sharing one name here would read as if they had to match.
  local selector="$1" file="$2" db sql_file; db="$(_sqlite_db "$selector")"
  [ -f "$file" ] || return 1
  storage_init "$selector" >/dev/null || return 13
  sql_file="$(mktemp "${TMPDIR:-/tmp}/agmsg-import.XXXXXX")" || return 13
  printf '%s\n' 'BEGIN IMMEDIATE;' > "$sql_file"
  local line t id team frm to body_hex body_expr msg_id agent at operation_key sender recipient kind record_type
  local wake_target created_at event_type actor result reason target work_key state generation origin stall_deadline
  local status available_at lease_owner lease_expires_at attempt last_error updated_at
  local consumer expires_at read_receipt_id
  j() { sqlite3 :memory: "SELECT COALESCE(json_extract('$(_sqlite_lit "$line")','\$.$1'),'')" 2>/dev/null | tr -d '\r'; }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    record_type="$(sqlite3 :memory: "WITH input(record) AS (SELECT '$(_sqlite_lit "$line")')
      SELECT CASE WHEN json_valid(record) THEN
        CASE WHEN json_type(record)='object' AND json_type(record,'\$.type')='text'
          THEN json_extract(record,'\$.type') ELSE '__agmsg_invalid__' END
        ELSE '__agmsg_invalid__' END FROM input;" 2>/dev/null)"
    if [ "$record_type" = __agmsg_invalid__ ] || ! _sqlite_import_required_fields_valid "$line" "$record_type"; then
      rm -f "$sql_file"
      echo "agmsg: import failed: invalid JSON record" >&2
      return 13
    fi
    t="$record_type"; id=$(j id); team=$(j team); at=$(j at)
    if [ "$t" = message_sent ]; then
      frm=$(j from); to=$(j to)
      body_hex="$(sqlite3 :memory: "SELECT hex(json_extract('$(_sqlite_lit "$line")','\$.body'))" 2>/dev/null | tr -d '\r\n')"
      body_expr="CAST(X'$body_hex' AS TEXT)"
      # Same utility as a live send, so an imported store presents the same
      # legacy view as the store it came from (#689).
      _sqlite_message_sent_statements_expr "$team" "$frm" "$to" "$body_expr" "$id" "$at" >> "$sql_file"
    elif [ "$t" = message_read ]; then
      agent=$(j agent); msg_id=$(j msg_id)
      printf '%s\n' "INSERT INTO events (type,id,team,agent,msg_id,at)
        VALUES ('message_read','$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
                '$(_sqlite_lit "$agent")','$(_sqlite_lit "$msg_id")','$(_sqlite_lit "$at")');
        UPDATE messages SET read_at='$(_sqlite_lit "$at")'
         WHERE read_at IS NULL
           AND id = (SELECT e.legacy_id FROM events e
                      WHERE e.type='message_sent' AND e.team='$(_sqlite_lit "$team")'
                        AND e.id='$(_sqlite_lit "$msg_id")' AND e.legacy_id IS NOT NULL);" >> "$sql_file"
    elif [ "$t" = lifecycle_message ]; then
      sender=$(j sender); operation_key=$(j operation_key); msg_id=$(j message_id)
      recipient=$(j recipient); kind=$(j kind); wake_target=$(j wake_target); created_at=$(j created_at)
      if ! _sqlite_lifecycle_token_valid "$team" || ! _sqlite_lifecycle_token_valid "$sender" \
          || ! _sqlite_lifecycle_token_valid "$operation_key" || ! _sqlite_lifecycle_token_valid "$msg_id" \
          || ! _sqlite_lifecycle_token_valid "$recipient" || ! _sqlite_lifecycle_kind_valid "$kind" \
          || ! _sqlite_lifecycle_token_valid "$wake_target" || [ -z "$created_at" ]; then
        rm -f "$sql_file"; echo "agmsg: import failed: invalid lifecycle record" >&2; return 13
      fi
      printf '%s\n' "INSERT OR IGNORE INTO lifecycle_messages
        (team,sender,operation_key,message_id,recipient,kind,wake_target,created_at)
        VALUES ('$(_sqlite_lit "$team")','$(_sqlite_lit "$sender")',
          '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$msg_id")',
          '$(_sqlite_lit "$recipient")','$(_sqlite_lit "$kind")',
          '$(_sqlite_lit "$wake_target")','$(_sqlite_lit "$created_at")');
        SELECT CASE WHEN EXISTS(SELECT 1 FROM lifecycle_messages
          WHERE team='$(_sqlite_lit "$team")' AND sender='$(_sqlite_lit "$sender")'
            AND operation_key='$(_sqlite_lit "$operation_key")' AND message_id='$(_sqlite_lit "$msg_id")'
            AND recipient='$(_sqlite_lit "$recipient")' AND kind='$(_sqlite_lit "$kind")'
            AND wake_target='$(_sqlite_lit "$wake_target")' AND created_at='$(_sqlite_lit "$created_at")')
          THEN 1 ELSE json('agmsg import conflict') END;" >> "$sql_file"
    elif [ "$t" = lifecycle_event ]; then
      event_type=$(j event_type); operation_key=$(j operation_key); msg_id=$(j message_id)
      actor=$(j actor); result=$(j result); reason=$(j reason); target=$(j target)
      work_key=$(j work_key); state=$(j state); generation=$(j generation); origin=$(j origin)
      wake_target=$(j wake_target); stall_deadline=$(j stall_deadline)
      if ! _sqlite_lifecycle_token_valid "$id" || ! _sqlite_lifecycle_token_valid "$event_type" \
          || ! _sqlite_lifecycle_token_valid "$team" || ! _sqlite_lifecycle_token_valid "$operation_key"; then
        rm -f "$sql_file"; echo "agmsg: import failed: invalid lifecycle record" >&2; return 13
      fi
      if [ -n "$state" ] && ! _sqlite_lifecycle_work_state_valid "$state"; then
        rm -f "$sql_file"; echo "agmsg: import failed: invalid lifecycle record" >&2; return 13
      fi
      printf '%s\n' "INSERT OR IGNORE INTO lifecycle_events
        (id,type,team,operation_key,message_id,actor,result,reason,target,work_key,state,
         generation,origin,wake_target,stall_deadline,at)
        VALUES ('$(_sqlite_lit "$id")','$(_sqlite_lit "$event_type")',
          '$(_sqlite_lit "$team")','$(_sqlite_lit "$operation_key")',
          NULLIF('$(_sqlite_lit "$msg_id")',''),NULLIF('$(_sqlite_lit "$actor")',''),
          NULLIF('$(_sqlite_lit "$result")',''),NULLIF('$(_sqlite_lit "$reason")',''),
          NULLIF('$(_sqlite_lit "$target")',''),NULLIF('$(_sqlite_lit "$work_key")',''),
          NULLIF('$(_sqlite_lit "$state")',''),NULLIF('$(_sqlite_lit "$generation")',''),
          NULLIF('$(_sqlite_lit "$origin")',''),NULLIF('$(_sqlite_lit "$wake_target")',''),
          NULLIF('$(_sqlite_lit "$stall_deadline")',''),'$(_sqlite_lit "$at")');
        SELECT CASE WHEN EXISTS(SELECT 1 FROM lifecycle_events
          WHERE id='$(_sqlite_lit "$id")' AND type='$(_sqlite_lit "$event_type")'
            AND team='$(_sqlite_lit "$team")' AND operation_key='$(_sqlite_lit "$operation_key")'
            AND COALESCE(message_id,'')='$(_sqlite_lit "$msg_id")' AND COALESCE(actor,'')='$(_sqlite_lit "$actor")'
            AND COALESCE(result,'')='$(_sqlite_lit "$result")' AND COALESCE(reason,'')='$(_sqlite_lit "$reason")'
            AND COALESCE(target,'')='$(_sqlite_lit "$target")' AND COALESCE(work_key,'')='$(_sqlite_lit "$work_key")'
            AND COALESCE(state,'')='$(_sqlite_lit "$state")' AND COALESCE(generation,'')='$(_sqlite_lit "$generation")'
            AND COALESCE(origin,'')='$(_sqlite_lit "$origin")' AND COALESCE(wake_target,'')='$(_sqlite_lit "$wake_target")'
            AND COALESCE(stall_deadline,'')='$(_sqlite_lit "$stall_deadline")' AND at='$(_sqlite_lit "$at")')
          THEN 1 ELSE json('agmsg import conflict') END;" >> "$sql_file"
    elif [ "$t" = lifecycle_outbox ]; then
      operation_key=$(j operation_key); kind=$(j kind); target=$(j target); msg_id=$(j message_id)
      status=$(j status); available_at=$(j available_at); lease_owner=$(j lease_owner)
      lease_expires_at=$(j lease_expires_at); attempt=$(j attempt); last_error=$(j last_error)
      created_at=$(j created_at); updated_at=$(j updated_at)
      if ! _sqlite_lifecycle_token_valid "$id" || ! _sqlite_lifecycle_token_valid "$team" \
          || ! _sqlite_lifecycle_token_valid "$operation_key" || ! _sqlite_lifecycle_token_valid "$target"; then
        rm -f "$sql_file"; echo "agmsg: import failed: invalid lifecycle record" >&2; return 13
      fi
      case "$kind:$status:$attempt" in
        wake:pending:*|wake:leased:*|wake:done:*|cleanup:pending:*|cleanup:leased:*|cleanup:done:*|launch:pending:*|launch:leased:*|launch:done:*) ;;
        *) rm -f "$sql_file"; echo "agmsg: import failed: invalid lifecycle record" >&2; return 13 ;;
      esac
      printf '%s\n' "INSERT OR IGNORE INTO lifecycle_outbox
        (id,team,operation_key,kind,target,message_id,status,available_at,
         lease_owner,lease_expires_at,attempt,last_error,created_at,updated_at)
        VALUES ('$(_sqlite_lit "$id")','$(_sqlite_lit "$team")',
          '$(_sqlite_lit "$operation_key")','$(_sqlite_lit "$kind")',
          '$(_sqlite_lit "$target")',NULLIF('$(_sqlite_lit "$msg_id")',''),
          '$(_sqlite_lit "$status")','$(_sqlite_lit "$available_at")',
          NULLIF('$(_sqlite_lit "$lease_owner")',''),NULLIF('$(_sqlite_lit "$lease_expires_at")',''),
          '$(_sqlite_lit "$attempt")',NULLIF('$(_sqlite_lit "$last_error")',''),
          '$(_sqlite_lit "$created_at")','$(_sqlite_lit "$updated_at")');
        SELECT CASE WHEN EXISTS(SELECT 1 FROM lifecycle_outbox
          WHERE id='$(_sqlite_lit "$id")' AND team='$(_sqlite_lit "$team")'
            AND operation_key='$(_sqlite_lit "$operation_key")' AND kind='$(_sqlite_lit "$kind")'
            AND target='$(_sqlite_lit "$target")' AND COALESCE(message_id,'')='$(_sqlite_lit "$msg_id")'
            AND status='$(_sqlite_lit "$status")' AND available_at='$(_sqlite_lit "$available_at")'
            AND COALESCE(lease_owner,'')='$(_sqlite_lit "$lease_owner")'
            AND COALESCE(lease_expires_at,'')='$(_sqlite_lit "$lease_expires_at")'
            AND attempt='$(_sqlite_lit "$attempt")' AND COALESCE(last_error,'')='$(_sqlite_lit "$last_error")'
            AND created_at='$(_sqlite_lit "$created_at")' AND updated_at='$(_sqlite_lit "$updated_at")')
          THEN 1 ELSE json('agmsg import conflict') END;" >> "$sql_file"
    elif [ "$t" = lifecycle_processing_lease ]; then
      msg_id=$(j message_id); consumer=$(j consumer); expires_at=$(j expires_at)
      attempt=$(j attempt); read_receipt_id=$(j read_receipt_id); updated_at=$(j updated_at)
      if ! _sqlite_lifecycle_token_valid "$msg_id" || ! _sqlite_lifecycle_token_valid "$consumer" \
          || ! _sqlite_lifecycle_token_valid "$read_receipt_id" || [ "$attempt" -le 0 ]; then
        rm -f "$sql_file"; echo "agmsg: import failed: invalid lifecycle record" >&2; return 13
      fi
      printf '%s\n' "INSERT OR IGNORE INTO lifecycle_processing_leases
        (message_id,consumer,expires_at,attempt,read_receipt_id,updated_at)
        VALUES ('$(_sqlite_lit "$msg_id")','$(_sqlite_lit "$consumer")',
          '$(_sqlite_lit "$expires_at")','$(_sqlite_lit "$attempt")',
          '$(_sqlite_lit "$read_receipt_id")','$(_sqlite_lit "$updated_at")');
        SELECT CASE WHEN EXISTS(SELECT 1 FROM lifecycle_processing_leases
          WHERE message_id='$(_sqlite_lit "$msg_id")' AND consumer='$(_sqlite_lit "$consumer")'
            AND expires_at='$(_sqlite_lit "$expires_at")' AND attempt='$(_sqlite_lit "$attempt")'
            AND read_receipt_id='$(_sqlite_lit "$read_receipt_id")' AND updated_at='$(_sqlite_lit "$updated_at")')
          THEN 1 ELSE json('agmsg import conflict') END;" >> "$sql_file"
    fi
  done < "$file"
  printf '%s\n' 'COMMIT;' >> "$sql_file"
  agmsg_sqlite_warm
  if ! agmsg_sqlite -bail -batch "$db" < "$sql_file" >/dev/null 2>&1; then
    rm -f "$sql_file"
    echo "agmsg: import failed; transaction rolled back" >&2
    return 13
  fi
  rm -f "$sql_file"
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
