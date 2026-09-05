#!/usr/bin/env bash
# Optional Stage-1 remote synchronization extension for the SQLite driver.
# See docs/spec/ref/stage-1-remote-sync.md. All bulk input/output is JSONL.

# Exit 13 is this driver's "a check failed", and it was the ONLY thing a caller
# received: 113 sites across 13 functions returned it with nothing on stderr, so
# `storage sync reprocess failed (exit 13)` named no check and no line. Working
# out which one had fired meant reading the whole file against the failing
# machine's state.
#
# The location is derived, not written. A hand-written reason per site is one
# more sentence that can drift from the condition beside it -- the same drift
# #781 removed by folding an authority-file fault and its wording into one
# function. FUNCNAME/BASH_LINENO cannot disagree with where the return actually
# is, because the shell computes them from it.
#
# stderr because remote-sync.mjs already prefers it: `stderr.trim() || "driver
# returned a non-zero exit without diagnostics"`. Nothing above needs changing
# for this to surface -- and that fallback message is now what it always meant,
# "the driver said nothing", rather than the only thing it could ever say.
#
# Callers keep their own `return`. A function cannot return on behalf of the one
# that called it, so this only reports; replacing a bare return with a call to
# this would let execution fall through and change control flow.
_sqlite_sync_why() {
  printf 'agmsg: sqlite-sync: %s failed at %s:%s\n' \
    "${FUNCNAME[1]:-?}" "${BASH_SOURCE[1]##*/}" "${BASH_LINENO[0]:-?}" >&2
}

_sqlite_sync_uuid4() {
  local h n variant
  h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  [ "${#h}" -eq 32 ] || return 1
  n=$((16#${h:16:1}))
  variant=$(printf '%x' $(((n & 3) | 8)))
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant" "${h:17:3}" "${h:20:12}"
}

# Reservations are committed in groups rather than one transaction per message:
# a sqlite3 fork costs far more than the seal it records. The bounds are what
# an interrupted backfill re-does — at most this many messages, or this much
# accumulated SQL, are re-sealed by the next prepare.
_SQLITE_SYNC_COMMIT_CHUNK=50
_SQLITE_SYNC_COMMIT_BYTES=131072

# The statement goes in on stdin, not in argv. A single encrypted blob is legal
# up to max_blob_bytes, which is already larger than ARG_MAX once base64 and SQL
# quoting are applied — so an argv statement could not hold even one such row,
# and no group bound would have saved it.
#
# -bail on EVERY transaction this file feeds sqlite3 on stdin (here, reconcile,
# read-prepare, read-apply; the page apply already had it). On stdin the CLI
# runs on past a failed statement, so a BEGIN IMMEDIATE that loses the busy
# timeout to another writer is followed by the body executing anyway — each
# statement waiting its own timeout, and the ones that land after the other
# writer lets go commit on their own, outside any transaction. A lock that frees
# mid-script would apply the tail without the head. Statements handed over as an
# argv string do not have this problem: there the CLI stops at the first error.
# -bail makes the stdin form stop too, which is what lets the engine retry a busy
# call: nothing of a transaction that never began has been written.
_sqlite_sync_commit_chunk() {
  local db="$1" sql="$2"
  [ -n "$sql" ] || return 0
  agmsg_sqlite_warm
  printf 'BEGIN IMMEDIATE;\n%s\nCOMMIT;\n' "$sql" | agmsg_sqlite -bail "$db" >/dev/null 2>&1
}

# Builtin single-quote escaping, assigned into _SQLITE_SYNC_LIT in the CALLER's
# shell. _sqlite_lit forks printf|sed per call, which the bulk loop calls three
# times per message; a `$( )` wrapper here would fork just as surely.
#
# The quote is held in a variable rather than written as \' in the pattern:
# bash 3.2 (macOS /bin/bash) keeps the backslash of a \' REPLACEMENT, so
# `${1//\'/\'\'}` turns it's into it\'\'s there and into it''s on bash 4+. A
# variable is read the same way by every bash, and the contract test in
# tests/test_remote_sync.bats holds this equal to _sqlite_lit byte for byte.
_sqlite_sync_lit_into() { local q="'"; _SQLITE_SYNC_LIT="${1//$q/$q$q}"; }

# The UUIDv4 wire-id shape, for [[ =~ ]]: held in a variable because that is
# the one form every bash reads the same way -- an inline pattern with braces
# is at the mercy of each version's quoting rules. Kept byte-identical to the
# grep -E pattern it replaces on the per-message path (#908): checking a wire
# id used to cost a printf and a grep per pulled message.
_SQLITE_SYNC_WIRE_RE='^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'

# Bulk form of _sqlite_sync_uuid4: one /dev/urandom read and builtin-only
# formatting for `count` ids. A 1000-message catch-up page costs one fork here
# instead of one per message.
_sqlite_sync_uuid4_bulk() {
  local count="$1" hex out="" i off n
  local digits=0123456789abcdef
  case "$count" in ''|*[!0-9]*) return 1 ;; esac
  [ "$count" -ge 1 ] || return 0
  hex=$(od -An -N$((count * 16)) -tx1 /dev/urandom | tr -d ' \n') || return 1
  [ "${#hex}" -eq $((count * 32)) ] || return 1
  for ((i = 0; i < count; i++)); do
    off=$((i * 32))
    n=$((16#${hex:$((off + 16)):1}))
    out="${out}${hex:$off:8}-${hex:$((off + 8)):4}-4${hex:$((off + 13)):3}"
    out="${out}-${digits:$(((n & 3) | 8)):1}${hex:$((off + 17)):3}-${hex:$((off + 20)):12}
"
  done
  printf '%s' "$out"
}

_sqlite_sync_valid_binding() {
  printf '%s\n' "$1" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 1
  printf '%s\n' "$2" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 1
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
}

_sqlite_sync_decimal_le() {
  local left right
  left=$(printf '%s' "$1" | sed 's/^0*//')
  right=$(printf '%s' "$2" | sed 's/^0*//')
  [ -n "$left" ] || left=0
  [ -n "$right" ] || right=0
  if [ "${#left}" -lt "${#right}" ] ||
     { [ "${#left}" -eq "${#right}" ] && [[ "$left" < "$right" || "$left" = "$right" ]]; }; then
    echo 1
  else
    echo 0
  fi
}

_sqlite_sync_sequence() {
  case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "$(_sqlite_sync_decimal_le "$1" 9223372036854775807)" = 1 ]
}


# `jq -b` IS REQUIRED HERE, AND THE REQUIREMENT FAILS CLOSED (#829).
#
# A native Windows jq opens stdout in text mode, so every line it prints ends
# CRLF. Two values this driver sends ride out of a final-stage `jq … | @tsv`
# read by `while IFS=$'\t' read -r`: `read` consumes the LF, `IFS` has no CR,
# so the CR sticks to the LAST field -- the message `wire_id` and the base64
# envelope `blob`. The server then answers HTTP 400. Measured on the reporting
# machine: `hex(wire_id)` and `hex(blob)` both end `0D`, and stripping that byte
# and resending produces `push.ack … stored`.
#
# `-b` is jq's own answer to this and the manual names this exact case. It is
# the short form on purpose: `--binary` is rejected by jq-1.7.1-apple (measured:
# rc 2, same as an unknown option), while `-b` is accepted there and on the
# reporting machine's jq 1.8.2.
#
# REFUSING IS THE POINT. This repository checks that jq EXISTS and never that it
# is a particular version -- `doctor` does not look at jq at all -- so there is
# no floor to lean on. A jq without `-b` would exit 2 on every call, which is a
# failure either way; saying so by name here is the difference between "the sync
# is broken" and "this jq cannot do binary output". Falling back to stripping CR
# afterwards is deliberately NOT offered: it guesses at which CRs were added,
# and the guess is wrong for any value that legitimately ends a line with one.
_AGMSG_JQ_BINARY_OK=""

# Said every time it refuses, not only the first time (#829, raised in review).
#
# The result is cached because the probe costs a process, but a cached NO used to
# `return 1` in silence: the first push in a long-lived shell explained itself and
# every push after it just failed. A caller that retries -- which is what the
# engine does on its cycle -- would see one sentence and then nothing, and the
# one sentence scrolls away.
_sqlite_sync_jq_binary_refusal() {
  echo "agmsg: sending requires a jq whose -b (binary output) produces LF-terminated lines" >&2
  echo "agmsg:   this jq: $(jq --version 2>/dev/null || echo 'unknown')" >&2
  echo "agmsg:   a Windows jq without it emits CRLF, and the trailing CR rides into" >&2
  echo "agmsg:   the values this sends, which the server rejects (#829)." >&2
}

_sqlite_sync_require_jq_binary() {
  case "$_AGMSG_JQ_BINARY_OK" in
    yes) return 0 ;;
    no)  _sqlite_sync_jq_binary_refusal; return 1 ;;
  esac
  local probe="" ok=""
  # BOTH HALVES, AND NO SHARED FILE.
  #
  # Probing with `jq -b -r 'empty'` tested option parsing only -- it emits
  # nothing, so a jq that accepts `-b` and still writes CRLF passed. Reading a
  # sentinel fixes that half; the other half is that a jq can print the right
  # bytes and still fail, and through a process substitution that status is
  # unreachable (both raised in review).
  #
  # The first attempt at getting both wrote jq's output to
  # `${TMPDIR}/agmsg-jq-probe.$$` and took the status from the pipeline. `$$` is
  # the PARENT's pid inside a subshell, so concurrent sealers in one process tree
  # shared that path: one removed it while another was still reading, and the
  # driver refused a jq that was fine. `concurrent age-v1 sealers` caught it.
  # This is the same reasoning about `$$` that was wrong once already (#804).
  #
  # So the status travels in the stream instead of in a file. jq writes the
  # sentinel; `&&` appends a second line only if jq exited 0. Two `read`s, no
  # shared name, nothing to clean up -- and still `read` rather than `$( )`,
  # because command substitution on MSYS drops the byte this is looking for.
  { IFS= read -r probe; IFS= read -r ok; } < <(
    printf '{}\n' | { jq -b -r '"agmsg-probe"' && printf 'agmsg-ok\n'; } 2>/dev/null
  )
  if [ "$probe" = "agmsg-probe" ] && [ "$ok" = "agmsg-ok" ]; then
    _AGMSG_JQ_BINARY_OK=yes
    return 0
  fi
  _AGMSG_JQ_BINARY_OK=no
  _sqlite_sync_jq_binary_refusal
  return 1
}

# <team> is the storage selector, threaded from the contract that called us.
_sqlite_sync_schema() {
  command -v jq >/dev/null 2>&1 || {
    echo "agmsg: Stage-1 sync requires jq" >&2
    return 10
  }
  storage_init "$1" >/dev/null || { _sqlite_sync_why; return 13; }
  local db generation
  db="$(_sqlite_db "$1")"
  agmsg_sqlite "$db" "
    CREATE TABLE IF NOT EXISTS sync_store_metadata (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      generation TEXT NOT NULL UNIQUE
    );
    CREATE TABLE IF NOT EXISTS sync_bindings (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      push_cursor INTEGER NOT NULL DEFAULT 0,
      transport_cursor TEXT NOT NULL DEFAULT '0',
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation)
    );
    CREATE TABLE IF NOT EXISTS sync_messages (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      local_position INTEGER NOT NULL,
      local_id TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      server_seq TEXT,
      direction TEXT NOT NULL CHECK(direction IN ('push','pull')),
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,local_position),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,wire_id)
    );
    -- The one lookup on this table that the UNIQUE above cannot serve: the
    -- apply conflict guard asks whether a server_seq is already mapped to a
    -- DIFFERENT wire id, so it comes in by (binding, server_seq). Without
    -- this index that guard walked every row of the binding and fetched each
    -- one (rows carry the wire blob), once per imported message: 68.6 ms per
    -- message on a 21,471-row store, 73 percent of the import batch, and the
    -- reason import time grew with the store (#910). sync_quarantine already
    -- has the equivalent path as its second UNIQUE constraint.
    CREATE INDEX IF NOT EXISTS sync_messages_server_seq
      ON sync_messages(server_instance_id,remote_team_id,protocol_version,server_seq);
    CREATE TABLE IF NOT EXISTS sync_quarantine (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      server_received_at TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      status TEXT NOT NULL,
      policy_revision TEXT,
      local_security_revision TEXT,
      reason TEXT,
      PRIMARY KEY(server_instance_id,remote_team_id,protocol_version,wire_id),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,server_seq)
    );
    CREATE TABLE IF NOT EXISTS sync_conflicts (
      conflict_id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      reason TEXT NOT NULL,
      observed_at TEXT NOT NULL,
      UNIQUE(server_instance_id,remote_team_id,protocol_version,
             server_seq,wire_id,reason)
    );
    CREATE TABLE IF NOT EXISTS sync_resync_audits (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      expected_transport_cursor TEXT NOT NULL,
      accepted_floor TEXT NOT NULL,
      gap_start TEXT NOT NULL,
      gap_end TEXT NOT NULL,
      reason TEXT NOT NULL CHECK(reason='retention-gap-accepted'),
      accepted_at TEXT NOT NULL,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,accepted_floor)
    );
    CREATE TABLE IF NOT EXISTS sync_read_members (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      member_id TEXT NOT NULL,
      agent TEXT NOT NULL,
      remote_agent TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
      name_mismatch INTEGER NOT NULL DEFAULT 0 CHECK(name_mismatch IN (0,1)),
      blocked_reason TEXT,
      remote_server_seq TEXT NOT NULL DEFAULT '0',
      min_available_seq TEXT NOT NULL DEFAULT '0',
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,member_id),
      UNIQUE(local_team,server_instance_id,remote_team_id,
             protocol_version,driver_generation,agent)
    );
    CREATE TABLE IF NOT EXISTS sync_read_remote_exact (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      member_id TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,member_id,wire_id)
    );
    CREATE TABLE IF NOT EXISTS sync_read_aliases (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      agent TEXT NOT NULL,
      local_id TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      server_seq TEXT,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,agent,local_id),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,agent,wire_id)
    );
    CREATE TABLE IF NOT EXISTS sync_read_prepared (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      member_id TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,member_id)
    );
  " >/dev/null 2>&1 || { _sqlite_sync_why; return 13; }
  if ! agmsg_sqlite "$db" "PRAGMA table_info(sync_read_members);" | cut -d'|' -f2 |
      grep -qx remote_agent; then
    agmsg_sqlite "$db" "BEGIN IMMEDIATE;
      ALTER TABLE sync_read_members ADD COLUMN remote_agent TEXT NOT NULL DEFAULT '';
      ALTER TABLE sync_read_members ADD COLUMN name_mismatch INTEGER NOT NULL DEFAULT 0
        CHECK(name_mismatch IN (0,1));
      ALTER TABLE sync_read_members ADD COLUMN blocked_reason TEXT;
      UPDATE sync_read_members SET remote_agent=agent;
      COMMIT;" >/dev/null 2>&1 || { _sqlite_sync_why; return 13; }
  fi
  generation=$(agmsg_sqlite "$db" \
    "SELECT generation FROM sync_store_metadata WHERE singleton=1;" 2>/dev/null | tr -d '\r')
  if [ -z "$generation" ]; then
    generation=$(_sqlite_sync_uuid4) || { _sqlite_sync_why; return 13; }
    agmsg_sqlite "$db" "INSERT OR IGNORE INTO sync_store_metadata(singleton,generation)
      VALUES(1,'$(_sqlite_lit "$generation")');" >/dev/null 2>&1 || { _sqlite_sync_why; return 13; }
  fi
}

# Read-only cursor/audit lookup for explicit retention-gap recovery. This
# deliberately does not call _sqlite_sync_schema or initialize a binding.
storage_sync_resync_status() {
  local team="$1" server="$2" remote="$3" protocol="$4" floor="$5"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_sequence "$floor" || { _sqlite_sync_why; return 13; }
  local db tl generation table_count
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"
  [ -f "$db" ] || { _sqlite_sync_why; return 13; }
  table_count=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sqlite_master
    WHERE type='table' AND name IN ('sync_store_metadata','sync_bindings','sync_resync_audits');" \
    2>/dev/null | tr -d '\r') || { _sqlite_sync_why; return 13; }
  [ "$table_count" = 3 ] || { _sqlite_sync_why; return 13; }
  generation=$(agmsg_sqlite "$db" "SELECT generation FROM sync_store_metadata WHERE singleton=1;" \
    2>/dev/null | tr -d '\r') || { _sqlite_sync_why; return 13; }
  [ -n "$generation" ] || { _sqlite_sync_why; return 13; }
  local output
  output=$(_sqlite_data "$team" "SELECT json_object(
      'type','sync_resync_status','driver_generation',b.driver_generation,
      'transport_cursor',b.transport_cursor,'audit',CASE WHEN a.accepted_floor IS NULL
        THEN NULL ELSE json_object(
          'expected_transport_cursor',a.expected_transport_cursor,
          'accepted_floor',a.accepted_floor,'gap_start',a.gap_start,
          'gap_end',a.gap_end,'reason',a.reason) END)
    FROM sync_bindings b LEFT JOIN sync_resync_audits a
      ON a.local_team=b.local_team AND a.server_instance_id=b.server_instance_id
     AND a.remote_team_id=b.remote_team_id AND a.protocol_version=b.protocol_version
     AND a.driver_generation=b.driver_generation AND a.accepted_floor='$floor'
    WHERE b.local_team='$tl' AND b.server_instance_id='$server'
      AND b.remote_team_id='$remote' AND b.protocol_version=$protocol
      AND b.driver_generation='$(_sqlite_lit "$generation")';") || { _sqlite_sync_why; return 13; }
  [ -n "$output" ] || { _sqlite_sync_why; return 13; }
  printf '%s\n' "$output"
}

# Atomically records an operator-accepted unavailable interval and advances
# only the pull transport cursor.
storage_sync_resync() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  local line expected floor current reason generation db tl gap_start node_bin strict_parser
  node_bin="${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"
  strict_parser="$SKILL_DIR/scripts/internal/strict-jsonl.mjs"
  command -v "$node_bin" >/dev/null 2>&1 && [ -f "$strict_parser" ] || return 10
  line=$("$node_bin" "$strict_parser" current_seq expected_transport_cursor \
    min_available_seq reason type) || { _sqlite_sync_why; return 13; }
  printf '%s\n' "$line" | jq -e '
    (keys == ["current_seq","expected_transport_cursor","min_available_seq","reason","type"])
    and .type == "sync_resync" and .reason == "retention-gap-accepted"
    and (.expected_transport_cursor|type)=="string"
    and (.min_available_seq|type)=="string" and (.current_seq|type)=="string"' \
    >/dev/null 2>&1 || { _sqlite_sync_why; return 13; }
  expected=$(printf '%s\n' "$line" | jq -r '.expected_transport_cursor')
  floor=$(printf '%s\n' "$line" | jq -r '.min_available_seq')
  current=$(printf '%s\n' "$line" | jq -r '.current_seq')
  reason=$(printf '%s\n' "$line" | jq -r '.reason')
  _sqlite_sync_sequence "$expected" && _sqlite_sync_sequence "$floor" &&
    _sqlite_sync_sequence "$current" || { _sqlite_sync_why; return 13; }
  [ "$(_sqlite_sync_decimal_le "$expected" "$floor")" = 1 ] && [ "$expected" != "$floor" ] || { _sqlite_sync_why; return 13; }
  [ "$(_sqlite_sync_decimal_le "$floor" "$current")" = 1 ] || { _sqlite_sync_why; return 13; }
  gap_start=$((10#$expected + 1))
  _sqlite_sync_sequence "$gap_start" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  generation=$(_sqlite_sync_generation "$team"); db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"

  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE resync_assert(ok INTEGER CHECK(ok=1));
    INSERT INTO resync_assert SELECT CASE WHEN COUNT(*)=1 THEN 1 ELSE 0 END
      FROM sync_bindings WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$(_sqlite_lit "$generation")'
       AND transport_cursor='$expected';
    INSERT INTO sync_resync_audits
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,expected_transport_cursor,accepted_floor,gap_start,
       gap_end,reason,accepted_at)
    VALUES('$tl','$server','$remote',$protocol,'$(_sqlite_lit "$generation")',
      '$expected','$floor','$gap_start','$floor','$reason',
      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
    UPDATE sync_bindings SET transport_cursor='$floor'
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$(_sqlite_lit "$generation")'
       AND transport_cursor='$expected';
    COMMIT;" >/dev/null 2>&1 || { _sqlite_sync_why; return 13; }

  _sqlite_data "$team" "SELECT json_object(
      'type','sync_resync_result','driver_generation',driver_generation,
      'expected_transport_cursor',expected_transport_cursor,
      'transport_cursor',accepted_floor,'accepted_floor',accepted_floor,
      'gap_start',gap_start,'gap_end',gap_end,'reason',reason)
    FROM sync_resync_audits WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$(_sqlite_lit "$generation")' AND accepted_floor='$floor';"
}

# <team> is the storage selector, threaded from the contract that called us.
_sqlite_sync_generation() {
  agmsg_sqlite "$(_sqlite_db "$1")" \
    "SELECT generation FROM sync_store_metadata WHERE singleton=1;" | tr -d '\r'
}

# Legacy rows live in `messages`, which predates the event log and which nothing
# writes any more. The push candidate query reads `events` only, so a team whose
# history is entirely legacy would connect and upload nothing -- silently, since
# an empty page is a normal answer. This projects those rows into the event log
# once, per team, at the moment that team first prepares a push.
#
# The synthesized seq is `id - _AGMSG_LEGACY_SEQ_OFFSET`, which is negative and
# therefore below every existing position. That single choice satisfies all
# three things the position has to be at once:
#
#   collision-free  existing seq values are the positive AUTOINCREMENT space
#   stable          it is a pure function of the legacy row id, so a re-run
#                   reproduces it and the wire id reserved against it in
#                   sync_messages stays valid
#   ordered         legacy ids ascend, so the projected history sorts ahead of
#                   every event that already exists -- chronologically correct
#
# It also leaves read state alone. `read_cursors.local_position` holds positive
# values and the unread query asks for `seq > cursor`, so projected rows are
# below every cursor and stay delivered, which is what the phase-3 adoption
# already decided about them.
#
# Explicit negative rowids do not disturb AUTOINCREMENT: sqlite_sequence keeps
# the high-water it had, so the delivery tip (which reads it) is unaffected.
_AGMSG_LEGACY_SEQ_OFFSET=1000000000

_sqlite_sync_project_legacy() {
  local team="$1" db tl done_marker max_id
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"

  done_marker=$(agmsg_sqlite "$db" "SELECT value FROM storage_metadata
    WHERE key='legacy_push_projected_v1';" 2>/dev/null | tr -d '\r')
  [ -z "$done_marker" ] || return 0

  # A legacy id at or above the offset would project to a NON-negative seq and
  # collide with the live space. Refuse rather than corrupt: this is a constant
  # chosen to sit far above any real store, and "far above" is an assumption
  # worth failing on rather than assuming quietly.
  max_id=$(agmsg_sqlite "$db" "SELECT COALESCE(MAX(id),0) FROM messages
    WHERE team='$tl';" 2>/dev/null | tr -d '\r')
  case "$max_id" in ''|*[!0-9]*) max_id=0 ;; esac
  if [ "$max_id" -ge "$_AGMSG_LEGACY_SEQ_OFFSET" ]; then
    echo "agmsg: legacy message id $max_id exceeds the projection offset" >&2
    _sqlite_sync_why; return 13
  fi

  agmsg_sqlite "$db" "
    INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at,legacy_id)
      SELECT m.id - $_AGMSG_LEGACY_SEQ_OFFSET,'message_sent',CAST(m.id AS TEXT),
             m.team,m.from_agent,m.to_agent,m.body,m.created_at,
             -- Record which legacy row this event IS. The readers dedupe on
             -- events.legacy_id = messages.id, so a projected row without it is
             -- returned from both branches -- the same duplicate the mirror
             -- exists to avoid, arriving from the other direction (#689).
             m.id
        FROM messages m
       WHERE m.team='$tl'
         AND NOT EXISTS(SELECT 1 FROM events e
                         WHERE e.seq=m.id - $_AGMSG_LEGACY_SEQ_OFFSET)
         -- Never project a row this store wrote as the legacy copy of an event
         -- it already has (#689). Every message is now written to both tables,
         -- so without this the projection would put the mirror back into the
         -- event log as a SECOND event -- different id, different seq, no link
         -- to the first -- and the rewind below would push that duplicate to
         -- the server and on to every other machine.
         AND NOT EXISTS(SELECT 1 FROM events e2 WHERE e2.legacy_id = m.id);
    INSERT OR REPLACE INTO storage_metadata(key,value)
      VALUES('legacy_push_projected_v1','1');" >/dev/null 2>&1 || { _sqlite_sync_why; return 13; }
}

# Bindings default their push cursor to 0, which is above the projected space,
# so a team with legacy history would prepare zero candidates. Lower the cursor
# to just under the oldest projected position -- for a team with no legacy rows
# the subquery is NULL and this leaves the cursor exactly where it was.
#
# Lowering an already-advanced cursor is safe: both the candidate query and the
# emission filter on `server_seq IS NULL`, so rows the server already
# acknowledged are skipped rather than resent. The cost is a wider scan.
_sqlite_sync_rewind_to_legacy() {
  local team="$1" db tl
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"
  agmsg_sqlite "$db" "
    UPDATE sync_bindings
       SET push_cursor = MIN(push_cursor,
             COALESCE((SELECT MIN(seq)-1 FROM events
                        WHERE type='message_sent' AND team='$tl' AND seq<0),
                      push_cursor))
     WHERE local_team='$tl';" >/dev/null 2>&1 || { _sqlite_sync_why; return 13; }
}

_sqlite_sync_ensure_binding() {
  local team="$1" server="$2" remote="$3" protocol="$4" generation="$5"
  agmsg_sqlite "$(_sqlite_db "$team")" "INSERT OR IGNORE INTO sync_bindings
    (local_team,server_instance_id,remote_team_id,protocol_version,driver_generation)
    VALUES('$(_sqlite_lit "$team")','$server','$remote',$protocol,'$generation');" \
    >/dev/null 2>&1
}

# Emits sync_state followed by ordered, durable push reservations.
storage_sync_prepare_push() {
  local team="$1" server="$2" remote="$3" protocol="$4" limit="$5"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  case "$limit" in ''|*[!0-9]*) _sqlite_sync_why; return 13 ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 1000 ] || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  # HERE, NOT IN THE SCHEMA. `_sqlite_sync_schema` gates every Stage-1 call, so
  # requiring `-b` there refused receiving and status as well -- on a POSIX jq
  # that never needed binary stdout. The defect this closes is "can receive but
  # never send", and this is the only path that produces the two values the CR
  # rides on. Placed before anything is reserved or written (raised in review).
  _sqlite_sync_require_jq_binary || return 10

  local prepare generation db tl input_ok version cipher key_json key_id recipients max_blob allow_new
  prepare=$(cat)
  input_ok=$(printf '%s\n' "$prepare" | jq -r \
    'select(.type=="sync_prepare" and (.envelope_v|type)=="number" and
            (.cipher|type)=="string" and has("key_id") and
            (.max_blob_bytes|type)=="number" and (.allow_new|type)=="boolean") | "ok"' 2>/dev/null)
  [ "$input_ok" = ok ] || { _sqlite_sync_why; return 13; }
  version=$(printf '%s\n' "$prepare" | jq -r '.envelope_v')
  cipher=$(printf '%s\n' "$prepare" | jq -r '.cipher')
  key_json=$(printf '%s\n' "$prepare" | jq -c '.key_id')
  key_id=$(printf '%s\n' "$prepare" | jq -r '.key_id // empty')
  recipients=$(printf '%s\n' "$prepare" | jq -c '.recipients // []')
  max_blob=$(printf '%s\n' "$prepare" | jq -r '.max_blob_bytes')
  allow_new=$(printf '%s\n' "$prepare" | jq -r 'if .allow_new then 1 else 0 end')
  [ "$version" = 1 ] || { _sqlite_sync_why; return 13; }
  case "$cipher" in
    none) [ "$key_json" = null ] && [ "$recipients" = '[]' ] || { _sqlite_sync_why; return 13; } ;;
    age-v1)
      printf '%s\n' "$key_id" | grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$' || { _sqlite_sync_why; return 13; }
      [ "$(printf '%s\n' "$recipients" | jq -r 'length >= 1 and length <= 256 and (all(.[]; type=="string"))')" = true ] || { _sqlite_sync_why; return 13; }
      ;;
    *) _sqlite_sync_why; return 13 ;;
  esac
  case "$max_blob" in ''|*[!0-9]*) _sqlite_sync_why; return 13 ;; esac

  generation=$(_sqlite_sync_generation "$team") || { _sqlite_sync_why; return 13; }
  _sqlite_sync_project_legacy "$team" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_rewind_to_legacy "$team" || { _sqlite_sync_why; return 13; }
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"

  local rows uuids
  local pos local_id wire idx status blob q cipher_lit chunk_sql="" chunk_count=0
  local cipher_helper node_bin pending=0 prepared=0 sealed=0
  local -a seal_pos seal_local seal_wire
  cipher_helper="${AGMSG_SYNC_CIPHER_HELPER:-$SKILL_DIR/scripts/internal/sync-cipher.mjs}"
  node_bin="${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"
  [ -f "$cipher_helper" ] || { _sqlite_sync_why; return 13; }
  # 'reserved' carries the LEFT JOIN's existing wire_id so the immutability
  # check below is a filter on rows already in hand, not a lookup per message.
  rows=$(_sqlite_data "$team" "
    SELECT json_object('local_position',CAST(e.seq AS TEXT),'local_id',e.id,
                       'body',e.body,'at',e.at,'from_agent',e.from_agent,
                       'to_agent',e.to_agent,'reserved',m.wire_id)
      FROM events e
      JOIN sync_bindings b ON b.local_team='$tl'
       AND b.server_instance_id='$server' AND b.remote_team_id='$remote'
       AND b.protocol_version=$protocol AND b.driver_generation='$generation'
      LEFT JOIN sync_messages m ON m.local_team=b.local_team
       AND m.server_instance_id=b.server_instance_id
       AND m.remote_team_id=b.remote_team_id
       AND m.protocol_version=b.protocol_version
       AND m.driver_generation=b.driver_generation AND m.local_position=e.seq
     WHERE e.type='message_sent' AND e.team='$tl' AND e.seq>b.push_cursor
       AND m.server_seq IS NULL
       AND ($allow_new=1 OR m.wire_id IS NOT NULL)
     ORDER BY e.seq LIMIT $limit;
  ") || { _sqlite_sync_why; return 13; }

  # A reservation an earlier call already produced is immutable: the final
  # SELECT republishes it verbatim and it is never re-sealed.
  #
  # `rows` already holds the whole page, as it did before this was batched, and
  # a body is legal up to max_blob_bytes. So nothing below is allowed to keep a
  # SECOND copy of it: the filtered rows, the uuid-joined rows and the seal
  # requests are all produced as streams straight into the helper. The only
  # thing retained per message is its position, local id and wire id — ids
  # only, no body, a handful of bytes each.
  if [ -n "$rows" ]; then
    pending=$(printf '%s\n' "$rows" | jq -c 'select(.reserved==null)' | wc -l) || { _sqlite_sync_why; return 13; }
    pending=$((pending))
  fi

  if [ "$pending" -gt 0 ]; then
    uuids=$(_sqlite_sync_uuid4_bulk "$pending") || { _sqlite_sync_why; return 13; }
    # @tsv is lossless for ids. The seal request must NOT ride in a TSV —
    # @tsv escapes backslashes, which would corrupt every body containing a
    # quote — so it is built separately, as JSONL.
    while IFS=$'\t' read -r pos local_id wire; do
      [ -n "$pos" ] || continue
      seal_pos[$prepared]="$pos"; seal_local[$prepared]="$local_id"
      seal_wire[$prepared]="$wire"; prepared=$((prepared + 1))
    done < <(paste <(printf '%s\n' "$uuids") \
                   <(printf '%s\n' "$rows" | jq -c 'select(.reserved==null)') \
             | jq -b -rR 'split("\t") as $pair | ($pair[1] | fromjson) as $row
                       | [$row.local_position, $row.local_id, $pair[0]] | @tsv')
    [ "$prepared" -eq "$pending" ] || { _sqlite_sync_why; return 13; }
    if [ -n "$key_id" ]; then q="'$(_sqlite_lit "$key_id")'"; else q="NULL"; fi
    cipher_lit="$(_sqlite_lit "$cipher")"

    # The whole page is sealed by one helper invocation, which fans the work out
    # over worker threads when the page is large enough to be worth it. Results
    # arrive in COMPLETION order (each carries its request index) and are
    # committed in groups as they land, so an interrupted run keeps every group
    # it had already committed and the next prepare re-seals only what is left.
    while IFS=$'\t' read -r idx status blob; do
      case "$idx" in ''|*[!0-9]*) continue ;; esac
      [ "$idx" -lt "$prepared" ] || continue
      if [ "$status" != ok ] || [ -z "$blob" ]; then
        printf 'agmsg: cipher helper did not seal message %s (%s)\n' "$idx" "$status" >&2
        continue
      fi
      if [ "${AGMSG_SYNC_TEST_ABORT_AFTER_SEAL:-}" = 1 ]; then
        return 75
      fi
      pos="${seal_pos[$idx]}"; wire="${seal_wire[$idx]}"
      _sqlite_sync_lit_into "${seal_local[$idx]}"; local_id="$_SQLITE_SYNC_LIT"
      _sqlite_sync_lit_into "$blob"; blob="$_SQLITE_SYNC_LIT"
      # INSERT OR IGNORE makes concurrent prepare calls converge on one winner;
      # the final SELECT below always emits the committed winner's bytes.
      chunk_sql="$chunk_sql
        INSERT OR IGNORE INTO sync_messages
          (local_team,server_instance_id,remote_team_id,protocol_version,
           driver_generation,local_position,local_id,wire_id,envelope_v,cipher,
           key_id,blob,direction)
        VALUES('$tl','$server','$remote',$protocol,'$generation',$pos,
               '$local_id','$wire',1,'$cipher_lit',$q,'$blob','push');
        INSERT OR IGNORE INTO sync_read_aliases
          (local_team,server_instance_id,remote_team_id,protocol_version,
           driver_generation,agent,local_id,wire_id,server_seq)
        SELECT m.local_team,m.server_instance_id,m.remote_team_id,m.protocol_version,
               m.driver_generation,e.to_agent,m.local_id,m.wire_id,m.server_seq
          FROM sync_messages m JOIN events e ON e.seq=m.local_position
         WHERE m.local_team='$tl' AND m.server_instance_id='$server'
           AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
           AND m.driver_generation='$generation' AND m.local_position=$pos
           AND EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
             AND r.team=e.team AND r.agent=e.to_agent AND r.msg_id=e.id);"
      chunk_count=$((chunk_count + 1))
      if [ "$chunk_count" -ge "$_SQLITE_SYNC_COMMIT_CHUNK" ] ||
         [ "${#chunk_sql}" -ge "$_SQLITE_SYNC_COMMIT_BYTES" ]; then
        _sqlite_sync_commit_chunk "$db" "$chunk_sql" || { _sqlite_sync_why; return 13; }
        sealed=$((sealed + chunk_count)); chunk_sql=""; chunk_count=0
      fi
    done < <(paste <(printf '%s\n' "$uuids") \
                   <(printf '%s\n' "$rows" | jq -c 'select(.reserved==null)') \
      | jq -cR \
        --arg cipher "$cipher" --arg key "$key_id" --arg team_id "$remote" \
        --argjson version "$version" --argjson protocol "$protocol" \
        --argjson max_blob "$max_blob" --argjson recipients "$recipients" '
        split("\t") as $pair | ($pair[1] | fromjson) as $row
        | (if ($row.body | length) == 0 then error("empty message body") else . end)
        | (if ($row.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
             then ($row.at | .[0:19] + ".000000Z") else $row.at end) as $created
        | {type:"sync_seal",envelope_v:$version,cipher:$cipher,
           key_id:(if $key=="" then null else $key end),max_blob_bytes:$max_blob,
           wire_id:$pair[0],team_id:$team_id,protocol_version:$protocol,
           recipients:$recipients,
           projection:{body:$row.body,created_at:$created,
                       from_agent:$row.from_agent,to_agent:$row.to_agent}}' \
      | "$node_bin" "$cipher_helper" seal-batch "$pending" \
      | jq -b -r --unbuffered --arg cipher "$cipher" --argjson key "$key_json" '
          select(.type=="sync_seal_result")
          | [(.index|tostring),
             (if .status=="ok" and .envelope.v==1 and .envelope.cipher==$cipher
                 and .envelope.key_id==$key and (.envelope.blob|type)=="string"
                 and (.envelope.blob|length)>0
               then "ok" else (.state // .status // "invalid") end),
             (.envelope.blob // "")] | @tsv')
    # The loop body runs in THIS shell (process substitution, not a pipeline),
    # so the trailing partial chunk is still here to commit.
    if [ "$chunk_count" -gt 0 ]; then
      _sqlite_sync_commit_chunk "$db" "$chunk_sql" || { _sqlite_sync_why; return 13; }
      sealed=$((sealed + chunk_count))
    fi
    # A message the helper could not seal stays unsealed and is retried by the
    # next prepare; failing here keeps that identical to the pre-batch driver,
    # which also aborted the call while keeping what it had committed.
    [ "$sealed" -eq "$pending" ] || { _sqlite_sync_why; return 13; }
  fi

  _sqlite_data "$team" "SELECT json_object('type','sync_state','driver_generation',
      '$generation','transport_cursor',transport_cursor)
    FROM sync_bindings WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$generation';
    SELECT json_object('type','sync_push_candidate','local_position',
      CAST(m.local_position AS TEXT),'local_id',m.local_id,'id',m.wire_id,
      'envelope',json_object('v',m.envelope_v,'cipher',m.cipher,
                             'key_id',m.key_id,'blob',m.blob))
    FROM sync_messages m JOIN sync_bindings b
      ON b.local_team=m.local_team AND b.server_instance_id=m.server_instance_id
     AND b.remote_team_id=m.remote_team_id AND b.protocol_version=m.protocol_version
     AND b.driver_generation=m.driver_generation
    WHERE m.local_team='$tl' AND m.server_instance_id='$server'
      AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
      AND m.driver_generation='$generation' AND m.local_position>b.push_cursor
      AND m.server_seq IS NULL ORDER BY m.local_position LIMIT $limit;"
}

# Reads complete server acknowledgements and advances only the contiguous prefix.
storage_sync_reconcile_push() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  local generation db tl line values="" type pos wire seq disposition jq_ok count=0
  generation=$(_sqlite_sync_generation "$team"); db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # One `jq` per line, not one per field -- the same read `storage_sync_apply_pull`
    # already does (#780), for the same reason. Five field reads plus a `grep` cost
    # six forks per acknowledgement, and a fork is 6.3 ms on the machine this was
    # measured on, which is nearly all of the 37.8 ms an acknowledgement took.
    #
    # `-s` with a length check, because one LINE is not one JSON value to jq: two
    # values on a line would otherwise each emit a full set of assignments and the
    # second would overwrite the first, `jq_ok` included, so a page could hide
    # anything in the tail of a line (#780).
    #
    # `tostring` before `@sh` on every field, which is not decoration. `@sh`
    # emits one quoted word per element of an ARRAY, and a line carrying several
    # words is not an assignment to the shell -- it is an assignment PREFIXED TO
    # A COMMAND. Three things follow at once: the field is not assigned, so the
    # variable keeps the PREVIOUS line's value, and `$pos` is interpolated into
    # SQL below; `jq_ok` is on a later line and is still reached, so the line is
    # ACCEPTED; and the shell resolves and runs a word taken from the input.
    # This input arrives from the sync server, so all three are server-chosen.
    #
    # `tostring` makes an array or object arrive as a single quoted value
    # carrying its JSON text, which the whitelist below refuses, and leaves
    # strings and numbers exactly as they were.
    #
    # `@sh` is jq's shell-quoting filter, so every value arrives verbatim through
    # `eval` with nothing for this side to get wrong. `jq_ok` is emitted LAST: a
    # line jq cannot parse produces no assignments at all, so the sentinel stays 0
    # and this fails closed rather than proceeding on stale values from the
    # previous iteration.
    jq_ok=0
    eval "$(printf '%s\n' "$line" | jq -r -s '
      if length != 1 then error("one JSON value per line") else .[0] end
      | "type=\(.type // "" | tostring | @sh)",
      "pos=\(.local_position // "" | tostring | @sh)",
      "wire=\(.id // "" | tostring | @sh)",
      "seq=\(.server_seq // "" | tostring | @sh)",
      "disposition=\(.disposition // "" | tostring | @sh)",
      "jq_ok=1"' 2>/dev/null)"
    [ "$jq_ok" = 1 ] || { _sqlite_sync_why; return 13; }
    [ "$type" = sync_push_ack ] || { _sqlite_sync_why; return 13; }
    # $pos and $seq are interpolated into SQL below, so these stay whitelists.
    # A local position may be negative (projected legacy history sits under the
    # live space); a server sequence is assigned by the server and never is.
    case "$pos" in
      '' | '-') _sqlite_sync_why; return 13 ;;
      -*) case "${pos#-}" in
            '' | *[!0-9]*) _sqlite_sync_why; return 13 ;;
          esac ;;
      *[!0-9]*) _sqlite_sync_why; return 13 ;;
    esac
    case "$seq" in
      '' | *[!0-9]*) _sqlite_sync_why; return 13 ;;
    esac
    case "$disposition" in stored|duplicate) ;; *) _sqlite_sync_why; return 13 ;; esac
    # The sixth fork, removed. `case` is a builtin and these two patterns are
    # exactly `^[0-9a-f-]{36}$`: a length of 36, and not one character outside
    # the class. Kept as a whitelist because `$wire` is interpolated into SQL.
    # (`storage_sync_apply_pull` still greps, but its pattern is the strict
    # UUIDv4 shape, which does not reduce to a glob this cleanly.)
    case "${#wire}" in 36) ;; *) _sqlite_sync_why; return 13 ;; esac
    case "$wire" in *[!0-9a-f-]*) _sqlite_sync_why; return 13 ;; esac
    values="${values}${values:+,}($pos,'$wire','$seq')"; count=$((count + 1))
  done
  [ "$count" -gt 0 ] || { _sqlite_sync_why; return 13; }

  # Stdin, for the same reason as the pull outcomes (#882): `$values` gains an
  # entry per acked message and a full catch-up push carries a thousand.
  _sqlite_exec_stdin "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE incoming_sync_acks(
      local_position INTEGER UNIQUE,wire_id TEXT UNIQUE,server_seq TEXT UNIQUE);
    INSERT INTO incoming_sync_acks VALUES $values;
    CREATE TEMP TABLE sync_assert(ok INTEGER CHECK(ok=1));
    INSERT INTO sync_assert SELECT CASE WHEN COUNT(*)=$count THEN 1 ELSE 0 END
      FROM incoming_sync_acks a JOIN sync_messages m
        ON m.local_team='$tl' AND m.server_instance_id='$server'
       AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
       AND m.driver_generation='$generation' AND m.local_position=a.local_position
       AND m.wire_id=a.wire_id
       AND (m.server_seq IS NULL OR m.server_seq=a.server_seq);
    UPDATE sync_messages SET server_seq=(SELECT a.server_seq FROM incoming_sync_acks a
      WHERE a.local_position=sync_messages.local_position AND a.wire_id=sync_messages.wire_id)
      WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
        AND protocol_version=$protocol AND driver_generation='$generation'
        AND EXISTS(SELECT 1 FROM incoming_sync_acks a
          WHERE a.local_position=sync_messages.local_position AND a.wire_id=sync_messages.wire_id);
    UPDATE sync_read_aliases AS x SET server_seq=(
      SELECT m.server_seq FROM sync_messages m
       WHERE m.local_team=x.local_team AND m.server_instance_id=x.server_instance_id
         AND m.remote_team_id=x.remote_team_id AND m.protocol_version=x.protocol_version
         AND m.driver_generation=x.driver_generation AND m.local_id=x.local_id
         AND m.wire_id=x.wire_id)
     WHERE x.local_team='$tl' AND x.server_instance_id='$server'
       AND x.remote_team_id='$remote' AND x.protocol_version=$protocol
       AND x.driver_generation='$generation';
    -- The cursor advances to the end of the CONTIGUOUS acknowledged run, which
    -- is what it always did. What changed is how the run's end is found.
    --
    -- It used to ask, for each candidate e, whether any gap existed in
    -- (push_cursor, e.seq]. That inner test named e.seq, so it was correlated:
    -- one scan of the gap set per candidate, and the work grew with the SQUARE
    -- of the number of candidates. On a first connect, where every message is a
    -- candidate, that is the whole history squared (#912).
    --
    -- The gap set does not depend on e. The FIRST gap after the cursor bounds
    -- every contiguous run that starts there, so the answer is the largest
    -- candidate below it. Same answer: a candidate below the first gap has no
    -- gap beneath it, and one at or above it has that gap.
    --
    -- A TEMP TABLE rather than a subquery, for two reasons that both had to be
    -- measured rather than assumed. Written inline as a derived table, SQLite
    -- re-evaluated it per candidate and the quadratic came straight back (3.3 s
    -- against 27 ms at 2,000 rows). Written twice as an uncorrelated scalar
    -- subquery it is fast, but then the gap query exists in two places that can
    -- drift apart. A temp table is built once because of how it is built, not
    -- because a planner chose to.
    --
    -- No sentinel. An earlier revision bounded with 9223372036854775807 as
    -- though it were infinity; it is the largest value events.seq can hold, so
    -- a candidate sitting exactly there was accepted by the old query and
    -- refused by the new one. `IS NULL OR <` says what was meant and has no
    -- boundary to collide with.
    CREATE TEMP TABLE sync_first_gap AS
      SELECT MIN(gap.seq) AS seq FROM events gap LEFT JOIN sync_messages gm
        ON gm.local_team='$tl' AND gm.server_instance_id='$server'
       AND gm.remote_team_id='$remote' AND gm.protocol_version=$protocol
       AND gm.driver_generation='$generation' AND gm.local_position=gap.seq
      WHERE gap.type='message_sent' AND gap.team='$tl' AND gm.server_seq IS NULL
        AND gap.seq>(SELECT push_cursor FROM sync_bindings
                      WHERE local_team='$tl' AND server_instance_id='$server'
                        AND remote_team_id='$remote' AND protocol_version=$protocol
                        AND driver_generation='$generation');
    UPDATE sync_bindings AS b SET push_cursor=COALESCE((
      SELECT MAX(e.seq) FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.seq>b.push_cursor
        AND ((SELECT seq FROM sync_first_gap) IS NULL
             OR e.seq<(SELECT seq FROM sync_first_gap))),b.push_cursor)
    WHERE b.local_team='$tl' AND b.server_instance_id='$server'
      AND b.remote_team_id='$remote' AND b.protocol_version=$protocol
      AND b.driver_generation='$generation';
    COMMIT;" >/dev/null 2>&1 || return 12

  _sqlite_data "$team" "SELECT json_object('type','sync_reconcile_result','push_cursor',
    CAST(push_cursor AS TEXT)) FROM sync_bindings WHERE local_team='$tl'
    AND server_instance_id='$server' AND remote_team_id='$remote'
    AND protocol_version=$protocol AND driver_generation='$generation';"
}

# Reads a validated pull page, durably quarantines/reconciles/imports it, then
# advances the transport cursor in the same transaction.
storage_sync_apply_pull() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  local generation db tl sql_file line type final_cursor="" corrupt=0 outcome_ids=""
  local seq wire received v cipher key_id blob status policy local_rev reason kind
  local from to body at local_id q line_next_after jq_ok nul_flag
  local cipher_q blob_q key_id_q received_q policy_q local_rev_q reason_q
  local from_q to_q body_q at_q
  generation=$(_sqlite_sync_generation "$team"); db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || { _sqlite_sync_why; return 13; }
  sql_file=$(mktemp "${TMPDIR:-/tmp}/agmsg-sync-sql.XXXXXX") || { _sqlite_sync_why; return 13; }
  _AGMSG_SYNC_SQL_FILE="$sql_file"
  _AGMSG_SYNC_JQ_ERR=""
  trap 'case "${_AGMSG_SYNC_SQL_FILE:-}" in "${TMPDIR:-/tmp}"/agmsg-sync-sql.*) rm -f "$_AGMSG_SYNC_SQL_FILE" ;; esac
        case "${_AGMSG_SYNC_JQ_ERR:-}" in "${TMPDIR:-/tmp}"/agmsg-sync-jq.*) rm -f "$_AGMSG_SYNC_JQ_ERR" ;; esac' EXIT INT TERM HUP
  printf '%s\n' 'BEGIN IMMEDIATE;
    CREATE TEMP TABLE sync_apply_envelope(blob TEXT);
    INSERT INTO temp.sync_apply_envelope VALUES(NULL);' > "$sql_file"

  # ONE jq FOR THE WHOLE PAGE, AND NO eval AT ALL (#908 item 3, #940).
  #
  # Each message used to pay a printf and a jq, and the jq's output was a list
  # of shell assignments fed to eval -- which is why every field had to travel
  # through `tostring | @sh` (#930): the only thing standing between a
  # server-chosen string and the shell was quoting discipline. Both costs go
  # together. The page is parsed by a single jq that emits, after a leading
  # record count, one quarantine-flag frame followed by every record's
  # eighteen fields as raw values, all separated by NUL bytes; the loop below
  # reads them with `read -d ''` into plain variables. Nothing server-chosen
  # is ever parsed as shell again -- the class #930 had to defend is gone,
  # not guarded.
  #
  # The framing is sound because a NUL can never appear inside a value jq
  # emits: fourteen fields (type, next_after, server_seq, id,
  # server_received_at, envelope.*, status, policy_revision,
  # local_security_revision, reason, projection.kind) still refuse the whole
  # record's page outright if they hold one, naming the record and the field
  # -- these are the fields every UPDATE in this function uses to find a
  # SPECIFIC existing row, so a corrupt one cannot be trusted to name itself,
  # let alone be stripped and reused as if clean (identifier poisoning: a
  # DIFFERENT record's real id, with U+0000 appended, would strip down to
  # that record's own wire id and land this record's outcome on it instead).
  # The remaining four -- projection.from_agent/to_agent/body/created_at,
  # never used to look up or update a different row -- have U+0000 stripped
  # unconditionally instead, with the leading flag frame naming whether any
  # of the four held it; the shell routes a flagged record to per-record
  # quarantine rather than losing the whole page to it (#940's own
  # regression: one bad body made a team impossible to ever pull again). The
  # old pipeline silently stored a NUL-holding body MANGLED -- the byte
  # becoming other bytes on the way through `jq -r` and the shell's own
  # NUL-stripping -- and reported success; this neither rewrites nor loses
  # it: the value the store cannot hold verbatim is named and quarantined,
  # not silently kept.
  #
  # --raw-input keeps the old "one JSON value per line" refusal: each line is
  # fromjson'd on its own, so a line smuggling two values fails exactly as it
  # did when the per-line jq slurped it (the error names the line). `-s` holds
  # the page in jq's memory once -- the same order of memory the old
  # per-message `-s` peaked at for its largest message, page-wide, and a page
  # is bounded at 1000 records.
  local jq_err page_count record_index field_name
  jq_err=$(mktemp "${TMPDIR:-/tmp}/agmsg-sync-jq.XXXXXX") || { rm -f "$sql_file"; _sqlite_sync_why; return 13; }
  _AGMSG_SYNC_JQ_ERR="$jq_err"
  exec 3< <(jq -j -R -s '
    def fields: ["type","next_after","server_seq","id","server_received_at",
                 "envelope.v","envelope.cipher","envelope.key_id","envelope.blob",
                 "status","policy_revision","local_security_revision","reason",
                 "projection.kind","projection.from_agent","projection.to_agent",
                 "projection.body","projection.created_at"];
    # Only these four are payload: never used to look up or update a DIFFERENT
    # row (id/wire and server_seq are; so is type/status, indirectly, via the
    # whitelist and the fixed-literal case match). A record whose id, server
    # seq, or any other non-payload field carries U+0000 cannot be safely
    # named after stripping -- a trailing byte on an otherwise-valid UUID
    # would strip down to the real wire_id of a DIFFERENT record, and the
    # quarantine UPDATE for this record would land on that unrelated row
    # instead (found in review: identifier poisoning, not merely a lost
    # U+0000 guard on this one record). Those fields keep the page-wide
    # error() unchanged.
    def is_payload_field($name): (["projection.from_agent","projection.to_agent",
      "projection.body","projection.created_at"] | index($name)) != null;
    def pick($r; $name):
      (if   $name == "type"                    then $r.type // ""
       elif $name == "next_after"              then $r.next_after // ""
       elif $name == "server_seq"              then $r.server_seq // ""
       elif $name == "id"                      then $r.id // ""
       elif $name == "server_received_at"      then $r.server_received_at // ""
       elif $name == "envelope.v"              then $r.envelope.v
       elif $name == "envelope.cipher"         then $r.envelope.cipher
       elif $name == "envelope.key_id"         then $r.envelope.key_id // ""
       elif $name == "envelope.blob"           then $r.envelope.blob
       elif $name == "status"                  then $r.status
       elif $name == "policy_revision"         then $r.policy_revision // ""
       elif $name == "local_security_revision" then $r.local_security_revision // ""
       elif $name == "reason"                  then $r.reason // ""
       elif $name == "projection.kind"         then $r.projection.kind // ""
       elif $name == "projection.from_agent"   then $r.projection.from_agent // ""
       elif $name == "projection.to_agent"     then $r.projection.to_agent // ""
       elif $name == "projection.body"         then $r.projection.body // ""
       else                                         $r.projection.created_at // ""
       end) | tostring;
    [ split("\n")[] | select(length > 0) ] as $lines
    | ($lines | length | tostring) + "\u0000"
    , ( $lines | to_entries[]
        | (.key + 1) as $n
        | (try (.value | fromjson) catch error("record \($n): not one JSON value on its line")) as $r
        | ( [ fields[] as $name
              | pick($r; $name) as $v
              | if is_payload_field($name) then $v
                elif ($v | contains("\u0000"))
                then error("record \($n): field \($name) contains U+0000")
                else $v end
              | {name: $name, v: .} ] ) as $entries
        | ( $entries | map(select(is_payload_field(.name)) | .v | contains("\u0000")) | any ) as $flag_bool
        | ( (if $flag_bool then "1" else "0" end) + "\u0000" )
        , ( $entries[] | (if is_payload_field(.name) then (.v | gsub("\u0000"; "")) else .v end) + "\u0000" ) )
  ' 2>"$jq_err")
  # ONE cleanup for EVERY failure after the stream opened: the file descriptor,
  # both temp files, the globals the trap reads, and the trap itself. The bats
  # suite calls this function directly in a long-lived shell, so a site that
  # returns without coming through here leaks an fd and a temp file into that
  # shell -- exactly what the first review of this change found at the sites
  # that predate the stream and still only removed the SQL file.
  _sqlite_sync_apply_fail() {  # [message]
    if [ "$#" -gt 0 ]; then
      [ -s "$jq_err" ] && sed 's/^/agmsg: sqlite-sync: /' "$jq_err" >&2
      printf 'agmsg: sqlite-sync: %s\n' "$1" >&2
    fi
    # A brace group, because `exec` with no command word applies its
    # redirections to the shell itself and they outlive the statement: the
    # bare form sent every later stderr write in this shell to /dev/null,
    # starting with `_sqlite_sync_why` (#911).
    { exec 3<&-; } 2>/dev/null || true
    rm -f "$sql_file" "$jq_err"
    _AGMSG_SYNC_SQL_FILE=""; _AGMSG_SYNC_JQ_ERR=""
    trap - EXIT INT TERM HUP
  }
  if ! IFS= read -r -d '' page_count <&3 || ! [[ "$page_count" =~ ^[0-9]+$ ]]; then
    _sqlite_sync_apply_fail "the page produced no readable record count"
    _sqlite_sync_why; return 13
  fi
  record_index=0
  while [ "$record_index" -lt "$page_count" ]; do
    record_index=$((record_index + 1))
    # #940 per-record: one extra frame ahead of the eighteen, naming whether
    # ANY of this record's fields held U+0000. jq has already stripped the
    # byte from every value below regardless of the flag (a no-op when it was
    # never there), so the framing can never break on it again -- the flag is
    # read, and branched on, before any of those values are trusted.
    if ! IFS= read -r -d '' nul_flag <&3; then
      _sqlite_sync_apply_fail "record $record_index ended mid-frame at the NUL flag"
      _sqlite_sync_why; return 13
    fi
    for field_name in type line_next_after seq wire received v cipher key_id blob \
                      status policy local_rev reason kind from to body at; do
      if ! IFS= read -r -d '' "$field_name" <&3; then
        _sqlite_sync_apply_fail "record $record_index ended mid-frame at field $field_name"
        _sqlite_sync_why; return 13
      fi
    done
    if [ "$type" = sync_pull_cursor ]; then
      # Held in its own variable and copied only here. Every line now carries
      # a next_after, so assigning the cursor directly would let a message
      # line after the cursor line blank it.
      final_cursor="$line_next_after"
      case "$final_cursor" in ''|*[!0-9]*) _sqlite_sync_apply_fail; _sqlite_sync_why; return 13 ;; esac
      continue
    fi
    [ "$type" = sync_pull_message ] || { _sqlite_sync_apply_fail; _sqlite_sync_why; return 13; }
    [[ "$wire" =~ $_SQLITE_SYNC_WIRE_RE ]] \
      || { _sqlite_sync_apply_fail; _sqlite_sync_why; return 13; }
    outcome_ids="${outcome_ids}${outcome_ids:+,}'$wire'"
    case "$seq:$v" in *[!0-9:]*) _sqlite_sync_apply_fail; _sqlite_sync_why; return 13 ;; esac
    case "$status" in importable|unsupported_cipher|pending_key|authentication_failed|malformed|policy_violation) ;; *) _sqlite_sync_apply_fail; _sqlite_sync_why; return 13 ;; esac
    # Quoted ONCE PER MESSAGE, here, in the shell: each of these fields used
    # to go through `$(_sqlite_lit ...)` -- a printf|sed fork -- at every use
    # site in the SQL below, 32 forks per message and most of the 34 processes
    # a pulled message cost (#908). _sqlite_sync_lit_into is the builtin form
    # the bulk seal loop already uses; the escaping rule lives there, not here.
    # Inside the per-message loop on purpose: every one of these changes with
    # the message, and hoisting them to the page would carry the previous
    # message's values into this one's rows.
    _sqlite_sync_lit_into "$cipher"; cipher_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$blob"; blob_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$key_id"; key_id_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$received"; received_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$policy"; policy_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$local_rev"; local_rev_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$reason"; reason_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$from"; from_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$to"; to_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$body"; body_q="$_SQLITE_SYNC_LIT"
    _sqlite_sync_lit_into "$at"; at_q="$_SQLITE_SYNC_LIT"
    q="'$key_id_q'"; [ -n "$key_id" ] || q=NULL
    printf "%s\n" "
      UPDATE temp.sync_apply_envelope SET blob='$blob_q';
      INSERT OR IGNORE INTO sync_conflicts
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,envelope_v,cipher,key_id,blob,
         reason,observed_at)
      SELECT '$tl','$server','$remote',$protocol,'$generation','$seq','$wire',$v,
             '$cipher_q',$q,(SELECT blob FROM temp.sync_apply_envelope),
             'server sequence maps to another wire id',
             strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE EXISTS(SELECT 1 FROM sync_quarantine qx
        WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
          AND qx.protocol_version=$protocol AND qx.server_seq='$seq'
          AND qx.wire_id<>'$wire')
         OR EXISTS(SELECT 1 FROM sync_messages mx
        WHERE mx.server_instance_id='$server' AND mx.remote_team_id='$remote'
          AND mx.protocol_version=$protocol AND mx.server_seq='$seq'
          AND mx.wire_id<>'$wire');
      INSERT OR IGNORE INTO sync_conflicts
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,envelope_v,cipher,key_id,blob,
         reason,observed_at)
      SELECT '$tl','$server','$remote',$protocol,'$generation','$seq','$wire',$v,
             '$cipher_q',$q,(SELECT blob FROM temp.sync_apply_envelope),
             'wire id maps to another sequence or envelope',
             strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE EXISTS(SELECT 1 FROM sync_quarantine qx
        WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
          AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
          AND (qx.server_seq<>'$seq' OR qx.envelope_v<>$v
            OR qx.cipher<>'$cipher_q'
            OR COALESCE(qx.key_id,'')<>'$key_id_q'
            OR qx.blob<>(SELECT blob FROM temp.sync_apply_envelope)))
         OR EXISTS(SELECT 1 FROM sync_messages mx
        WHERE mx.server_instance_id='$server' AND mx.remote_team_id='$remote'
          AND mx.protocol_version=$protocol AND mx.wire_id='$wire'
          AND (mx.server_seq IS NOT NULL AND mx.server_seq<>'$seq'
            OR mx.envelope_v<>$v OR mx.cipher<>'$cipher_q'
            OR COALESCE(mx.key_id,'')<>'$key_id_q'
            OR mx.blob<>(SELECT blob FROM temp.sync_apply_envelope)));
      INSERT OR IGNORE INTO sync_quarantine
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,server_received_at,envelope_v,
         cipher,key_id,blob,status,policy_revision,local_security_revision,reason)
      VALUES('$tl','$server','$remote',$protocol,'$generation','$seq','$wire',
        '$received_q',$v,'$cipher_q',$q,
        (SELECT blob FROM temp.sync_apply_envelope),'$status','$policy_q',
        '$local_rev_q','$reason_q');
      UPDATE sync_quarantine SET status='$status',
          policy_revision='$policy_q',
          local_security_revision='$local_rev_q',
          reason='$reason_q'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire'
         AND server_seq='$seq' AND envelope_v=$v
         AND cipher='$cipher_q'
         AND COALESCE(key_id,'')='$key_id_q'
         AND blob=(SELECT blob FROM temp.sync_apply_envelope)
         AND status NOT IN ('corrupt_state','imported','reconciled');
      UPDATE sync_quarantine SET status='corrupt_state',reason='wire envelope mismatch'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire'
         AND (server_seq<>'$seq' OR envelope_v<>$v OR cipher<>'$cipher_q'
              OR COALESCE(key_id,'')<>'$key_id_q'
              OR blob<>(SELECT blob FROM temp.sync_apply_envelope));
      UPDATE sync_quarantine SET status='corrupt_state',reason='binding sequence conflict'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire'
         AND EXISTS(SELECT 1 FROM sync_conflicts cx
           WHERE cx.server_instance_id='$server' AND cx.remote_team_id='$remote'
             AND cx.protocol_version=$protocol AND cx.wire_id='$wire');
      UPDATE sync_quarantine SET status='corrupt_state',reason='mapped envelope mismatch'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire' AND EXISTS(
           SELECT 1 FROM sync_messages m WHERE m.server_instance_id='$server'
             AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
             AND m.wire_id='$wire' AND (m.envelope_v<>$v OR m.cipher<>'$cipher_q'
               OR COALESCE(m.key_id,'')<>'$key_id_q'
               OR m.blob<>(SELECT blob FROM temp.sync_apply_envelope)
               OR (m.server_seq IS NOT NULL AND m.server_seq<>'$seq')));
      UPDATE sync_messages SET server_seq='$seq' WHERE server_instance_id='$server'
        AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
        AND envelope_v=$v AND cipher='$cipher_q'
        AND COALESCE(key_id,'')='$key_id_q'
        AND blob=(SELECT blob FROM temp.sync_apply_envelope) AND (server_seq IS NULL OR server_seq='$seq')
        AND EXISTS(SELECT 1 FROM sync_quarantine qx
          WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
            AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
            AND qx.status='importable');
      UPDATE sync_quarantine SET status='reconciled' WHERE server_instance_id='$server'
        AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
        AND status='importable' AND EXISTS(SELECT 1 FROM sync_messages m
          WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
            AND m.protocol_version=$protocol AND m.wire_id='$wire' AND m.server_seq='$seq');" >> "$sql_file"

    if [ "$nul_flag" = 1 ]; then
      # #940: quarantine this one record instead of losing the whole page to
      # it. This is the fourth corrupt_state reason (three already exist for
      # envelope/sequence/mapping mismatches, above) -- no new machinery, just
      # a new WHERE this record's wire_id can land in. The row already exists
      # from the INSERT a few statements up, so this only ever overrides its
      # status; it never creates one. Appended last for this record, so it is
      # the final word on the row no matter what the earlier UPDATEs above set
      # -- and it lands in the same transaction, ahead of any later record's
      # SQL, so the "importable" branch below never sees a status this record
      # was supposed to be denied.
      printf "%s\n" "
        UPDATE sync_quarantine SET status='corrupt_state',reason='body contains U+0000'
         WHERE server_instance_id='$server' AND remote_team_id='$remote'
           AND protocol_version=$protocol AND wire_id='$wire';" >> "$sql_file"
      # Skip the importable-message path below outright, rather than relying
      # on its NOT EXISTS(...corrupt_state) guard: jq has already stripped
      # U+0000 from $body/$from/$to for every value in this record, and if a
      # value WAS nothing but that one byte, the emptied field would trip the
      # "-n" checks below and fail the whole page (return 13) -- exactly the
      # failure this change exists to stop happening for one bad record.
      continue
    fi

    if [ "$status" = importable ]; then
      if [ -n "$kind" ]; then
        case "$kind" in
          member_joined|member_left|member_renamed|key_rotated) ;;
          *)
            echo "agmsg: storage sync apply cannot acknowledge projection kind '$kind'" >&2
            _sqlite_sync_apply_fail; _sqlite_sync_why; return 13 ;;
        esac
        # The roster driver has already durably applied this mutation. Storage
        # owns the quarantine and transport cursor, so it records the matching
        # terminal outcome without projecting a roster event into messages.
        printf "%s\n" "
          UPDATE sync_quarantine SET status='imported'
           WHERE server_instance_id='$server' AND remote_team_id='$remote'
             AND protocol_version=$protocol AND wire_id='$wire'
             AND server_seq='$seq' AND status='importable';" >> "$sql_file"
        continue
      fi
      [ -n "$from" ] && [ -n "$to" ] && [ -n "$body" ] && [ -n "$at" ] || {
        echo "agmsg: storage sync apply received an importable message without its projection" >&2
        _sqlite_sync_apply_fail; _sqlite_sync_why; return 13;
      }
      local_id=$(compat_uuid7) || { _sqlite_sync_apply_fail; _sqlite_sync_why; return 13; }
      printf "%s\n" "
        INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
        SELECT 'message_sent','$local_id','$tl','$from_q',
               '$to_q','$body_q','$at_q'
        WHERE NOT EXISTS(SELECT 1 FROM sync_messages m
          WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
            AND m.protocol_version=$protocol AND m.wire_id='$wire')
          AND NOT EXISTS(SELECT 1 FROM sync_quarantine qx
          WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
            AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
            AND qx.status='corrupt_state')
          AND NOT EXISTS(SELECT 1 FROM sync_conflicts cx
          WHERE cx.server_instance_id='$server' AND cx.remote_team_id='$remote'
            AND cx.protocol_version=$protocol AND cx.wire_id='$wire');
        -- Mirror into the legacy table, which other software still reads
        -- (#689). This is the arrival path for anything sent from another
        -- machine: mirroring only local sends would leave those readers seeing
        -- one side of a conversation, and that is the side this exists for.
        --
        -- Keyed off the event actually having been inserted rather than
        -- repeating the three-part duplicate guard above. If the event was
        -- skipped there is no row with this id, so neither statement fires and
        -- last_insert_rowid() is never read.
        INSERT INTO messages(team,from_agent,to_agent,body,created_at)
        SELECT '$tl','$from_q','$to_q',
               '$body_q','$at_q'
         WHERE EXISTS(SELECT 1 FROM events e
                       WHERE e.id='$local_id' AND e.legacy_id IS NULL);
        UPDATE events SET legacy_id=last_insert_rowid()
         WHERE id='$local_id' AND legacy_id IS NULL;
        INSERT OR IGNORE INTO sync_messages
          (local_team,server_instance_id,remote_team_id,protocol_version,
           driver_generation,local_position,local_id,wire_id,envelope_v,cipher,
           key_id,blob,server_seq,direction)
        SELECT '$tl','$server','$remote',$protocol,'$generation',seq,id,'$wire',$v,
               '$cipher_q',$q,(SELECT blob FROM temp.sync_apply_envelope),'$seq','pull'
          FROM events WHERE id='$local_id';
        UPDATE sync_quarantine SET status='imported' WHERE server_instance_id='$server'
          AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
          AND status<>'corrupt_state' AND EXISTS(SELECT 1 FROM sync_messages m
            WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
              AND m.protocol_version=$protocol AND m.wire_id='$wire'
              AND m.direction='pull');" >> "$sql_file"
    fi
  done
  # The stream must end exactly where the count said. One more read must fail
  # AND deliver nothing: read -d '' returns non-zero at EOF while still
  # filling the variable with any bytes that arrived before it, so surplus
  # without a final NUL passes the status check alone (review finding).
  field_name=""
  if IFS= read -r -d '' field_name <&3 || [ -n "$field_name" ]; then
    _sqlite_sync_apply_fail "the page carried bytes past its declared $page_count records"
    _sqlite_sync_why; return 13
  fi
  exec 3<&-
  rm -f "$jq_err"; _AGMSG_SYNC_JQ_ERR=""
  [ -n "$final_cursor" ] || { _sqlite_sync_apply_fail; _sqlite_sync_why; return 13; }
  printf "%s\n" "UPDATE sync_bindings SET transport_cursor='$final_cursor'
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    COMMIT;" >> "$sql_file"
  # -bail, for the reason the local write path already carries it: the CLI
  # reports a statement error and keeps going, so a failure partway through this
  # batch would still reach the sync mapping, the transport cursor and the
  # COMMIT. A non-zero exit afterwards does not undo what was committed. The
  # batch now spans the event, its legacy mirror and the mapping, so a partial
  # commit is exactly the asymmetry the mirror exists to prevent — an event with
  # no copy, or a copy nothing points at (#689). Found in the local path while
  # building this and not carried across; a reviewer caught that.
  if ! agmsg_sqlite -bail "$db" < "$sql_file" >/dev/null 2>&1; then
    _sqlite_sync_apply_fail; _sqlite_sync_why; return 13
  fi
  rm -f "$sql_file"
  trap - EXIT INT TERM HUP
  _AGMSG_SYNC_SQL_FILE=""
  corrupt=$(agmsg_sqlite "$db" "SELECT
    (SELECT COUNT(*) FROM sync_quarantine WHERE
    server_instance_id='$server' AND remote_team_id='$remote' AND protocol_version=$protocol
    AND status='corrupt_state') +
    (SELECT COUNT(*) FROM sync_conflicts WHERE server_instance_id='$server'
     AND remote_team_id='$remote' AND protocol_version=$protocol);" | tr -d '\r')
  # STDIN, BECAUSE THIS ONE GROWS WITH THE PAGE (#882). `outcome_ids` gains an
  # entry per pulled message and is embedded TWICE below, so the command line
  # this used to be would pass about 400 messages on Windows and refuse the
  # next one. Nothing else about the query changed.
  _sqlite_data_stdin "$team" "SELECT json_object('type','sync_apply_result','transport_cursor',
    transport_cursor,'corrupt_count',$corrupt) FROM sync_bindings
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    SELECT json_object('type','sync_apply_outcome','id',wire_id,
                       'server_seq',server_seq,'status',status)
      FROM sync_quarantine WHERE server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND wire_id IN (${outcome_ids:-''})
    UNION ALL
    SELECT json_object('type','sync_apply_outcome','id',c.wire_id,
                       'server_seq',c.server_seq,'status','corrupt_state')
      FROM sync_conflicts c WHERE c.server_instance_id='$server'
       AND c.remote_team_id='$remote' AND c.protocol_version=$protocol
       AND c.wire_id IN (${outcome_ids:-''})
       AND NOT EXISTS(SELECT 1 FROM sync_quarantine qx
         WHERE qx.server_instance_id=c.server_instance_id
           AND qx.remote_team_id=c.remote_team_id
           AND qx.protocol_version=c.protocol_version AND qx.wire_id=c.wire_id);"
}

# Emits durable blocking envelopes for explicit decrypt/import reprocessing.
# This never changes the transport cursor; apply performs any resulting state
# transition atomically against that already-advanced cursor.
storage_sync_reprocess() {
  local team="$1" server="$2" remote="$3" protocol="$4" limit="$5" after="${6:-}"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  case "$limit" in ''|*[!0-9]*) _sqlite_sync_why; return 13 ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 1000 ] || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  local generation tl after_seq after_wire after_sql=""
  if [ -n "$after" ]; then
    case "$after" in *:*) ;; *) _sqlite_sync_why; return 13 ;; esac
    after_seq="${after%%:*}"; after_wire="${after#*:}"
    case "$after_seq" in ''|*[!0-9]*) _sqlite_sync_why; return 13 ;; esac
    [ "$after_seq" = 0 ] || [ "${after_seq#0}" = "$after_seq" ] || { _sqlite_sync_why; return 13; }
    [ "$after_seq" -le 9223372036854775807 ] 2>/dev/null || { _sqlite_sync_why; return 13; }
    printf '%s' "$after_wire" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || { _sqlite_sync_why; return 13; }
    after_sql="AND (CAST(server_seq AS INTEGER)>$after_seq OR
      (CAST(server_seq AS INTEGER)=$after_seq AND wire_id>'$after_wire'))"
  fi
  generation=$(_sqlite_sync_generation "$team") || { _sqlite_sync_why; return 13; }
  tl=$(_sqlite_lit "$team")
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || { _sqlite_sync_why; return 13; }
  _sqlite_data "$team" "SELECT json_object('type','sync_state','driver_generation',
      '$generation','transport_cursor',transport_cursor)
    FROM sync_bindings WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$generation';
    WITH candidates AS (
      SELECT server_seq,wire_id,server_received_at,envelope_v,cipher,key_id,blob,status
        FROM sync_quarantine
       WHERE local_team='$tl' AND server_instance_id='$server'
         AND remote_team_id='$remote' AND protocol_version=$protocol
         AND driver_generation='$generation'
         AND status IN ('unsupported_cipher','pending_key','authentication_failed',
                        'malformed','policy_violation')
         $after_sql
       ORDER BY CAST(server_seq AS INTEGER),wire_id LIMIT $((limit + 1))
    ), output AS (
      SELECT 0 AS trailer,CAST(server_seq AS INTEGER) AS sequence_order,wire_id,
        json_object('type','sync_reprocess_candidate','server_seq',server_seq,
          'id',wire_id,'server_received_at',server_received_at,
          'envelope',json_object('v',envelope_v,'cipher',cipher,'key_id',key_id,'blob',blob),
          'prior_status',status) AS record
      FROM candidates ORDER BY CAST(server_seq AS INTEGER),wire_id LIMIT $limit
    ), trailer AS (
      SELECT 1 AS trailer,NULL AS sequence_order,NULL AS wire_id,
        json_object('type','sync_reprocess_page','next_after',
          CASE WHEN COUNT(*)>$limit THEN (
            SELECT server_seq||':'||wire_id FROM candidates
             ORDER BY CAST(server_seq AS INTEGER),wire_id LIMIT 1 OFFSET $((limit - 1)))
            ELSE NULL END,
          'has_more',CASE WHEN COUNT(*)>$limit THEN json('true') ELSE json('false') END
        ) AS record
      FROM candidates
    )
    SELECT record FROM (SELECT * FROM output UNION ALL SELECT * FROM trailer)
     ORDER BY trailer,sequence_order,wire_id;"
}

# Derive the remote read frontier and exact wire exceptions from durable local
# outcomes. The authenticated member roster/floor is supplied by the engine.
storage_sync_prepare_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  local generation db tl context floor current members local_agents count values="" local_values=""
  local member id name agent insert_members="" insert_local_agents=""
  generation=$(_sqlite_sync_generation "$team") || { _sqlite_sync_why; return 13; }
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || { _sqlite_sync_why; return 13; }
  context=$(cat)
  [ "$(printf '%s\n' "$context" | jq -r '
    select(.type=="sync_read_context" and (.min_available_seq|type)=="string" and
      (.current_seq|type)=="string" and (.members|type)=="array" and
      (.local_agents|type)=="array" and (.local_agents|length)<=1000 and
      ((.local_agents|unique|length)==(.local_agents|length)) and all(.local_agents[];
        (type=="string") and length>0) and
      (.members|length)<=1000 and all(.members[];
        ((.member_id|type)=="string") and ((.name|type)=="string") and (.name|length)>0)) | "ok"' \
      2>/dev/null)" = ok ] || { _sqlite_sync_why; return 13; }
  # ...and the roster list on its own line, so a refusal here is told apart
  # from the eight context checks above by the line number _sqlite_sync_why
  # prints (#911) -- and says what it is in words as well. The bound is the
  # size the contract test actually passes through this path (10,000): the
  # list is one entry per roster mutation the team ever applied, so a team
  # past it has had ten thousand joins, leaves or renames, which is a signal
  # to look at the design, not a size to wave through. Over the bound is
  # refused (13), which leaves the frontier where it was -- the safe side.
  # Shape and size in jq, then the DOMAIN per entry through
  # _sqlite_sync_sequence -- the same bound (9223372036854775807) this
  # function already holds current_seq to, a hundred lines above. Two review
  # findings shaped this:
  #   - Shape alone let 9223372036854775808..9999999999999999999 through. The
  #     temp table's INTEGER PRIMARY KEY (a rowid alias) refuses such a value
  #     outright, so the whole read-prepare transaction died with a datatype
  #     mismatch -- neither a 13 nor "no evidence", a way of failing the
  #     contract does not name. Hence the domain check.
  #   - The shape test is anchored \A..\z, not ^..$: in jq's regex engine $
  #     also matches before one trailing newline, so "1\n" passed as a
  #     sequence; the per-entry loop below then read "1", skipped the empty
  #     line, and the SQL got (1\n), which SQLite accepts as 1 -- a malformed
  #     entry exempting a real sequence, the one direction this must never
  #     take. With absolute anchors no accepted entry can carry a newline, so
  #     the line-framed loop sees exactly the entries jq accepted.
  # Pure bash per entry, no fork; at most 10,000 entries.
  # The jq program lives in a variable: bash 3.2 misparses the backslashes of
  # \A and \z when they sit in a quoted string inside $( ), and the check
  # then fails closed for every list (macOS CI, and the same 3.2 divergence
  # #928 met with a quote). The same reason _SQLITE_SYNC_WIRE_RE is a variable.
  local roster_seqs_jq
  roster_seqs_jq='select((.roster_seqs|type)=="null" or ((.roster_seqs|type)=="array" and
      (.roster_seqs|length)<=10000 and all(.roster_seqs[];
        (type=="string") and test("\\A(0|[1-9][0-9]{0,18})\\z")))) | "ok"'
  [ "$(printf '%s\n' "$context" | jq -r "$roster_seqs_jq" 2>/dev/null)" = ok ] || {
    echo "agmsg: sqlite-sync: roster_seqs is not a list of at most 10000 canonical sequences (#968)" >&2
    _sqlite_sync_why; return 13
  }
  local roster_seq
  while IFS= read -r roster_seq; do
    [ -n "$roster_seq" ] || continue
    _sqlite_sync_sequence "$roster_seq" || {
      echo "agmsg: sqlite-sync: roster_seqs carries '$roster_seq', which is not a canonical sequence (#968)" >&2
      _sqlite_sync_why; return 13
    }
  done <<EOF
$(printf '%s\n' "$context" | jq -r '.roster_seqs // [] | .[]')
EOF
  floor=$(printf '%s\n' "$context" | jq -r '.min_available_seq')
  current=$(printf '%s\n' "$context" | jq -r '.current_seq')
  case "$floor:$current" in *[!0-9:]*) _sqlite_sync_why; return 13 ;; esac
  [ "$(_sqlite_sync_decimal_le "$floor" "$current")" = 1 ] &&
    [ "$(_sqlite_sync_decimal_le "$current" 9223372036854775807)" = 1 ] || { _sqlite_sync_why; return 13; }
  members=$(printf '%s\n' "$context" | jq -c '.members[]')
  count=0
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    id=$(printf '%s\n' "$member" | jq -r '.member_id')
    name=$(printf '%s\n' "$member" | jq -r '.name')
    printf '%s\n' "$id" | grep -Eq \
      '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || { _sqlite_sync_why; return 13; }
    values="${values}${values:+,}('$id','$(_sqlite_lit "$name")')"
    count=$((count + 1))
  done <<EOF
$members
EOF
  local_agents=$(printf '%s\n' "$context" | jq -r '.local_agents[]')
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    local_values="${local_values}${local_values:+,}('$(_sqlite_lit "$agent")')"
  done <<EOF
$local_agents
EOF
  if [ "$count" -gt 0 ]; then
    insert_members="INSERT INTO incoming_read_members VALUES $values;"
  fi
  # Sequences the engine knows to be roster mutations (#968). They occupy
  # server sequence numbers but are, by design, not messages: the engine routes
  # them to the roster driver, so they never gain a sync_messages mapping and
  # (on the engine pull path) never enter sync_quarantine at all. Without this
  # list the contiguity check below reads every one of them as a hole and pins
  # the frontier at the first -- which is seq 1, the founding member_joined, on
  # every team ever created. Validated above as decimal strings, so they are
  # emitted as integers here without further quoting. Absent list => empty
  # table => today's behavior (a frontier that cannot advance), never a
  # frontier advanced on evidence that was not supplied.
  local insert_roster_seqs="" roster_values
  roster_values=$(printf '%s\n' "$context" |
    jq -r '[.roster_seqs // [] | .[] | "(" + . + ")"] | join(",")')
  if [ -n "$roster_values" ]; then
    insert_roster_seqs="INSERT OR IGNORE INTO roster_read_seqs VALUES $roster_values;"
  fi
  if [ -n "$local_values" ]; then
    insert_local_agents="INSERT INTO local_read_agents VALUES $local_values;"
  fi

  # Stdin, third of the same kind (#882): `$insert_members` carries one row per
  # roster member and `$insert_local_agents` one per local agent.
  _sqlite_exec_stdin "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE incoming_read_members(member_id TEXT UNIQUE,agent TEXT UNIQUE);
    CREATE TEMP TABLE local_read_agents(agent TEXT PRIMARY KEY);
    CREATE TEMP TABLE roster_read_seqs(server_seq INTEGER PRIMARY KEY);
    $insert_members
    $insert_local_agents
    $insert_roster_seqs
    UPDATE sync_read_members SET active=0 WHERE local_team='$tl'
      AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    INSERT INTO sync_read_members
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,member_id,agent,remote_agent,active,name_mismatch,
       remote_server_seq,min_available_seq)
    SELECT '$tl','$server','$remote',$protocol,'$generation',member_id,agent,agent,1,
           CASE WHEN EXISTS(SELECT 1 FROM local_read_agents l WHERE l.agent=incoming_read_members.agent)
                THEN 0 ELSE 1 END,
           '$floor','$floor' FROM incoming_read_members WHERE 1
    ON CONFLICT(local_team,server_instance_id,remote_team_id,protocol_version,
                driver_generation,member_id) DO UPDATE SET
      remote_agent=excluded.agent,active=1,
      name_mismatch=CASE WHEN sync_read_members.agent=excluded.agent
        AND EXISTS(SELECT 1 FROM local_read_agents l WHERE l.agent=excluded.agent)
        THEN 0 ELSE 1 END,
      remote_server_seq=CAST(MAX(CAST(sync_read_members.remote_server_seq AS INTEGER),$floor) AS TEXT),
      min_available_seq=CAST(MAX(CAST(sync_read_members.min_available_seq AS INTEGER),$floor) AS TEXT);
    INSERT OR IGNORE INTO sync_read_aliases
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,agent,local_id,wire_id,server_seq)
    SELECT m.local_team,m.server_instance_id,m.remote_team_id,m.protocol_version,
           m.driver_generation,e.to_agent,m.local_id,m.wire_id,m.server_seq
      FROM sync_messages m JOIN events e ON e.seq=m.local_position
     WHERE m.local_team='$tl' AND m.server_instance_id='$server'
       AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
       AND m.driver_generation='$generation' AND m.server_seq IS NOT NULL
       AND EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team=e.team AND r.agent=e.to_agent AND r.msg_id=e.id);
    UPDATE sync_read_aliases AS x SET server_seq=(
      SELECT m.server_seq FROM sync_messages m
       WHERE m.local_team=x.local_team AND m.server_instance_id=x.server_instance_id
         AND m.remote_team_id=x.remote_team_id AND m.protocol_version=x.protocol_version
         AND m.driver_generation=x.driver_generation AND m.local_id=x.local_id
         AND m.wire_id=x.wire_id)
     WHERE x.local_team='$tl' AND x.server_instance_id='$server'
       AND x.remote_team_id='$remote' AND x.protocol_version=$protocol
       AND x.driver_generation='$generation' AND x.server_seq IS NULL;
    DELETE FROM sync_read_prepared WHERE local_team='$tl'
      AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    INSERT INTO sync_read_prepared
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,member_id,server_seq)
    WITH held AS (
      -- The sequence space this client is expected to hold (#968): every
      -- message in quarantine, plus every sequence the roster driver applied
      -- as a roster mutation. A roster sequence that also has a quarantine row
      -- (the bootstrap path quarantines them) is one row here, flagged roster.
      SELECT q.local_team,q.server_instance_id,q.remote_team_id,q.protocol_version,
             q.driver_generation,CAST(q.server_seq AS INTEGER) AS seq,q.status,q.wire_id,
             EXISTS(SELECT 1 FROM roster_read_seqs r
                     WHERE r.server_seq=CAST(q.server_seq AS INTEGER)) AS roster
        FROM sync_quarantine q
       WHERE q.local_team='$tl' AND q.server_instance_id='$server'
         AND q.remote_team_id='$remote' AND q.protocol_version=$protocol
         AND q.driver_generation='$generation'
      UNION ALL
      SELECT '$tl','$server','$remote',$protocol,'$generation',r.server_seq,'imported',NULL,1
        FROM roster_read_seqs r
       WHERE NOT EXISTS(SELECT 1 FROM sync_quarantine q
                         WHERE q.local_team='$tl' AND q.server_instance_id='$server'
                           AND q.remote_team_id='$remote' AND q.protocol_version=$protocol
                           AND q.driver_generation='$generation'
                           AND CAST(q.server_seq AS INTEGER)=r.server_seq)
    ), ordered AS (
      SELECT rm.member_id,rm.agent,CAST(rm.remote_server_seq AS INTEGER) AS base,
             CAST(b.transport_cursor AS INTEGER) AS tip,
             h.seq,h.status,h.roster,m.local_position,e.to_agent,
             ROW_NUMBER() OVER(PARTITION BY rm.member_id ORDER BY h.seq) AS rn
        FROM sync_read_members rm JOIN sync_bindings b
          ON b.local_team=rm.local_team AND b.server_instance_id=rm.server_instance_id
         AND b.remote_team_id=rm.remote_team_id AND b.protocol_version=rm.protocol_version
         AND b.driver_generation=rm.driver_generation
        LEFT JOIN held h ON h.local_team=rm.local_team
         AND h.server_instance_id=rm.server_instance_id AND h.remote_team_id=rm.remote_team_id
         AND h.protocol_version=rm.protocol_version AND h.driver_generation=rm.driver_generation
         AND h.seq>CAST(rm.remote_server_seq AS INTEGER)
         AND h.seq<=MIN(CAST(b.transport_cursor AS INTEGER),$current)
        LEFT JOIN sync_messages m ON m.server_instance_id=rm.server_instance_id
         AND m.remote_team_id=rm.remote_team_id AND m.protocol_version=rm.protocol_version
         AND m.wire_id=h.wire_id
        LEFT JOIN events e ON e.seq=m.local_position
       WHERE rm.local_team='$tl' AND rm.server_instance_id='$server'
         AND rm.remote_team_id='$remote' AND rm.protocol_version=$protocol
         AND rm.driver_generation='$generation' AND rm.active=1
         AND rm.name_mismatch=0
    ), bad AS (
      -- A roster sequence is accounted for by being a roster sequence: it has
      -- no message mapping and never will. Everything else keeps the strict
      -- reading -- a message sequence with no mapping, or missing from the
      -- space entirely, is still a hole, so a lost message still pins.
      SELECT member_id,MIN(base+rn) AS seq FROM ordered
       WHERE seq IS NULL OR seq<>base+rn OR status NOT IN ('imported','reconciled')
          OR (local_position IS NULL AND roster=0)
          OR (to_agent=agent AND local_position>COALESCE((SELECT local_position
                FROM read_cursors c WHERE c.team='$tl' AND c.agent=ordered.agent),0)
              AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
                AND r.team='$tl' AND r.agent=ordered.agent
                AND r.msg_id=(SELECT id FROM events se WHERE se.seq=ordered.local_position)))
       GROUP BY member_id
    )
    SELECT '$tl','$server','$remote',$protocol,'$generation',rm.member_id,
      CAST(MAX(CAST(rm.remote_server_seq AS INTEGER),
      MIN(CAST(b.transport_cursor AS INTEGER),$current,COALESCE(bad.seq-1,$current))) AS TEXT)
      FROM sync_read_members rm JOIN sync_bindings b
        ON b.local_team=rm.local_team AND b.server_instance_id=rm.server_instance_id
       AND b.remote_team_id=rm.remote_team_id AND b.protocol_version=rm.protocol_version
       AND b.driver_generation=rm.driver_generation
      LEFT JOIN bad ON bad.member_id=rm.member_id
     WHERE rm.local_team='$tl' AND rm.server_instance_id='$server'
       AND rm.remote_team_id='$remote' AND rm.protocol_version=$protocol
       AND rm.driver_generation='$generation' AND rm.active=1
       AND rm.name_mismatch=0;
    COMMIT;" >/dev/null || { _sqlite_sync_why; return 13; }

  _sqlite_data "$team" "SELECT json_object('type','sync_read_frontier','member_id',f.member_id,
      'server_seq',f.server_seq) FROM sync_read_prepared f JOIN sync_read_members rm
      ON rm.local_team=f.local_team AND rm.server_instance_id=f.server_instance_id
     AND rm.remote_team_id=f.remote_team_id AND rm.protocol_version=f.protocol_version
     AND rm.driver_generation=f.driver_generation AND rm.member_id=f.member_id
     WHERE f.local_team='$tl' AND f.server_instance_id='$server' AND f.remote_team_id='$remote'
      AND f.protocol_version=$protocol AND f.driver_generation='$generation'
      AND rm.blocked_reason IS NULL ORDER BY f.member_id;
    SELECT json_object('type','sync_read_exact','member_id',rm.member_id,'wire_id',x.wire_id)
      FROM sync_read_aliases x JOIN sync_read_members rm
        ON rm.local_team=x.local_team AND rm.server_instance_id=x.server_instance_id
       AND rm.remote_team_id=x.remote_team_id AND rm.protocol_version=x.protocol_version
       AND rm.driver_generation=x.driver_generation AND rm.agent=x.agent AND rm.active=1
       AND rm.blocked_reason IS NULL
      JOIN sync_read_prepared f ON f.local_team=rm.local_team
       AND f.server_instance_id=rm.server_instance_id AND f.remote_team_id=rm.remote_team_id
       AND f.protocol_version=rm.protocol_version AND f.driver_generation=rm.driver_generation
       AND f.member_id=rm.member_id
     WHERE x.local_team='$tl' AND x.server_instance_id='$server'
       AND x.remote_team_id='$remote' AND x.protocol_version=$protocol
       AND x.driver_generation='$generation' AND x.server_seq IS NOT NULL
       AND CAST(x.server_seq AS INTEGER)>f.server_seq
     ORDER BY rm.member_id,x.wire_id;"
  _sqlite_data "$team" "SELECT json_object('type','sync_read_blocked','member_id',member_id,
      'reason',CASE WHEN name_mismatch=1 THEN 'member-name-mismatch' ELSE blocked_reason END)
      FROM sync_read_members WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND active=1
       AND (name_mismatch=1 OR blocked_reason IS NOT NULL) ORDER BY member_id;"
}

# Persist a server-declared exact-set limit for one member. Prepared local facts
# remain untouched and can be retried after operator remediation.
storage_sync_block_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  local generation db tl input member reason
  generation=$(_sqlite_sync_generation "$team") || { _sqlite_sync_why; return 13; }
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"; input=$(cat)
  member=$(printf '%s\n' "$input" | jq -r 'select(.type=="sync_read_block")|.member_id // empty')
  reason=$(printf '%s\n' "$input" | jq -r 'select(.type=="sync_read_block")|.reason // empty')
  printf '%s\n' "$member" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || { _sqlite_sync_why; return 13; }
  [ "$reason" = read-state-limit-exceeded ] || { _sqlite_sync_why; return 13; }
  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE sync_read_block_assert(ok INTEGER CHECK(ok=1));
    UPDATE sync_read_members SET blocked_reason='$reason'
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND member_id='$member' AND active=1;
    INSERT INTO sync_read_block_assert VALUES(changes());
    COMMIT;" >/dev/null || { _sqlite_sync_why; return 13; }
  printf '{"type":"sync_read_blocked","member_id":"%s","reason":"%s"}\n' "$member" "$reason"
}

storage_sync_unblock_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  local generation db tl input member
  generation=$(_sqlite_sync_generation "$team") || { _sqlite_sync_why; return 13; }
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"; input=$(cat)
  member=$(printf '%s\n' "$input" | jq -r 'select(.type=="sync_read_unblock")|.member_id // empty')
  printf '%s\n' "$member" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || { _sqlite_sync_why; return 13; }
  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE sync_read_unblock_assert(ok INTEGER CHECK(ok=1));
    INSERT INTO sync_read_unblock_assert SELECT COUNT(*) FROM sync_read_members
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND member_id='$member' AND active=1;
    UPDATE sync_read_members SET blocked_reason=NULL
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND member_id='$member' AND active=1
       AND blocked_reason='read-state-limit-exceeded';
    COMMIT;" >/dev/null || { _sqlite_sync_why; return 13; }
  printf '{"type":"sync_read_unblocked","member_id":"%s"}\n' "$member"
}

# Merge one authenticated server read-state page and project coverage only onto
# already imported/reconciled local messages. Transport/decrypt cursors are not
# touched by this operation.
storage_sync_apply_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || { _sqlite_sync_why; return 13; }
  _sqlite_sync_schema "$team" || return $?
  local generation db tl sql_file line type floor="" current="" member seq wire
  generation=$(_sqlite_sync_generation "$team") || { _sqlite_sync_why; return 13; }
  db="$(_sqlite_db "$team")"; tl="$(_sqlite_lit "$team")"
  sql_file=$(mktemp "${TMPDIR:-/tmp}/agmsg-read-sync-sql.XXXXXX") || { _sqlite_sync_why; return 13; }
  _AGMSG_READ_SYNC_SQL_FILE="$sql_file"
  trap 'case "${_AGMSG_READ_SYNC_SQL_FILE:-}" in "${TMPDIR:-/tmp}"/agmsg-read-sync-sql.*) rm -f "$_AGMSG_READ_SYNC_SQL_FILE" ;; esac' EXIT INT TERM HUP
  printf '%s\n' 'BEGIN IMMEDIATE; CREATE TEMP TABLE sync_read_assert(ok INTEGER CHECK(ok=1));' > "$sql_file"
  # ONE jq for the whole page, NUL-framed, instead of five processes per record
  # (3x jq + 2x grep). This mirrors what the pull path and the ack path already
  # do (#908 / #927 / #939 / #940); read-apply is the one path that work did not
  # reach. Measured before this change: 44.4 ms/record on Linux and 0.53-0.66
  # s/record on Git Bash under Windows -- 116 s and 24-25 min for a 2,600-record
  # page. Upstream report: #969.
  #
  # The record shapes are unchanged and so are the checks: the type allowlist,
  # the UUIDv7 member id, the UUIDv4 wire id, the digits-only sequences, and
  # exit 13 on anything unexpected. The UUID patterns below are byte-identical
  # to the grep -E patterns they replace; only the matcher changed, from a
  # forked grep to bash's own =~ (the substitution upstream made on the pull
  # path in #939).
  local jq_err rs_count rs_index field_name
  jq_err=$(mktemp "${TMPDIR:-/tmp}/agmsg-read-sync-jq.XXXXXX") || { rm -f "$sql_file"; _sqlite_sync_why; return 13; }
  _AGMSG_READ_SYNC_JQ_ERR="$jq_err"
  exec 4< <(jq -j -R -s '
    def fields: ["type","min_available_seq","current_seq","member_id","server_seq","wire_id"];
    def pick($r; $name):
      (if   $name == "type"              then $r.type // ""
       elif $name == "min_available_seq" then $r.min_available_seq // ""
       elif $name == "current_seq"       then $r.current_seq // ""
       elif $name == "member_id"         then $r.member_id // ""
       elif $name == "server_seq"        then $r.server_seq // ""
       else $r.wire_id // "" end) as $v
      | (if ($v|type) == "string" then $v else ($v|tostring) end);
    [ split("\n")[] | select(length > 0) ] as $lines
    | ($lines | length | tostring) + "\u0000"
    , ( $lines | to_entries[]
        | (.key + 1) as $n
        | (try (.value | fromjson) catch error("record \($n): not one JSON value on its line")) as $r
        | fields[] as $name
        | pick($r; $name) as $v
        | (if ($v | contains("\u0000"))
           then error("record \($n): field \($name) contains U+0000")
           else $v end) + "\u0000" )
  ' 2>"$jq_err")
  # ONE cleanup for every failure after the stream opened -- fd, both temp
  # files, the globals the trap reads, and the trap itself. Mirrors
  # _sqlite_sync_apply_fail on the pull path, for the same reason: this
  # function is called directly from the bats suite in a long-lived shell.
  _sqlite_read_apply_fail() {  # [message]
    if [ "$#" -gt 0 ]; then
      [ -s "$jq_err" ] && sed 's/^/agmsg: sqlite-sync: /' "$jq_err" >&2
      printf 'agmsg: sqlite-sync: %s\n' "$1" >&2
    fi
    { exec 4<&-; } 2>/dev/null || true
    rm -f "$sql_file" "$jq_err"
    _AGMSG_READ_SYNC_SQL_FILE=""; _AGMSG_READ_SYNC_JQ_ERR=""
    trap - EXIT INT TERM HUP
  }
  if ! IFS= read -r -d '' rs_count <&4 || ! [[ "$rs_count" =~ ^[0-9]+$ ]]; then
    _sqlite_read_apply_fail "the read-state page produced no readable record count"
    _sqlite_sync_why; return 13
  fi
  rs_index=0
  while [ "$rs_index" -lt "$rs_count" ]; do
    rs_index=$((rs_index + 1))
    for field_name in type rs_floor rs_current member seq wire; do
      if ! IFS= read -r -d '' "$field_name" <&4; then
        _sqlite_read_apply_fail "record $rs_index ended mid-frame at field $field_name"
        _sqlite_sync_why; return 13
      fi
    done
    case "$type" in
      sync_read_snapshot)
        [ -z "$floor" ] || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
        floor="$rs_floor"
        current="$rs_current"
        case "$floor:$current" in *[!0-9:]*) _sqlite_read_apply_fail; _sqlite_sync_why; return 13 ;; esac
        [ "$(_sqlite_sync_decimal_le "$floor" "$current")" = 1 ] &&
          [ "$(_sqlite_sync_decimal_le "$current" 9223372036854775807)" = 1 ] || {
            _sqlite_read_apply_fail; _sqlite_sync_why; return 13;
          }
        ;;
      sync_read_frontier)
        [ -n "$current" ] || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
        case "$seq" in ''|*[!0-9]*) _sqlite_read_apply_fail; _sqlite_sync_why; return 13 ;; esac
        [[ "$member" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
          || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
        [ "$(_sqlite_sync_decimal_le "$seq" "$current")" = 1 ] || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
        printf "%s\n" "INSERT INTO sync_read_assert SELECT CASE WHEN EXISTS(
          SELECT 1 FROM sync_read_members WHERE local_team='$tl'
            AND server_instance_id='$server' AND remote_team_id='$remote'
            AND protocol_version=$protocol AND driver_generation='$generation'
            AND member_id='$member' AND active=1) THEN 1 ELSE 0 END;
        UPDATE sync_read_members SET remote_server_seq=
          CAST(MAX(CAST(remote_server_seq AS INTEGER),$seq) AS TEXT)
          WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
            AND protocol_version=$protocol AND driver_generation='$generation'
            AND member_id='$member' AND active=1;" >> "$sql_file"
        ;;
      sync_read_exact)
        [ -n "$current" ] || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
        [[ "$member" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
          || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
        [[ "$wire" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] \
          || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
        printf "%s\n" "INSERT INTO sync_read_assert SELECT CASE WHEN EXISTS(
          SELECT 1 FROM sync_read_members WHERE local_team='$tl'
            AND server_instance_id='$server' AND remote_team_id='$remote'
            AND protocol_version=$protocol AND driver_generation='$generation'
            AND member_id='$member' AND active=1) THEN 1 ELSE 0 END;
        INSERT OR IGNORE INTO sync_read_remote_exact
          (local_team,server_instance_id,remote_team_id,protocol_version,
           driver_generation,member_id,wire_id)
          SELECT '$tl','$server','$remote',$protocol,'$generation','$member','$wire'
           WHERE EXISTS(SELECT 1 FROM sync_read_members rm WHERE rm.local_team='$tl'
             AND rm.server_instance_id='$server' AND rm.remote_team_id='$remote'
             AND rm.protocol_version=$protocol AND rm.driver_generation='$generation'
             AND rm.member_id='$member' AND rm.active=1);" >> "$sql_file"
        ;;
      *) _sqlite_read_apply_fail; _sqlite_sync_why; return 13 ;;
    esac
  done
  if IFS= read -r -d '' field_name <&4 || [ -n "$field_name" ]; then
    _sqlite_read_apply_fail "the read-state page carried bytes after its last record"
    _sqlite_sync_why; return 13
  fi
  { exec 4<&-; } 2>/dev/null || true
  if [ -s "$jq_err" ]; then
    _sqlite_read_apply_fail "the read-state page could not be parsed"
    _sqlite_sync_why; return 13
  fi
  rm -f "$jq_err"; _AGMSG_READ_SYNC_JQ_ERR=""
  # Through the same cleanup as every other failure site, for the reason the
  # pull path already routes its structurally identical tail check that way
  # (the final_cursor check): reached here the fd is closed and both temp files
  # are gone, but the trap and the global the trap reads are still set, and the
  # bats suite calls this function directly in a long-lived shell (review
  # finding).
  [ -n "$floor" ] && [ -n "$current" ] || { _sqlite_read_apply_fail; _sqlite_sync_why; return 13; }
  printf "%s\n" "
    UPDATE sync_read_members SET
      min_available_seq=CAST(MAX(CAST(min_available_seq AS INTEGER),$floor) AS TEXT),
      remote_server_seq=CAST(MAX(CAST(remote_server_seq AS INTEGER),$floor) AS TEXT)
     WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
       AND protocol_version=$protocol AND driver_generation='$generation' AND active=1;
    INSERT INTO events(type,id,team,agent,msg_id,at)
    SELECT 'message_read',lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||
           '-7'||substr(lower(hex(randomblob(2))),2)||'-8'||substr(lower(hex(randomblob(2))),2)||
           '-'||lower(hex(randomblob(6))),e.team,rm.agent,e.id,
           strftime('%Y-%m-%dT%H:%M:%SZ','now')
      FROM sync_read_members rm JOIN sync_messages m
        ON m.local_team=rm.local_team AND m.server_instance_id=rm.server_instance_id
       AND m.remote_team_id=rm.remote_team_id AND m.protocol_version=rm.protocol_version
       AND m.driver_generation=rm.driver_generation AND m.server_seq IS NOT NULL
      JOIN events e ON e.seq=m.local_position
      LEFT JOIN sync_quarantine q ON q.server_instance_id=m.server_instance_id
       AND q.remote_team_id=m.remote_team_id AND q.protocol_version=m.protocol_version
       AND q.wire_id=m.wire_id
     WHERE rm.local_team='$tl' AND rm.server_instance_id='$server'
       AND rm.remote_team_id='$remote' AND rm.protocol_version=$protocol
       AND rm.driver_generation='$generation' AND rm.active=1 AND e.to_agent=rm.agent
       AND (m.direction='push' OR q.status IN ('imported','reconciled'))
       AND (CAST(m.server_seq AS INTEGER)<=CAST(rm.remote_server_seq AS INTEGER)
         OR EXISTS(SELECT 1 FROM sync_read_remote_exact x
           WHERE x.local_team=rm.local_team AND x.server_instance_id=rm.server_instance_id
             AND x.remote_team_id=rm.remote_team_id AND x.protocol_version=rm.protocol_version
             AND x.driver_generation=rm.driver_generation AND x.member_id=rm.member_id
             AND x.wire_id=m.wire_id))
       AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team=e.team AND r.agent=rm.agent AND r.msg_id=e.id);
    INSERT OR IGNORE INTO read_cursors(team,agent,local_position)
      SELECT '$tl',agent,0 FROM sync_read_members WHERE local_team='$tl'
       AND server_instance_id='$server' AND remote_team_id='$remote'
       AND protocol_version=$protocol AND driver_generation='$generation' AND active=1;
    UPDATE read_cursors SET local_position=MAX(local_position,COALESCE((
      SELECT MIN(e.seq)-1 FROM events e WHERE e.type='message_sent' AND e.team='$tl'
       AND e.to_agent=read_cursors.agent AND e.seq>read_cursors.local_position
       AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team=e.team AND r.agent=read_cursors.agent AND r.msg_id=e.id)
    ),$(_sqlite_highwater))) WHERE team='$tl' AND agent IN (
      SELECT agent FROM sync_read_members WHERE local_team='$tl'
       AND server_instance_id='$server' AND remote_team_id='$remote'
       AND protocol_version=$protocol AND driver_generation='$generation' AND active=1);
    DELETE FROM sync_read_remote_exact AS x WHERE x.local_team='$tl'
      AND x.server_instance_id='$server' AND x.remote_team_id='$remote'
      AND x.protocol_version=$protocol AND x.driver_generation='$generation'
      AND EXISTS(SELECT 1 FROM sync_messages m JOIN sync_read_members rm
        ON rm.local_team=x.local_team AND rm.server_instance_id=x.server_instance_id
       AND rm.remote_team_id=x.remote_team_id AND rm.protocol_version=x.protocol_version
       AND rm.driver_generation=x.driver_generation AND rm.member_id=x.member_id
       WHERE m.server_instance_id=x.server_instance_id AND m.remote_team_id=x.remote_team_id
         AND m.protocol_version=x.protocol_version AND m.wire_id=x.wire_id
         AND m.server_seq IS NOT NULL
         AND CAST(m.server_seq AS INTEGER)<=CAST(rm.remote_server_seq AS INTEGER));
    DELETE FROM sync_read_aliases AS x WHERE x.local_team='$tl'
      AND x.server_instance_id='$server' AND x.remote_team_id='$remote'
      AND x.protocol_version=$protocol AND x.driver_generation='$generation'
      AND x.server_seq IS NOT NULL AND EXISTS(SELECT 1 FROM sync_read_members rm
        WHERE rm.local_team=x.local_team AND rm.server_instance_id=x.server_instance_id
          AND rm.remote_team_id=x.remote_team_id AND rm.protocol_version=x.protocol_version
          AND rm.driver_generation=x.driver_generation AND rm.agent=x.agent
          AND CAST(x.server_seq AS INTEGER)<=CAST(rm.remote_server_seq AS INTEGER));
    COMMIT;" >> "$sql_file"
  if ! agmsg_sqlite -bail "$db" < "$sql_file" >/dev/null 2>&1; then
    rm -f "$sql_file"; trap - EXIT INT TERM HUP; _sqlite_sync_why; return 13
  fi
  rm -f "$sql_file"; trap - EXIT INT TERM HUP; _AGMSG_READ_SYNC_SQL_FILE=""
  _sqlite_data "$team" "SELECT json_object('type','sync_read_apply_result','min_available_seq',
      MAX(min_available_seq),'member_count',COUNT(*)) FROM sync_read_members
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation' AND active=1;"
}
