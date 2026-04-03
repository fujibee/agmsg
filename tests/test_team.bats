#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# --- join.sh ---

@test "join: creates team and adds agent" {
  run bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Joined team myteam as alice" ]]
}

@test "join: creates team config on first join" {
  bash "$SCRIPTS/join.sh" newteam first claude-code /tmp/proj
  [ -f "$TEST_SKILL_DIR/teams/newteam/config.json" ]
}

@test "join: adds multiple agents to same team" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "2 member" ]]
}

# --- leave.sh ---

@test "leave: removes agent from team" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam bob claude-code /tmp/proj-b
  run bash "$SCRIPTS/leave.sh" myteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Left team myteam" ]]
  run bash "$SCRIPTS/team.sh" myteam
  [[ ! "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
}

@test "leave: removes team dir when last member leaves" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/leave.sh" myteam alice
  [ ! -d "$TEST_SKILL_DIR/teams/myteam" ]
}

# --- team.sh ---

@test "team: shows team members with types" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj-a
  bash "$SCRIPTS/join.sh" myteam bob codex /tmp/proj-b
  run bash "$SCRIPTS/team.sh" myteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "claude-code" ]]
  [[ "$output" =~ "bob" ]]
  [[ "$output" =~ "codex" ]]
}

# --- whoami.sh ---

@test "whoami: returns agent identity" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agent=alice" ]]
  [[ "$output" =~ "teams=myteam" ]]
}

@test "whoami: returns not_joined when no match" {
  run bash "$SCRIPTS/whoami.sh" /tmp/unknown claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not_joined=true" ]]
}

@test "whoami: returns multiple when multiple identities" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/proj
  bash "$SCRIPTS/join.sh" myteam reviewer claude-code /tmp/proj
  run bash "$SCRIPTS/whoami.sh" /tmp/proj claude-code
  [ "$status" -eq 0 ]
  [[ "$output" =~ "multiple=true" ]]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "reviewer" ]]
}

@test "whoami: lists available teams when not joined" {
  bash "$SCRIPTS/join.sh" team1 alice claude-code /tmp/other
  run bash "$SCRIPTS/whoami.sh" /tmp/nothere claude-code
  [[ "$output" =~ "available_teams=team1" ]]
}
