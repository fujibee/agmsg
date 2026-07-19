#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "ready: mark makes check succeed, and clear consumes the sentinel" {
  run bash "$SCRIPTS/ready.sh" check team alice
  [ "$status" -ne 0 ]

  run bash "$SCRIPTS/ready.sh" mark team alice
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/ready.sh" check team alice
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/ready.sh" clear team alice
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/ready.sh" check team alice
  [ "$status" -ne 0 ]
}

@test "ready: clear is idempotent when no sentinel exists" {
  run bash "$SCRIPTS/ready.sh" clear team missing
  [ "$status" -eq 0 ]
}

@test "ready: actas sentinel is distinct from watcher readiness" {
  bash "$SCRIPTS/ready.sh" mark team alice

  [ -f "$TEST_SKILL_DIR/run/actas-ready.team__alice" ]
  [ ! -e "$TEST_SKILL_DIR/run/ready.team__alice" ]
}

@test "ready: filesystem encoding prevents lossy name collisions" {
  bash "$SCRIPTS/ready.sh" mark 'team one' 'alice/bob'
  bash "$SCRIPTS/ready.sh" mark 'team_one' 'alice_bob'

  run bash "$SCRIPTS/ready.sh" check 'team one' 'alice/bob'
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/ready.sh" check 'team_one' 'alice_bob'
  [ "$status" -eq 0 ]

  bash "$SCRIPTS/ready.sh" clear 'team one' 'alice/bob'
  run bash "$SCRIPTS/ready.sh" check 'team_one' 'alice_bob'
  [ "$status" -eq 0 ]
}

@test "ready: mark is idempotent and refreshes the same sentinel" {
  bash "$SCRIPTS/ready.sh" mark team alice
  local count_before
  count_before="$(find "$TEST_SKILL_DIR/run" -name 'actas-ready.*' | wc -l | tr -d ' ')"

  bash "$SCRIPTS/ready.sh" mark team alice
  local count_after
  count_after="$(find "$TEST_SKILL_DIR/run" -name 'actas-ready.*' | wc -l | tr -d ' ')"

  [ "$count_before" -eq 1 ]
  [ "$count_after" -eq 1 ]
}

@test "ready: rejects unknown actions and malformed argv" {
  run bash "$SCRIPTS/ready.sh" nope team alice
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]

  run bash "$SCRIPTS/ready.sh" mark team
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]

  run bash "$SCRIPTS/ready.sh" mark '' alice
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage:"* ]]
}
