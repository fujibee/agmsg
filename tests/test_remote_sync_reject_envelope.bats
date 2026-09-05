#!/usr/bin/env bats

# #1042: on a sync_pull_message the apply path `tostring`-ed envelope.blob and
# envelope.cipher with no type guard, so a JSON null, an absent key, or a number
# was stored as the plausible-looking text "null"/"12345" and reported rc=0 -- a
# malformed envelope reading as content on a byte-exact feature. The two other
# fields that lacked `// ""` were already guarded elsewhere (status by a
# whitelist, envelope.v by a numeric gate, both rc=13); blob and cipher are now
# refused the same way. These pin all three layers:
#   read     the input shapes the jq pick turns into "null"/"12345" (null / absent
#            key / number) are the cases exercised below
#   return   a refused message stores NO row (sync_messages, sync_quarantine, or
#            the projected messages table)
#   process  the call returns rc=13 -- NOT rc=0 with no row, which a caller would
#            read as success. Allowing a non-string again (the mutation) makes
#            each reject case fail on the rc assertion.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  SERVER_ID=018f3f7e-0000-7000-8000-000000000000
  TEAM_ID=018f3f7e-0000-7000-8000-000000000001
}
teardown() { teardown_test_env; }

# A one-message page with the message transformed by the jq expression in $1.
page() {
  jq -nc '{type:"sync_pull_message",server_seq:"1",
    id:"550e8400-e29b-41d4-a716-446655440001",
    server_received_at:"2026-07-20T13:00:00.000000Z",
    envelope:{v:1,cipher:"age-v1",key_id:"epoch-1",blob:"ciphertext-abc"},
    status:"importable",policy_revision:"0",local_security_revision:"0",
    projection:{body:"body-1",from_agent:"alice",to_agent:"bob",
      created_at:"2026-07-20T13:00:00.000000Z"}} | '"$1"
  printf '%s\n' '{"type":"sync_pull_cursor","next_after":"1"}'
}

# Total rows this message could have left behind, across every table it reaches.
stored_rows() {
  local db; db=$(agmsg_db_path demo)
  agmsg_sqlite "$db" "SELECT
    (SELECT count(*) FROM sync_messages)
  + (SELECT count(*) FROM sync_quarantine)
  + (SELECT count(*) FROM messages);" | tr -d '\r'
}

@test "sync apply: a clean message still imports (rc 0), so the reject is specific (#1042)" {
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$(page '.')"
  [ "$status" -eq 0 ]
  [ "$(agmsg_sqlite "$(agmsg_db_path demo)" "SELECT blob FROM sync_messages WHERE server_seq='1';" | tr -d '\r')" = ciphertext-abc ]
}

@test "sync apply: a null / absent / numeric envelope.blob is refused with rc 13 and no row (#1042)" {
  local mut
  for mut in '.envelope.blob=null' 'del(.envelope.blob)' '.envelope.blob=12345'; do
    export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store-blob-${mut//[^a-z]/}"
    storage_init demo >/dev/null
    run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$(page "$mut")"
    [ "$status" -eq 13 ]          # process: failure, not a silent rc 0
    [ "$(stored_rows)" -eq 0 ]    # return: nothing stored anywhere
  done
}

@test "sync apply: a null / absent / numeric envelope.cipher is refused with rc 13 and no row (#1042)" {
  local mut
  for mut in '.envelope.cipher=null' 'del(.envelope.cipher)' '.envelope.cipher=12345'; do
    export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store-cipher-${mut//[^a-z]/}"
    storage_init demo >/dev/null
    run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$(page "$mut")"
    [ "$status" -eq 13 ]
    [ "$(stored_rows)" -eq 0 ]
  done
}

@test "sync apply: an empty-string blob is a present string and stays in scope of the seal side, not refused here (#1042)" {
  # Documents the boundary: the #1042 guard rejects a NON-string. An empty string
  # is a string, so it is not this guard's business (the seal side owns "is this a
  # real ciphertext"); flip this if the contract later refuses empty too.
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$(page '.envelope.blob=""')"
  [ "$status" -eq 0 ]
}
