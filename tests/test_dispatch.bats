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

# Every other test here passes `--type codex`, so none of them exercises the
# default — which is where #783 actually bit. dispatch.sh must resolve a type
# for the commands that require one, but whoami.sh is the caller that can work
# it out itself, and handing it the `codex` default replaced detection with a
# guess: a Claude Code user on Windows who never set AGMSG_AGENT_TYPE asked "am
# I joined AS CODEX?", got the truthful `not_joined=true`, and read it as "I am
# not joined". Reverting either half of the dispatch change turns this red.
@test "dispatch: with no type chosen, identity comes from detection, not the codex default (#783)" {
  local proj="$BATS_TEST_TMPDIR/project-claude"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" demo carol claude-code "$proj"

  # Control first. If detection does not land on claude-code here, the
  # assertion below would pass or fail for a reason that has nothing to do
  # with dispatch, and this line says so instead of staying quiet.
  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/whoami.sh" "$proj"
  [ "$status" -eq 0 ]
  # A plain command: a non-last `[[ ]]` cannot fail the test on bash 3.2 (#670),
  # and a control that cannot fail is not a control.
  grep -qF "type=claude-code" <<<"$output"

  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/windows/dispatch.sh" --project "$proj" -- inbox
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages." ]]
}

# The other direction: a type the caller DID choose must still be honoured, so
# the fix above cannot be "ignore the type argument".
@test "dispatch: an explicitly chosen type is still what identity is resolved as (#783)" {
  local proj="$BATS_TEST_TMPDIR/project-both"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" demo dave claude-code "$proj"

  # Asked as codex, dave is not there — dispatch must stop rather than quietly
  # resolve him. (The output is `suggest=true`, not `not_joined=true`: setup()
  # registers codex agents in other projects, so the scan has something to
  # suggest. What matters is that dave is not the answer.)
  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/windows/dispatch.sh" --type codex --project "$proj" -- inbox
  [ "$status" -eq 2 ]
  [[ ! "$output" =~ "agent=dave" ]]
}

# "Explicit" is TWO entrances, and a control that drives one of them measures
# half of the property. `--type` is covered above; this is the environment
# side. Without it, flattening AGENT_TYPE_EXPLICIT's env-derived value to empty
# leaves every declared control green, so the claim "both are honoured" would
# rest on reading the source rather than on anything the tree enforces.
@test "dispatch: AGMSG_AGENT_TYPE is honoured over detection, exactly as --type is (#801)" {
  local proj="$BATS_TEST_TMPDIR/project-envtype"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" demo gina claude-code "$proj"

  # Detection would answer claude-code here — CLAUDE_CODE_SESSION_ID is set and
  # gina is registered under it. The env var says codex, and the env var wins,
  # so gina must not be the identity that comes back.
  run env CLAUDE_CODE_SESSION_ID=test-session AGMSG_AGENT_TYPE=codex \
    bash "$SCRIPTS/windows/dispatch.sh" --project "$proj" -- inbox
  [ "$status" -eq 2 ]
  refute grep -qF "agent=gina" <<<"$output"
}

# WHAT THIS BINDS IS THE BREAKAGE, NOT THE REPAIR. Detecting the type inside
# whoami.sh fixed the message a user reads; it did not fix what dispatch then
# WRITES. `actas` resolves the identity from the claude-code registration and
# immediately calls identities.sh and join.sh — with the type dispatch is
# holding. Left at the `codex` literal, an already-joined claude-code user gets
# a SECOND registration under codex: one person, two identities.
#
# So the assertion is that the wrong record does not appear. Asserting "the
# claude-code one is used" would pass while an extra codex row was created
# beside it.
@test "dispatch: actas with no type chosen does not register the user again under codex (#801)" {
  local proj="$BATS_TEST_TMPDIR/project-actas"
  mkdir -p "$proj"
  bash "$SCRIPTS/join.sh" demo erin claude-code "$proj"

  # Control: nothing is registered as codex in this project yet, so a codex
  # row found afterwards can only have been created by the run below.
  run bash "$SCRIPTS/identities.sh" "$proj" codex
  [ -z "$output" ]

  run env CLAUDE_CODE_SESSION_ID=test-session bash "$SCRIPTS/windows/dispatch.sh" --project "$proj" -- actas frank
  [ "$status" -eq 0 ]

  run bash "$SCRIPTS/identities.sh" "$proj" codex
  [ -z "$output" ]
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

@test "dispatch: 'team list' reaches team-list.sh, not team.sh (P1 — 'list' must never be treated as a team name)" {
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
