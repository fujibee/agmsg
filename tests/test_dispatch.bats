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
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_BOB" --team demo --agent bob -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: environment team and agent can check inbox" {
  run env AGMSG_TEAM=demo AGMSG_AGENT=bob bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_BOB" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: whoami single identity resolves inbox" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

@test "dispatch: multiple identity stops without choosing" {
  bash "$SCRIPTS/join.sh" many first codex "$PROJECT_MULTI"
  bash "$SCRIPTS/join.sh" many second codex "$PROJECT_MULTI"

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_MULTI" -- inbox
  [ "$status" -eq 2 ]
  [[ "$output" =~ "multiple=true" ]]
  [[ "$output" =~ "agmsg -Team <team> -Agent <agent> inbox" ]]
}

@test "dispatch: send then history preserves Japanese, quotes, and emoji" {
  local message='確認しました "quoted" emoji 🚀'
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- send bob "$message"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- history
  [ "$status" -eq 0 ]
  [[ "$output" =~ "$message" ]]
}

@test "dispatch: export routes to export.sh and emits JSONL" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- send bob "exported"
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- export
  [ "$status" -eq 0 ]
  [[ "$output" =~ \"type\":\"message_sent\" ]]
  [[ "$output" =~ "exported" ]]
}

@test "dispatch: export forwards --limit and --out to export.sh" {
  bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- send bob "e1"
  bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo --agent alice -- send bob "e2"
  local out="$BATS_TEST_TMPDIR/dispatch-export.jsonl"
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" --team demo -- export --limit 1 --out "$out"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -f "$out" ]
  local count
  count="$(grep -c '"type":"message_sent"' "$out")"
  [ "$count" -eq 1 ]
  grep -q "e2" "$out"
}

@test "dispatch: codex mode off and turn delegate to delivery" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- mode off
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]

  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- mode turn
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
}

@test "dispatch: 'team list' reaches team-list.sh, not team.sh (co1 P1 — 'list' must never be treated as a team name)" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- team list --json
  [ "$status" -eq 0 ]
  # team.sh's "Team not found: list" / "Team: list" output would appear if
  # this had been misrouted to team.sh with "list" as the team name.
  [[ "$output" != *"Team not found: list"* ]]
  [[ "$output" != *"Team: list"* ]]
  [ "$(echo "$output" | python3 -c "import json,sys; print(json.load(sys.stdin)['schema_version'])")" = "1" ]
  local names
  names="$(echo "$output" | python3 -c "import json,sys; print(','.join(t['name'] for t in json.load(sys.stdin)['teams']))")"
  [[ ",$names," == *",demo,"* ]]
}

@test "dispatch: bare 'team demo' still reaches team.sh (no regression from the 'team list' routing fix)" {
  run bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$PROJECT_ALICE" -- team demo
  [ "$status" -eq 0 ]
  [[ "$output" == *"Team: demo"* ]]
}
