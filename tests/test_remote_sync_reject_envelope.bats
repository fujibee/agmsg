#!/usr/bin/env bats

# #1042: on a sync_pull_message the apply path `tostring`-ed envelope.blob and
# envelope.cipher with no type guard, so a JSON null, an absent key, or a number
# was stored as the plausible-looking text "null"/"12345" and reported rc=0 -- a
# malformed envelope reading as content on a byte-exact feature. The two other
# fields that lacked `// ""` were already refused elsewhere (status by a
# whitelist, envelope.v by a numeric gate, both rc=13); blob and cipher are now
# refused the same way. These pin all three layers:
#   read     the input shapes the jq pick turns into "null"/"12345" -- a null, an
#            absent key (jq reads both as null), and a number -- are exercised
#   return   a refused message stores NO row (sync_messages, sync_quarantine, or
#            the projected messages table); the page is rejected atomically
#   process  the call returns rc=13, NOT rc=0-with-no-row (a caller reads rc=0 as
#            success), AND says WHAT was rejected -- the diagnostic naming the
#            record, the field, the observed JSON type, and "not a string". That
#            diagnostic is the requested property, so it is asserted, not just its
#            side effects; a diagnostic that is present but generic must fail too.
#
# Exercised through the PRODUCTION adapter (internal/storage-sync-driver.sh, the
# `apply` entry the Node engine calls), so the test also establishes that the
# adapter passes the driver's stderr and its rc=13 through unchanged, rather than
# only the driver function in isolation.

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

# Apply a page through the production adapter; $output holds stdout AND stderr.
apply() { run bash "$SCRIPTS/internal/storage-sync-driver.sh" apply demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$(page "$1")"; }

# Total rows this message could have left behind, across every table it reaches.
stored_rows() {
  local db; db=$(agmsg_db_path demo)
  agmsg_sqlite "$db" "SELECT
    (SELECT count(*) FROM sync_messages)
  + (SELECT count(*) FROM sync_quarantine)
  + (SELECT count(*) FROM messages);" | tr -d '\r'
}

@test "sync apply: a clean message still imports (rc 0), so the reject is specific (#1042)" {
  apply '.'
  [ "$status" -eq 0 ]
  [ "$(agmsg_sqlite "$(agmsg_db_path demo)" "SELECT blob FROM sync_messages WHERE server_seq='1';" | tr -d '\r')" = ciphertext-abc ]
}

@test "sync apply: a null / absent / numeric envelope.blob is refused, rc 13, no row, named diagnostic (#1042)" {
  local spec mut ty
  # jq reads a null and an absent key identically (null), so both take the "null"
  # arm; a number takes the "number" arm. Each store is fresh so no prior row can
  # mask the "nothing stored" check.
  for spec in '.envelope.blob=null|null' 'del(.envelope.blob)|null' '.envelope.blob=12345|number'; do
    mut="${spec%|*}"; ty="${spec##*|}"
    export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store-blob-$ty-${mut//[^a-z]/}"; storage_init demo >/dev/null
    apply "$mut"
    [ "$status" -eq 13 ]                                                    # process: failure, not rc 0
    [ "$(stored_rows)" -eq 0 ]                                              # return: nothing stored
    # process: the diagnostic names WHAT was rejected -- record, field, observed
    # type, and "not a string". Asserting the observed type is the positive
    # control that it reached THIS type check and not some other failure, and it
    # reddens a diagnostic that is present but generic, not only one removed.
    grep -q "record 1: envelope.blob is $ty, not a string" <<<"$output"
  done
}

@test "sync apply: a null / absent / numeric envelope.cipher is refused, rc 13, no row, named diagnostic (#1042)" {
  local spec mut ty
  for spec in '.envelope.cipher=null|null' 'del(.envelope.cipher)|null' '.envelope.cipher=12345|number'; do
    mut="${spec%|*}"; ty="${spec##*|}"
    export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store-cipher-$ty-${mut//[^a-z]/}"; storage_init demo >/dev/null
    apply "$mut"
    [ "$status" -eq 13 ]
    [ "$(stored_rows)" -eq 0 ]
    grep -q "record 1: envelope.cipher is $ty, not a string" <<<"$output"
  done
}

@test "sync apply: an empty-string blob is a present string and is not this guard's business (#1042)" {
  # The #1042 guard rejects a NON-string. An empty string is a string, so the seal
  # side owns "is this a real ciphertext", not this apply-time type check. Flip
  # this if the contract later refuses empty too.
  apply '.envelope.blob=""'
  [ "$status" -eq 0 ]
}
