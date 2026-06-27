#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watch-once-proj"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

@test "watch-once: exits 2 on timeout when no unread inbound exists" {
  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "watch-once: reports existing unread inbound without marking it read" {
  bash "$SCRIPTS/send.sh" team bob alice "hello pending" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=pending" ]]
  [[ "$output" =~ "count=1" ]]

  run bash "$SCRIPTS/inbox.sh" team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello pending" ]]
}

@test "watch-once: ignores messages already read by inbox.sh" {
  bash "$SCRIPTS/send.sh" team bob alice "read already" >/dev/null
  bash "$SCRIPTS/inbox.sh" team alice >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "watch-once: ignores messages addressed to another agent" {
  bash "$SCRIPTS/send.sh" team alice bob "for bob" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=timeout" ]]
}

@test "watch-once: detects a message that arrives after it starts" {
  bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 5 --interval 1 \
    >"$TEST_SKILL_DIR/watch-once.out" 2>"$TEST_SKILL_DIR/watch-once.err" 3>&- &
  local pid=$!
  sleep 1
  bash "$SCRIPTS/send.sh" team bob alice "arrived later" >/dev/null
  wait "$pid"
  local status=$?

  [ "$status" -eq 0 ]
  grep -q "status=pending" "$TEST_SKILL_DIR/watch-once.out"
}

@test "watch-once: skips a subscription held by another live session" {
  setup_live_owner "$TEST_SKILL_DIR/run" other-sid
  bash "$SCRIPTS/actas-claim.sh" "$PROJ" codex alice other-sid >/dev/null
  bash "$SCRIPTS/send.sh" team bob alice "locked out" >/dev/null

  run bash "$TYPES/codex/watch-once.sh" "$PROJ" codex --name alice --team team --timeout 1 --interval 1
  [ "$status" -eq 1 ]
  [[ "$output" =~ "no available subscription" ]]
}
