#!/usr/bin/env bats
load test_helper

setup() {
  setup_test_env
  export PROJ=/tmp/agmsg-claim-readers
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  export DB="$(bash -c '. "$1/lib/storage.sh"; agmsg_storage_load; agmsg_db_path team' _ "$SCRIPTS")"
  WATCH_PID=""
}
teardown() {
  if [ -n "$WATCH_PID" ]; then kill "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; fi
  teardown_test_env
}
send_one() { bash "$SCRIPTS/send.sh" team bob alice "$1" >/dev/null; }
# Seed exact bytes without command-substitution trimming or sqlite CLI input
# line normalization changing an opaque ID or a header containing CR/LF.
insert_reader_event_exact() {
  local db="$1" value encoded separator=""
  shift
  {
    printf "INSERT INTO events(type,id,team,from_agent,to_agent,body,at) VALUES('message_sent',"
    for value in "$@"; do
      encoded="$(printf '%s' "$value" | od -An -v -t x1 | tr -d ' \n')"
      printf "%sCAST(X'%s' AS TEXT)" "$separator" "$encoded"
      separator=,
    done
    printf ');\n'
  } | sqlite3 "$db"
}
unread() {
  bash -c '. "$1/lib/storage.sh"; agmsg_storage_load; storage_list_unread team alice' _ "$SCRIPTS"
}
claims() { sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_claims;'; }
assert_no_watch_payload_diagnostics() {
  local marker diagnostic
  for marker in "$@"; do
    for diagnostic in "$TEST_SKILL_DIR/err" "$TEST_SKILL_DIR"/run/watch.*.log*; do
      [ -f "$diagnostic" ] || continue
      if grep -qF "$marker" "$diagnostic"; then
        printf 'message body reached watch diagnostics\n'
        return 1
      fi
    done
  done
}
wait_file() {
  local i
  for i in $(seq 1 300); do [ -e "$1" ] && return 0; sleep 0.05; done
  return 1
}
wait_text() {
  local i
  for i in $(seq 1 300); do grep -qF "$2" "$1" 2>/dev/null && return 0; sleep 0.05; done
  return 1
}
wait_watch_stopped() {
  local i
  for i in $(seq 1 300); do
    kill -0 "$WATCH_PID" 2>/dev/null || return 0
    sleep 0.05
  done
  return 1
}
fixture_override() { cat >> "$SCRIPTS/lib/delivery-reader.sh"; }

@test "claimed inbox: output compatibility and exact ACK leave later arrivals unread" {
  send_one first
  export AGMSG_TEST_MARK_BARRIER="$TEST_SKILL_DIR/barrier"
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- &
  local pid=$!
  wait_file "$AGMSG_TEST_MARK_BARRIER.reached"
  [ "$(claims)" = 1 ]
  send_one later
  : > "$AGMSG_TEST_MARK_BARRIER.release"
  wait "$pid"
  grep -qF '1 new message(s):' "$TEST_SKILL_DIR/out"
  grep -qF first "$TEST_SKILL_DIR/out"
  ! grep -qF later "$TEST_SKILL_DIR/out" || return 1
  [[ "$(unread)" == *later* ]] || return 1
  [ "$(claims)" = 0 ]
}

@test "claimed inbox: concurrent reader cannot disclose a reserved message" {
  send_one exclusive
  local barrier="$TEST_SKILL_DIR/barrier"
  AGMSG_TEST_MARK_BARRIER="$barrier" bash "$SCRIPTS/inbox.sh" team alice \
    >"$TEST_SKILL_DIR/one" 2>"$TEST_SKILL_DIR/err" 3>&- &
  local pid=$!
  wait_file "$barrier.reached"
  run bash "$SCRIPTS/inbox.sh" team alice --quiet
  [ "$status" = 0 ]
  [ -z "$output" ]
  : > "$barrier.release"; wait "$pid"
  grep -q exclusive "$TEST_SKILL_DIR/one"
  [ -z "$(unread)" ]
}

@test "claimed inbox: failed renewal releases NOT_SENT but attempted write failure retains UNKNOWN" {
  send_one withheld
  fixture_override <<'SH'
agmsg_delivery_claim_renew() { return 13; }
SH
  run bash "$SCRIPTS/inbox.sh" team alice
  [ "$status" = 13 ]
  [[ "$output" != *withheld* ]] || return 1
  [ "$(claims)" = 0 ]
  sed '$d' "$SCRIPTS/lib/delivery-reader.sh" > "$TEST_SKILL_DIR/reader"
  mv "$TEST_SKILL_DIR/reader" "$SCRIPTS/lib/delivery-reader.sh"
  local rc=0
  bash "$SCRIPTS/inbox.sh" team alice >&- 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" -ne 0 ]
  grep -q 'outcome is unknown' "$TEST_SKILL_DIR/err"
  [ "$(claims)" = 1 ]
  [[ "$(unread)" == *withheld* ]] || return 1
  run bash "$SCRIPTS/inbox.sh" team alice --quiet
  [ "$status" = 0 ]; [ -z "$output" ]
}

@test "claimed inbox: accepted output plus failed ACK stays exit zero and leased unread" {
  send_one accepted
  fixture_override <<'SH'
agmsg_delivery_claim_ack() { return 13; }
SH
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err"
  grep -q accepted "$TEST_SKILL_DIR/out"
  grep -q 'failed to record read state' "$TEST_SKILL_DIR/err"
  [ "$(claims)" = 1 ]
  [[ "$(unread)" == *accepted* ]] || return 1
}

@test "claimed readers: opaque ID and large body are lossless and never external argv" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  storage_init team >/dev/null
  local id=$'-quote\'|space \tline\n日本語' body sql
  printf -v body '%150000s' x
  body="$body"$'\r\n\tlast'
  sql="$(_sqlite_message_sent_sql team bob alice "$body" "$id" '2026-10-02T00:00:00Z')"
  printf '%s\n' "$sql" | sqlite3 "$DB"
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err"
  grep -qF '\n\tlast' "$TEST_SKILL_DIR/out"
  [ "$(wc -c < "$TEST_SKILL_DIR/out")" -gt 150000 ]
  [ -z "$(unread)" ]
  [ "$(claims)" = 0 ]
}

@test "claimed Stop: later team failure preserves earlier output and exact ACK" {
  bash "$SCRIPTS/join.sh" aateam alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" aateam bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/send.sh" aateam bob alice 'earlier payload' >/dev/null
  send_one later
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_claim | sed '1s/agmsg_reader_claim/_real_reader_claim/')"
agmsg_reader_claim() { [ "$1" != team ] || return 13; _real_reader_claim "$@"; }
SH
  bash "$SCRIPTS/check-inbox.sh" claude-code "$PROJ" </dev/null >"$TEST_SKILL_DIR/out"
  jq -e '.decision=="block" and (.reason|contains("earlier payload")) and (.reason|contains("stopped early"))' "$TEST_SKILL_DIR/out"
  ! grep -qF 'bob: later' "$TEST_SKILL_DIR/out" || return 1
  run bash -c '. "$1/lib/storage.sh"; agmsg_storage_load; storage_list_unread aateam alice' _ "$SCRIPTS"
  [ "$status" = 0 ]; [ -z "$output" ]
  [[ "$(unread)" == *later* ]] || return 1
}

@test "claimed PostToolUse: leased rows are hidden and ready rows remain unread" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  send_one reserved
  bash -c '. "$1/lib/storage.sh"; agmsg_storage_load; storage_claim_unread team alice other 60 1' _ "$SCRIPTS" >/dev/null
  send_one ready
  bash "$SCRIPTS/check-inbox.sh" codex "$PROJ" PostToolUse </dev/null >"$TEST_SKILL_DIR/out"
  jq -e '.hookSpecificOutput.additionalContext | contains("ready") and (contains("reserved")|not)' "$TEST_SKILL_DIR/out"
  [[ "$(unread)" == *reserved* ]] || return 1
  [[ "$(unread)" == *ready* ]] || return 1
  [ "$(claims)" = 1 ]
}

@test "claimed watch: a contested earlier row keeps the read frontier gap" {
  send_one gap
  bash -c '. "$1/lib/storage.sh"; agmsg_storage_load; storage_claim_unread team alice other 60 1' _ "$SCRIPTS" >"$TEST_SKILL_DIR/claim"
  send_one delivered
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" delivered
  # Wait for ACK after observing stdout; output and consumption are separate.
  local i
  for i in $(seq 1 100); do [[ "$(unread)" != *delivered* ]] && break; sleep 0.05; done
  [[ "$(unread)" == *gap* ]] || return 1
  [[ "$(unread)" != *delivered* ]] || return 1
  ! grep -qF ' | gap' "$TEST_SKILL_DIR/out" || return 1
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM delivery_claims WHERE owner='other';")" = 1 ]
}

@test "unsupported reader: warning is once per process and legacy remains visible" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  source "$SCRIPTS/lib/delivery-reader.sh"
  storage_describe() { printf 'name=fixture\ncapabilities=old\n'; }
  { agmsg_reader_init fixture; agmsg_reader_init fixture; } 2>"$TEST_SKILL_DIR/err"
  [ "$AGMSG_READER_CLAIMS" = 0 ]
  [ "$(grep -c 'without reservation guarantees' "$TEST_SKILL_DIR/err")" = 1 ]
}

@test "claimed inbox: formatting failure before write releases the whole set" {
  send_one unattempted
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_parse | sed '1s/agmsg_reader_parse/_real_reader_parse/')"
_fixture_parse_count=0
agmsg_reader_parse() {
  _fixture_parse_count=$((_fixture_parse_count + 1))
  [ "$_fixture_parse_count" -ne 1 ] || return 13
  _real_reader_parse "$@"
}
SH
  run bash "$SCRIPTS/inbox.sh" team alice
  [ "$status" = 13 ]
  [[ "$output" != *unattempted* ]] || return 1
  [ "$(claims)" = 0 ]
  [[ "$(unread)" == *unattempted* ]] || return 1
}

@test "claimed Stop: failed final renewal omits only that team and releases it" {
  bash "$SCRIPTS/join.sh" aateam alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" aateam bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/send.sh" aateam bob alice retained >/dev/null
  send_one notsent
  fixture_override <<'SH'
eval "$(declare -f agmsg_delivery_claim_renew | sed '1s/agmsg_delivery_claim_renew/_real_claim_renew/')"
agmsg_delivery_claim_renew() { [ "$1" != team ] || return 13; _real_claim_renew "$@"; }
SH
  bash "$SCRIPTS/check-inbox.sh" claude-code "$PROJ" </dev/null >"$TEST_SKILL_DIR/out"
  jq -e '.reason|contains("retained") and (contains("notsent")|not) and contains("stopped early")' "$TEST_SKILL_DIR/out"
  [ "$(claims)" = 0 ]
  [[ "$(unread)" == *notsent* ]] || return 1
}

@test "claimed Stop: attempted stdout failure retains lease and delivering exit zero" {
  send_one uncertain
  bash "$SCRIPTS/check-inbox.sh" claude-code "$PROJ" </dev/null >&- 2>"$TEST_SKILL_DIR/err"
  grep -q 'outcome is unknown' "$TEST_SKILL_DIR/err"
  [ "$(claims)" = 1 ]
  [[ "$(unread)" == *uncertain* ]] || return 1
}

@test "claimed watch: ownership change before stdout releases NOT_SENT" {
  send_one private
  local barrier="$TEST_SKILL_DIR/barrier" lock
  AGMSG_TEST_MARK_BARRIER="$barrier" AGMSG_WATCH_INTERVAL=60 \
    bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_file "$barrier.reached"
  [ "$(claims)" = 1 ]
  lock="$(_actas_session_path team alice)"
  mkdir -p "$(dirname "$lock")"
  printf 'foreign-owner\n' > "$lock"
  : > "$barrier.release"
  wait_text "$TEST_SKILL_DIR/out" 'changed hands'
  ! grep -qF ' | private' "$TEST_SKILL_DIR/out" || return 1
  [ "$(claims)" = 0 ]
  [[ "$(unread)" == *private* ]] || return 1
}

@test "reader admission: durable reservation is empty but corrupt resolution is an error" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  source "$SCRIPTS/lib/delivery-reader.sh"; agmsg_reader_init fixture
  agmsg_bridge_reservation_status() { return 0; }
  agmsg_delivery_claim_unread() { printf should-not-run; return 99; }
  run agmsg_reader_claim team alice
  [ "$status" = 0 ]; [ -z "$output" ]
  agmsg_bridge_reservation_status() { return 13; }
  run agmsg_reader_claim team alice
  [ "$status" = 13 ]
  [[ "$output" == *'could not be validated'* ]] || return 1
}

@test "reader admission: actual malformed and missing-shape reservations fail visibly" {
  send_one guarded
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  local reservation="$(_agmsg_bridge_guard_path team alice)" content
  mkdir -p "$(dirname "$reservation")"
  for content in '{broken' '{}' '{"type":"antigravity"}'; do
    printf '%s\n' "$content" > "$reservation"
    local rc=0
    bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
    [ "$rc" = 13 ]
    [ ! -s "$TEST_SKILL_DIR/out" ]
    [ -s "$TEST_SKILL_DIR/err" ]
    [[ "$(unread)" == *guarded* ]] || return 1
  done
}

@test "claimed inbox: an opaque ID ending in newline is acknowledged exactly" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  storage_init team >/dev/null
  sqlite3 "$DB" "INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    VALUES('message_sent','trailing'||char(10),'team','bob','alice','ending-newline','2026-10-02T00:00:00Z');"
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err"
  grep -q ending-newline "$TEST_SKILL_DIR/out"
  [ ! -s "$TEST_SKILL_DIR/err" ]
  [ -z "$(unread)" ]
  [ "$(claims)" = 0 ]
}

@test "claimed watch: ownership change after stdout retains UNKNOWN lease" {
  send_one accepted-before-move
  local barrier="$TEST_SKILL_DIR/consume" lock expected_unread
  expected_unread="$(unread)"
  export AGMSG_TEST_POLL_COMPLETE="$TEST_SKILL_DIR/poll-complete"
  fixture_override <<'SH'
sleep() {
  if [ "$#" -eq 1 ] && [ "$1" = 60 ]; then
    : > "$AGMSG_TEST_POLL_COMPLETE"
  fi
  command sleep "$@"
}
SH
  AGMSG_TEST_CONSUME_BARRIER="$barrier" AGMSG_WATCH_INTERVAL=60 \
    bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_file "$barrier.reached"
  grep -q accepted-before-move "$TEST_SKILL_DIR/out"
  lock="$(_actas_session_path team alice)"
  mkdir -p "$(dirname "$lock")"
  printf 'foreign-owner\n' > "$lock"
  : > "$barrier.release"
  wait_text "$TEST_SKILL_DIR/out" 'reservation retained until expiry'
  # The broad watcher still processes other pairs after that diagnostic.
  # Observe at the complete poll's unchanged 60s sleep boundary,
  # so the zero-timeout SQL oracle cannot race the next pair's transaction.
  wait_file "$AGMSG_TEST_POLL_COMPLETE"
  kill -0 "$WATCH_PID"
  [ "$(claims)" = 1 ]
  [ "$(unread)" = "$expected_unread" ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  kill -0 "$WATCH_PID"
}

@test "claimed watch: control ACK failure cannot trigger teardown" {
  send_one ctrl:despawn
  fixture_override <<'SH'
agmsg_delivery_claim_ack() { return 13; }
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" 'teardown was not attempted'
  bash "$SCRIPTS/identities.sh" "$PROJ" claude-code | grep -q alice
  [ "$(claims)" = 1 ]
  [[ "$(unread)" == *ctrl:despawn* ]] || return 1
}

@test "claimed watch: broad subscription consumes control without process actions" {
  send_one ctrl:despawn
  send_one after-control
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" after-control
  ! grep -q 'ctrl:despawn' "$TEST_SKILL_DIR/out" || return 1
  bash "$SCRIPTS/identities.sh" "$PROJ" claude-code | grep -q alice
  [[ "$(unread)" != *ctrl:despawn* ]] || return 1
}

@test "claimed watch: a delivered batch counts toward the host re-arm decision" {
  send_one claimed-renewal-probe
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_control_metadata | sed '1s/agmsg_reader_control_metadata/_rearm_reader_control/')"
agmsg_reader_control_metadata() {
  _rearm_reader_control "$@" || return $?
  # Advance only the fixture's elapsed clock after the real ACK. This tests
  # the next-cycle renewal decision without depending on machine startup time.
  if [ "$1" = ack ]; then SECONDS=7200; fi
}
SH
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice --max-seconds=3600 \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" 'agmsg watch: re-arm'
  wait "$WATCH_PID"
  WATCH_PID=""
  [ "$(grep -cF claimed-renewal-probe "$TEST_SKILL_DIR/out")" = 1 ]
  grep -qF -- 'alice --max-seconds=3600' "$TEST_SKILL_DIR/out"
  [ -z "$(unread)" ]
  [ "$(claims)" = 0 ]
}

@test "unsupported inbox: legacy stdout and quiet stay compatible with visible warning" {
  send_one legacy-payload
  sed 's/,delivery-claims-v1//;s/,delivery-claims-bytes-v1//' "$SCRIPTS/drivers/storage/sqlite.sh" > "$TEST_SKILL_DIR/driver"
  mv "$TEST_SKILL_DIR/driver" "$SCRIPTS/drivers/storage/sqlite.sh"
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err"
  grep -q '1 new message(s):' "$TEST_SKILL_DIR/out"
  grep -q legacy-payload "$TEST_SKILL_DIR/out"
  grep -q 'without reservation guarantees' "$TEST_SKILL_DIR/err"
  [ -z "$(unread)" ]
  bash "$SCRIPTS/inbox.sh" team alice --quiet >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err"
  [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q 'without reservation guarantees' "$TEST_SKILL_DIR/err"
}

@test "claimed inbox: bounded invocation leaves excess backlog unread for the next call" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  storage_init team >/dev/null
  sqlite3 "$DB" "WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<1001)
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    SELECT 'message_sent','bounded-'||n,'team','bob','alice','body-'||n,'2026-10-02T00:00:00Z' FROM numbers;"
  export AGMSG_FIXTURE_PROFILE="$TEST_SKILL_DIR/reader-timing"
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_claim | sed '1s/agmsg_reader_claim/_profile_reader_claim/')"
eval "$(declare -f agmsg_reader_parse | sed '1s/agmsg_reader_parse/_profile_reader_parse/')"
eval "$(declare -f agmsg_reader_control_metadata | sed '1s/agmsg_reader_control_metadata/_profile_reader_control/')"
agmsg_reader_claim() {
  local start=$SECONDS rc=0
  _profile_reader_claim "$@" || rc=$?
  printf 'claim %s\n' "$((SECONDS-start))" >> "$AGMSG_FIXTURE_PROFILE"
  return "$rc"
}
agmsg_reader_parse() {
  local start=$SECONDS rc=0
  _profile_reader_parse "$@" || rc=$?
  printf 'parse %s\n' "$((SECONDS-start))" >> "$AGMSG_FIXTURE_PROFILE"
  return "$rc"
}
agmsg_reader_control_metadata() {
  local start=$SECONDS rc=0
  _profile_reader_control "$@" || rc=$?
  printf '%s %s\n' "$1" "$((SECONDS-start))" >> "$AGMSG_FIXTURE_PROFILE"
  return "$rc"
}
SH
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || {
    cat "$TEST_SKILL_DIR/err" >&2
    sqlite3 "$DB" "SELECT COUNT(*),MIN(expires_at),MAX(expires_at),strftime('%s','now') FROM delivery_claims;" >&2
    return 1
  }
  grep -q '1000 new message(s):' "$TEST_SKILL_DIR/out"
  [ "$(unread | wc -l | tr -d ' ')" = 1 ]
  [ ! -s "$TEST_SKILL_DIR/err" ]
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/remaining" 2>"$TEST_SKILL_DIR/err"
  grep -q '1 new message(s):' "$TEST_SKILL_DIR/remaining"
  [ -z "$(unread)" ]
  [ ! -s "$TEST_SKILL_DIR/err" ]
  while IFS= read -r timing; do printf '# reader phase seconds: %s\n' "$timing" >&3; done < "$AGMSG_FIXTURE_PROFILE"
}

@test "claimed readers: mismatched pair nontext recipient and duplicate IDs are rejected before stdout" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  source "$SCRIPTS/lib/delivery-reader.sh"; agmsg_reader_init fixture
  local token document bad patch
  printf -v token '%064d' 0
  document="{\"id\":\"one\",\"from\":\"bob\",\"body\":\"private\",\"at\":\"2026-10-02\",\"team\":\"team\",\"to\":\"alice\",\"claim_token\":\"$token\"}"
  agmsg_reader_parse "$document" inbox 1 team alice
  for patch in '.team="other"' '.to="other"' '.to=17'; do
    bad="$(printf '%s' "$document" | jq -c "$patch")"
    run agmsg_reader_parse "$bad" inbox 1 team alice
    [ "$status" = 13 ]
  done
  run agmsg_reader_parse "$document"$'\n'"$document" inbox 1 team alice
  [ "$status" = 13 ]
}

@test "claimed inbox: raw NUL from a capability driver cannot become changed valid JSON" {
  send_one untouched
  cat >> "$SCRIPTS/drivers/storage/sqlite.sh" <<'SH'
storage_claim_unread() {
  printf '{"id":"one","team":"team","from":"bob","to":"alice","at":"2026-10-02","body":"be\000fore","claim_token":"%064d"}\n' 0
}
SH
  local rc=0
  bash "$SCRIPTS/inbox.sh" team alice >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]
  [ ! -s "$TEST_SKILL_DIR/out" ]
  [[ "$(unread)" == *untouched* ]] || return 1
}

@test "claimed watch: accepted targeted control reaches teardown before any later claim can fail" {
  send_one ctrl:despawn
  send_one later
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_claim | sed '1s/agmsg_reader_claim/_real_reader_claim/')"
agmsg_reader_claim() {
  [ ! -e "$SKILL_DIR/claimed-once" ] || return 13
  : > "$SKILL_DIR/claimed-once"
  _real_reader_claim "$@"
}
SH
  cat > "$SCRIPTS/reset.sh" <<'SH'
#!/usr/bin/env bash
printf 'reset attempted\n' > "$(cd "$(dirname "$0")/.." && pwd)/reset-attempted"
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_file "$TEST_SKILL_DIR/reset-attempted"
  [[ "$(unread)" != *ctrl:despawn* ]] || return 1
  [[ "$(unread)" == *later* ]] || return 1
  # The later row shared the first group's token but was never attempted.
  [ "$(claims)" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 1 ]
}

@test "claimed watch: normal groups ACK exact 32-row subsets before the next group" {
  bulk_send_direct team bob alice 33 40 GROUP
  fixture_override <<'SH'
eval "$(declare -f agmsg_delivery_claim_ack | sed '1s/agmsg_delivery_claim_ack/_group_real_ack/')"
agmsg_delivery_claim_ack() {
  _group_real_ack "$@" || return $?
  printf '%s\n' "$(( $# - 4 ))" >> "$SKILL_DIR/group-acks"
}
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" GROUP-32-
  wait_text "$TEST_SKILL_DIR/group-acks" 1
  [ "$(cat "$TEST_SKILL_DIR/group-acks")" = $'32\n1' ]
  [ "$(grep -c 'GROUP-' "$TEST_SKILL_DIR/out")" = 33 ]
  [ -z "$(unread)" ]
  [ "$(claims)" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 33 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 33 ]
}

@test "claimed watch: normal prefix then targeted control ACKs before teardown and releases only the tail" {
  send_one before-control
  send_one ctrl:despawn
  send_one after-control
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_claim | sed '1s/agmsg_reader_claim/_group_real_claim/')"
agmsg_reader_claim() {
  [ ! -e "$SKILL_DIR/group-claimed" ] || return 13
  : > "$SKILL_DIR/group-claimed"
  _group_real_claim "$@"
}
SH
  cat > "$SCRIPTS/reset.sh" <<'SH'
#!/usr/bin/env bash
sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;' > "$(cd "$(dirname "$0")/.." && pwd)/reset-receipts"
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/reset-receipts" 2
  grep -qF ' | before-control' "$TEST_SKILL_DIR/out"
  ! grep -qF after-control "$TEST_SKILL_DIR/out" || return 1
  ! grep -qF ctrl:despawn "$TEST_SKILL_DIR/out" || return 1
  local remaining
  remaining="$(unread)"
  [[ "$remaining" == *after-control* ]] || return 1
  [[ "$remaining" != *before-control* && "$remaining" != *ctrl:despawn* ]] || return 1
  [ "$(claims)" = 0 ]
}

@test "claimed watch: a failed grouped write retains all attempted members UNKNOWN" {
  send_one first-attempted
  send_one second-attempted
  send_one third-attempted
  local rc=0
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >&- 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 0 ]
  grep -qF 'write outcome UNKNOWN' "$TEST_SKILL_DIR/err"
  assert_no_watch_payload_diagnostics first-attempted second-attempted third-attempted
  [ "$(claims)" = 3 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  local remaining
  remaining="$(unread)"
  [[ "$remaining" == *first-attempted* && "$remaining" == *second-attempted* && "$remaining" == *third-attempted* ]] || return 1
}

@test "claimed watch: failed serial write retains current UNKNOWN but releases untouched control and tail" {
  send_one attempted-prefix
  send_one ctrl:despawn
  send_one untouched-tail
  # The tail exercises both the short control ID and the >512-hex-digit
  # decoder pipeline, preserving opaque trailing newlines exactly.
  local tail_id tail_hex
  printf -v tail_id '%0300d' 0
  tail_id="$tail_id"$'\nopaque-tail\n'
  tail_hex="$(printf '%s' "$tail_id" | od -An -v -t x1 | tr -d ' \n' | tr 'a-f' 'A-F')"
  sqlite3 "$DB" "UPDATE events SET id=CAST(X'$tail_hex' AS TEXT)
    WHERE type='message_sent' AND body='untouched-tail';"
  [ "$(sqlite3 "$DB" "SELECT hex(id) FROM events WHERE type='message_sent' AND body='untouched-tail';")" = "$tail_hex" ]
  local rc=0
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >&- 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 0 ]
  grep -qF 'write outcome UNKNOWN' "$TEST_SKILL_DIR/err"
  assert_no_watch_payload_diagnostics attempted-prefix ctrl:despawn untouched-tail
  local retained_count
  retained_count="$(claims)"
  [ "$retained_count" = 1 ] || {
    printf 'serial UNKNOWN retained claims: expected=1 actual=%s\n' "$retained_count"
    # Counts and known error categories only: never print message bodies,
    # opaque IDs, tokens, or installation paths into CI failure diagnostics.
    sqlite3 "$DB" "SELECT 'active='||COUNT(*)||',min_ttl='||COALESCE(MIN(c.expires_at-strftime('%s','now')),0)||
      ',attempted='||COALESCE(SUM(e.body='attempted-prefix'),0)||
      ',control='||COALESCE(SUM(e.body='ctrl:despawn'),0)||
      ',tail='||COALESCE(SUM(e.body='untouched-tail'),0)
      FROM delivery_claims c JOIN events e ON e.id=c.msg_id WHERE e.type='message_sent';
      SELECT 'receipts='||COUNT(*) FROM delivery_ack_receipts;
      SELECT 'reads='||COUNT(*) FROM events WHERE type='message_read';"
    local reason
    for reason in 'invalid_claim' 'invalid_arguments' 'runtime_error' 'could not release' \
      'Bad file descriptor' 'write error' 'write outcome UNKNOWN' 'database is locked'; do
      if grep -qF "$reason" "$TEST_SKILL_DIR/err"; then
        printf 'stderr category: %s\n' "$reason"
      fi
    done
    return 1
  }
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT e.body FROM delivery_claims c JOIN events e ON e.id=c.msg_id WHERE e.type='message_sent';")" = attempted-prefix ]
  local remaining
  remaining="$(unread)"
  [[ "$remaining" == *attempted-prefix* && "$remaining" == *ctrl:despawn* && "$remaining" == *untouched-tail* ]] || return 1
}

@test "claimed watch: failed last serial write has no tail and cannot disclose through diagnostics" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  storage_init team >/dev/null
  insert_reader_event_exact "$DB" last-serial-id team $'sender\r\nheader' alice \
    last-serial-attempted '2026-10-03T00:00:00Z'
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_parse | sed '1s/agmsg_reader_parse/_serial_real_parse/')"
agmsg_reader_parse() {
  _serial_real_parse "$@" || return $?
  [ "$2" != watch-group ] || printf '%s\n' "$AGMSG_READER_GROUP_KIND" > "$SKILL_DIR/prepared-kind"
}
SH
  local rc=0
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >&- 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 0 ]
  [ "$(cat "$TEST_SKILL_DIR/prepared-kind")" = rows ]
  grep -qF 'write outcome UNKNOWN' "$TEST_SKILL_DIR/err"
  assert_no_watch_payload_diagnostics last-serial-attempted
  [ "$(claims)" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [[ "$(unread)" == *last-serial-attempted* ]] || return 1
}

@test "claimed watch: a failed UNKNOWN buffer drain retains all leases without logging or teardown" {
  send_one failed-drain-attempted
  send_one ctrl:despawn
  send_one failed-drain-tail
  fixture_override <<'SH'
_fixture_emit_attempted=0
_fixture_drain_failures=0
printf() {
  if [ "$_fixture_emit_attempted" = 1 ] && [ "$#" = 2 ] &&
     [ "$1" = '%s' ] && [ -z "$2" ]; then
    _fixture_drain_failures=$((_fixture_drain_failures + 1))
    : > "$SKILL_DIR/drain-failed-$_fixture_drain_failures"
    return 1
  fi
  if [ "$#" = 2 ] && [ "$1" = '%s' ] && [[ "$2" == *' | failed-drain-attempted'* ]]; then
    _fixture_emit_attempted=1
  fi
  builtin printf "$@"
}
agmsg_delivery_claim_release() { : > "$SKILL_DIR/release-attempted"; return 13; }
SH
  cat > "$SCRIPTS/reset.sh" <<'SH'
#!/usr/bin/env bash
: > "$(cd "$(dirname "$0")/.." && pwd)/reset-attempted"
SH
  local rc=0
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >&- 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 0 ]
  [ -f "$TEST_SKILL_DIR/drain-failed-1" ]
  [ ! -e "$TEST_SKILL_DIR/drain-failed-2" ]
  [ ! -e "$TEST_SKILL_DIR/release-attempted" ]
  [ ! -e "$TEST_SKILL_DIR/reset-attempted" ]
  assert_no_watch_payload_diagnostics failed-drain-attempted ctrl:despawn failed-drain-tail 'write outcome UNKNOWN'
  [ "$(claims)" = 3 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  local remaining
  remaining="$(unread)"
  [[ "$remaining" == *failed-drain-attempted* && "$remaining" == *ctrl:despawn* && "$remaining" == *failed-drain-tail* ]] || return 1
}

@test "claimed watch: uncertain serial ACK keeps current and releases untouched tail without teardown" {
  send_one accepted-prefix
  send_one ctrl:despawn
  send_one untouched-tail
  fixture_override <<'SH'
agmsg_delivery_claim_ack() { return 13; }
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" 'acknowledgement is uncertain'
  grep -qF ' | accepted-prefix' "$TEST_SKILL_DIR/out"
  ! grep -qF ' | untouched-tail' "$TEST_SKILL_DIR/out" || return 1
  [ "$(claims)" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT e.body FROM delivery_claims c JOIN events e ON e.id=c.msg_id WHERE e.type='message_sent';")" = accepted-prefix ]
  bash "$SCRIPTS/identities.sh" "$PROJ" claude-code | grep -q alice
}

@test "claimed watch: tail release failure cannot undo an acknowledged targeted control" {
  send_one ctrl:despawn
  send_one unreleased-tail
  fixture_override <<'SH'
agmsg_delivery_claim_release() { return 13; }
SH
  cat > "$SCRIPTS/reset.sh" <<'SH'
#!/usr/bin/env bash
sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;' > "$(cd "$(dirname "$0")/.." && pwd)/reset-receipts"
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/reset-receipts" 1
  [ "$(claims)" = 1 ]
  local remaining
  remaining="$(unread)"
  [[ "$remaining" == *unreleased-tail* && "$remaining" != *ctrl:despawn* ]] || return 1
  grep -qF 'could not release an unattempted delivery' "$TEST_SKILL_DIR/err"
}

@test "claimed watch: Unicode fields and opaque IDs retain exact bytes through grouped preparation" {
  local uteam='チーム café' ufrom='送信者 🧪' uto='受信者 é'
  bash "$SCRIPTS/join.sh" "$uteam" "$uto" claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" "$uteam" "$ufrom" claude-code "$PROJ" >/dev/null
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  local udb id body prefix expected
  storage_init "$uteam" >/dev/null
  udb="$(agmsg_db_path "$uteam")"
  id=$'-quote\'|space\tline\n日本語🧪\n'
  prefix='日本語 🧪 café é " apostrophe '\'' literal \u0000 \'
  prefix="$prefix AGMSG_READER_PAYLOAD AGMSG_READER_END"$'\001'
  body="$prefix"$'\tline\nnext\rEND'
  insert_reader_event_exact "$udb" "$id" "$uteam" "$ufrom" "$uto" "$body" '2026-10-03T00:00:00Z'
  [ "$(sqlite3 "$udb" "SELECT hex(id) FROM events WHERE type='message_sent';")" = \
    "$(printf '%s' "$id" | od -An -v -t x1 | tr -d ' \n' | tr 'a-f' 'A-F')" ]
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_parse | sed '1s/agmsg_reader_parse/_unicode_real_parse/')"
agmsg_reader_parse() {
  _unicode_real_parse "$@" || return $?
  [ "$2" != watch-group ] || printf '%s\n' "$AGMSG_READER_GROUP_KIND" > "$SKILL_DIR/prepared-kind"
}
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code "$uto" \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" nextEND
  local i remaining
  for i in $(seq 1 100); do
    remaining="$(storage_list_unread "$uteam" "$uto")"
    [ -z "$remaining" ] && break
    sleep 0.05
  done
  [ -z "$remaining" ]
  printf -v expected '%s | %s | %s → %s | %s\\tline\\nnextEND\n' \
    '2026-10-03T00:00:00Z' "$uteam" "$ufrom" "$uto" "$prefix"
  printf '%s' "$expected" > "$TEST_SKILL_DIR/expected"
  cmp "$TEST_SKILL_DIR/expected" "$TEST_SKILL_DIR/out"
  [ "$(cat "$TEST_SKILL_DIR/prepared-kind")" = text ]
  [ "$(sqlite3 "$udb" "SELECT COUNT(*) FROM delivery_ack_receipts WHERE team='チーム café';")" = 1 ]
  local got_id
  got_id="$(sqlite3 "$udb" "SELECT hex(msg_id) FROM delivery_ack_receipts WHERE team='チーム café';")"
  [ "$got_id" = "$(printf '%s' "$id" | od -An -v -t x1 | tr -d ' \n' | tr 'a-f' 'A-F')" ]
}

@test "claimed watch: header CRLF uses lossless hex rows and exact ACK" {
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  storage_init team >/dev/null
  local sender=$'sender\r\nAGMSG_READER_PAYLOAD' stamp=$'2026-10-03\r\nAGMSG_READER_END'
  local id=$'header-opaque\n日本語' body='header-fallback-body'
  insert_reader_event_exact "$DB" "$id" team "$sender" alice "$body" "$stamp"
  [ "$(sqlite3 "$DB" "SELECT hex(from_agent)||'|'||hex(at) FROM events WHERE type='message_sent';")" = \
    "$(printf '%s' "$sender" | od -An -v -t x1 | tr -d ' \n' | tr 'a-f' 'A-F')|$(printf '%s' "$stamp" | od -An -v -t x1 | tr -d ' \n' | tr 'a-f' 'A-F')" ]
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_parse | sed '1s/agmsg_reader_parse/_header_real_parse/')"
agmsg_reader_parse() {
  _header_real_parse "$@" || return $?
  [ "$2" != watch-group ] || printf '%s\n' "$AGMSG_READER_GROUP_KIND" > "$SKILL_DIR/prepared-kind"
}
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" "$body"
  local i remaining
  for i in $(seq 1 100); do
    remaining="$(unread)"
    [ -z "$remaining" ] && break
    sleep 0.05
  done
  [ -z "$remaining" ]
  printf '%s | team | %s → alice | %s\n' "$stamp" "$sender" "$body" > "$TEST_SKILL_DIR/expected"
  cmp "$TEST_SKILL_DIR/expected" "$TEST_SKILL_DIR/out"
  [ "$(cat "$TEST_SKILL_DIR/prepared-kind")" = rows ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT hex(msg_id) FROM delivery_ack_receipts;')" = \
    "$(printf '%s' "$id" | od -An -v -t x1 | tr -d ' \n' | tr 'a-f' 'A-F')" ]


}

@test "claimed watch: decoded NUL at the parser boundary refuses output and retains an undisclosed lease" {
  send_one parser-body
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_claim | sed '1s/agmsg_reader_claim/_nul_real_claim/')"
agmsg_reader_claim() {
  local result
  result="$(_nul_real_claim "$@")" || return $?
  # The real facade already rejects this. Inject after it to exercise the
  # reader's independent guard before SQLite can truncate decoded NUL text.
  printf '%s\n' "$result" | sed 's/parser-body/\\u0000/'
}
SH
  run env AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice
  [ "$status" = 75 ]
  [[ "$output" == *'delivery preparation failed'* ]] || return 1
  [[ "$output" != *' | parser-body'* ]] || return 1
  [ "$(claims)" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [[ "$(unread)" == *parser-body* ]] || return 1
}

@test "claimed watch: a failed SQL quote producer cannot disclose and releases after validated retry" {
  send_one withheld-on-quote-failure
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_parse | sed '1s/agmsg_reader_parse/_quote_real_parse/')"
agmsg_reader_parse() { AGMSG_TEST_QUOTE_ARMED=1 _quote_real_parse "$@"; }
SH
  local shimbin="$TEST_SKILL_DIR/quote-bin" real_sed
  real_sed="$(command -v sed)"
  mkdir -p "$shimbin"
  cat > "$shimbin/sed" <<SH
#!/usr/bin/env bash
if [ "\${AGMSG_TEST_QUOTE_ARMED:-}" = 1 ] && [ "\${1:-}" = "s/'/''/g" ] && [ ! -e "$TEST_SKILL_DIR/quote-failed-once" ]; then
  : > "$TEST_SKILL_DIR/quote-failed-once"
  cat >/dev/null
  exit 13
fi
exec "$real_sed" "\$@"
SH
  chmod +x "$shimbin/sed"
  PATH="$shimbin:$PATH" AGMSG_WATCH_INTERVAL=60 \
    bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" 'delivery preparation failed'
  wait_watch_stopped
  local rc=0
  wait "$WATCH_PID" || rc=$?
  WATCH_PID=""
  [ "$rc" = 75 ]
  [ -e "$TEST_SKILL_DIR/quote-failed-once" ]
  ! grep -qF ' | withheld-on-quote-failure' "$TEST_SKILL_DIR/out" || return 1
  # The second parse validates the real token and IDs before NOT_SENT release.
  [ "$(claims)" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [[ "$(unread)" == *withheld-on-quote-failure* ]] || return 1
}

@test "claimed watch: malformed private frames expose no globals or payload and release NOT_SENT" {
  send_one frame-withheld-first
  send_one frame-withheld-second
  fixture_override <<'SH'
eval "$(declare -f _agmsg_reader_watch_frame | sed '1s/_agmsg_reader_watch_frame/_frame_real_read/')"
_agmsg_reader_watch_frame() {
  local tmp="$1.fault" rc=0
  (umask 077; : > "$tmp") || return 13
  case "$AGMSG_TEST_FRAME_FAULT" in
    missing-header) sed '1d' "$1" > "$tmp" ;;
    bad-header) sed '1s/^text|/bad|/' "$1" > "$tmp" ;;
    extra-header) sed '1s/$/|extra/' "$1" > "$tmp" ;;
    bad-id) sed '2s/.*/00/' "$1" > "$tmp" ;;
    duplicate-id) awk 'NR==2 { id=$0 } NR==3 { print id; next } { print }' "$1" > "$tmp" ;;
    missing-marker) sed '/^AGMSG_READER_PAYLOAD$/d' "$1" > "$tmp" ;;
    missing-end) sed '$d' "$1" > "$tmp" ;;
    header-nul) { printf '\000'; cat "$1"; } > "$tmp" ;;
    payload-nul) { cat "$1"; printf '\000'; } > "$tmp" ;;
    *) rm -f "$tmp"; return 13 ;;
  esac
  cat "$tmp" > "$1" || return 13
  rm -f "$tmp" || return 13
  _frame_real_read "$1" || rc=$?
  printf '%s|%s|%s|%s|%s|%s\n' "${#AGMSG_READER_IDS[@]}" "${#AGMSG_READER_TOKEN}" \
    "${#AGMSG_READER_TEXT}" "${#AGMSG_READER_ROWS}" "${#AGMSG_READER_METADATA}" \
    "${#AGMSG_READER_GROUP_KIND}" > "$SKILL_DIR/frame-globals"
  return "$rc"
}
SH
  local mode rc file
  mkdir "$TEST_SKILL_DIR/frame-tmp"
  for mode in missing-header bad-header extra-header bad-id duplicate-id missing-marker missing-end header-nul payload-nul; do
    AGMSG_TEST_FRAME_FAULT="$mode" TMPDIR="$TEST_SKILL_DIR/frame-tmp" AGMSG_WATCH_INTERVAL=60 \
      bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
      >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
    WATCH_PID=$!
    wait_text "$TEST_SKILL_DIR/out" 'delivery preparation failed'
    wait_watch_stopped
    rc=0; wait "$WATCH_PID" || rc=$?
    WATCH_PID=""
    [ "$rc" = 75 ]
    [ "$(cat "$TEST_SKILL_DIR/frame-globals")" = '0|0|0|0|0|0' ]
    ! grep -qF ' | frame-withheld-' "$TEST_SKILL_DIR/out" || return 1
    [ "$(claims)" = 0 ]
    [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
    [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
    for file in "$TEST_SKILL_DIR/frame-tmp"/agmsg-watch-prepared.*; do
      [ ! -e "$file" ]
    done
  done
  local remaining
  remaining="$(unread)"
  [[ "$remaining" == *frame-withheld-first* && "$remaining" == *frame-withheld-second* ]] || return 1
  # A rows payload must repeat the exact prefix identity, not merely a valid
  # hex ID. Exercise this private boundary without attempting any handoff.
  source "$SCRIPTS/lib/storage.sh"; agmsg_storage_load
  source "$SCRIPTS/lib/delivery-reader.sh"
  local token token_hex
  printf -v token '%064d' 0
  token_hex="$(printf '%s' "$token" | od -An -v -t x1 | tr -d ' \n' | tr 'a-f' 'A-F')"
  file="$TEST_SKILL_DIR/mismatched-frame"
  (umask 077; printf 'rows|1|%s\n61\nAGMSG_READER_PAYLOAD\n62|62|78|74|74|61|%s\nAGMSG_READER_END\n' \
    "$token" "$token_hex" > "$file")
  AGMSG_READER_IDS=(); AGMSG_READER_TOKEN=""; AGMSG_READER_TEXT=""
  AGMSG_READER_ROWS=""; AGMSG_READER_METADATA=""; AGMSG_READER_GROUP_KIND=""
  rc=0; _frame_real_read "$file" || rc=$?
  [ "$rc" = 13 ]
  [ "${#AGMSG_READER_IDS[@]}" = 0 ]
  [ -z "$AGMSG_READER_TOKEN$AGMSG_READER_TEXT$AGMSG_READER_ROWS$AGMSG_READER_METADATA$AGMSG_READER_GROUP_KIND" ]
}

@test "claimed watch: successful SQL output with failed producer status is never handed off" {
  send_one status-withheld
  fixture_override <<'SH'
eval "$(declare -f agmsg_reader_parse | sed '1s/agmsg_reader_parse/_status_real_parse/')"
agmsg_reader_parse() {
  if [ "$2" = watch-group ]; then
    AGMSG_TEST_SQL_STATUS=1 _status_real_parse "$@"
  else
    _status_real_parse "$@"
  fi
}
eval "$(declare -f agmsg_sqlite | sed '1s/agmsg_sqlite/_status_real_sqlite/')"
agmsg_sqlite() {
  _status_real_sqlite "$@" || return $?
  if [ "${AGMSG_TEST_SQL_STATUS:-}" = 1 ]; then
    : > "$SKILL_DIR/sql-output-refused"
    return 13
  fi
}
SH
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
  WATCH_PID=$!
  wait_text "$TEST_SKILL_DIR/out" 'delivery preparation failed'
  wait_watch_stopped
  local rc=0
  wait "$WATCH_PID" || rc=$?
  WATCH_PID=""
  [ "$rc" = 75 ]
  [ -e "$TEST_SKILL_DIR/sql-output-refused" ]
  ! grep -qF ' | status-withheld' "$TEST_SKILL_DIR/out" || return 1
  [ "$(claims)" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [[ "$(unread)" == *status-withheld* ]] || return 1
}

@test "claimed watch: private capture tool failures cannot authorize valid-looking output" {
  send_one capture-withheld
  fixture_override <<'SH'
eval "$(declare -f _agmsg_reader_watch_frame | sed '1s/_agmsg_reader_watch_frame/_capture_real_read/')"
_agmsg_reader_watch_frame() {
  local rc=0
  AGMSG_TEST_CAPTURE_ARMED=1 _capture_real_read "$@" || rc=$?
  printf '%s|%s|%s|%s|%s|%s\n' "${#AGMSG_READER_IDS[@]}" "${#AGMSG_READER_TOKEN}" \
    "${#AGMSG_READER_TEXT}" "${#AGMSG_READER_ROWS}" "${#AGMSG_READER_METADATA}" \
    "${#AGMSG_READER_GROUP_KIND}" > "$SKILL_DIR/capture-globals"
  return "$rc"
}
SH
  local tool real shimbin="$TEST_SKILL_DIR/capture-bin" rc file
  mkdir "$shimbin" "$TEST_SKILL_DIR/capture-tmp"
  for tool in tr wc cat; do
    real="$(command -v "$tool")"
    cat > "$shimbin/$tool" <<SH
#!/usr/bin/env bash
if [ "\${AGMSG_TEST_CAPTURE_ARMED:-}" = 1 ] && [ "\${AGMSG_TEST_CAPTURE_TOOL:-}" = "$tool" ]; then
  "$real" "\$@" || exit \$?
  : > "$TEST_SKILL_DIR/capture-failed-$tool"
  exit 13
fi
exec "$real" "\$@"
SH
    chmod +x "$shimbin/$tool"
  done
  for tool in tr wc cat; do
    PATH="$shimbin:$PATH" AGMSG_TEST_CAPTURE_TOOL="$tool" \
      TMPDIR="$TEST_SKILL_DIR/capture-tmp" AGMSG_WATCH_INTERVAL=60 \
      bash "$SCRIPTS/watch.sh" fixture "$PROJ" claude-code alice \
      >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" 3>&- 4>&- &
    WATCH_PID=$!
    wait_text "$TEST_SKILL_DIR/out" 'delivery preparation failed'
    wait_watch_stopped
    rc=0; wait "$WATCH_PID" || rc=$?
    WATCH_PID=""
    [ "$rc" = 75 ]
    [ -e "$TEST_SKILL_DIR/capture-failed-$tool" ]
    [ "$(cat "$TEST_SKILL_DIR/capture-globals")" = '0|0|0|0|0|0' ]
    ! grep -qF ' | capture-withheld' "$TEST_SKILL_DIR/out" || return 1
    [ "$(claims)" = 0 ]
    [ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
    [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
    for file in "$TEST_SKILL_DIR/capture-tmp"/agmsg-watch-prepared.*; do
      [ ! -e "$file" ]
    done
  done
  [[ "$(unread)" == *capture-withheld* ]] || return 1
}
