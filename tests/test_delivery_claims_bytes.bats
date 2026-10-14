#!/usr/bin/env bats
load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  source "$SCRIPTS/lib/storage.sh"
  source "$SCRIPTS/lib/delivery-claims.sh"
  agmsg_storage_load
  storage_init bounded >/dev/null
  DB=$(agmsg_db_path bounded)
}
teardown() { teardown_test_env; }

seed() {
  sqlite3 "$DB" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','$1','bounded','sender','bob',$2,'2026-01-01');"
}
claim() { storage_claim_unread_bounded bounded bob owner 60 32 "${1:-4096}"; }

@test "bounded claims: aggregate overflow is deferred without an oversized warning or lost fence" {
  seed first "replace(hex(zeroblob(1250)),'0','a')"
  seed second "replace(hex(zeroblob(1250)),'0','b')"
  claim > "$TEST_SKILL_DIR/out"
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -le 4096 ]
  [ "$(jq -sr 'length' "$TEST_SKILL_DIR/out")" = 1 ]
  [ "$(jq -r .id "$TEST_SKILL_DIR/out")" = first ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 1 ]
  storage_claim_ack bounded bob owner "$(jq -r .claim_token "$TEST_SKILL_DIR/out")" first >/dev/null
  claim > "$TEST_SKILL_DIR/out"
  [ "$(jq -r .id "$TEST_SKILL_DIR/out")" = second ]
}

@test "bounded claims: oversized raw head bypasses JSON construction and later records progress" {
  seed giant 'hex(zeroblob(33554433))'
  seed next "'small'"
  # The canonical bounded projection represents an impossible raw record with
  # NULL, preserving its unread identity without constructing its JSON body.
  local unread
  unread=$(_sqlite_unread_sql bounded bob 4096)
  [ "$(sqlite3 "$DB" "SELECT j IS NULL FROM ($unread) WHERE id='giant';")" = 1 ]
  claim > "$TEST_SKILL_DIR/out"
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -le 4096 ]
  [ "$(jq -sr 'map(.type)|join(",")' "$TEST_SKILL_DIR/out")" = message_sent,delivery_oversized ]
  [ "$(jq -sr '.[0].id' "$TEST_SKILL_DIR/out")" = next ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM delivery_claims WHERE msg_id='giant';")" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='message_read';")" = 0 ]
}

@test "bounded claims: whole output includes exact status and LF bytes at boundary" {
  seed exact "''"
  seed oversized 'hex(zeroblob(3000))'
  local unread overhead bytes fill token
  unread=$(_sqlite_unread_sql bounded bob)
  overhead=$(sqlite3 "$DB" "SELECT length(CAST(json_set(j,'$.claim_token',printf('%064d',0),'$.claim_expires_at',CAST(strftime('%s','now') AS INTEGER)+60) AS BLOB))+1 FROM ($unread) WHERE id='exact';")
  bytes=$(printf '%s\n' '{"type":"delivery_oversized"}' | wc -c)
  fill=$((4096-bytes-overhead))
  sqlite3 "$DB" "UPDATE events SET body=replace(printf('%${fill}s',''),' ','x') WHERE id='exact';"
  claim > "$TEST_SKILL_DIR/out"
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -eq 4096 ]
  token=$(jq -sr '.[0].claim_token' "$TEST_SKILL_DIR/out")
  storage_claim_release bounded bob owner "$token" exact >/dev/null
  sqlite3 "$DB" "UPDATE events SET body=body||'x' WHERE id='exact';"
  claim > "$TEST_SKILL_DIR/out"
  [ "$(cat "$TEST_SKILL_DIR/out")" = '{"type":"delivery_oversized"}' ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}

@test "bounded claims: UTF8 escaping and opaque IDs use serialized byte length" {
  seed tabs "replace(printf('%2400s',''),' ',char(9))"
  seed unicode "replace(printf('%1400s',''),' ','日')"
  seed opaque "'body'"
  sqlite3 "$DB" "UPDATE events SET id=hex(zeroblob(3000)) WHERE id='opaque';"
  seed small "'日'||char(9)||char(10)||'終'"
  claim > "$TEST_SKILL_DIR/out"
  [ "$(jq -sr '.[0].id' "$TEST_SKILL_DIR/out")" = small ]
  [ "$(jq -sr '.[-1].type' "$TEST_SKILL_DIR/out")" = delivery_oversized ]
  [ "$(jq -sr 'length' "$TEST_SKILL_DIR/out")" = 2 ]
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -le 4096 ]
}

@test "bounded claims: count limit leaves the next fitting row without oversized status" {
  sqlite3 "$DB" "WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<33)
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    SELECT 'message_sent',printf('%02d',v),'bounded','sender','bob',replace(printf('%100s',''),' ',char(1)),'2026-01-01' FROM n;"
  claim 1048576 > "$TEST_SKILL_DIR/out"
  [ "$(jq -sr 'length' "$TEST_SKILL_DIR/out")" = 32 ]
  [ "$(jq -sr 'map(select(.type=="delivery_oversized"))|length' "$TEST_SKILL_DIR/out")" = 0 ]
  storage_list_deliverable_bounded bounded bob 32 1048576 > "$TEST_SKILL_DIR/peek"
  [ "$(jq -r .id "$TEST_SKILL_DIR/peek")" = 33 ]
  [ "$(jq -r 'has("claim_token")' "$TEST_SKILL_DIR/peek")" = false ]
}

@test "bounded claims: readiness excludes live claims and reports only impossible unclaimed rows" {
  seed first "'small'"
  seed huge 'hex(zeroblob(3000))'
  local exact token
  exact=$(storage_claim_unread bounded bob prior 60 100 huge)
  token=$(printf '%s\n' "$exact" | jq -r .claim_token)
  storage_list_deliverable_bounded bounded bob 32 4096 > "$TEST_SKILL_DIR/out"
  [ "$(jq -sr 'length' "$TEST_SKILL_DIR/out")" = 1 ]
  [ "$(jq -r .id "$TEST_SKILL_DIR/out")" = first ]
  storage_claim_release bounded bob prior "$token" huge >/dev/null
  storage_list_deliverable_bounded bounded bob 32 4096 > "$TEST_SKILL_DIR/out"
  [ "$(jq -sr '.[-1].type' "$TEST_SKILL_DIR/out")" = delivery_oversized ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}

@test "bounded claims: driver rejects bounds and exact IDs without touching claims" {
  local bound
  seed first "'small'"
  for bound in 0 4095 1048577 invalid; do
    run claim "$bound"
    [ "$status" -eq 13 ]
  done
  run storage_claim_unread_bounded bounded bob owner 60 33 4096
  [ "$status" -eq 13 ]
  run storage_claim_unread_bounded bounded bob owner 60 32 4096 first
  [ "$status" -eq 13 ]
  run storage_list_deliverable_bounded bounded bob 33 4096
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}

@test "bounded API: capability opt-in and strict request parameters" {
  local request
  for request in \
    '{"team":"bounded","agent":"bob","owner":"r","max_bytes":4096,"ids":[]}' \
    '{"team":"bounded","agent":"bob","owner":"r","max_bytes":4096,"limit":33}' \
    '{"team":"bounded","agent":"bob","owner":"r","max_bytes":"4096"}' \
    '{"team":"bounded","agent":"bob","owner":"r","max_bytes":4095}'; do
    run agmsg_delivery_parse_request claim "$request"
    [ "$status" -eq 13 ]
  done
  agmsg_delivery_parse_request claim '{"team":"bounded","agent":"bob","owner":"r","max_bytes":4096}'
  [ "$AGMSG_CLAIM_LIMIT" = 32 ]
  [ "$AGMSG_CLAIM_MAX_BYTES" = 4096 ]
  storage_describe() { printf 'capabilities=delivery-claims-v1\n'; }
  run agmsg_delivery_claim_unread_bounded bounded bob owner 60 32 4096
  [ "$status" -eq 13 ]
  [[ "$output" == *delivery_claims_bytes_unavailable* ]] || return 1
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}

@test "bounded API: CLI opt-in emits full validated records and terminal status" {
  printf '\nstorage_describe() { printf "name=sqlite\\ncapabilities=delivery-claims-v1,delivery-claims-bytes-v1\\n"; }\n' >> "$SCRIPTS/drivers/storage/sqlite.sh"
  seed first "'small'"
  seed huge 'hex(zeroblob(3000))'
  printf '%s' '{"team":"bounded","agent":"bob","owner":"r","max_bytes":4096}' |
    bash "$SCRIPTS/delivery-claims.sh" claim > "$TEST_SKILL_DIR/out"
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -le 4096 ]
  [ "$(jq -sr '.[0].id' "$TEST_SKILL_DIR/out")" = first ]
  [ "$(jq -sr '.[-1]' "$TEST_SKILL_DIR/out" | jq -c .)" = '{"type":"delivery_oversized"}' ]
}

@test "bounded claims: oversized status covers available rows beyond the fitting count limit" {
  sqlite3 "$DB" "WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<33)
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    SELECT 'message_sent',printf('%02d',v),'bounded','sender','bob','small','2026-01-01' FROM n;"
  seed oversized 'hex(zeroblob(600000))'
  claim 1048576 > "$TEST_SKILL_DIR/out"
  [ "$(jq -sr 'length' "$TEST_SKILL_DIR/out")" = 33 ]
  [ "$(jq -sr '.[-1].type' "$TEST_SKILL_DIR/out")" = delivery_oversized ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 32 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM delivery_claims WHERE msg_id IN ('33','oversized');")" = 0 ]
}

@test "bounded API: post-publication refusal keeps its undisclosed lease and emits no records" {
  seed first "'small'"
  storage_describe() { printf 'capabilities=delivery-claims-v1,delivery-claims-bytes-v1\n'; }
  local checks=0 rc=0
  agmsg_bridge_claim_guard_check() { checks=$((checks+1)); [ "$checks" -eq 1 ]; }
  agmsg_delivery_claim_unread_bounded bounded bob owner 60 32 4096 > "$TEST_SKILL_DIR/out" || rc=$?
  [ "$rc" -eq 13 ]
  [ ! -s "$TEST_SKILL_DIR/out" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 1 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='message_read';")" = 0 ]
}
