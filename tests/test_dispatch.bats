#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJECT_ALICE="$BATS_TEST_TMPDIR/project-alice"
  export PROJECT_BOB="$BATS_TEST_TMPDIR/project-bob"
  export PROJECT_MULTI="$BATS_TEST_TMPDIR/project-multi"
  mkdir -p "$PROJECT_ALICE" "$PROJECT_BOB" "$PROJECT_MULTI"
  bash "$SCRIPTS/join.sh" demo alice codex "$PROJECT_ALICE"
  bash "$SCRIPTS/join.sh" demo bob codex "$PROJECT_BOB"
}

teardown() {
  teardown_test_env
}

@test "dispatch: explicit team and agent can check inbox" {
  run bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_BOB" --team demo --agent bob -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: environment team and agent can check inbox" {
  run env AGMSG_TEAM=demo AGMSG_AGENT=bob bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_BOB" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: whoami single identity resolves inbox" {
  run bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: multiple identity stops without choosing" {
  bash "$SCRIPTS/join.sh" many first codex "$PROJECT_MULTI"
  bash "$SCRIPTS/join.sh" many second codex "$PROJECT_MULTI"

  run bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_MULTI" -- inbox
  [ "$status" -eq 2 ]
  [[ "$output" =~ "multiple=true" ]]
  [[ "$output" =~ "agmsg -Team <team> -Agent <agent> inbox" ]]
}

@test "dispatch: send then history preserves Japanese, quotes, and emoji" {
  local message='確認しました "quoted" emoji 🚀'
  run bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- send bob "$message"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- history
  [ "$status" -eq 0 ]
  [[ "$output" =~ "$message" ]]
}

@test "dispatch: codex mode off and turn delegate to delivery" {
  run bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- mode off
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]

  run bash "$SCRIPTS/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- mode turn
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
}
