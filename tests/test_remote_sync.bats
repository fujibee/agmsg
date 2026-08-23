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

# `_sqlite_sync_apply_fail` closes fd 3 with `exec 3<&- 2>/dev/null`. `exec` with
# no command word runs nothing -- it applies its redirections to the shell
# itself, and they outlive the statement. So every later write to stderr in that
# shell went to /dev/null, and the first thing written after it is
# `_sqlite_sync_why`: the line #911 exists to print. The two messages emitted
# *before* the close still arrived, so the output looked almost right.
@test "sync contract: a failed apply still names the check that returned 13 (#911)" {
  local rc=0
  printf 'not json at all\n' |
    storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 \
      >/dev/null 2>"$BATS_TEST_TMPDIR/apply.err" || rc=$?
  [ "$rc" -eq 13 ]
  grep -q 'storage_sync_apply_pull failed at' "$BATS_TEST_TMPDIR/apply.err"
}

@test "sync contract: the builtin quote and the forking quote agree on adversarial input (#908)" {
  # storage_sync_apply_pull quotes its eleven per-message fields through
  # _sqlite_sync_lit_into (a bash expansion) where it used to fork
  # _sqlite_lit (printf|sed) at every use site. A speed change that alters
  # one quoted byte corrupts rows, so the two are held equal here on the
  # inputs that matter to SQL quoting: a quote alone, doubled, leading,
  # trailing; a newline; a backslash, and one next to a quote; empty;
  # sed's and printf's own metacharacters.
  local input expected actual
  while IFS= read -r -d '' input; do
    expected="$(_sqlite_lit "$input")"
    _sqlite_sync_lit_into "$input"
    actual="$_SQLITE_SYNC_LIT"
    [ "$actual" = "$expected" ] || {
      printf 'quote mismatch for %q: builtin %q, helper %q\n' "$input" "$actual" "$expected" >&2
      return 1
    }
  done < <(printf '%s\0' \
    "plain" "it's" "two''quotes" "'leading" "trailing'" "'" "''" "" \
    $'line one\nline two' $'tab\there' 'back\slash' "back\\'slash quote" \
    '100% $HOME' 'and & ampersand' 'a/b' 'dots...')
  # And the shape SQL needs: every single quote doubled, nothing else touched.
  _sqlite_sync_lit_into "a'b''c"
  [ "$_SQLITE_SYNC_LIT" = "a''b''''c" ]
}

@test "sync contract: a page with one U+0000 record quarantines it and applies the rest (#940)" {
  # #940's fix made a body holding U+0000 refuse the whole PAGE (error() in
  # the framing jq aborts the stream mid-read, so nothing downstream of the
  # bad record -- however many good records follow it -- ever lands). One
  # dirty record made a team impossible to clone. This is the replacement:
  # the record is named and quarantined, the other two apply, and the page
  # commits (exit 0), not exit 13.
  local nul_body clean1 dirty clean2 page result db
  nul_body=$(jq -nc '"before" + ([0]|implode) + "after"')
  clean1=$(jq -nc '
    {type:"sync_pull_message",server_seq:"1",id:"550e8400-e29b-41d4-a716-446655440050",
     server_received_at:"2026-07-20T13:00:00.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"one",created_at:"2026-07-20T13:00:00.000000Z",
        from_agent:"alice",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"one",created_at:"2026-07-20T13:00:00.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  dirty=$(jq -nc --argjson b "$nul_body" '
    {type:"sync_pull_message",server_seq:"2",id:"550e8400-e29b-41d4-a716-446655440051",
     server_received_at:"2026-07-20T13:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:($b|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:$b,created_at:"2026-07-20T13:00:01.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  clean2=$(jq -nc '
    {type:"sync_pull_message",server_seq:"3",id:"550e8400-e29b-41d4-a716-446655440052",
     server_received_at:"2026-07-20T13:00:02.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"three",created_at:"2026-07-20T13:00:02.000000Z",
        from_agent:"alice",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"three",created_at:"2026-07-20T13:00:02.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n%s\n%s\n' "$clean1" "$dirty" "$clean2" \
    '{"type":"sync_pull_cursor","next_after":"3"}')
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$page"
  [ "$status" -eq 0 ]
  result="$output"
  # The page committed: the cursor advanced past the quarantined record too
  # (#940 does not ask the caller to re-fetch the same page forever).
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].transport_cursor')" = 3 ]
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].corrupt_count')" -eq 1 ]
  [ "$(printf '%s\n' "$result" | jq -sr \
    '[.[]|select(.id=="550e8400-e29b-41d4-a716-446655440051")][0].status')" = corrupt_state ]
  # The other two land; the dirty one's ID is in neither table.
  [ "$(storage_history demo | jq -s 'length')" -eq 2 ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="one" or .body=="three")]|length')" -eq 2 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" \
    "SELECT status,reason FROM sync_quarantine WHERE wire_id='550e8400-e29b-41d4-a716-446655440051';" \
    | tr -d '\r')" = "corrupt_state|body contains U+0000" ]
  [ "$(agmsg_sqlite "$db" \
    "SELECT COUNT(*) FROM sync_messages WHERE wire_id='550e8400-e29b-41d4-a716-446655440051';" \
    | tr -d '\r')" -eq 0 ]
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM events WHERE body LIKE '%before%';" \
    | tr -d '\r')" -eq 0 ]
}

@test "sync contract: U+0000 in from_agent quarantines the record the same as in body (#940)" {
  # #940's guard checked every one of the eighteen fields, not just body.
  # The per-record replacement must too: the field that carried the NUL is
  # not the thing being tested here, only that ANY field having it routes
  # the whole record to quarantine rather than erroring the page.
  local nul_from page result db
  nul_from=$(jq -nc '"alice" + ([0]|implode)')
  page=$(jq -nc --argjson from "$nul_from" '
    {type:"sync_pull_message",server_seq:"1",id:"550e8400-e29b-41d4-a716-446655440053",
     server_received_at:"2026-07-20T13:00:00.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"hello",created_at:"2026-07-20T13:00:00.000000Z",
        from_agent:$from,to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"hello",created_at:"2026-07-20T13:00:00.000000Z",
                 from_agent:$from,to_agent:"bob"}}')
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 \
    <<<"$(printf '%s\n%s\n' "$page" '{"type":"sync_pull_cursor","next_after":"1"}')"
  [ "$status" -eq 0 ]
  result="$output"
  [ "$(printf '%s\n' "$result" | jq -sr '.[0].corrupt_count')" -eq 1 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" \
    "SELECT status,reason FROM sync_quarantine WHERE wire_id='550e8400-e29b-41d4-a716-446655440053';" \
    | tr -d '\r')" = "corrupt_state|body contains U+0000" ]
  [ "$(storage_history demo | jq -s 'length')" -eq 0 ]
}

@test "sync contract: a line that is not one JSON value still fails the whole page (#940)" {
  # Per-record quarantine is scoped to values that fromjson CAN parse but the
  # store cannot hold. A line that is not parseable JSON at all names no
  # record to quarantine, so it stays exit 13 for the page, unchanged from
  # before this change.
  local page db
  page=$(printf '%s\n%s\n' 'not json at all' '{"type":"sync_pull_cursor","next_after":"1"}')
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$page"
  [ "$status" -eq 13 ]
  printf '%s\n' "$output" | grep -q 'record 1: not one JSON value on its line'
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_quarantine;" | tr -d '\r')" -eq 0 ]
}

@test "sync contract: U+0000 in an identity field fails the page, not just the record (identifier poisoning, review finding)" {
  # A record's own id/wire is never stripped and quarantined: a corrupt id
  # or server_seq cannot be trusted to name itself, let alone anything else.
  # The concrete danger this guards against: id/wire is the WHERE key every
  # UPDATE in this function uses. If it were stripped instead of refused, a
  # value like "<good-uuid>" + U+0000 would strip down to an existing wire
  # id that belongs to a DIFFERENT, legitimate record already imported --
  # and this record's corrupt_state UPDATE would land on that unrelated row
  # instead of failing to identify anything. Proven both ways: the page
  # fails outright, AND the prior legitimate record it could have collided
  # with is untouched.
  local prior_wire='550e8400-e29b-41d4-a716-446655440060'
  local prior page db
  prior=$(jq -nc --arg id "$prior_wire" '
    {type:"sync_pull_message",server_seq:"1",id:$id,
     server_received_at:"2026-07-20T13:00:00.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"legitimate prior message",created_at:"2026-07-20T13:00:00.000000Z",
        from_agent:"alice",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"legitimate prior message",created_at:"2026-07-20T13:00:00.000000Z",
                 from_agent:"alice",to_agent:"bob"}}')
  page=$(printf '%s\n%s\n' "$prior" '{"type":"sync_pull_cursor","next_after":"1"}')
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" \
    "SELECT status FROM sync_quarantine WHERE wire_id='$prior_wire';" | tr -d '\r')" = imported ]

  # Now a second page: one record whose id is the SAME UUID with a trailing
  # U+0000 appended -- the exact string that, if stripped rather than
  # refused, becomes $prior_wire.
  local poisoned_id
  poisoned_id=$(jq -nc --arg u "$prior_wire" '$u + ([0]|implode)')
  local poisoned
  poisoned=$(jq -nc --argjson id "$poisoned_id" '
    {type:"sync_pull_message",server_seq:"2",id:$id,
     server_received_at:"2026-07-20T13:00:01.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"attacker record",created_at:"2026-07-20T13:00:01.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"attacker record",created_at:"2026-07-20T13:00:01.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  local page2
  page2=$(printf '%s\n%s\n' "$poisoned" '{"type":"sync_pull_cursor","next_after":"2"}')
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$page2"
  [ "$status" -eq 13 ]
  printf '%s\n' "$output" | grep -q 'record 1: field id contains U+0000'
  # The prior, legitimate record is untouched -- not quarantined, not
  # overwritten, still imported under its real wire id.
  [ "$(agmsg_sqlite "$db" \
    "SELECT status FROM sync_quarantine WHERE wire_id='$prior_wire';" | tr -d '\r')" = imported ]
  [ "$(storage_history demo | jq -s '[.[]|select(.body=="legitimate prior message")]|length')" -eq 1 ]
}

@test "sync contract: apply refuses a wire id that is not a canonical UUIDv4 (#908)" {
  # The shape check moved from `printf | grep -Eq` to `[[ =~ ]]` with the
  # pattern in a variable; the acceptance set must not move with it. One
  # accepted id and the near-misses: wrong version nibble, wrong variant
  # nibble, uppercase, too short, and empty.
  local good='{"type":"sync_pull_message","server_seq":"1","id":"550e8400-e29b-41d4-a716-446655440000","server_received_at":"2026-07-20T13:00:00.000000Z","envelope":{"v":1,"cipher":"none","key_id":null,"blob":"e30="},"status":"malformed","policy_revision":"0","local_security_revision":"0","reason":"fixture"}'
  local page cursor='{"type":"sync_pull_cursor","next_after":"1"}'
  page=$(printf '%s\n%s\n' "$good" "$cursor")
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  local bad
  for bad in \
    "550e8400-e29b-51d4-a716-446655440000" \
    "550e8400-e29b-41d4-c716-446655440000" \
    "550E8400-E29B-41D4-A716-446655440000" \
    "550e8400-e29b-41d4-a716-44665544000" \
    ""; do
    page=$(printf '%s\n%s\n' "${good/550e8400-e29b-41d4-a716-446655440000/$bad}" "$cursor")
    run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$page"
    [ "$status" -eq 13 ]
  done
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

# The existing contiguous-prefix test has exactly ONE gap, and with one gap the
# first gap and the last gap are the same row -- so it cannot tell "stop at the
# first gap" from "stop at the last one". Two gaps separate them, and that is
# the whole correctness question for how the run's end is found.
# An earlier revision bounded the candidate scan with 9223372036854775807 as
# though it were infinity. It is the largest value `events.seq` can hold, so a
# message sitting exactly there was accepted before and refused after -- a
# changed acceptance set at one value, which a differential run over ordinary
# fixtures never visits. The bound is now `IS NULL OR <`, which has no such
# value; this pins that it stays that way.
@test "sync contract: a message at the maximum seq still advances the cursor (#912)" {
  local db candidates acks result max=9223372036854775807
  storage_send demo alice bob one >/dev/null
  db=$(agmsg_db_path demo)
  # Move the second message to the top of the seq space. AUTOINCREMENT permits
  # an explicit value, and this is the only one the old sentinel collided with.
  storage_send demo alice bob two >/dev/null
  sqlite3 "$db" "UPDATE events SET seq=$max WHERE body='two';"

  candidates=$(prepare_push 5)
  acks=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate")
    | {type:"sync_push_ack",local_position,id,server_seq:.local_position,disposition:"stored"}')
  result=$(printf '%s\n' "$acks" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = "$max" ]
}

@test "sync contract: reconcile stops at the FIRST gap, not the last (#912)" {
  local i candidates acks result
  for i in one two three four five; do storage_send demo alice bob "$i" >/dev/null; done
  candidates=$(prepare_push 5)

  # Acknowledge 2 and 4. Gaps at 1, 3 and 5.
  acks=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate" and ((.local_position|tonumber)==2 or (.local_position|tonumber)==4))
    | {type:"sync_push_ack",local_position,id,server_seq:.local_position,disposition:"stored"}')
  result=$(printf '%s\n' "$acks" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  # Nothing contiguous from the cursor: the first gap is position 1.
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = 0 ]

  # Fill position 1. The run is now 1..2 and stops at the gap at 3 -- bounding by
  # the LAST gap instead would carry the cursor to 4, straight over that gap.
  acks=$(printf '%s\n' "$candidates" | jq -c '
    select(.type=="sync_push_candidate" and (.local_position|tonumber)==1)
    | {type:"sync_push_ack",local_position,id,server_seq:"1",disposition:"stored"}')
  result=$(printf '%s\n' "$acks" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1)
  [ "$(printf '%s\n' "$result" | jq -r '.push_cursor')" = 2 ]
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
  # --separate-stderr so the two halves can be asserted apart. "Fail closed" is
  # about not emitting a status RECORD, and that is stdout; asserting the pair
  # was silent also pinned "says nothing about why", which is the defect being
  # fixed here. Both are checked, so neither can be lost by the other changing.
  run --separate-stderr storage_sync_resync_status demo "$SERVER_ID" "$other" 1 10
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  grep -q 'storage_sync_resync_status failed at sqlite-sync\.sh:[0-9]' <<<"$stderr"
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
  # An old store also predates the schema-revision stamp (#1001): reset it,
  # or the simulated pre-cursor store would fast-path around the adoption
  # this seeder exists to exercise. No product path deletes the marker; only
  # this simulation does.
  agmsg_sqlite "$db" "
    PRAGMA user_version=0;
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

# The #780 guard, on the ACK path. The existing "two JSON values on one line"
# test drives `sync_pull_message`, so the same guard on reconcile was carried by
# nothing: a second value on the line would emit a second full set of
# assignments, `jq_ok` included, and the last one would win.
@test "sync contract: reconcile refuses two JSON values on one ack line (#780)" {
  _seed_legacy_history
  prepare_push >/dev/null
  local one two
  one='{"type":"sync_push_ack","local_position":"1","id":"00000000-0000-4000-8000-000000000000","server_seq":"1","disposition":"stored"}'
  # Second value hides a different position on the same line.
  two='{"type":"sync_push_ack","local_position":"2","id":"00000000-0000-4000-8000-000000000001","server_seq":"2","disposition":"stored"}'
  # Drive it in THIS shell, for the reason _reconcile_one_ack documents: a 127
  # from an undefined function would look like the rejection being asserted.
  run printf_two_acks_through_reconcile "$one" "$two"
  [ "$status" -eq 13 ]
}

printf_two_acks_through_reconcile() {
  printf '%s %s\n' "$1" "$2" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1
}

# `@sh` turns an ARRAY into a list of shell WORDS, so an array-typed field does
# not merely slip past the whitelist -- it changes what `eval` is handed.
# `"local_position": ["1","<name>"]` expands to `pos='1' '<name>'`, which is a
# command-prefix assignment: it RUNS `<name>`, leaves `pos` holding the previous
# line's value, and still reaches `jq_ok=1`, so the line is accepted.
#
# Two assertions, because "refused" and "did not execute" are different claims
# and only one of them is about the exit status.
@test "sync contract: an array-typed ack field is refused and does not execute (#780)" {
  _seed_legacy_history
  prepare_push >/dev/null
  local marker shim good
  marker="$BATS_TEST_TMPDIR/executed"
  shim="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$shim"
  printf '#!/bin/sh\ntouch %s\n' "$marker" > "$shim/agmsg-exec-probe"
  chmod +x "$shim/agmsg-exec-probe"

  # The probe must be runnable, or "it did not run" proves nothing.
  PATH="$shim:$PATH" agmsg-exec-probe
  [ -f "$marker" ]
  rm -f "$marker"

  good='{"type":"sync_push_ack","local_position":"1","id":"00000000-0000-4000-8000-000000000000","server_seq":"1","disposition":"stored"}'
  run _reconcile_array_position "$good"
  # Execution first: it is the more severe of the two claims, and asserting the
  # exit status ahead of it would stop the test before this ever ran.
  refute test -f "$marker"
  [ "$status" -eq 13 ]
}

_reconcile_array_position() {
  local bad
  bad='{"type":"sync_push_ack","local_position":["1","agmsg-exec-probe"],"id":"00000000-0000-4000-8000-000000000001","server_seq":"2","disposition":"stored"}'
  # PATH is exported for the WHOLE function, not prefixed to `printf`. A prefix
  # assignment would scope it to the left side of the pipe, while the `eval` that
  # could run the probe is on the right -- so the "did not execute" assertion
  # would hold because the probe was unreachable, not because nothing ran it.
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  printf '%s\n%s\n' "$1" "$bad" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1
}

# The sentinel, driven the only way that can fail. A single unparseable line is
# caught anyway -- with no assignments the fields are empty and the position
# whitelist refuses "" -- so the shape that separates a working sentinel from a
# broken one is a GOOD line followed by a BAD one: without it the bad line
# silently re-uses the good line's position, wire id and sequence, and is
# counted a second time.
@test "sync contract: an unparseable ack line does not inherit the previous line (#780)" {
  _seed_legacy_history
  prepare_push >/dev/null
  local good
  good='{"type":"sync_push_ack","local_position":"1","id":"00000000-0000-4000-8000-000000000000","server_seq":"1","disposition":"stored"}'
  run _reconcile_good_then_garbage "$good"
  [ "$status" -eq 13 ]
}

_reconcile_good_then_garbage() {
  printf '%s\n{not json\n' "$1" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1
}

# The wire-id check stopped being a `grep -Eq '^[0-9a-f-]{36}$'` and became two
# builtin `case` patterns. Same whitelist or not is the question, and `$wire`
# goes straight into SQL, so it is asked with the shapes that separate the two:
# right length wrong charset, right charset wrong length, and an injection that
# is neither.
@test "sync contract: an ack wire id stays a whitelist after the grep was removed" {
  _seed_legacy_history
  prepare_push >/dev/null
  local bad
  for bad in \
    "00000000-0000-4000-8000-00000000000" \
    "00000000-0000-4000-8000-0000000000000" \
    "00000000-0000-4000-8000-00000000000g" \
    "00000000-0000-4000-8000-00000000000'" \
    "'; DROP TABLE sync_messages; --" \
    "" \
    "00000000-0000-4000-8000-0000000000 0"; do
    run _reconcile_one_ack_wire "$bad"
    [ "$status" -eq 13 ]
  done
}

_reconcile_one_ack_wire() {
  printf '{"type":"sync_push_ack","local_position":"1","id":"%s","server_seq":"1","disposition":"stored"}\n' \
    "$1" | storage_sync_reconcile_push demo "$SERVER_ID" "$TEAM_ID" 1
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
# Every field of a pulled line reaches `eval` through `@sh`, and `@sh` emits one
# quoted word per element of an ARRAY. A line of several words is an assignment
# prefixed to a COMMAND, so an array-valued field both fails to assign -- leaving
# the previous value in place -- and gets a word from the input resolved and run.
# This input comes from the sync server.
#
# Two claims, asserted separately because they fail separately, and the more
# severe one first: nothing from the line ran, and the page was refused.
@test "sync contract: an array-valued pull field is refused and does not execute" {
  local marker shim rc=0 bad
  marker="$BATS_TEST_TMPDIR/executed"
  shim="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$shim"
  printf '#!/bin/sh\ntouch %s\n' "$marker" > "$shim/agmsg-exec-probe"
  chmod +x "$shim/agmsg-exec-probe"

  # The probe has to be runnable, or "it did not run" would hold because it was
  # unreachable and this test would pass against any implementation.
  PATH="$shim:$PATH" agmsg-exec-probe
  [ -f "$marker" ]
  rm -f "$marker"

  bad=$(jq -nc '
    {type:["sync_pull_message","agmsg-exec-probe"],server_seq:"4",
     id:"550e8400-e29b-41d4-a716-4466554400d9",
     server_received_at:"2026-07-20T13:00:04.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:(
       {body:"array field",created_at:"2026-07-20T13:00:04.000000Z",
        from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:"array field",created_at:"2026-07-20T13:00:04.000000Z",
                 from_agent:"carol",to_agent:"bob"}}')
  # Exported, not prefixed: a prefix assignment would scope PATH to the left of
  # the pipe, while the `eval` that could run the probe is on the right.
  export PATH="$shim:$PATH"
  printf '%s\n' "$bad" \
    | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null 2>&1 || rc=$?

  refute test -f "$marker"
  [ "$rc" -ne 0 ]
}

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

# Builds a pull page of N distinct importable messages, so the only thing that
# varies between two runs of the case below is how many ids the apply carries.
_sync_page_of() {
  local n="$1" i seq id
  i=0
  while [ "$i" -lt "$n" ]; do
    seq=$((i + 1))
    id="$(printf '550e8400-e29b-41d4-a716-4466%08x' "$seq")"
    jq -nc --arg id "$id" --arg seq "$seq" '
      {type:"sync_pull_message",server_seq:$seq,id:$id,
       server_received_at:"2026-07-20T13:00:00.000000Z",
       envelope:{v:1,cipher:"none",key_id:null,blob:(
         {body:("m" + $seq),created_at:"2026-07-20T13:00:00.000000Z",
          from_agent:"carol",to_agent:"bob"}|tojson|@base64)},
       status:"importable",policy_revision:"0",local_security_revision:"0",
       projection:{body:("m" + $seq),created_at:"2026-07-20T13:00:00.000000Z",
                   from_agent:"carol",to_agent:"bob"}}'
    i=$((i + 1))
  done
  jq -nc --arg after "$n" '{type:"sync_pull_cursor",next_after:$after}'
}

# Records the length of every sqlite3 command line, then runs the real one.
# Measuring the ARGUMENT LENGTH rather than waiting for an operating system to
# refuse it is what makes this case mean the same thing on every platform: the
# limit that broke #882 is Windows' 32,767 characters, and a test that only
# went red where the limit is small would be green on the machines that run it.
_sqlite_argv_recorder() {
  local dir="$TEST_SKILL_DIR/argv-probe" real
  real="$(command -v sqlite3)"
  mkdir -p "$dir"
  : > "$dir/lengths"
  printf '%s\n' '#!/usr/bin/env bash' \
    'joined="$*"' \
    "printf '%s\\n' \"\${#joined}\" >> $(printf '%q' "$dir/lengths")" \
    "exec $(printf '%q' "$real") \"\$@\"" > "$dir/sqlite3"
  chmod +x "$dir/sqlite3"
  printf '%s\n' "$dir"
}

_longest_argv() {
  sort -n "$TEST_SKILL_DIR/argv-probe/lengths" | tail -1
}

@test "sync contract: applying a pull page does not grow the command line (#882)" {
  # A Windows machine could not pull a team past a few hundred messages: the
  # apply put one wire id per message into the SQL that reads the outcomes back,
  # twice, and handed it to sqlite3 as an ARGUMENT. Measured on Windows, sqlite3
  # took 827 uuids and refused 837; the command line caps at 32,767 characters.
  # Nothing in the product chose that number, and the team that hit it was 2,079
  # messages.
  local probe short long
  probe="$(_sqlite_argv_recorder)"

  _sync_page_of 5 | PATH="$probe:$PATH" storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  short="$(_longest_argv)"

  : > "$TEST_SKILL_DIR/argv-probe/lengths"
  _sync_page_of 120 | PATH="$probe:$PATH" storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  long="$(_longest_argv)"

  # The page really did get bigger -- without this the case would pass if both
  # runs had silently applied nothing.
  # The second page is a superset of the first, so the store holds 120 -- what
  # this pins is that the larger apply really did import, which is what makes
  # the length comparison above about anything.
  [ "$(storage_history demo | jq -s 'length')" -eq 120 ]

  # Before the fix this difference was 115 messages x 78 characters. The bound
  # is deliberately loose: what must not happen is growth PER MESSAGE, and a
  # cursor or a count moving by a few characters is not that.
  [ "$long" -lt "$((short + 200))" ]
}

@test "sync contract: a store another writer holds is busy (11), not a failed check (13)" {
  # #910: an unlock's reprocess died on the page where an engine's first prepare
  # held the store past the busy timeout, and the 13 it got read as "this page
  # cannot be processed". The adapter tells the two apart -- and only the
  # adapter: the driver function still returns 13 and still names the site, the
  # adapter reads the last statement's outcome and exits 11 with its own line.
  prepare_push >/dev/null
  local db adapter holder
  db=$(agmsg_db_path demo)
  adapter="$SCRIPTS/internal/storage-sync-driver.sh"
  # Another process holds the write lock for longer than the busy timeout.
  ( printf 'BEGIN IMMEDIATE;\nSELECT 1;\n'; sleep 3; printf 'COMMIT;\n' ) | sqlite3 "$db" >/dev/null &
  holder=$!
  sleep 0.5
  export AGMSG_BUSY_TIMEOUT=200
  run --separate-stderr bash "$adapter" reprocess demo "$SERVER_ID" "$TEAM_ID" 1 10
  unset AGMSG_BUSY_TIMEOUT
  wait "$holder"
  [ "$status" -eq 11 ]
  [ -z "$output" ]
  grep -q 'failed at sqlite-sync\.sh:[0-9]' <<<"$stderr"
  grep -q 'reprocess: the store is busy' <<<"$stderr"
  # The same call once the writer is gone: the input was never the problem.
  run --separate-stderr bash "$adapter" reprocess demo "$SERVER_ID" "$TEAM_ID" 1 10
  [ "$status" -eq 0 ]
  grep -q '"type":"sync_reprocess_page"' <<<"$output"
  # A refused input still exits 13: the two are told apart, not merged.
  run --separate-stderr bash "$adapter" reprocess demo "$SERVER_ID" "$TEAM_ID" 1 0
  [ "$status" -eq 13 ]
  grep -q 'failed at sqlite-sync\.sh:[0-9]' <<<"$stderr"
}

@test "sync schema: the conflict guard's server_seq lookup on sync_messages is a search, not a scan (#910)" {
  # The apply conflict guard asks whether a server_seq already maps to a
  # different wire id. sync_messages' UNIQUE serves wire_id lookups only, so
  # this came in by server_seq as a walk of every row of the binding, once
  # per imported message -- 68.6 ms per message on a 21,471-row store, and
  # the reason import time grew with the store. Schema setup now carries the
  # index, on new stores and on any store the next sync call touches.
  prepare_push >/dev/null
  local db
  db=$(agmsg_db_path demo)
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND tbl_name='sync_messages' AND name='sync_messages_server_seq';" | tr -d '\r')" -eq 1 ]
  sqlite3 "$db" "EXPLAIN QUERY PLAN SELECT 1 FROM sync_messages mx
    WHERE mx.server_instance_id='s' AND mx.remote_team_id='r'
      AND mx.protocol_version=1 AND mx.server_seq='7' AND mx.wire_id<>'w';" |
    grep -q 'USING INDEX sync_messages_server_seq\|USING COVERING INDEX sync_messages_server_seq'
  # A store whose sync schema predates the index picks it up on the next call.
  sqlite3 "$db" "DROP INDEX sync_messages_server_seq;"
  prepare_push >/dev/null
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='sync_messages_server_seq';" | tr -d '\r')" -eq 1 ]
}

# Piped `agmsg_sqlite` sites under <root>/scripts with no warm within the two
# lines above the pipe, one "file:line" per line. Comment lines are not sites:
# the rule is about processes, and a comment starts none. A whole file is never
# excluded -- a real pipeline added to any file must be seen (review finding on
# #904: the earlier file-level skip would have hidden one).
_462_unwarmed_under() {
  local root="$1" file n line stripped prev
  while IFS=: read -r file n line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in \#*) continue ;; esac
    prev="$(sed -n "$((n > 2 ? n - 2 : 1)),$((n))p" "$root/$file")"
    case "$prev" in *agmsg_sqlite_warm*) continue ;; esac
    printf '%s:%s\n' "$file" "$n"
  done < <(cd "$root" && grep -rn '| agmsg_sqlite' scripts/)
}

# Executable (non-comment) piped sites under <root>/scripts: the population
# the scan judges, counted the same way the scan reads them.
_462_piped_sites_under() {
  local root="$1" file n line stripped count=0
  while IFS=: read -r file n line; do
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in \#*) continue ;; esac
    count=$((count + 1))
  done < <(cd "$root" && grep -rn '| agmsg_sqlite' scripts/)
  printf '%s\n' "$count"
}

@test "storage: every piped agmsg_sqlite warms the escape probe first (#462)" {
  # THE SET IS DERIVED, NOT LISTED. `agmsg_sqlite` memoises the escape probe so
  # it costs one sqlite3 process per shell rather than one per call, and the
  # right-hand side of a pipeline is a subshell: it inherits a memo but cannot
  # leave one behind. A process whose first database access is piped therefore
  # probes on every call, forever -- the cost #462 removed. A redirection
  # (`agmsg_sqlite db < file`) runs in the current shell and is fine.
  #
  # Written as a scan rather than as one case per site because the sites move:
  # three were added the day this was found, by a change that was reviewed and
  # cleared without anyone noticing the shell rule underneath it. A statement
  # inside a helper that warms is reached through the helper, so the scan looks
  # two lines up rather than one.
  local root unwarmed
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  unwarmed="$(_462_unwarmed_under "$root")"
  [ -z "$unwarmed" ] || {
    printf 'piped agmsg_sqlite with no warm above it:\n%s\n' "$unwarmed"
    false
  }
  # The scan can see something: a positive control on the instrument itself,
  # counting only executable sites (a comment mentioning the pipe is not one).
  [ "$(_462_piped_sites_under "$root")" -ge 8 ]
}

@test "storage: the #462 scan goes red when a helper loses its warm (mutation control)" {
  # A guard that stays green under the break it exists for is not a guard.
  # Copy the tree, delete the warm from the stdin helper -- the central path
  # every driver batch goes through -- and the scan must name that pipe.
  local root copy target
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  copy="$BATS_TEST_TMPDIR/scan-mutant"
  mkdir -p "$copy"
  cp -R "$root/scripts" "$copy/scripts"
  target="$copy/scripts/drivers/storage/sqlite.sh"
  grep -q 'agmsg_sqlite_warm' "$target"
  # Remove exactly the warm line inside _sqlite_exec_stdin.
  awk 'BEGIN{inside=0} /^_sqlite_exec_stdin\(\) \{/{inside=1} inside && /agmsg_sqlite_warm/{inside=0; next} /^}/{inside=0} {print}' "$target" > "$target.mutant"
  mv "$target.mutant" "$target"
  # The mutation took: one fewer warm in the file.
  [ "$(grep -c 'agmsg_sqlite_warm' "$target")" -eq "$(( $(grep -c 'agmsg_sqlite_warm' "$root/scripts/drivers/storage/sqlite.sh") - 1 ))" ]
  local unwarmed
  unwarmed="$(_462_unwarmed_under "$copy")"
  printf '%s\n' "$unwarmed" | grep -q '^scripts/drivers/storage/sqlite.sh:[0-9][0-9]*$'
  # And ONLY that site: the mutant differs from the tree in one place.
  [ "$(printf '%s\n' "$unwarmed" | grep -c .)" -eq 1 ]
}

# ---- #968: roster sequences and the read frontier ----

_968_apply_messages() {
  # Apply messages to bob at the given server sequences and mark them all read.
  local page="" i=0 seq last
  for seq in "$@"; do
    i=$((i+1))
    page="${page}$(jq -nc --arg s "$seq" --arg n "$i" '
      {type:"sync_pull_message",server_seq:$s,
       id:("550e8400-e29b-41d4-a716-4466554409"+(if ($n|length)==1 then "0"+$n else $n end)),
       server_received_at:"2026-07-21T06:00:00.000000Z",
       envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"importable",
       policy_revision:"0",local_security_revision:"0",
       projection:{body:("msg "+$n),created_at:"2026-07-21T06:00:00.000000Z",
                   from_agent:"alice",to_agent:"bob"}}')
"
  done
  last="${!#}"
  page="${page}{\"type\":\"sync_pull_cursor\",\"next_after\":\"$last\"}"
  printf '%s\n' "$page" | storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  local id
  for id in $(storage_history demo | jq -r 'select(.to=="bob")|.id'); do
    storage_read_cursor_consume demo bob "$(storage_watch_tip demo:bob)" "$id" >/dev/null
  done
}

_968_prepare() {
  # $1 = current_seq, $2 = roster_seqs as a JSON array, or the word none.
  local roster="$2" context
  context=$(jq -nc --arg cur "$1" --arg roster "$roster" '
    {type:"sync_read_context",min_available_seq:"0",current_seq:$cur,local_agents:["bob"],
     members:[{member_id:"018f3f7e-0000-7000-8000-000000000010",name:"bob"}]}
    + (if $roster=="none" then {} else {roster_seqs:($roster|fromjson)} end)')
  printf '%s\n' "$context" | storage_sync_prepare_read_state demo "$SERVER_ID" "$TEAM_ID" 1
}

_968_frontier() { printf '%s\n' "$1" | jq -r 'select(.type=="sync_read_frontier")|.server_seq'; }
_968_exact_count() { printf '%s\n' "$1" | jq -r 'select(.type=="sync_read_exact")|.wire_id' | grep -c . || true; }

@test "read-state: a frontier advances across roster sequences the engine names, and stays pinned when it does not (#968)" {
  # The reported shape: seq 1 and 2 were member_joined (never messages), the
  # messages start at 3. Everything is imported and read.
  _968_apply_messages 3 4 5 6
  local prepared
  prepared=$(_968_prepare 6 '["1","2"]')
  [ "$(_968_frontier "$prepared")" = 6 ]
  [ "$(_968_exact_count "$prepared")" -eq 0 ]
  # Without the roster list the check has no evidence for seq 1 and 2, and a
  # frontier is never advanced on evidence that was not supplied: this is the
  # pre-#968 behavior, pinned at 0 with every read message shipped as an
  # exception. Kept as the documented fail-safe direction.
  prepared=$(_968_prepare 6 none)
  [ "$(_968_frontier "$prepared")" = 0 ]
  [ "$(_968_exact_count "$prepared")" -eq 4 ]
}

@test "read-state: a lost MESSAGE still pins the frontier; the roster list exempts only its own sequences (#968)" {
  # Seq 4 is a message that never arrived. The roster list says 1 and 2 only.
  _968_apply_messages 3 5 6
  local prepared
  prepared=$(_968_prepare 6 '["1","2"]')
  [ "$(_968_frontier "$prepared")" = 3 ]
  # The two read messages past the hole travel as exact exceptions, as before.
  [ "$(_968_exact_count "$prepared")" -eq 2 ]
  # The one way this check goes green while something is wrong, named: a
  # roster list that claims a sequence which was really a message. The journal
  # is written from the same records the server labelled as roster mutations,
  # so this needs the label to be wrong first; it is recorded here as the
  # residual, not hidden.
  prepared=$(_968_prepare 6 '["1","2","4"]')
  [ "$(_968_frontier "$prepared")" = 6 ]
}

@test "read-state: a roster row that IS in quarantine (bootstrap path) is exempt only when the roster list names it (#968)" {
  # The bootstrap path quarantines roster records and marks them imported
  # without a message mapping. Imported-and-unmapped is NOT by itself the
  # exemption: only the roster list is, so a message row that somehow lost its
  # mapping still reads as a hole.
  local wire=550e8400-e29b-41d4-a716-446655440921 roster
  roster=$(jq -nc --arg id "$wire" '
    {type:"sync_pull_message",server_seq:"1",id:$id,
     server_received_at:"2026-07-21T05:59:00.000000Z",
     envelope:{v:1,cipher:"none",key_id:null,blob:"e30="},status:"importable",
     policy_revision:"0",local_security_revision:"0",
     projection:{kind:"member_joined",mutation_id:"019fb4bb-7948-7520-8c16-ab64753e2012",
       member_id:"019fb4bb-7948-7ce9-8e4f-61229dc726cf",name:"dana",occurred_at:"2026-07-21T05:59:00.000000Z"}}')
  printf '%s\n%s\n' "$roster" '{"type":"sync_pull_cursor","next_after":"1"}' |
    storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 >/dev/null
  local db
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT status FROM sync_quarantine WHERE wire_id='$wire';" | tr -d '\r')" = imported ]
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages WHERE wire_id='$wire';" | tr -d '\r')" -eq 0 ]
  _968_apply_messages 2 3
  local prepared
  prepared=$(_968_prepare 3 '["1"]')
  [ "$(_968_frontier "$prepared")" = 3 ]
  [ "$(_968_exact_count "$prepared")" -eq 0 ]
  prepared=$(_968_prepare 3 '[]')
  [ "$(_968_frontier "$prepared")" = 0 ]
}

@test "read-state: a malformed roster list is refused, not partially trusted (#968)" {
  _968_apply_messages 1 2
  run _968_prepare 2 '["1","x"]'
  [ "$status" -eq 13 ]
  run _968_prepare 2 '[1]'
  [ "$status" -eq 13 ]
  run _968_prepare 2 '"1"'
  [ "$status" -eq 13 ]
}

@test "read-state: the roster list bound is swept on both sides -- 10,000 pass and advance the frontier, 10,001 are refused and it does not move (#968)" {
  # Messages sit past ten thousand roster sequences; all are read.
  _968_apply_messages 10001 10002 10003 10004
  local ten_k prepared db
  ten_k=$(jq -nc '[range(1;10001) | tostring]')
  prepared=$(_968_prepare 10004 "$ten_k")
  # Passing is not the claim -- the frontier landing on the right value is.
  [ "$(_968_frontier "$prepared")" = 10004 ]
  [ "$(_968_exact_count "$prepared")" -eq 0 ]
  # One past the bound: refused, and told apart from every other context
  # refusal by its own message (the #911 line number would differ as well).
  run _968_prepare 10004 "$(jq -nc '[range(1;10002) | tostring]')"
  [ "$status" -eq 13 ]
  printf '%s\n' "$output" | grep -Fq "roster_seqs is not a list of at most 10000"
  # And nothing moved: the frontier recorded by the accepted call is still
  # the one on disk, not a partially trusted one.
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT server_seq FROM sync_read_prepared;" | tr -d '\r')" = 10004 ]
}

@test "read-state: a roster sequence is validated against the sequence DOMAIN, not just its shape (#968)" {
  # 9223372036854775808 through 9999999999999999999 are canonical-looking
  # 19-digit decimals past MAX_SEQUENCE. Handed to the INTEGER PRIMARY KEY
  # temp table they are refused with a datatype mismatch that takes the whole
  # read-prepare transaction down -- no 13, no reason (measured in review).
  # MAX itself is a legal sequence.
  _968_apply_messages 1 2
  local prepared
  prepared=$(_968_prepare 2 '["9223372036854775807"]')
  [ "$(_968_frontier "$prepared")" = 2 ]
  run _968_prepare 2 '["9223372036854775808"]'
  [ "$status" -eq 13 ]
  printf '%s\n' "$output" | grep -Fq "not a canonical sequence"
  run _968_prepare 2 '["9999999999999999999"]'
  [ "$status" -eq 13 ]
}

@test "read-state: a roster entry with a trailing newline is refused at the shape check, and the frontier does not move (#968)" {
  # jq's regex engine lets $ match before one trailing newline, so an entry
  # of "1\n" passed a ^..$ shape test; the line-framed per-entry loop then
  # validated "1" and the SQL received (1\n), which SQLite accepts as 1 -- a
  # malformed entry exempting a real sequence (review finding, measured).
  # The shape test is anchored \A..\z now. Each control proves the frontier
  # did not move, because the danger here is advancing, not failing.
  _968_apply_messages 3 4
  local prepared db
  prepared=$(_968_prepare 4 '["1","2"]')
  [ "$(_968_frontier "$prepared")" = 4 ]
  db=$(agmsg_db_path demo)
  run _968_prepare 4 "$(jq -nc '["1\n","2"]')"
  [ "$status" -eq 13 ]
  printf '%s\n' "$output" | grep -Fq "canonical sequences"
  [ "$(agmsg_sqlite "$db" "SELECT server_seq FROM sync_read_prepared;" | tr -d '\r')" = 4 ]
  run _968_prepare 4 "$(jq -nc '["1\n2"]')"
  [ "$status" -eq 13 ]
  [ "$(agmsg_sqlite "$db" "SELECT server_seq FROM sync_read_prepared;" | tr -d '\r')" = 4 ]
  run _968_prepare 4 '[""]'
  [ "$status" -eq 13 ]
  [ "$(agmsg_sqlite "$db" "SELECT server_seq FROM sync_read_prepared;" | tr -d '\r')" = 4 ]
}
