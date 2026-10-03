#!/usr/bin/env bats
load test_helper
setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init protected >/dev/null
  DB=$(agmsg_db_path protected)
}
teardown() { teardown_test_env; }
seed() {
  sqlite3 "$DB" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','$1','protected','alice','bob',$2,'2026-01-01');"
}
rows() { _sqlite_bridge_claim_unread protected bob supervisor 600; }

@test "protected bytes: giant raw fields and escaped IDs refuse before creating a claim" {
  seed first "'small'"
  local kind
  for kind in raw_body raw_id escaped_id; do
    sqlite3 "$DB" "UPDATE events SET id='first',body='small';"
    case "$kind" in
      raw_body) sqlite3 "$DB" "UPDATE events SET body=hex(zeroblob(524289));" ;;
      raw_id) sqlite3 "$DB" "UPDATE events SET id=hex(zeroblob(524289));" ;;
      escaped_id) sqlite3 "$DB" "UPDATE events SET id=replace(printf('%600000s',''),' ',char(9));" ;;
    esac
    run rows
    [ "$status" -eq 13 ]
    [[ "$output" == *message_size_limit* ]] || return 1
    [[ "$output" != *claim_token* ]] || return 1
    [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
  done
}

@test "protected bytes: an oversized later record ends the complete ordered prefix" {
  seed first "'small'"
  seed giant "'small'"
  seed later "'small'"
  sqlite3 "$DB" "UPDATE events SET id=replace(printf('%600000s',''),' ',char(9)) WHERE id='giant';"
  rows > "$TEST_SKILL_DIR/out"
  [ "$(jq -sr 'map(.id)' "$TEST_SKILL_DIR/out" | jq -c .)" = '["first"]' ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 1 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='message_read';")" = 0 ]
}

@test "protected bytes: exact receive envelope includes all fences and linefeed" {
  seed first "''"
  rows > "$TEST_SKILL_DIR/out"
  local overhead fill
  overhead=$(wc -c < "$TEST_SKILL_DIR/out")
  fill=$((1048576-overhead))
  sqlite3 "$DB" "DELETE FROM delivery_claims; UPDATE events SET id=id||replace(printf('%${fill}s',''),' ','x');"
  rows > "$TEST_SKILL_DIR/out"
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -eq 1048576 ]
  sqlite3 "$DB" "DELETE FROM delivery_claims; UPDATE events SET id=id||'x';"
  run rows
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}

@test "protected bytes: saved recovery input accepts exact byte bound and refuses one extra without mutation" {
  seed first "'small'"
  local saved padding token
  saved=$(storage_list_unread protected bob | jq -cs '{id:"old",messages:.}')
  printf -v padding '%*s' "$((4194304-${#saved}))" ''
  saved="$saved$padding"
  _sqlite_bridge_claim_recover protected bob replacement 600 "$saved" > "$TEST_SKILL_DIR/out"
  token=$(jq -r .claim_token "$TEST_SKILL_DIR/out")
  [ "$(jq '.claim_ids|length' "$TEST_SKILL_DIR/out")" = 1 ]
  run _sqlite_bridge_claim_recover protected bob replacement 600 "$saved "
  [ "$status" -eq 13 ]
  [[ "$output" == *recovery_size_limit* ]] || return 1
  [ "$(sqlite3 "$DB" 'SELECT token FROM delivery_claims;')" = "$token" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_ack_receipts;')" = 0 ]
}

@test "protected bytes: recovery whole-result bound refuses before replacing original claims" {
  seed a "''"
  seed b "''"
  local saved overhead fill remainder before
  saved=$(storage_list_unread protected bob | jq -cs '{id:"old",messages:.}')
  _sqlite_bridge_claim_recover protected bob replacement 600 "$saved" > "$TEST_SKILL_DIR/out"
  overhead=$(wc -c < "$TEST_SKILL_DIR/out")
  # Each ID appears three times: original_ids, claim_ids, and messages.
  fill=$(((4194304-overhead)/3)); remainder=$(((4194304-overhead)%3))
  sqlite3 "$DB" "DELETE FROM delivery_claims;
    UPDATE events SET id=id||replace(printf('%$((fill/2))s',''),' ','x') WHERE id='a';
    UPDATE events SET id=id||replace(printf('%$((fill-fill/2))s',''),' ','x'),body=printf('%${remainder}s','') WHERE id='b';"
  saved=$(storage_list_unread protected bob | jq -cs '{id:"old",messages:.}')
  _sqlite_bridge_claim_recover protected bob replacement 600 "$saved" > "$TEST_SKILL_DIR/out"
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -eq 4194304 ]
  sqlite3 "$DB" "UPDATE delivery_claims SET expires_at=0; UPDATE events SET body=body||'x' WHERE id LIKE 'b%';"
  before=$(sqlite3 "$DB" 'SELECT token FROM delivery_claims ORDER BY msg_id;')
  saved=$(storage_list_unread protected bob | jq -cs '{id:"old",messages:.}')
  run _sqlite_bridge_claim_recover protected bob replacement 600 "$saved"
  [ "$status" -eq 13 ]
  [[ "$output" == *recovery_output_size_limit* ]] || return 1
  [ "$(sqlite3 "$DB" 'SELECT token FROM delivery_claims ORDER BY msg_id;')" = "$before" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_ack_receipts;')" = 0 ]
}
