#!/usr/bin/env bash
# Private SQLite delivery primitives, sourced by sqlite.sh. No capability or
# consumer is enabled here. The facade must add role-reservation/FD3 admission
# before exposing these operations. Owner labels are metadata, not authority.
#
# Record calls return JSONL only. Controls keep the driver ABI's ok/0 or
# runtime_error/13; stderr names invalid_arguments, maintenance_active,
# claim_unavailable, invalid_claim, or receipt_unknown. A failed acquisition
# with no payload may still have committed an undisclosed lease (response loss):
# never guess its token or replay the same owner's old payload. Let it expire.

_sqlite_delivery_error() { printf 'agmsg delivery: %s\n' "$1" >&2; return 13; }

_sqlite_delivery_uint() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 4 ] && [ "$1" -ge 1 ] && [ "$1" -le "$2" ]
}

_sqlite_delivery_token() {
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#1}" -eq 64 ]
}

# Admission must not reuse watch.sh's positive-epoch partition memo. A move
# can publish a different selector while a claimant is waiting for SQLite.
_sqlite_delivery_fresh_db() (
  _AGMSG_POLL_CYCLE_EPOCH=0
  _sqlite_db "$1"
)

_sqlite_delivery_shared_ready() {
  local shared barrier
  shared="$(_agmsg_runtime_db_path)" || return 13
  barrier="$(_sqlite_delivery_maintenance_get_db "$shared" "$1")" || return 13
  [ -z "$barrier" ] || { _sqlite_delivery_error maintenance_active; return 13; }
}

# SQL is a shell value and travels only over stdin. Buffer all stdout until
# sqlite3 has exited successfully AFTER COMMIT; -bail closes/rolls back on the
# first error. No RETURNING or early SELECT output is treated as a commit.
# No EXIT trap: library calls must preserve their long-lived caller's cleanup.
_sqlite_delivery_run_db() {
  local result
  result="$(_sqlite_exec_stdin "$1" "$2")" || return 13
  [ -z "$result" ] || printf '%s\n' "$result"
}

_sqlite_delivery_context_sql() {
  printf '%s\n' "CREATE TEMP TABLE _delivery_context AS
    SELECT CAST(strftime('%s','now') AS INTEGER) AS now,
           lower(hex(randomblob(32))) AS token, $(_sqlite_highwater) AS tip;"
}

# Named CHECK failures supply stable private refusal reasons on stderr. All
# conditions/names are internal SQL, with external values quoted separately.
_sqlite_delivery_assert_sql() {
  printf '%s\n' "CREATE TEMP TABLE _delivery_assert_$1 (
    valid INTEGER NOT NULL CONSTRAINT $1 CHECK(valid=1));
    INSERT INTO _delivery_assert_$1 VALUES(CASE WHEN ($2) THEN 1 ELSE 0 END);"
}

_sqlite_delivery_ids_sql() {
  local id
  printf '%s\n' 'CREATE TEMP TABLE _delivery_ids(id TEXT PRIMARY KEY NOT NULL);'
  for id in "$@"; do
    [ -n "$id" ] || { _sqlite_delivery_error invalid_arguments; return 13; }
    printf 'INSERT INTO _delivery_ids VALUES('
    _sqlite_quote "$id"
    printf ');\n'
  done
}

# storage_claim_unread TEAM AGENT OWNER TTL LIMIT [EXACT_ID ...]
# Normal batches: 1..1000 records (default at the future facade). Explicit
# recovery sets are not truncated: every requested ID must be available.
storage_claim_unread() {
  [ $# -ge 5 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  local team="$1" agent="$2" owner="$3" ttl="$4" limit="$5"; shift 5
  [ -n "$team" ] && [ -n "$agent" ] && [ -n "$owner" ] &&
    _sqlite_delivery_uint "$ttl" 3600 && _sqlite_delivery_uint "$limit" 1000 || {
      _sqlite_delivery_error invalid_arguments; return 13;
    }
  local tl al ol ids pick exact="" sql db current result
  _sqlite_lit_into tl "$team"; _sqlite_lit_into al "$agent"; _sqlite_lit_into ol "$owner"
  ids="$(_sqlite_delivery_ids_sql "$@")" || return 13
  pick="ORDER BY u.ts,u.src,u.ord LIMIT $limit"
  if [ $# -gt 0 ]; then
    pick='AND u.id IN (SELECT id FROM _delivery_ids) ORDER BY u.ts,u.src,u.ord'
    exact="$(_sqlite_delivery_assert_sql claim_unavailable '(SELECT COUNT(*) FROM _delivery_selected)=(SELECT COUNT(*) FROM _delivery_ids)')"
  fi
  db="$(_sqlite_delivery_fresh_db "$team")" || return 13
  _sqlite_delivery_shared_ready "$team" || return 13
  _sqlite_init_db "$db" >/dev/null || return 13
  sql="BEGIN IMMEDIATE;
    $(_sqlite_delivery_context_sql)
    $ids
    $(_sqlite_delivery_assert_sql maintenance_active "NOT EXISTS(SELECT 1 FROM delivery_maintenance WHERE team='$tl')")
    DELETE FROM delivery_claims WHERE team='$tl' AND expires_at<=(SELECT now FROM _delivery_context);
    DELETE FROM delivery_ack_receipts WHERE team='$tl' AND retain_until<=(SELECT now FROM _delivery_context);
    CREATE TEMP TABLE _delivery_selected AS
      SELECT u.* FROM ($(_sqlite_unread_sql "$team" "$agent")) u
       WHERE NOT EXISTS(SELECT 1 FROM delivery_claims c
         WHERE c.team='$tl' AND c.agent='$al' AND c.msg_id=u.id)
       $pick;
    $exact
    INSERT INTO delivery_claims(team,agent,msg_id,owner,token,expires_at)
      SELECT '$tl','$al',s.id,'$ol',c.token,c.now+$ttl
        FROM _delivery_selected s CROSS JOIN _delivery_context c;
    SELECT json_set(s.j,'\$.claim_token',c.token,'\$.claim_expires_at',c.now+$ttl)
      FROM _delivery_selected s CROSS JOIN _delivery_context c ORDER BY s.ts,s.src,s.ord;
    COMMIT;"
  result="$(_sqlite_delivery_run_db "$db" "$sql")" || return 13
  # Cooperative transforms install shared fallback barriers before any path/
  # config mutation and check live claims in the involved stores. Retain the
  # payload until BOTH postchecks succeed. An undisclosed lease may expire;
  # never re-resolve a path to try to release an old store's token.
  _sqlite_delivery_shared_ready "$team" || return 13
  current="$(_sqlite_delivery_fresh_db "$team")" || return 13
  [ "$current" = "$db" ] || { _sqlite_delivery_error selector_changed; return 13; }
  [ -z "$result" ] || printf '%s\n' "$result"
}

# Every requested member is validated before any member changes. Release and
# renewal require live leases. ACK additionally accepts the SAME retained
# receipt after an ambiguous response; a read marker alone is never a receipt.
_sqlite_claim_change() {
  local protection="$1" operation="$2"; shift 2
  [ -z "$protection" ] || _sqlite_delivery_token "$protection" || return 13
  [ $# -ge 5 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  local team="$1" agent="$2" owner="$3" token="$4" ttl=""; shift 4
  [ -n "$team" ] && [ -n "$agent" ] && [ -n "$owner" ] && _sqlite_delivery_token "$token" || {
    _sqlite_delivery_error invalid_arguments; return 13;
  }
  if [ "$operation" = renew ]; then
    ttl="$1"; shift
    _sqlite_delivery_uint "$ttl" 3600 || { _sqlite_delivery_error invalid_arguments; return 13; }
  fi
  [ $# -gt 0 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  local tl al ol ids valid mutation sql db predicate read_sql frontier_sql group=""
  _sqlite_lit_into tl "$team"; _sqlite_lit_into al "$agent"; _sqlite_lit_into ol "$owner"
  ids="$(_sqlite_delivery_ids_sql "$@")" || return 13
  predicate='protection_id IS NULL'
  if [ -n "$protection" ]; then
    predicate="protection_id='$protection'"
    group="$(_sqlite_delivery_assert_sql invalid_protected_group "NOT EXISTS(
      SELECT msg_id FROM delivery_claims WHERE team='$tl' AND agent='$al'
        AND token='$token' AND protection_id='$protection' AND msg_id NOT IN (SELECT id FROM _delivery_ids)
      UNION ALL SELECT msg_id FROM delivery_ack_receipts WHERE team='$tl' AND agent='$al'
        AND token='$token' AND protection_id='$protection' AND msg_id NOT IN (SELECT id FROM _delivery_ids))")"
  fi
  db="$(_sqlite_delivery_fresh_db "$team")" || return 13
  _sqlite_init_db "$db" >/dev/null || return 13
  valid="NOT EXISTS(SELECT 1 FROM _delivery_ids i WHERE NOT EXISTS(
    SELECT 1 FROM _delivery_active a WHERE a.id=i.id))"
  case "$operation" in
    renew)
      mutation="$(_sqlite_delivery_assert_sql maintenance_active "NOT EXISTS(SELECT 1 FROM delivery_maintenance WHERE team='$tl')")
        $(_sqlite_delivery_assert_sql invalid_claim "$valid")
        $(_sqlite_delivery_assert_sql already_read "NOT EXISTS(SELECT 1 FROM _delivery_ids i WHERE NOT EXISTS(SELECT 1 FROM ($(_sqlite_unread_sql "$team" "$agent")) u WHERE u.id=i.id))")
        UPDATE delivery_claims SET expires_at=(SELECT now FROM _delivery_context)+$ttl
         WHERE team='$tl' AND agent='$al' AND msg_id IN (SELECT id FROM _delivery_ids);" ;;
    release)
      mutation="$(_sqlite_delivery_assert_sql invalid_claim "$valid")
        DELETE FROM delivery_claims WHERE team='$tl' AND agent='$al'
          AND msg_id IN (SELECT id FROM _delivery_ids);" ;;
    ack)
      # Keep generation failures separate from later substitutions. A failed
      # read-event generator must not leave a successful receipt-only ACK.
      read_sql="$(_sqlite_read_ids_sql "$team" "$agent" "$(_sqlite_now)" _delivery_active "$@")" || return 13
      frontier_sql="$(_sqlite_read_frontier_sql "$team" "$agent" '(SELECT tip FROM _delivery_context)' 'EXISTS(SELECT 1 FROM _delivery_active)')" || return 13
      valid="NOT EXISTS(SELECT 1 FROM _delivery_ids i WHERE NOT EXISTS(
        SELECT 1 FROM _delivery_active a WHERE a.id=i.id) AND NOT EXISTS(
        SELECT 1 FROM delivery_ack_receipts r WHERE r.team='$tl' AND r.agent='$al'
          AND r.msg_id=i.id AND r.owner='$ol' AND r.token='$token'
          AND r.$predicate AND r.retain_until>(SELECT now FROM _delivery_context)))"
      mutation="$(_sqlite_delivery_assert_sql receipt_unknown "$valid")
        $read_sql
        $frontier_sql
        INSERT INTO delivery_ack_receipts(team,agent,msg_id,owner,token,acked_at,retain_until,protection_id)
          SELECT '$tl','$al',a.id,'$ol','$token',c.now,c.now+86400,a.protection_id
            FROM _delivery_active a CROSS JOIN _delivery_context c;
        DELETE FROM delivery_claims WHERE team='$tl' AND agent='$al'
          AND msg_id IN (SELECT id FROM _delivery_active);" ;;
    *) _sqlite_delivery_error invalid_arguments; return 13 ;;
  esac
  sql="BEGIN IMMEDIATE;
    $(_sqlite_delivery_context_sql)
    $ids
    $group
    CREATE TEMP TABLE _delivery_active AS SELECT c.msg_id AS id,c.protection_id FROM delivery_claims c
      WHERE c.team='$tl' AND c.agent='$al' AND c.owner='$ol' AND c.token='$token'
        AND c.$predicate AND c.expires_at>(SELECT now FROM _delivery_context)
        AND c.msg_id IN (SELECT id FROM _delivery_ids);
    $mutation
    COMMIT;"
  _sqlite_delivery_run_db "$db" "$sql"
}

storage_claim_renew() {
  _sqlite_claim_change "" renew "$@" || { echo runtime_error; return 13; }; echo ok
}
storage_claim_ack() {
  _sqlite_claim_change "" ack "$@" || { echo runtime_error; return 13; }; echo ok
}
storage_claim_release() {
  _sqlite_claim_change "" release "$@" || { echo runtime_error; return 13; }; echo ok
}

# Read-only readiness; storage_list_unread remains the actual read-state view.
# Protected durable role reservations are checked by the later admission layer.
storage_list_deliverable() {
  [ $# -ge 2 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  local team="$1" agent="$2" limit=100; shift 2
  if [ $# -gt 0 ]; then
    [ $# -eq 2 ] && [ "$1" = --limit ] || { _sqlite_delivery_error invalid_arguments; return 13; }
    limit="$2"
  fi
  _sqlite_delivery_uint "$limit" 1000 || { _sqlite_delivery_error invalid_arguments; return 13; }
  local tl al db current result
  _sqlite_lit_into tl "$team"; _sqlite_lit_into al "$agent"
  db="$(_sqlite_delivery_fresh_db "$team")" || return 13
  _sqlite_delivery_shared_ready "$team" || return 13
  [ -f "$db" ] || return 0
  _sqlite_init_db "$db" >/dev/null || return 13
  result="$(_sqlite_delivery_run_db "$db" "SELECT u.j FROM ($(_sqlite_unread_sql "$team" "$agent")) u
    WHERE NOT EXISTS(SELECT 1 FROM delivery_claims c WHERE c.team='$tl' AND c.agent='$al'
      AND c.msg_id=u.id AND c.expires_at>CAST(strftime('%s','now') AS INTEGER))
      AND NOT EXISTS(SELECT 1 FROM delivery_maintenance WHERE team='$tl')
    ORDER BY u.ts,u.src,u.ord LIMIT $limit;")" || return 13
  _sqlite_delivery_shared_ready "$team" || return 13
  current="$(_sqlite_delivery_fresh_db "$team")" || return 13
  [ "$current" = "$db" ] || { _sqlite_delivery_error selector_changed; return 13; }
  [ -z "$result" ] || printf '%s\n' "$result"
}

# Maintenance blocks the WHOLE team, including claims addressed to other agents.
# Explicit paths support destination admission before publishing a config flip.
# Paired team keys share a token and are admitted atomically in one store.
_sqlite_delivery_maintenance_begin_db() {
  [ $# -ge 3 ] && [ -n "$1" ] && [ -n "$2" ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  local db="$1" descriptor="$2" ids dl; shift 2
  ids="$(_sqlite_delivery_ids_sql "$@")" || return 13
  _sqlite_lit_into dl "$descriptor"
  _sqlite_init_db "$db" >/dev/null || return 13
  _sqlite_delivery_run_db "$db" "BEGIN IMMEDIATE;
    $(_sqlite_delivery_context_sql)
    $ids
    $(_sqlite_delivery_assert_sql maintenance_active 'NOT EXISTS(SELECT 1 FROM delivery_maintenance WHERE team IN (SELECT id FROM _delivery_ids))')
    $(_sqlite_delivery_assert_sql claims_active 'NOT EXISTS(SELECT 1 FROM delivery_claims WHERE team IN (SELECT id FROM _delivery_ids) AND expires_at>(SELECT now FROM _delivery_context))')
    INSERT INTO delivery_maintenance(team,descriptor,token,created_at)
      SELECT i.id,'$dl',c.token,c.now FROM _delivery_ids i CROSS JOIN _delivery_context c;
    SELECT json_object('type','delivery_maintenance','team',i.id,'descriptor','$dl',
      'token',c.token,'created_at',c.now) FROM _delivery_ids i CROSS JOIN _delivery_context c ORDER BY i.id;
    COMMIT;"
}

storage_delivery_maintenance_begin() {
  [ $# -eq 2 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  _sqlite_delivery_maintenance_begin_db "$(_sqlite_db "$1")" "$2" "$1"
}

_sqlite_delivery_maintenance_get_db() {
  [ $# -eq 2 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  [ -f "$1" ] || return 0
  # Classify both facts in one read snapshot. A concurrent first send can
  # atomically publish the table and revision 2 between separate queries;
  # combining an old absence with the new revision falsely reports corruption.
  local schema_state
  schema_state="$(_sqlite_delivery_run_db "$1" "SELECT CASE
    WHEN EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='delivery_maintenance') THEN 'present'
    WHEN (SELECT user_version FROM pragma_user_version)<2 THEN 'legacy'
    ELSE 'corrupt' END;")" || return 13
  case "$schema_state" in
    legacy) return 0 ;;
    present) ;;
    *) _sqlite_delivery_error corrupt_state; return 12 ;;
  esac
  _sqlite_delivery_run_db "$1" "SELECT json_object('type','delivery_maintenance','team',team,
    'descriptor',descriptor,'token',token,'created_at',created_at)
    FROM delivery_maintenance WHERE team=$(_sqlite_quote "$2");"
}

# INTERNAL only. The transform owner must verify operation-specific completion
# or rollback invariants BEFORE using this fragment. There is no public generic
# force-clear. It composes with a caller's BEGIN IMMEDIATE ... COMMIT (purge).
_sqlite_delivery_maintenance_finish_sql() {
  [ $# -ge 3 ] && [ -n "$1" ] && _sqlite_delivery_token "$2" || {
    _sqlite_delivery_error invalid_arguments; return 13;
  }
  local descriptor="$1" token="$2" ids; shift 2
  ids="$(_sqlite_delivery_ids_sql "$@")" || return 13
  printf '%s\n' "$ids
    $(_sqlite_delivery_assert_sql maintenance_mismatch "NOT EXISTS(SELECT 1 FROM _delivery_ids i WHERE NOT EXISTS(SELECT 1 FROM delivery_maintenance m WHERE m.team=i.id AND m.descriptor=$(_sqlite_quote "$descriptor") AND m.token='$token')) AND NOT EXISTS(SELECT 1 FROM delivery_maintenance m WHERE (m.descriptor=$(_sqlite_quote "$descriptor") OR m.token='$token') AND m.team NOT IN (SELECT id FROM _delivery_ids))")
    DELETE FROM delivery_maintenance WHERE team IN (SELECT id FROM _delivery_ids);"
}

_sqlite_delivery_maintenance_finish_db() {
  [ $# -ge 4 ] || { _sqlite_delivery_error invalid_arguments; echo runtime_error; return 13; }
  local db="$1" sql; shift
  sql="$(_sqlite_delivery_maintenance_finish_sql "$@")" || { echo runtime_error; return 13; }
  _sqlite_delivery_run_db "$db" "BEGIN IMMEDIATE; $sql COMMIT;" || { echo runtime_error; return 13; }
  echo ok
}

# Private bridge operations. These are intentionally outside the public claim
# facade. The type transport must authorize FD3/state before calling them.
# Generic operations above can never mutate a protected claim or receipt.
_sqlite_bridge_ready() {
  local db current barrier
  db="$(_sqlite_delivery_fresh_db "$1")" || return 13
  _sqlite_delivery_shared_ready "$1" || return 13
  barrier="$(_sqlite_delivery_maintenance_get_db "$db" "$1")" || return 13
  [ -z "$barrier" ] || { _sqlite_delivery_error maintenance_active; return 13; }
  current="$(_sqlite_delivery_fresh_db "$1")" || return 13
  [ "$db" = "$current" ] || { _sqlite_delivery_error selector_changed; return 13; }
}

_sqlite_bridge_committed() {
  local team="$1" db="$2" result current
  result="$(_sqlite_delivery_run_db "$db" "$3")" || return 13
  _sqlite_bridge_ready "$team" || return 13
  current="$(_sqlite_delivery_fresh_db "$team")" || return 13
  [ "$db" = "$current" ] || { _sqlite_delivery_error selector_changed; return 13; }
  [ -z "$result" ] || printf '%s\n' "$result"
}

_sqlite_bridge_claim_unread() {
  local team="$1" agent="$2" owner="$3" ttl="$4" db tl al ol sql unread record
  _sqlite_delivery_uint "$ttl" 3600 || return 13
  [ -n "$team" ] && [ -n "$agent" ] && [ -n "$owner" ] || return 13
  db="$(_sqlite_delivery_fresh_db "$team")" || return 13
  _sqlite_bridge_ready "$team" || return 13
  _sqlite_init_db "$db" >/dev/null || return 13
  _sqlite_lit_into tl "$team"; _sqlite_lit_into al "$agent"; _sqlite_lit_into ol "$owner"
  unread="$(_sqlite_unread_sql "$team" "$agent" 1048576)" || return 13
  record="json_set(u.j,'\$.claim_token',c.token,'\$.claim_expires_at',c.now+$ttl,'\$.protection_id',c.protection_id)"
  sql="BEGIN IMMEDIATE;
    $(_sqlite_delivery_context_sql)
    ALTER TABLE _delivery_context ADD COLUMN protection_id TEXT;
    UPDATE _delivery_context SET protection_id=lower(hex(randomblob(32)));
    $(_sqlite_delivery_assert_sql maintenance_active "NOT EXISTS(SELECT 1 FROM delivery_maintenance WHERE team='$tl')")
    $(_sqlite_delivery_assert_sql claims_active "NOT EXISTS(SELECT 1 FROM delivery_claims WHERE team='$tl' AND agent='$al' AND expires_at>(SELECT now FROM _delivery_context))")
    DELETE FROM delivery_claims WHERE team='$tl' AND agent='$al' AND expires_at<=(SELECT now FROM _delivery_context);
    CREATE TEMP TABLE _delivery_candidates AS SELECT u.*,
      COALESCE(length(CAST(json_extract(u.j,'\$.body') AS BLOB)),65537) AS bytes,
      $record AS record,COALESCE(length(CAST($record AS BLOB))+1,1048577) AS wire_bytes
      FROM ($unread) u CROSS JOIN _delivery_context c ORDER BY u.ts,u.src,u.ord LIMIT 20;
    $(_sqlite_delivery_assert_sql message_size_limit 'NOT EXISTS(SELECT 1 FROM _delivery_candidates WHERE rowid=1 AND (bytes>65536 OR wire_bytes>1048576))')
    CREATE TEMP TABLE _delivery_selected AS SELECT s.* FROM _delivery_candidates s
      WHERE (SELECT SUM(p.bytes) FROM _delivery_candidates p WHERE p.rowid<=s.rowid)<=65536
        AND (SELECT SUM(p.wire_bytes) FROM _delivery_candidates p WHERE p.rowid<=s.rowid)<=1048576;
    INSERT INTO delivery_claims(team,agent,msg_id,owner,token,expires_at,protection_id)
      SELECT '$tl','$al',s.id,'$ol',c.token,c.now+$ttl,c.protection_id
        FROM _delivery_selected s CROSS JOIN _delivery_context c;
    SELECT record FROM _delivery_selected ORDER BY ts,src,ord;
    COMMIT;"
  _sqlite_bridge_committed "$team" "$db" "$sql"
}

# Validate generic provenance without modifying state. The public mutation
# repeats this condition transactionally, so this read grants no lasting right.
_sqlite_delivery_generic_valid() {
  local operation="$1" team="$2" agent="$3" owner="$4" token="$5"; shift 5
  [ "$operation" = ack ] || [ "$operation" = release ] || return 13
  _sqlite_delivery_token "$token" && [ $# -gt 0 ] || return 13
  local db tl al ol ids receipt="" result
  db="$(_sqlite_delivery_fresh_db "$team")" || return 13
  [ -f "$db" ] || return 13
  _sqlite_lit_into tl "$team"; _sqlite_lit_into al "$agent"; _sqlite_lit_into ol "$owner"
  ids="$(_sqlite_delivery_ids_sql "$@")" || return 13
  if [ "$operation" = ack ]; then
    receipt="AND NOT EXISTS(SELECT 1 FROM delivery_ack_receipts r WHERE r.team='$tl' AND r.agent='$al'
      AND r.msg_id=i.id AND r.owner='$ol' AND r.token='$token' AND r.protection_id IS NULL
      AND r.retain_until>CAST(strftime('%s','now') AS INTEGER))"
  fi
  result="$(_sqlite_delivery_run_db "$db" "$ids
    SELECT NOT EXISTS(SELECT 1 FROM _delivery_ids i WHERE NOT EXISTS(
      SELECT 1 FROM delivery_claims c WHERE c.team='$tl' AND c.agent='$al' AND c.msg_id=i.id
        AND c.owner='$ol' AND c.token='$token' AND c.protection_id IS NULL
        AND c.expires_at>CAST(strftime('%s','now') AS INTEGER)) $receipt);")" || return 13
  [ "$result" = 1 ]
}

_sqlite_bridge_claim_change() {
  local operation="$1" protection="$2"; shift 2
  _sqlite_delivery_token "$protection" || return 13
  _sqlite_claim_change "$protection" "$operation" "$@" || { echo runtime_error; return 13; }
  echo ok
}

# Complete canonical addressed messages, including already-read rows. The
# negative projected event is represented by its original legacy identity.
_sqlite_bridge_messages_sql() {
  local tl al; _sqlite_lit_into tl "$1"; _sqlite_lit_into al "$2"
  printf '%s\n' "SELECT e.id,e.from_agent AS sender,e.body,e.at FROM events e
    WHERE e.type='message_sent' AND e.seq>0 AND e.team='$tl' AND e.to_agent='$al'
    UNION ALL SELECT CAST(m.id AS TEXT),m.from_agent,m.body,m.created_at FROM messages m
    WHERE m.team='$tl' AND m.to_agent='$al' AND NOT EXISTS(
      SELECT 1 FROM events e WHERE e.legacy_id=m.id AND e.seq>0);"
}

# JSON is one saved batch, passed as a shell value/stdin SQL (never exec argv).
# Authentication, explicit confirmation and verified-dead takeover precede this
# call. The transaction reconciles ONLY the original immutable saved messages.
_sqlite_bridge_claim_recover() {
  local team="$1" agent="$2" owner="$3" ttl="$4" batch="$5" db tl al ol bl sql unread
  local LC_ALL=C
  [ "${#batch}" -le 4194304 ] || { _sqlite_delivery_error recovery_size_limit; return 13; }
  _sqlite_delivery_uint "$ttl" 3600 || return 13
  db="$(_sqlite_delivery_fresh_db "$team")" || return 13
  _sqlite_bridge_ready "$team" || return 13
  _sqlite_init_db "$db" >/dev/null || return 13
  _sqlite_lit_into tl "$team"; _sqlite_lit_into al "$agent"; _sqlite_lit_into ol "$owner"; _sqlite_lit_into bl "$batch"
  unread="$(_sqlite_unread_sql "$team" "$agent" 1048576)" || return 13
  sql="BEGIN IMMEDIATE;
    $(_sqlite_delivery_context_sql)
    ALTER TABLE _delivery_context ADD COLUMN protection_id TEXT;
    UPDATE _delivery_context SET protection_id=lower(hex(randomblob(32)));
    CREATE TEMP TABLE _bridge_batch(document TEXT NOT NULL);
    INSERT INTO _bridge_batch VALUES('$bl');
    CREATE TEMP TABLE _bridge_saved(id TEXT PRIMARY KEY, sender TEXT,body TEXT,at TEXT,team TEXT,recipient TEXT);
    INSERT INTO _bridge_saved SELECT json_extract(value,'\$.id'),json_extract(value,'\$.from'),
      json_extract(value,'\$.body'),json_extract(value,'\$.at'),json_extract(value,'\$.team'),json_extract(value,'\$.to') FROM json_each((SELECT document FROM _bridge_batch),'\$.messages');
    $(_sqlite_delivery_assert_sql invalid_saved_batch "EXISTS(SELECT 1 FROM _bridge_saved) AND NOT EXISTS(
      SELECT 1 FROM _bridge_saved s WHERE s.id IS NULL OR s.id='' OR s.team IS NOT '$tl' OR s.recipient IS NOT '$al' OR NOT EXISTS(
        SELECT 1 FROM ($(_sqlite_bridge_messages_sql "$team" "$agent" | sed 's/;$/ /')) m
        WHERE m.id=s.id AND m.sender=s.sender AND m.body=s.body AND m.at=s.at))")
    $(_sqlite_delivery_assert_sql maintenance_active "NOT EXISTS(SELECT 1 FROM delivery_maintenance WHERE team='$tl')")
    $(_sqlite_delivery_assert_sql claims_active "NOT EXISTS(SELECT 1 FROM delivery_claims c WHERE c.team='$tl' AND c.agent='$al'
      AND c.expires_at>(SELECT now FROM _delivery_context) AND NOT (
        c.msg_id IN (SELECT id FROM _bridge_saved) AND c.owner=COALESCE(json_extract((SELECT document FROM _bridge_batch),'\$.claim_owner'),'')
        AND c.token=COALESCE(json_extract((SELECT document FROM _bridge_batch),'\$.claim_token'),'')
        AND c.protection_id=COALESCE(json_extract((SELECT document FROM _bridge_batch),'\$.protection_id'),'')))")
    CREATE TEMP TABLE _delivery_selected AS SELECT u.* FROM ($unread) u
      WHERE u.id IN (SELECT id FROM _bridge_saved) AND NOT EXISTS(
        SELECT 1 FROM delivery_ack_receipts r WHERE r.team='$tl' AND r.agent='$al' AND r.msg_id=u.id
          AND r.owner=COALESCE(json_extract((SELECT document FROM _bridge_batch),'\$.claim_owner'),'') AND r.token=COALESCE(json_extract((SELECT document FROM _bridge_batch),'\$.claim_token'),'')
          AND r.protection_id=COALESCE(json_extract((SELECT document FROM _bridge_batch),'\$.protection_id'),'') AND r.retain_until>(SELECT now FROM _delivery_context));
    $(_sqlite_delivery_assert_sql recovery_size_limit 'NOT EXISTS(SELECT 1 FROM _delivery_selected WHERE j IS NULL)')
    CREATE TEMP TABLE _bridge_response AS SELECT json_object('original_ids',json((SELECT json_group_array(id) FROM _bridge_saved)),
      'already_read_ids',json((SELECT json_group_array(id) FROM _bridge_saved WHERE id NOT IN (SELECT id FROM _delivery_selected))),
      'claim_ids',json((SELECT json_group_array(id) FROM _delivery_selected)),
      'claim_token',c.token,'claim_expires_at',c.now+$ttl,'protection_id',c.protection_id,
      'messages',json((SELECT json_group_array(json(j)) FROM _delivery_selected))) AS document FROM _delivery_context c;
    $(_sqlite_delivery_assert_sql recovery_output_size_limit 'NOT EXISTS(SELECT 1 FROM _bridge_response WHERE length(CAST(document AS BLOB))+1>4194304)')
    DELETE FROM delivery_claims WHERE team='$tl' AND agent='$al' AND msg_id IN (SELECT id FROM _bridge_saved);
    INSERT INTO delivery_claims(team,agent,msg_id,owner,token,expires_at,protection_id)
      SELECT '$tl','$al',s.id,'$ol',c.token,c.now+$ttl,c.protection_id FROM _delivery_selected s CROSS JOIN _delivery_context c;
    SELECT document FROM _bridge_response;
    COMMIT;"
  _sqlite_bridge_committed "$team" "$db" "$sql"
}

# Optional byte-bounded extension has a distinct ABI; never append a byte
# argument to storage_claim_unread, whose positional tail is exact IDs.
# shellcheck source=sqlite-delivery-bounded.sh
source "${BASH_SOURCE[0]%/*}/sqlite-delivery-bounded.sh"
