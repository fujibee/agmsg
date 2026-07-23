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
  storage_init >/dev/null
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
  db=$(agmsg_db_path)
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
  db=$(agmsg_db_path)
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
  db=$(agmsg_db_path)
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
  db=$(agmsg_db_path)
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
  db=$(agmsg_db_path)
  [ "$(agmsg_sqlite "$db" "SELECT status FROM sync_quarantine WHERE wire_id='550e8400-e29b-41d4-a716-446655440020';" | tr -d '\r')" = imported ]
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
  db=$(agmsg_db_path)
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
  before=$(agmsg_sqlite "$(agmsg_db_path)" "SELECT total_changes();" | tr -d '\r')
  storage_sync_resync_status demo "$SERVER_ID" "$TEAM_ID" 1 10 >/dev/null
  after=$(agmsg_sqlite "$(agmsg_db_path)" "SELECT total_changes();" | tr -d '\r')
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
  db=$(agmsg_db_path)
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
  db=$(agmsg_db_path)
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

  db=$(agmsg_db_path)
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
  db=$(agmsg_db_path)
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
