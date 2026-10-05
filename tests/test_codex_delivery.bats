#!/usr/bin/env bats
load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  printf '{"team":"team","agent":"alice","owner":"fixture"}' | bash "$SCRIPTS/delivery-claims.sh" claim >/dev/null
}
teardown() { teardown_test_env; }

@test "Codex claimed delivery: transport state machine and real-store receipts" {
  run node --test "$BATS_TEST_DIRNAME/codex_delivery.test.cjs"
  printf '%s\n' "$output"
  [ "$status" -eq 0 ]
}

@test "watch-once: claim-aware readiness suppresses leases and durable reservations" {
  bash "$SCRIPTS/send.sh" team bob alice pending >/dev/null
  printf '{"team":"team","agent":"alice","owner":"fixture"}' | bash "$SCRIPTS/delivery-claims.sh" claim >/dev/null
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0
  [ "$status" -eq 2 ]
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" 'UPDATE delivery_claims SET expires_at=0;'
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '{broken' > "$TEST_SKILL_DIR/run/read-reservation.team__alice.json"
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq 'read failed'
  rm "$TEST_SKILL_DIR/run/read-reservation.team__alice.json"
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'status=pending count=1 '
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" 'SELECT count(*) FROM messages WHERE read_at IS NULL;')" = 1 ]
}

@test "watch-once: malformed or failed pair peek is a visible error" {
  bash "$SCRIPTS/send.sh" team bob alice pending >/dev/null
  printf '\nagmsg_delivery_list_deliverable() { printf "not-json\\n"; }\n' >> "$SCRIPTS/lib/delivery-claims.sh"
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq 'malformed unread records'
  printf '\nagmsg_delivery_list_deliverable() { return 13; }\n' >> "$SCRIPTS/lib/delivery-claims.sh"
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -Fq 'deliverable read failed'
}

@test "watch-once: oversized-only readiness reports once, waits, and wakes on later fitting messages" {
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "INSERT INTO messages(team,from_agent,to_agent,body) VALUES('team','bob','alice',hex(zeroblob(600000)));"
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0 --max-bytes 1048576
  [ "$status" -eq 3 ]; [ "$output" = 'status=oversized' ]
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0 --max-bytes 1048576 --oversized-reported
  [ "$status" -eq 2 ]; [ "$output" = 'status=timeout' ]
  bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 20 --interval 1 --max-bytes 1048576 --oversized-reported > "$TEST_SKILL_DIR/watcher.out" 2> "$TEST_SKILL_DIR/watcher.err" &
  local watcher=$!
  sleep 2
  kill -0 "$watcher"
  bash "$SCRIPTS/send.sh" team bob alice fitting >/dev/null
  wait "$watcher"
  run cat "$TEST_SKILL_DIR/watcher.out"
  [[ "$output" =~ ^status=pending\ count=1\ max_id=[0-9]+\ oversized=1$ ]] || return 1
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" 'SELECT count(*) FROM delivery_claims;')" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT count(*) FROM events WHERE type='message_read';")" -eq 0 ]
}

@test "watch-once: malformed bounded status and unsupported bounded capability fail explicitly" {
  local facade="$SCRIPTS/lib/delivery-claims.sh"
  cp "$facade" "$TEST_SKILL_DIR/facade-original"
  local malformed
  for malformed in '{"type":"delivery_oversized","count":1}' $'{"type":"delivery_oversized"}\n{"type":"delivery_oversized"}'; do
    cp "$TEST_SKILL_DIR/facade-original" "$facade"
    printf '\nagmsg_delivery_list_deliverable_bounded(){ cat <<\x27FIXTURE_RECORDS\x27\n%s\nFIXTURE_RECORDS\n}\n' "$malformed" >> "$facade"
    run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0 --max-bytes 1048576
    [ "$status" -eq 1 ]; [[ "$output" == *'malformed unread records'* ]] || return 1
  done
  cp "$TEST_SKILL_DIR/facade-original" "$facade"
  printf '\nstorage_describe(){ printf "name=sqlite\\ncapabilities=delivery-claims-v1\\n"; }\n' >> "$SCRIPTS/drivers/storage/sqlite.sh"
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0 --max-bytes 1048576
  [ "$status" -eq 1 ]; [[ "$output" == *delivery-claims-bytes-v1* ]] || return 1
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 0
  [ "$status" -eq 2 ]; [ "$output" = 'status=timeout' ]
}
