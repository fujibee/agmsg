#!/usr/bin/env bats
# Protected driver boundary plus real type-guard/transport tests use only fixtures.
load test_helper
setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init protected >/dev/null
  DB="$(agmsg_db_path protected)"
}
teardown() { teardown_test_env; }
_sql() { sqlite3 "$DB" "$1"; }
_rows() { _sqlite_bridge_claim_unread protected bob supervisor 600; }
_field() { printf '%s\n' "$1" | jq -r "$2" | head -1; }

@test "protected claims: generic operations cannot mutate protected lease or retained receipt" {
  local id rows token protection
  id=$(storage_send protected alice bob body)
  rows=$(_rows); token=$(_field "$rows" .claim_token); protection=$(_field "$rows" .protection_id)
  [ "${#protection}" = 64 ]; [ "$protection" != "$token" ]
  run storage_claim_renew protected bob supervisor "$token" 600 "$id"
  [ "$status" = 13 ]
  run storage_claim_release protected bob supervisor "$token" "$id"
  [ "$status" = 13 ]
  run storage_claim_ack protected bob supervisor "$token" "$id"
  [ "$status" = 13 ]
  _sqlite_bridge_claim_change ack "$protection" protected bob supervisor "$token" "$id" >/dev/null
  [ "$(_sql 'SELECT protection_id FROM delivery_ack_receipts;')" = "$protection" ]
  run storage_claim_ack protected bob supervisor "$token" "$id"
  [ "$status" = 13 ]
  _sqlite_bridge_claim_change ack "$protection" protected bob supervisor "$token" "$id" >/dev/null
  [ -z "$(storage_list_unread protected bob)" ]
}

@test "protected claims: complete stored group is required and generic owners drain first" {
  local a b rows token protection generic
  a=$(storage_send protected alice bob first); b=$(storage_send protected alice bob second)
  generic=$(storage_claim_unread protected bob supervisor 600 1 "$a")
  run _rows
  [ "$status" = 13 ]; [[ "$output" == *claims_active* ]] || return 1
  token=$(_field "$generic" .claim_token)
  _sqlite_delivery_generic_valid ack protected bob supervisor "$token" "$a"
  storage_claim_ack protected bob supervisor "$token" "$a" >/dev/null
  _sqlite_delivery_generic_valid ack protected bob supervisor "$token" "$a"
  rows=$(_rows); token=$(_field "$rows" .claim_token); protection=$(_field "$rows" .protection_id)
  _sqlite_bridge_claim_change release "$protection" protected bob supervisor "$token" "$b" >/dev/null
  a=$(storage_send protected alice bob third)
  rows=$(_rows); token=$(_field "$rows" .claim_token); protection=$(_field "$rows" .protection_id)
  run _sqlite_bridge_claim_change ack "$protection" protected bob supervisor "$token" "$b"
  [ "$status" = 13 ]; [[ "$output" == *invalid_protected_group* ]] || return 1
  [ "$(_sql 'SELECT count(*) FROM delivery_claims;')" = 2 ]
}

@test "protected claims: ordered byte-limited prefix commits before output and oversized head refuses" {
  local body first second rows
  body=$(printf '%033000d' 0)
  first=$(storage_send protected alice bob "$body"); second=$(storage_send protected alice bob "$body")
  rows=$(_rows)
  [ "$(_field "$rows" .id)" = "$first" ]
  [ "$(_sql 'SELECT count(*) FROM delivery_claims;')" = 1 ]
  _sql 'DELETE FROM delivery_claims; DELETE FROM events; DELETE FROM messages;'
  body=$(printf '%070000d' 0); storage_send protected alice bob "$body" >/dev/null
  run _rows
  [ "$status" = 13 ]; [[ "$output" == *message_size_limit* ]] || return 1
  [[ "$output" != *claim_token* ]] || return 1; [ "$(_sql 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}

@test "protected recovery: tokenless mixed read batch claims only original unread members" {
  local first second saved result token protection
  first=$(storage_send protected alice bob first); second=$(storage_send protected alice bob second)
  saved=$(storage_list_unread protected bob | jq -s '{id:"old",messages:.}')
  storage_mark_read_batch protected bob "$first" >/dev/null
  result=$(_sqlite_bridge_claim_recover protected bob replacement 600 "$saved")
  [ "$(jq -r '.already_read_ids[]' <<< "$result")" = "$first" ]
  [ "$(jq -r '.claim_ids[]' <<< "$result")" = "$second" ]
  token=$(_field "$result" .claim_token); protection=$(_field "$result" .protection_id)
  _sqlite_bridge_claim_change ack "$protection" protected bob replacement "$token" "$second" >/dev/null
  result=$(_sqlite_bridge_claim_recover protected bob replacement 600 "$saved")
  [ "$(jq '.claim_ids|length' <<< "$result")" = 0 ]
  [ "$(jq '.already_read_ids|length' <<< "$result")" = 2 ]
}

@test "protected recovery: live generic refuses then expiry rotates and fences stale generic token" {
  local id saved generic old result token protection
  id=$(storage_send protected alice bob message)
  saved=$(storage_list_unread protected bob | jq -s '{id:"old",messages:.}')
  generic=$(storage_claim_unread protected bob generic 600 20); old=$(_field "$generic" .claim_token)
  run _sqlite_bridge_claim_recover protected bob replacement 600 "$saved"
  [ "$status" = 13 ]; [[ "$output" == *claims_active* ]] || return 1
  _sql "UPDATE delivery_claims SET expires_at=0;"
  result=$(_sqlite_bridge_claim_recover protected bob replacement 600 "$saved")
  token=$(_field "$result" .claim_token); protection=$(_field "$result" .protection_id)
  [ "$old" != "$token" ]
  run storage_claim_ack protected bob generic "$old" "$id"
  [ "$status" = 13 ]
  _sqlite_bridge_claim_change ack "$protection" protected bob replacement "$token" "$id" >/dev/null
}

@test "protected recovery: missing wrong-recipient and changed saved messages fail without mutation" {
  local id saved bad
  id=$(storage_send protected alice bob message)
  saved=$(storage_list_unread protected bob | jq -s '{id:"old",messages:.}')
  bad=$(jq '.messages[0].id="missing"' <<< "$saved")
  run _sqlite_bridge_claim_recover protected bob replacement 600 "$bad"
  [ "$status" = 13 ]
  run _sqlite_bridge_claim_recover protected carol replacement 600 "$saved"
  [ "$status" = 13 ]
  bad=$(jq '.messages[0].body="changed"' <<< "$saved")
  run _sqlite_bridge_claim_recover protected bob replacement 600 "$bad"
  [ "$status" = 13 ]; [ "$(_sql 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}

@test "protected schema: incomplete unpublished revision 2 refuses without reclassifying state" {
  _sql 'ALTER TABLE delivery_claims DROP COLUMN protection_id;'
  run storage_init protected
  [ "$status" = 13 ]; [[ "$output" == *incomplete_delivery_schema* ]] || return 1
  [ "$(_sql "SELECT count(*) FROM pragma_table_info('delivery_claims') WHERE name='protection_id';")" = 0 ]
}

@test "protected claims: failure after SELECT rolls back and exposes no payload" {
  storage_send protected alice bob undisclosed-secret-body >/dev/null
  eval "$(declare -f _sqlite_exec_stdin | sed '1s/_sqlite_exec_stdin/_exec_original/')"
  _sqlite_exec_stdin() {
    local sql="$2"
    sql="${sql/COMMIT;/SELECT * FROM fixture_missing_table; COMMIT;}"
    _exec_original "$1" "$sql"
  }
  run _rows
  [ "$status" = 13 ]
  [[ "$output" != *undisclosed-secret-body* ]] || return 1
  [ "$(_sql 'SELECT count(*) FROM delivery_claims;')" = 0 ]
}
