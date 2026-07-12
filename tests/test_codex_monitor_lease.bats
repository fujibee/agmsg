#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export LEASE="$TYPES/codex/codex-monitor-lease.sh"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
}

teardown() {
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

arm() {
  bash "$LEASE" arm "$TEST_PROJECT" team alice thread-123 --ttl 60
}

@test "Codex monitor lease is opt-in" {
  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=inactive"* ]]

  run arm
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=active"* ]]
}

@test "heartbeat renews an active lease and fallback stays dormant" {
  arm >/dev/null

  run bash "$LEASE" heartbeat "$TEST_PROJECT" team alice thread-123 --ttl 60
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=active"* ]]

  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123 --fallback-after 30
  [ "$status" -eq 2 ]
  [[ "$output" == *"status=healthy"* ]]
}

@test "claim reserves an unread high-water mark without consuming the inbox" {
  arm >/dev/null
  bash "$SCRIPTS/send.sh" team bob alice "lease pending" >/dev/null

  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123 --retry-after 60
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=wake"* ]]
  [[ "$output" == *"max_id="* ]]

  run bash "$SCRIPTS/inbox.sh" team alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease pending"* ]]
}

@test "heartbeat and watchdog cannot reserve the same unread message twice" {
  arm >/dev/null
  bash "$SCRIPTS/send.sh" team bob alice "only once" >/dev/null

  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123 --retry-after 60
  [ "$status" -eq 0 ]
  max_id="$(printf '%s\n' "$output" | sed -n 's/.*max_id=\([0-9][0-9]*\).*/\1/p')"

  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123 --retry-after 60
  [ "$status" -eq 2 ]
  [[ "$output" == *"status=waiting"* ]]

  run bash "$LEASE" delivered "$TEST_PROJECT" team alice thread-123 "$max_id"
  [ "$status" -eq 0 ]

  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123 --retry-after 60
  [ "$status" -eq 2 ]
  [[ "$output" == *"status=waiting"* ]]
}

@test "three failed visible wakes stop automatic retries until heartbeat recovery" {
  arm >/dev/null
  bash "$SCRIPTS/send.sh" team bob alice "wake failure" >/dev/null
  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 0 ]
  max_id="$(printf '%s\n' "$output" | sed -n 's/.*max_id=\([0-9][0-9]*\).*/\1/p')"

  for _ in 1 2 3; do
    bash "$LEASE" failed "$TEST_PROJECT" team alice thread-123 "$max_id" >/dev/null
  done

  run bash "$LEASE" claim "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=error"* ]]

  run bash "$LEASE" heartbeat "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=active"* ]]
}

@test "automation ids survive status and are returned during teardown" {
  arm >/dev/null
  bash "$LEASE" automation "$TEST_PROJECT" team alice thread-123 heartbeat-id watchdog-id >/dev/null

  run bash "$LEASE" disarm "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"heartbeat_automation_id=heartbeat-id"* ]]
  [[ "$output" == *"watchdog_automation_id=watchdog-id"* ]]

  run bash "$LEASE" status "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=inactive"* ]]
}

@test "project teardown removes only that project's leases" {
  other_project="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" other-team other-agent codex "$other_project" >/dev/null
  arm >/dev/null
  bash "$LEASE" arm "$other_project" other-team other-agent other-thread >/dev/null

  run bash "$LEASE" disarm-project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"team=team name=alice"* ]]

  run bash "$LEASE" status "$other_project" other-team other-agent other-thread
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=active"* ]]
  rm -rf "$other_project"
}

@test "session teardown leaves an inactive tombstone for automation cleanup" {
  arm >/dev/null
  bash "$LEASE" automation "$TEST_PROJECT" team alice thread-123 heartbeat-id watchdog-id >/dev/null

  run bash "$LEASE" deactivate-thread "$TEST_PROJECT" thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=inactive"* ]]
  [[ "$output" == *"heartbeat_automation_id=heartbeat-id"* ]]

  run bash "$LEASE" status "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=inactive"* ]]

  run bash "$LEASE" heartbeat "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=inactive"* ]]
}

@test "heartbeat and watchdog prompts preserve inbox ownership" {
  run bash "$LEASE" prompt "$TEST_PROJECT" team alice thread-123 heartbeat
  [ "$status" -eq 0 ]
  [[ "$output" == *"inbox.sh"* ]]
  [[ "$output" == *"visible Codex thread"* ]]

  run bash "$LEASE" prompt "$TEST_PROJECT" team alice thread-123 watchdog
  [ "$status" -eq 0 ]
  [[ "$output" == *"send_message_to_thread"* ]]
  [[ "$output" == *"must never run inbox.sh"* ]]
}

@test "stale lease lock does not block monitor recovery" {
  arm_output="$(arm)"
  lease_id="$(printf '%s\n' "$arm_output" | sed -n 's/.*lease_id=\([^ ]*\).*/\1/p')"
  mkdir "$TEST_SKILL_DIR/run/$lease_id.state.lock"
  printf '99999999\n' > "$TEST_SKILL_DIR/run/$lease_id.state.lock/pid"

  run bash "$LEASE" heartbeat "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=active"* ]]
}
