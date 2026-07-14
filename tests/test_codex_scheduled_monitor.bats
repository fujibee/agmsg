#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export MONITOR="$TYPES/codex/codex-scheduled-monitor.sh"
  export AGMSG_RUN_PATH="$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
}

teardown() {
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

arm() {
  bash "$MONITOR" arm "$TEST_PROJECT" team alice owner-1 --now 1000
}

check_at() {
  bash "$MONITOR" check "$TEST_PROJECT" team alice owner-1 --now "$1" --force
}

@test "scheduled monitor starts at two minutes and rejects an early duplicate run" {
  run arm
  [ "$status" -eq 0 ]
  [[ "$output" == *"stage=fast"* ]]
  [[ "$output" == *"next_interval=120"* ]]
  [[ "$output" == *"next_rrule=FREQ=MINUTELY;INTERVAL=2"* ]]

  run bash "$MONITOR" check "$TEST_PROJECT" team alice owner-1 --now 1001
  [ "$status" -eq 2 ]
  [[ "$output" == *"status=not_due"* ]]
}

@test "scheduled monitor backs off at thirty minutes and four hours" {
  arm >/dev/null

  run check_at 2800
  [ "$status" -eq 2 ]
  [[ "$output" == *"stage=medium"* ]]
  [[ "$output" == *"next_interval=900"* ]]
  [[ "$output" == *"schedule_change=1"* ]]

  bash "$MONITOR" scheduled "$TEST_PROJECT" team alice owner-1 900 >/dev/null
  run check_at 15400
  [ "$status" -eq 2 ]
  [[ "$output" == *"stage=slow"* ]]
  [[ "$output" == *"next_interval=3600"* ]]
  [[ "$output" == *"next_rrule=FREQ=HOURLY;INTERVAL=1"* ]]
}

@test "scheduled prepare is idempotent and emits one current-task prompt" {
  export AGMSG_CODEX_SCHEDULED_OWNER="owner-prepared"

  run bash "$MONITOR" prepare "$TEST_PROJECT" team alice --now 1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=prepared owner=owner-prepared"* ]]
  [[ "$output" == *"FREQ=MINUTELY;INTERVAL=2"* ]]
  [[ "$output" == *"returns to this current task"* ]]

  run bash "$MONITOR" prepare "$TEST_PROJECT" team alice --now 1001
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=already_prepared owner=owner-prepared"* ]]
  state_count="$(find "$AGMSG_RUN_PATH" -maxdepth 1 -name 'codex-scheduled-monitor.*.state' -type f | wc -l | tr -d ' ')"
  [ "$state_count" -eq 1 ]

  run bash "$MONITOR" status-identity "$TEST_PROJECT" team alice --now 1001
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=active"* ]]

  run bash "$MONITOR" status-project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"identity=team/alice"* ]]
  [[ "$output" == *"status=active count=1"* ]]

  run bash "$MONITOR" stop-identity "$TEST_PROJECT" team alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=inactive schedule_action=pause"* ]]

  run bash "$MONITOR" stop-identity "$TEST_PROJECT" team alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=inactive schedule_action=pause"* ]]
}

@test "scheduled stop-project disarms every role in the project" {
  AGMSG_CODEX_SCHEDULED_OWNER="owner-alice" bash "$MONITOR" prepare "$TEST_PROJECT" team alice --now 1000 >/dev/null
  AGMSG_CODEX_SCHEDULED_OWNER="owner-bob" bash "$MONITOR" prepare "$TEST_PROJECT" team bob --now 1000 >/dev/null

  run bash "$MONITOR" stop-project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped=2"* ]]
  [[ "$output" == *"schedule_action=pause"* ]]

  run bash "$MONITOR" status-project "$TEST_PROJECT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=inactive count=0"* ]]
}

@test "new unread mail resets a slow cycle to two minutes without consuming it" {
  arm >/dev/null
  bash "$MONITOR" scheduled "$TEST_PROJECT" team alice owner-1 3600 >/dev/null
  bash "$SCRIPTS/send.sh" team bob alice "scheduled reset" >/dev/null

  run check_at 20000
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=wake"* ]]
  [[ "$output" == *"new_message=1"* ]]
  [[ "$output" == *"stage=fast"* ]]
  [[ "$output" == *"next_interval=120"* ]]
  [[ "$output" == *"schedule_change=1"* ]]
  max_id="$(printf '%s\n' "$output" | sed -n 's/.*max_id=\([0-9][0-9]*\).*/\1/p')"

  run bash "$SCRIPTS/inbox.sh" team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"scheduled reset"* ]]

  run bash "$MONITOR" delivered "$TEST_PROJECT" team alice owner-1 "$max_id" --now 20000
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=delivered"* ]]

  run bash "$MONITOR" status "$TEST_PROJECT" team alice owner-1 --now 20120
  [ "$status" -eq 0 ]
  [[ "$output" == *"elapsed=120"* ]]
}

@test "the same unread high-water mark does not reset the cycle twice" {
  arm >/dev/null
  bash "$SCRIPTS/send.sh" team bob alice "only one reset" >/dev/null
  check_at 20000 >/dev/null

  run check_at 20120
  [ "$status" -eq 2 ]
  [[ "$output" == *"status=waiting"* ]]
  [[ "$output" == *"new_message=0"* ]]
  [[ "$output" == *"elapsed=120"* ]]
}

@test "scheduled monitor checks once at twenty four hours and then expires" {
  arm >/dev/null

  run check_at 87400
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=expired"* ]]
  [[ "$output" == *"schedule_action=pause"* ]]

  run check_at 87401
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=expired"* ]]
}

@test "scheduled prompt keeps one task and prohibits relay and app restart paths" {
  run bash "$MONITOR" prompt "$TEST_PROJECT" team alice owner-1
  [ "$status" -eq 0 ]
  [[ "$output" == *"do not notify the user"* ]]
  [[ "$output" == *"Do not create another task"* ]]
  [[ "$output" == *"heartbeat automation"* ]]
  [[ "$output" == *"targetThreadId is this current task"* ]]
  [[ "$output" == *"Never edit automation files directly"* ]]
  [[ "$output" == *"Never use Desktop relay"* ]]
  [[ "$output" == *"ChatGPT.app restart"* ]]
  [[ "$output" == *"status is inactive"* ]]
}
