#!/usr/bin/env bash
# Optional byte-bounded records, advertised as delivery-claims-bytes-v1.
_sqlite_delivery_byte_limit() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 7 ] && [ "$1" -ge 4096 ] && [ "$1" -le 1048576 ]
}

# The bounded ABI deliberately has no exact-ID tail.
storage_claim_unread_bounded() {
  [ "$#" -eq 6 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  _sqlite_delivery_bounded claim "$@"
}
storage_list_deliverable_bounded() {
  [ "$#" -eq 4 ] || { _sqlite_delivery_error invalid_arguments; return 13; }
  _sqlite_delivery_bounded peek "$1" "$2" readiness 60 "$3" "$4"
}

_sqlite_delivery_bounded() {
  local operation="$1" team="$2" agent="$3" owner="$4" ttl="$5" limit="$6" max_bytes="$7"
  [ -n "$team" ] && [ -n "$agent" ] && [ -n "$owner" ] &&
    _sqlite_delivery_uint "$ttl" 3600 && _sqlite_delivery_uint "$limit" 32 &&
    _sqlite_delivery_byte_limit "$max_bytes" || { _sqlite_delivery_error invalid_arguments; return 13; }
  local db current result tl al ol unread final sql mutation="" output_column=j begin=BEGIN
  local status='{"type":"delivery_oversized"}' record_budget
  # Reserve exactly the terminal ASCII status and LF, even when unused. This
  # makes an individual record's eligibility independent of its neighbors.
  record_budget=$((10#$max_bytes-${#status}-1))
  _sqlite_lit_into tl "$team"; _sqlite_lit_into al "$agent"; _sqlite_lit_into ol "$owner"
  db="$(_sqlite_delivery_fresh_db "$team")" || return 13
  _sqlite_delivery_shared_ready "$team" || return 13
  if [ "$operation" = peek ] && [ ! -f "$db" ]; then return 0; fi
  _sqlite_init_db "$db" >/dev/null || return 13
  unread="$(_sqlite_unread_sql "$team" "$agent" "$max_bytes")" || return 13
  final="json_set(u.j,'\$.claim_token',c.token,'\$.claim_expires_at',c.now+$ttl)"
  if [ "$operation" = claim ]; then
    begin='BEGIN IMMEDIATE'
    output_column=record
    mutation="DELETE FROM delivery_claims WHERE team='$tl' AND expires_at<=(SELECT now FROM _delivery_context);
      DELETE FROM delivery_ack_receipts WHERE team='$tl' AND retain_until<=(SELECT now FROM _delivery_context);
      INSERT INTO delivery_claims(team,agent,msg_id,owner,token,expires_at)
        SELECT '$tl','$al',s.id,'$ol',c.token,c.now+$ttl FROM _delivery_selected s CROSS JOIN _delivery_context c;"
  fi
  sql="$begin;
    $(_sqlite_delivery_context_sql)
    $(_sqlite_delivery_assert_sql maintenance_active "NOT EXISTS(SELECT 1 FROM delivery_maintenance WHERE team='$tl')")
    CREATE TEMP VIEW _delivery_available AS SELECT u.* FROM ($unread) u
      WHERE NOT EXISTS(SELECT 1 FROM delivery_claims a WHERE a.team='$tl' AND a.agent='$al'
        AND a.msg_id=u.id AND a.expires_at>(SELECT now FROM _delivery_context));
    CREATE TEMP TABLE _delivery_status AS SELECT EXISTS(
      SELECT 1 FROM _delivery_available u CROSS JOIN _delivery_context c
      WHERE u.j IS NULL OR length(CAST($final AS BLOB))+1>$record_budget) AS oversized;
    CREATE TEMP TABLE _delivery_candidates AS
      SELECT u.*,$final AS record,length(CAST($final AS BLOB))+1 AS bytes
      FROM _delivery_available u CROSS JOIN _delivery_context c
      WHERE u.j IS NOT NULL AND length(CAST($final AS BLOB))+1<=$record_budget
      ORDER BY u.ts,u.src,u.ord LIMIT $limit;
    CREATE TEMP TABLE _delivery_selected AS SELECT s.* FROM _delivery_candidates s
      WHERE (SELECT SUM(p.bytes) FROM _delivery_candidates p WHERE p.rowid<=s.rowid)<=$record_budget;
    $mutation
    SELECT $output_column FROM _delivery_selected ORDER BY ts,src,ord;
    SELECT '$status' FROM _delivery_status WHERE oversized=1;
    COMMIT;"
  result="$(_sqlite_delivery_run_db "$db" "$sql")" || return 13
  _sqlite_delivery_shared_ready "$team" || return 13
  current="$(_sqlite_delivery_fresh_db "$team")" || return 13
  [ "$current" = "$db" ] || { _sqlite_delivery_error selector_changed; return 13; }
  [ -z "$result" ] || printf '%s\n' "$result"
}
