#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  SERVER_ID=018f3f7e-0000-7000-8000-000000000000
  TEAM_ID=018f3f7e-0000-7000-8000-000000000001
  PREPARE='{"type":"sync_prepare","envelope_v":1,"cipher":"none","key_id":null,"max_blob_bytes":1048576,"allow_new":true}'
}

teardown() { teardown_test_env; }

prepare_push() {
  printf '%s\n' "$PREPARE" | storage_sync_prepare_push demo "$SERVER_ID" "$TEAM_ID" 1 "${1:-100}"
}

@test "sync contract: prepare is re-entrant and byte-stable before reconcile" {
  storage_send demo alice bob "preserve these exact bytes" >/dev/null
  local first second
  first=$(prepare_push)
  second=$(prepare_push)
  [ "$first" = "$second" ]
  [ "$(printf '%s\n' "$first" | jq -s '[.[] | select(.type=="sync_push_candidate")] | length')" -eq 1 ]
  printf '%s\n' "$first" | jq -e 'select(.type=="sync_push_candidate")
    | (.id | test("^[0-9a-f]{8}-[0-9a-f]{4}-4"))
      and (.envelope.cipher=="none") and (.envelope.key_id==null)' >/dev/null
}

@test "sync contract: a crash after sealing publishes neither wire nor envelope" {
  storage_send demo alice bob "seal once after recovery" >/dev/null
  export AGMSG_SYNC_TEST_WIRE_LOG="$BATS_TEST_TMPDIR/private-wires.log"
  export AGMSG_SYNC_REAL_CIPHER_HELPER="$SCRIPTS/internal/sync-cipher.mjs"
  export AGMSG_SYNC_CIPHER_HELPER="$BATS_TEST_DIRNAME/fixtures/sync-cipher-capture.mjs"
  export AGMSG_SYNC_TEST_ABORT_AFTER_SEAL=1
  run prepare_push
  [ "$status" -eq 75 ]
  local db
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages;" | tr -d '\r')" -eq 0 ]

  unset AGMSG_SYNC_TEST_ABORT_AFTER_SEAL
  run prepare_push
  [ "$status" -eq 0 ]
  local published first_private second_private
  published=$(printf '%s\n' "$output" | jq -r 'select(.type=="sync_push_candidate") | .id')
  first_private=$(sed -n '1p' "$AGMSG_SYNC_TEST_WIRE_LOG")
  second_private=$(sed -n '2p' "$AGMSG_SYNC_TEST_WIRE_LOG")
  [ -n "$first_private" ]
  [ -n "$second_private" ]
  [ "$first_private" != "$second_private" ]
  [ "$published" = "$second_private" ]
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages;" | tr -d '\r')" -eq 1 ]
}

@test "sync contract: reconcile advances only the acknowledged contiguous prefix" {
  storage_send demo alice bob one >/dev/null
  storage_send demo alice bob two >/dev/null
  storage_send demo alice bob three >/dev/null
  local candidates late early result
  candidates=$(prepare_push 3)
  late=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate" and (.local_position|tonumber)>1)
    | {type:"sync_push_ack",local_position,id,server_seq:.local_position,disposition:"stored"}')
  result=$(printf '%s\n' "$late" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = 0 ]
  early=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate" and .local_position=="1")
    | {type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  result=$(printf '%s\n' "$early" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = 3 ]
}

@test "sync contract: pull reconciles echoes, imports wire IDs once, and keeps read state separate" {
  storage_send demo alice bob "outgoing" >/dev/null
  local prepared candidate ack envelope echo remote page result
  prepared=$(prepare_push)
  candidate=$(printf '%s\n' "$prepared" | jq -c 'select(.type=="sync_push_candidate")')
  ack=$(printf '%s\n' "$candidate" | jq -c \
    '{type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  envelope=$(printf '%s\n' "$candidate" | jq -c '.envelope')
  echo=$(jq -nc --argjson envelope "$envelope" --arg id "$(printf '%s\n' "$candidate" | jq -r '.id')" '
    {type:"sync_pull_message",server_seq:"1",id:$id,
     server_received_at:"2026-07-20T13:00:00.000000Z",envelope:$envelope,
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"outgoing",created_at:"2026-07-20T13:00:00.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"2",
     id:"550e8400-e29b-41d4-a716-446655440000",
     server_received_at:"2026-07-20T13:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"incoming",created_at:"2026-07-20T13:00:01.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"incoming",created_at:"2026-07-20T13:00:01.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n%s\n' "$echo" "$remote" '{"type":"sync_pull_cursor","next_after":"2"}')
  result=$(printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].transport_cursor')" = 2 ]
  [ "$(storage_history demo | jq -s 'length')" -eq 2 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="outgoing")]|length')" -eq 1 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  [ "$(storage_list_unread demo bob | jq -s '[.[]|select(.body=="incoming")]|length')" -eq 1 ]
  # Re-applying a durable page cannot create a second local event.
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  [ "$(storage_history demo | jq -s 'length')" -eq 2 ]
}

@test "sync contract: a server sequence reused by another wire ID is durably corrupt" {
  local first second first_page second_page result db
  first=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",id:"550e8400-e29b-41d4-a716-446655440010",
     server_received_at:"2026-07-20T13:01:00.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"malformed",
     policy_revision:"0",local_security_revision:"0",reason:"fixture"}')
  first_page=$(printf '%s\n%s\n' "$first" '{"type":"sync_pull_cursor","next_after":"1"}')
  printf '%s\n' "$first_page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  second=$(printf '%s\n' "$first" | jq -c '.id="550e8400-e29b-41d4-a716-446655440011"')
  second_page=$(printf '%s\n%s\n' "$second" '{"type":"sync_pull_cursor","next_after":"1"}')
  result=$(printf '%s\n' "$second_page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -s '.[0].corrupt_count')" -ge 1 ]
  [ "$(printf '%s\n' "$result" | jq -s '[.[]|select(.id=="550e8400-e29b-41d4-a716-446655440011" and .status=="corrupt_state")]|length')" -eq 1 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_conflicts;" | tr -d '\r')" -eq 1 ]
}

@test "sync contract: pull conflicts with an acked mapping before its echo arrives" {
  storage_send demo alice bob "acked without echo" >/dev/null
  local prepared candidate ack remote page result db
  prepared=$(prepare_push)
  candidate=$(printf '%s\n' "$prepared" | jq -c 'select(.type=="sync_push_candidate")')
  ack=$(printf '%s\n' "$candidate" | jq -c \
    '{type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",
     id:"550e8400-e29b-41d4-a716-446655440012",
     server_received_at:"2026-07-20T13:01:30.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"conflicting remote",created_at:"2026-07-20T13:01:30.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"conflicting remote",created_at:"2026-07-20T13:01:30.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n' "$remote" '{"type":"sync_pull_cursor","next_after":"1"}')
  result=$(printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].corrupt_count')" -ge 1 ]
  [ "$(printf '%s\n' "$result" | jq -sr '[.[]|select(.id=="550e8400-e29b-41d4-a716-446655440012")][0].status')" = corrupt_state ]
  [ "$(storage_history demo | jq -s 'length')" -eq 1 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages WHERE server_seq='1';" | tr -d '\r')" -eq 1 ]
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_conflicts;" | tr -d '\r')" -eq 1 ]
}

@test "sync contract: a mapped echo keeps its blocking policy evaluation" {
  storage_send demo alice bob "mapped" >/dev/null
  local prepared candidate ack blocked page result db wire
  prepared=$(prepare_push)
  candidate=$(printf '%s\n' "$prepared" | jq -c 'select(.type=="sync_push_candidate")')
  ack=$(printf '%s\n' "$candidate" | jq -c \
    '{type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  printf '%s\n' "$ack" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  wire=$(printf '%s\n' "$candidate" | jq -r '.id')
  blocked=$(printf '%s\n' "$candidate" | jq -c '
    {type:"sync_pull_message",server_seq:"1",id,
     server_received_at:"2026-07-20T13:02:00.000000Z",envelope,
     status:"policy_violation",policy_revision:"2",local_security_revision:"1",
     reason:"E2EE required"}')
  page=$(printf '%s\n%s\n' "$blocked" '{"type":"sync_pull_cursor","next_after":"1"}')
  result=$(printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr --arg wire "$wire" '[.[]|select(.id==$wire)][0].status')" = policy_violation ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT status FROM sync_quarantine WHERE wire_id='$wire';" | tr -d '\r')" = policy_violation ]
  [ "$(storage_history demo | jq -s 'length')" -eq 1 ]
}

@test "sync contract: explicit reprocess imports quarantine without rewinding transport" {
  local blocked page pending candidate reevaluated result db
  blocked=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",
     id:"550e8400-e29b-41d4-a716-446655440020",
     server_received_at:"2026-07-20T13:03:00.000000Z",
     envelope:{v:1,cipher:"age-v1",key_id:"epoch-1",blob:"YWdlLWZpeHR1cmU="},
     status:"pending_key",policy_revision:"0",local_security_revision:"0",
     reason:"identity not installed"}')
  page=$(printf '%s\n%s\n' "$blocked" '{"type":"sync_pull_cursor","next_after":"1"}')
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  pending=$(storage_sync_reprocess demo "$SERVER_ID" "$TEAM_ID" 1 100)
  [ "$(printf '%s\n' "$pending" | jq -s '[.[]|select(.type=="sync_reprocess_candidate")]|length')" -eq 1 ]
  [ "$(printf '%s\n' "$pending" | jq -r 'select(.type=="sync_state")|.transport_cursor')" = 1 ]
  candidate=$(printf '%s\n' "$pending" | jq -c 'select(.type=="sync_reprocess_candidate")')
  reevaluated=$(printf '%s\n' "$candidate" | jq -c '
    .type="sync_pull_message" | .status="importable" | .policy_revision="0"
    | .local_security_revision="0" | del(.prior_status)
    | .projection={body:"opened later",created_at:"2026-07-20T13:03:00.000000Z",
                   from_agent:"alice",to_agent:"bob"}')
  result=$(printf '%s\n%s\n' "$reevaluated" \
    '{"type":"sync_pull_cursor","next_after":"1"}' \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].transport_cursor')" = 1 ]
  [ "$(printf '%s\n' "$result" | jq -sr '[.[]|select(.status=="imported")]|length')" -eq 1 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="opened later")]|length')" -eq 1 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT status FROM sync_quarantine WHERE wire_id='550e8400-e29b-41d4-a716-446655440020';" | tr -d '\r')" = imported ]
}

@test "sync contract: reprocess acknowledges a roster projection without making a message" {
  local wire blocked page reevaluated result db
  wire=550e8400-e29b-41d4-a716-446655440021
  blocked=$(jq -nc --arg id "$wire" '
    {type:"sync_pull_message",server_seq:"1",id:$id,
     server_received_at:"2026-07-30T20:33:33.000000Z",
     envelope:{v:1,cipher:"age-v1",key_id:"epoch-1",blob:"YWdl"},
     status:"unsupported_cipher",reason:"age-v1 is not configured",
     policy_revision:"0",local_security_revision:"0"}')
  page=$(printf '%s\n%s\n' "$blocked" '{"type":"sync_pull_cursor","next_after":"1"}')
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  reevaluated=$(printf '%s\n' "$blocked" | jq -c '
    .status="importable" | .reason="" |
    .projection={kind:"member_joined",
      mutation_id:"019fb4bb-7948-7520-8c16-ab64753e2012",
      member_id:"019fb4bb-7948-7ce9-8e4f-61229dc726cf",
      name:"dana",occurred_at:"2026-07-30T20:33:33.000000Z"}')
  result=$(printf '%s\n%s\n' "$reevaluated" \
    '{"type":"sync_pull_cursor","next_after":"1"}' |
    storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r --arg id "$wire" \
    'select(.type=="sync_apply_outcome" and .id==$id)|.status')" = imported ]
  [ "$(storage_history demo | jq -s 'length')" -eq 0 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT status FROM sync_quarantine WHERE wire_id='$wire';" | tr -d '\r')" = imported ]
  [ "$(storage_sync_reprocess demo "$SERVER_ID" "$TEAM_ID" 1 100 |
    jq -s '[.[]|select(.type=="sync_reprocess_candidate")]|length')" -eq 0 ]
}

@test "sync contract: reprocess candidate body and trailer share one keyset page" {
  local records="" page first token second index wire
  for index in 1 2 3; do
    wire=$(printf '550e8400-e29b-41d4-a716-%012d' "$((40 + index))")
    records="${records}$(jq -nc --arg seq "$index" --arg id "$wire" '
      {type:"sync_pull_message",server_seq:$seq,id:$id,
       server_received_at:"2026-07-20T13:04:00.000000Z",
       envelope:{v:1,cipher:"age-v1",key_id:"epoch-1",blob:"YWdl"},
       status:"authentication_failed",reason:"blocked",
       policy_revision:"0",local_security_revision:"0"}')"$'\n'
  done
  page="${records}{\"type\":\"sync_pull_cursor\",\"next_after\":\"3\"}"
  printf '%s\n' "$page" |
    storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  first=$(storage_sync_reprocess demo "$SERVER_ID" "$TEAM_ID" 1 2)
  [ "$(printf '%s\n' "$first" | jq -s '[.[]|select(.type=="sync_reprocess_candidate")]|length')" -eq 2 ]
  token=$(printf '%s\n' "$first" | jq -r 'select(.type=="sync_reprocess_page")|.next_after')
  [ "$token" = "2:550e8400-e29b-41d4-a716-000000000042" ]
  [ "$(printf '%s\n' "$first" | jq -r 'select(.type=="sync_reprocess_page")|.has_more')" = true ]
  second=$(storage_sync_reprocess demo "$SERVER_ID" "$TEAM_ID" 1 2 "$token")
  [ "$(printf '%s\n' "$second" | jq -sr '[.[]|select(.type=="sync_reprocess_candidate")][0].server_seq')" = 3 ]
  [ "$(printf '%s\n' "$second" | jq -r 'select(.type=="sync_reprocess_page")|.has_more')" = false ]
}

@test "sync contract: retention resync records one immutable gap and preserves local state" {
  storage_send demo alice bob "local survives retention" >/dev/null
  local prepared status input result repeated db wire
  prepared=$(prepare_push)
  wire=$(printf '%s\n' "$prepared" | jq -r 'select(.type=="sync_push_candidate")|.id')
  status=$(storage_sync_resync_status demo "$SERVER_ID" "$TEAM_ID" 1 5)
  printf '%s\n' "$status" | jq -e '
    keys==["audit","driver_generation","transport_cursor","type"]
    and .type=="sync_resync_status" and .transport_cursor=="0" and .audit==null' >/dev/null

  input='{"type":"sync_resync","expected_transport_cursor":"0","min_available_seq":"5","current_seq":"7","reason":"retention-gap-accepted"}'
  result=$(storage_sync_resync demo "$SERVER_ID" "$TEAM_ID" 1 <<< "$input")
  printf '%s\n' "$result" | jq -e '
    keys==["accepted_floor","driver_generation","expected_transport_cursor","gap_end","gap_start","reason","transport_cursor","type"]
    and .type=="sync_resync_result" and .expected_transport_cursor=="0"
    and .transport_cursor=="5" and .accepted_floor=="5"
    and .gap_start=="1" and .gap_end=="5"
    and .reason=="retention-gap-accepted"' >/dev/null

  status=$(storage_sync_resync_status demo "$SERVER_ID" "$TEAM_ID" 1 5)
  printf '%s\n' "$status" | jq -e '
    .transport_cursor=="5" and .audit=={
      expected_transport_cursor:"0",accepted_floor:"5",gap_start:"1",gap_end:"5",
      reason:"retention-gap-accepted"}' >/dev/null
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_resync_audits;" | tr -d '\r')" -eq 1 ]
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM events WHERE body='local survives retention';" | tr -d '\r')" -eq 1 ]
  [ "$(agmsg_sqlite "$db" "SELECT wire_id FROM sync_messages WHERE direction='push';" | tr -d '\r')" = "$wire" ]

  run storage_sync_resync demo "$SERVER_ID" "$TEAM_ID" 1 <<< "$input"
  [ "$status" -ne 0 ]
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_resync_audits;" | tr -d '\r')" -eq 1 ]
}

@test "sync contract: resync status is read-only and absent bindings fail closed" {
  local before after other
  prepare_push >/dev/null
  before=$(agmsg_sqlite "$(agmsg_db_path demo)" "SELECT total_changes();" | tr -d '\r')
  storage_sync_resync_status demo "$SERVER_ID" "$TEAM_ID" 1 10 >/dev/null
  after=$(agmsg_sqlite "$(agmsg_db_path demo)" "SELECT total_changes();" | tr -d '\r')
  [ "$before" = "$after" ]
  other=018f3f7e-0000-7000-8000-000000000002
  run storage_sync_resync_status demo "$SERVER_ID" "$other" 1 10
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "sync contract: resync input rejects duplicate keys and later records" {
  prepare_push >/dev/null
  local duplicate multiple db
  duplicate='{"type":"sync_resync","expected_transport_cursor":"0","min_available_seq":"4","min_available_seq":"5","current_seq":"7","reason":"retention-gap-accepted"}'
  run storage_sync_resync demo "$SERVER_ID" "$TEAM_ID" 1 <<< "$duplicate"
  [ "$status" -ne 0 ]
  multiple=$'{"type":"sync_resync","expected_transport_cursor":"0","min_available_seq":"5","current_seq":"7","reason":"retention-gap-accepted"}\n\n{"type":"sync_resync","expected_transport_cursor":"0","min_available_seq":"6","current_seq":"7","reason":"retention-gap-accepted"}'
  run storage_sync_resync demo "$SERVER_ID" "$TEAM_ID" 1 <<< "$multiple"
  [ "$status" -ne 0 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_resync_audits;" | tr -d '\r')" -eq 0 ]
  [ "$(agmsg_sqlite "$db" "SELECT transport_cursor FROM sync_bindings;" | tr -d '\r')" = 0 ]
}

@test "sync contract: resync uses the resolved Node runtime when literal node is unavailable" {
  prepare_push >/dev/null
  local resolved_node input result
  resolved_node=$(command -v node)
  [ -x "$resolved_node" ]
  input='{"type":"sync_resync","expected_transport_cursor":"0","min_available_seq":"5","current_seq":"7","reason":"retention-gap-accepted"}'
  node() { return 127; }
  export AGMSG_SYNC_NODE_BIN="$resolved_node"
  unset AGMSG_NODE
  result=$(storage_sync_resync demo "$SERVER_ID" "$TEAM_ID" 1 <<< "$input")
  unset -f node
  [ "$(printf '%s\n' "$result" | jq -r '.transport_cursor')" = 5 ]
}

@test "Stage-2 sync exports exact reads across holes and applies remote frontier separately" {
  local first second page ids second_local context prepared applied db
  first=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",id:"550e8400-e29b-41d4-a716-446655440031",
     server_received_at:"2026-07-21T06:00:00.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"importable",
     policy_revision:"0",local_security_revision:"0",
     projection:{body:"leave unread",created_at:"2026-07-21T06:00:00.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  second=$(jq -nc '
    {type:"sync_pull_message",server_seq:"2",id:"550e8400-e29b-41d4-a716-446655440032",
     server_received_at:"2026-07-21T06:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"importable",
     policy_revision:"0",local_security_revision:"0",
     projection:{body:"read out of order",created_at:"2026-07-21T06:00:01.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n%s\n' "$first" "$second" \
    '{"type":"sync_pull_cursor","next_after":"2"}')
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  ids=$(storage_history demo | jq -r 'select(.to=="bob")|.id')
  second_local=$(printf '%s\n' "$ids" | sed -n '2p')
  storage_read_cursor_consume demo bob "$(storage_watch_tip demo:bob)" "$second_local" >/dev/null
  context=$(jq -nc --arg member "018f3f7e-0000-7000-8000-000000000010" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:"2",local_agents:["bob"],
     members:[{member_id:$member,name:"bob"}]}')
  prepared=$(printf '%s\n' "$context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$prepared" | jq -r 'select(.type=="sync_read_frontier")|.server_seq')" = 0 ]
  [ "$(printf '%s\n' "$prepared" | jq -r 'select(.type=="sync_read_exact")|.wire_id')" = \
    550e8400-e29b-41d4-a716-446655440032 ]

  applied=$(printf '%s\n%s\n' \
    '{"type":"sync_read_snapshot","min_available_seq":"0","current_seq":"2"}' \
    '{"type":"sync_read_frontier","member_id":"018f3f7e-0000-7000-8000-000000000010","server_seq":"2"}' |
    storage_sync_apply_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$applied" | jq -r '.member_count')" = 1 ]
  [ "$(storage_list_unread demo bob | jq -s 'length')" -eq 0 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT transport_cursor FROM sync_bindings;" | tr -d '\r')" = 2 ]
}

@test "Stage-2 rename mismatch blocks remote frontier in either ordering" {
  local old_context new_context local_first_context prepared db member
  member=018f3f7e-0000-7000-8000-000000000010
  storage_send demo alice bob "local bob authority" >/dev/null
  old_context=$(jq -nc --arg member "$member" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:"0",local_agents:["bob"],
     members:[{member_id:$member,name:"bob"}]}')
  new_context=$(jq -nc --arg member "$member" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:"0",local_agents:["bob"],
     members:[{member_id:$member,name:"robert"}]}')
  local_first_context=$(jq -nc --arg member "$member" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:"0",local_agents:["robert"],
     members:[{member_id:$member,name:"bob"}]}')

  printf '%s\n' "$old_context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  prepared=$(printf '%s\n' "$new_context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$prepared" | jq -r 'select(.type=="sync_read_blocked")|.reason')" = \
    member-name-mismatch ]
  [ "$(printf '%s\n' "$prepared" | jq -s '[.[]|select(.type=="sync_read_frontier")]|length')" -eq 0 ]

  db=$(agmsg_db_path demo)
  agmsg_sqlite "$db" "UPDATE events SET to_agent='robert' WHERE team='demo' AND to_agent='bob';" >/dev/null
  agmsg_sqlite "$db" "UPDATE sync_read_members SET agent='robert',
    name_mismatch=CASE WHEN remote_agent='robert' THEN 0 ELSE 1 END
    WHERE local_team='demo' AND member_id='$member';" >/dev/null
  prepared=$(printf '%s\n' "$local_first_context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$prepared" | jq -r 'select(.type=="sync_read_blocked")|.reason')" = \
    member-name-mismatch ]
  [ "$(printf '%s\n' "$prepared" | jq -s '[.[]|select(.type=="sync_read_frontier")]|length')" -eq 0 ]
}

@test "Stage-2 initial remote name without local authority is blocked" {
  local context prepared member
  member=018f3f7e-0000-7000-8000-000000000010
  storage_send demo bob alice "local alice only" >/dev/null
  storage_send demo alice bob "remote projection cannot self-authorize bob" >/dev/null
  context=$(jq -nc --arg member "$member" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:"0",local_agents:["alice"],
     members:[{member_id:$member,name:"bob"}]}')
  prepared=$(printf '%s\n' "$context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$prepared" | jq -r 'select(.type=="sync_read_blocked")|.reason')" = \
    member-name-mismatch ]
  [ "$(printf '%s\n' "$prepared" | jq -s '[.[]|select(.type=="sync_read_frontier" or .type=="sync_read_exact")]|length')" -eq 0 ]
}

@test "Stage-2 exact limit block persists until explicit operator unblock" {
  local context member db result prepared
  member=018f3f7e-0000-7000-8000-000000000010
  storage_send demo alice bob "local bob authority" >/dev/null
  context=$(jq -nc --arg member "$member" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:"0",local_agents:["bob"],
     members:[{member_id:$member,name:"bob"}]}')
  printf '%s\n' "$context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  result=$(jq -nc --arg member "$member" '
    {type:"sync_read_block",member_id:$member,reason:"read-state-limit-exceeded"}' |
    storage_sync_block_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.reason')" = read-state-limit-exceeded ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT blocked_reason FROM sync_read_members WHERE member_id='$member';" | tr -d '\r')" = \
    read-state-limit-exceeded ]
  prepared=$(printf '%s\n' "$context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$prepared" | jq -r 'select(.type=="sync_read_blocked")|.reason')" = \
    read-state-limit-exceeded ]
  result=$(jq -nc --arg member "$member" '{type:"sync_read_unblock",member_id:$member}' |
    storage_sync_unblock_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.type')" = sync_read_unblocked ]
  prepared=$(printf '%s\n' "$context" |
    storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$prepared" | jq -s '[.[]|select(.type=="sync_read_frontier")]|length')" -eq 1 ]
}

# A store that predates the event log keeps its history in the legacy `messages`
# table; nothing writes that table any more, and the phase-3 adoption marked
# every row delivered. Connecting such a team has to upload that history — the
# failure mode is silent (zero candidates, no error), so it is pinned here.
_seed_legacy_history() {
  local db; db=$(agmsg_db_path demo)
  agmsg_sqlite "$db" "
    DELETE FROM storage_metadata WHERE key='read_cursor_v1';
    INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES
      ('demo','alice','bob','legacy one','2026-01-01T00:00:00Z'),
      ('demo','bob','alice','legacy two','2026-01-02T00:00:00Z'),
      ('demo','alice','bob','legacy three','2026-01-03T00:00:00Z');
  " >/dev/null
  # The new build initialising an old store: this is what marks them delivered.
  storage_init demo >/dev/null
}

@test "sync contract: a legacy-only team pushes its whole history, in order" {
  _seed_legacy_history
  local out positions
  out=$(prepare_push)
  [ "$(printf '%s\n' "$out" | jq -s '[.[] | select(.type=="sync_push_candidate")] | length')" -eq 3 ]
  positions=$(printf '%s\n' "$out" | jq -rs '[.[] | select(.type=="sync_push_candidate") | .local_id] | join(",")')
  [ "$positions" = "1,2,3" ]
}

@test "sync contract: pushing a legacy-only team twice is byte-identical" {
  _seed_legacy_history
  local first second
  first=$(prepare_push)
  second=$(prepare_push)
  # Non-vacuity first: two empty pages are byte-identical too, and that would
  # pass this test while proving nothing about wire id stability.
  [ "$(printf '%s\n' "$first" | jq -s '[.[] | select(.type=="sync_push_candidate")] | length')" -eq 3 ]
  [ "$first" = "$second" ]
}

@test "sync contract: projecting legacy history does not resurface it as unread" {
  _seed_legacy_history
  local before after
  before=$(storage_list_unread demo bob | wc -l)
  # Non-vacuity: the projection must actually have happened, or "the inbox did
  # not change" is trivially true and this guards nothing.
  [ "$(prepare_push | jq -s '[.[] | select(.type=="sync_push_candidate")] | length')" -eq 3 ]
  after=$(storage_list_unread demo bob | wc -l)
  [ "$before" = "$after" ]
  [ "$after" -eq 0 ]
}

@test "sync contract: a legacy history acknowledged once is never offered again" {
  _seed_legacy_history
  local candidates acks result second
  candidates=$(prepare_push)
  # The server stores each blob under its wire id and answers with a sequence.
  acks=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate")
    | {type:"sync_push_ack",local_position,id,
       server_seq:((.local_position|tonumber)+1000000000|tostring),
       disposition:"stored"}')
  result=$(printf '%s\n' "$acks" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = "-999999997" ]

  # Connecting again offers nothing: this is what "doing it twice leaves the
  # server unchanged" means locally, and it holds because the reservation keyed
  # on the projected position carries the same wire id both times.
  second=$(prepare_push)
  [ "$(printf '%s\n' "$second" | jq -s '[.[] | select(.type=="sync_push_candidate")] | length')" -eq 0 ]
}

# Feeds one hand-built ack through reconcile in THIS shell. Going through
# `bash -c` would start a shell where the driver functions are undefined, and
# the 127 that produces looks exactly like the rejection being asserted.
_reconcile_one_ack() {
  local pos="$1" seq="$2"
  printf '{"type":"sync_push_ack","local_position":"%s","id":"%s","server_seq":"%s","disposition":"stored"}\n' \
    "$pos" "00000000-0000-4000-8000-000000000000" "$seq" \
    | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1
}

@test "sync contract: an ack position stays a whitelist after allowing negatives" {
  # local_position is interpolated straight into SQL, so widening it to accept
  # projected (negative) positions must not widen it to anything else.
  _seed_legacy_history
  prepare_push >/dev/null
  local bad
  for bad in "-" "" "1;DROP TABLE events" "-1 OR 1=1" "--1" "1-1" "0x10" " 1" "+1" "1.0"; do
    run _reconcile_one_ack "$bad" 1
    # 13 specifically: a "command not found" 127 would also be non-zero and
    # would pass a laxer check while testing nothing.
    [ "$status" -eq 13 ]
  done
  # A server sequence is assigned by the server and is never negative, so it
  # did not get the same widening.
  run _reconcile_one_ack -999999999 -1
  [ "$status" -eq 13 ]
  # The events table is still there: nothing above reached a statement.
  [ "$(agmsg_sqlite "$(agmsg_db_path demo)" "SELECT COUNT(*) FROM events;" | tr -d '\r')" -gt 0 ]
}

# The legacy `messages` table is a read interface other software still opens
# (#689). A message that arrives from another machine lands here and nowhere
# else, so mirroring only local sends would leave those readers seeing one side
# of a conversation -- and the side they could not see is the reason this was
# worth doing at all.
@test "sync contract: a pulled message is mirrored into the legacy table, once" {
  local remote page db
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",
     id:"550e8400-e29b-41d4-a716-4466554400a1",
     server_received_at:"2026-07-20T13:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"arrived from elsewhere",created_at:"2026-07-20T13:00:01.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"arrived from elsewhere",created_at:"2026-07-20T13:00:01.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n' "$remote" '{"type":"sync_pull_cursor","next_after":"1"}')
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null

  db=$(agmsg_db_path demo)
  # Visible to a reader of the legacy table — queried the way such a reader
  # would, with no agmsg code in between.
  [ "$(sqlite3 "$db" "SELECT count(*) FROM messages WHERE body='arrived from elsewhere';" | tr -d '\r')" -eq 1 ]
  # And linked, so the readers that union the two tables see one message.
  [ "$(sqlite3 "$db" "SELECT count(*) FROM events e JOIN messages m ON m.id=e.legacy_id WHERE e.type='message_sent' AND e.body='arrived from elsewhere';" | tr -d '\r')" -eq 1 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="arrived from elsewhere")]|length')" -eq 1 ]
  [ "$(storage_list_unread demo bob | jq -s '[.[]|select(.body=="arrived from elsewhere")]|length')" -eq 1 ]

  # Re-applying the same durable page must not add a second legacy row either.
  # The event is guarded against duplication; the mirror has to inherit that
  # guard rather than carry its own copy of it.
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  [ "$(sqlite3 "$db" "SELECT count(*) FROM messages WHERE body='arrived from elsewhere';" | tr -d '\r')" -eq 1 ]
}

# A partial commit is the failure this batch has to be incapable of. It now
# spans the event, its legacy mirror, the sync mapping and the transport cursor,
# and the CLI's default is to report a statement error and keep going — so
# without -bail a failing mirror still reaches COMMIT and leaves an event with
# no copy, plus a cursor that says the page was applied. A non-zero exit
# afterwards does not undo any of that.
#
# Success and replay tests cannot see this; only a forced failure inside the
# batch can.
@test "sync contract: a failure inside the apply commits nothing (#689)" {
  local first second db before_cursor
  db=$(agmsg_db_path demo)

  # Apply one page for real first, so the sync mapping and the transport cursor
  # hold a value that a partial commit could move. Asserting against a store
  # where they do not exist yet cannot tell "did not advance" from "was never
  # there".
  first=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",
     id:"550e8400-e29b-41d4-a716-4466554400c1",
     server_received_at:"2026-07-20T13:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"first arrival",created_at:"2026-07-20T13:00:01.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"first arrival",created_at:"2026-07-20T13:00:01.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  printf '%s\n%s\n' "$first" '{"type":"sync_pull_cursor","next_after":"1"}' \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  before_cursor=$(sqlite3 "$db" "SELECT transport_cursor FROM sync_bindings WHERE local_team='demo';" | tr -d '\r')
  [ -n "$before_cursor" ]

  # Now make the mirror — and only the mirror — fail. Removing the table does
  # not work: storage_init recreates it before the batch runs, so the mirror
  # succeeds and the test proves nothing. A trigger survives that and aborts
  # exactly the statement under test.
  sqlite3 "$db" "CREATE TRIGGER block_mirror BEFORE INSERT ON messages
                 BEGIN SELECT RAISE(ABORT,'mirror blocked for this test'); END;"

  second=$(jq -nc '
    {type:"sync_pull_message",server_seq:"2",
     id:"550e8400-e29b-41d4-a716-4466554400c2",
     server_received_at:"2026-07-20T13:00:02.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"must not survive",created_at:"2026-07-20T13:00:02.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"must not survive",created_at:"2026-07-20T13:00:02.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  local rc=0
  printf '%s\n%s\n' "$second" '{"type":"sync_pull_cursor","next_after":"2"}' \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]

  # All three, not just the event. Asserting the event alone would also pass for
  # an implementation that deleted the event afterwards and left the mapping and
  # the cursor advanced -- which is the state that silently loses a message.
  [ "$(sqlite3 "$db" "SELECT count(*) FROM events WHERE body='must not survive';" | tr -d '\r')" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT count(*) FROM sync_messages WHERE wire_id='550e8400-e29b-41d4-a716-4466554400c2';" | tr -d '\r')" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT transport_cursor FROM sync_bindings WHERE local_team='demo';" | tr -d '\r')" = "$before_cursor" ]
}

# The other direction of the same correspondence. A row that was in the legacy
# table before any of this gets projected into the event log when a team is
# prepared for push; if that projection does not record which legacy row it is,
# the readers see the message from both branches and list it twice — the
# duplicate this change exists to remove, arriving from the other side.
@test "sync contract: a projected legacy row is not listed twice (#689)" {
  local db
  db=$(agmsg_db_path demo)
  sqlite3 "$db" "INSERT INTO messages (team,from_agent,to_agent,body,created_at)
                 VALUES ('demo','carol','bob','older than the event log','2026-07-01T00:00:00Z');"
  local legacy_id
  legacy_id=$(sqlite3 "$db" "SELECT id FROM messages WHERE body='older than the event log';" | tr -d '\r')

  prepare_push >/dev/null

  # Projected, and carrying the link back to the row it came from.
  [ "$(sqlite3 "$db" "SELECT COALESCE(legacy_id,-1) FROM events WHERE type='message_sent' AND body='older than the event log';" | tr -d '\r')" = "$legacy_id" ]

  # And therefore counted once by each reader.
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="older than the event log")]|length')" -eq 1 ]
  [ "$(storage_list_unread demo bob | jq -s '[.[]|select(.body=="older than the event log")]|length')" -eq 1 ]
}

# The single read is only possible because the shell `eval`s what jq emits, so
# the safety of that eval is this change's load-bearing claim. `@sh` is jq's
# shell-quoting filter and exists for exactly this — but a claim about a
# quoting filter is worth what its adversarial case is worth, and there was no
# adversarial case here before.
#
# The body carries every character class a shell acts on: command substitution
# in both spellings, a quote, a semicolon with a destructive command behind it,
# a backslash. Plus the tab and the newline, which is the other half — a reader
# that joined the fields with a delimiter would split this body into pieces.
#
# Asserted from both ends: nothing executed, and the value arrived unchanged.
# Either one alone passes for an implementation that is wrong in the other
# direction — a mangled body proves no injection, and a safe eval says nothing
# about whether the tab survived.
@test "sync contract: a projection body reaches the store verbatim, whatever it contains" {
  local canary body remote db got
  canary="$BATS_TEST_TMPDIR/should-not-exist"
  body="it's \$(touch $canary) \`touch $canary\`; rm -rf . \\ end
second line	after a tab"

  remote=$(jq -nc --arg b "$body" '
    {type:"sync_pull_message",server_seq:"1",
     id:"550e8400-e29b-41d4-a716-4466554400d1",
     server_received_at:"2026-07-20T13:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:$b,created_at:"2026-07-20T13:00:01.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:$b,created_at:"2026-07-20T13:00:01.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  printf '%s\n%s\n' "$remote" '{"type":"sync_pull_cursor","next_after":"1"}' \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null

  [ ! -e "$canary" ]

  db=$(agmsg_db_path demo)
  # Reached through the wire mapping rather than by matching on the body, which
  # is the value under test and cannot also be the key that finds it.
  got=$(sqlite3 "$db" "SELECT e.body FROM events e JOIN sync_messages m
          ON m.local_id=e.id
        WHERE m.wire_id='550e8400-e29b-41d4-a716-4466554400d1';" | tr -d '\r')
  [ "$got" = "$body" ]
}

# Every line of a page now carries a next_after, not just the cursor line,
# because all the fields are read in one pass. So the cursor has to be taken
# from the line whose TYPE says it is the cursor — assigning it from whatever
# the last read produced lets a message line arriving afterwards blank it, and
# the apply then either fails with no cursor or rewinds the transport.
#
# Position is not significant in the format, and this is the assertion that
# says so.
@test "sync contract: a message line after the cursor line does not blank the cursor" {
  local remote db
  db=$(agmsg_db_path demo)
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"9",
     id:"550e8400-e29b-41d4-a716-4466554400d2",
     server_received_at:"2026-07-20T13:00:09.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"after the cursor",created_at:"2026-07-20T13:00:09.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"after the cursor",created_at:"2026-07-20T13:00:09.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  printf '%s\n%s\n' '{"type":"sync_pull_cursor","next_after":"9"}' "$remote" \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null

  [ "$(sqlite3 "$db" "SELECT transport_cursor FROM sync_bindings WHERE local_team='demo';" | tr -d '\r')" = 9 ]
}

# A line jq cannot parse produces NO output, and an eval of nothing is not an
# error — it leaves every field holding the previous line's value. So the read
# has to say whether it happened, and the last thing jq emits is that flag.
#
# The garbage line is placed AFTER the cursor line on purpose. Before it, the
# stale fields still say "sync_pull_message" and the page fails at the end for
# want of a cursor, so the bug is invisible. After it, the stale fields say
# "sync_pull_cursor", the loop skips the line as if it had been one, and the
# page COMMITS — an unparseable line accepted as a page terminator.
@test "sync contract: an unparseable line fails the page, wherever it sits" {
  local remote db rc=0
  db=$(agmsg_db_path demo)
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"4",
     id:"550e8400-e29b-41d4-a716-4466554400d3",
     server_received_at:"2026-07-20T13:00:04.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"before the garbage",created_at:"2026-07-20T13:00:04.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"before the garbage",created_at:"2026-07-20T13:00:04.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  printf '%s\n%s\n%s\n' "$remote" '{"type":"sync_pull_cursor","next_after":"4"}' \
    'this is not json' \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  # And nothing from the page reached the store, including the message that
  # came before the bad line. Asserting only the exit status passes for an
  # implementation that committed and then reported the failure.
  [ "$(sqlite3 "$db" "SELECT count(*) FROM events WHERE body='before the garbage';" | tr -d '\r')" -eq 0 ]
}

# `.envelope.v` leaves jq with no default on purpose: absent, it reads "null",
# and the arity check rejects that. An empty-string default would let
# "$seq:$v" hold nothing but digits and a colon and walk straight past it.
#
# This test does NOT bind that choice, and saying so is the point of the
# paragraph. Run it against the empty-string default and it still passes —
# because an empty `envelope_v` interpolates into the batch as `,,`, which is a
# SQLite syntax error, so the page is refused a second time further down. Two
# rejections, one exit status, and the suite cannot see which one fired.
#
# What it does pin is the outcome for an input that has no envelope at all:
# refused, and nothing left behind in either table. The reason for preferring
# the check over the syntax error is in the driver, where a reader deciding
# whether the `tostring` matters will be standing.
@test "sync contract: a message with no envelope is refused, not defaulted" {
  local remote db rc=0
  db=$(agmsg_db_path demo)
  remote=$(jq -nc '
    {type:"sync_pull_message",server_seq:"5",
     id:"550e8400-e29b-41d4-a716-4466554400d4",
     server_received_at:"2026-07-20T13:00:05.000000Z",
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"no envelope",created_at:"2026-07-20T13:00:05.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  printf '%s\n%s\n' "$remote" '{"type":"sync_pull_cursor","next_after":"5"}' \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
  [ "$(sqlite3 "$db" "SELECT count(*) FROM events WHERE body='no envelope';" | tr -d '\r')" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT count(*) FROM sync_quarantine WHERE wire_id='550e8400-e29b-41d4-a716-4466554400d4';" | tr -d '\r')" -eq 0 ]
}

# One line is not one JSON value to jq. Given two concatenated objects it parses
# both, and a filter that emits assignments emits the whole list twice — the
# eval runs both and the second overwrites the first, `jq_ok` included. A page
# could put anything it liked in front of a well-formed message and have it
# vanish.
#
# The per-field reads this replaced refused it by accident: each substitution
# came back holding two lines, and the type and arity checks rejected the
# embedded newline. Raised in review of the single-read change.
#
# The leading object here is a VALID message with its own wire id, not garbage,
# so the assertion cannot pass merely because the line failed to parse — and the
# ids are checked separately, because "the page was refused" and "the right one
# was refused" are different claims.
@test "sync contract: two JSON values on one line are refused, not resolved to the last" {
  local first second db rc=0
  db=$(agmsg_db_path demo)
  first=$(jq -nc '
    {type:"sync_pull_message",server_seq:"6",
     id:"550e8400-e29b-41d4-a716-4466554400e1",
     server_received_at:"2026-07-20T13:00:06.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"hidden in front",created_at:"2026-07-20T13:00:06.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"hidden in front",created_at:"2026-07-20T13:00:06.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  second=$(jq -nc '
    {type:"sync_pull_message",server_seq:"7",
     id:"550e8400-e29b-41d4-a716-4466554400e2",
     server_received_at:"2026-07-20T13:00:07.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"the visible one",created_at:"2026-07-20T13:00:07.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"the visible one",created_at:"2026-07-20T13:00:07.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')

  printf '%s %s\n%s\n' "$first" "$second" '{"type":"sync_pull_cursor","next_after":"7"}' \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]

  # Neither of them, and neither wire id. The dangerous outcome is the SECOND
  # one landing while the first disappears without trace, so both are named.
  [ "$(sqlite3 "$db" "SELECT count(*) FROM events WHERE body IN ('hidden in front','the visible one');" | tr -d '\r')" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT count(*) FROM sync_quarantine WHERE wire_id IN ('550e8400-e29b-41d4-a716-4466554400e1','550e8400-e29b-41d4-a716-4466554400e2');" | tr -d '\r')" -eq 0 ]
}
