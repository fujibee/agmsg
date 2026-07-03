#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob codex /tmp/project-b
}

teardown() {
  teardown_test_env
}

# Extract one JSON field's string value from a line via sqlite's own JSON
# parser rather than grep/sed — avoids false matches on substrings and
# validates the line is actually parseable JSON as a side effect. Escapes
# the line's own single quotes before embedding it as a SQL string literal
# (mirrors _agmsg_sqlesc in the scripts under test) — this is about safely
# handing arbitrary JSON *into* the test's own SQL, unrelated to whether
# api.sh itself escapes correctly.
json_field() {
  local escaped; escaped="$(printf %s "$1" | sed "s/'/''/g")"
  sqlite_mem "SELECT json_extract('$escaped', '\$.$2');"
}

# Same escaping as json_field, for a plain json_valid() check.
json_valid_line() {
  local escaped; escaped="$(printf %s "$1" | sed "s/'/''/g")"
  sqlite_mem "SELECT json_valid('$escaped');"
}

# --- get teams ---

@test "api: get teams lists joined teams as JSONL" {
  run bash "$SCRIPTS/api.sh" get teams
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(json_field "$output" name)" = "testteam" ]
}

@test "api: get teams is empty (not an error) when no teams exist" {
  teardown_test_env
  setup_test_env
  run bash "$SCRIPTS/api.sh" get teams
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "api: get teams emits valid JSON even for a team name containing a quote" {
  bash "$SCRIPTS/join.sh" "o'brien" carol claude-code /tmp/project-c
  run bash "$SCRIPTS/api.sh" get teams
  [ "$status" -eq 0 ]
  local line
  line="$(echo "$output" | grep "o'brien" || true)"
  [ -n "$line" ]
  [ "$(json_valid_line "$line")" = "1" ]
  [ "$(json_field "$line" name)" = "o'brien" ]
}

# --- get teams <team> members ---

@test "api: get teams <team> members lists members with type and project" {
  run bash "$SCRIPTS/api.sh" get teams testteam members
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  local alice_line
  alice_line="$(echo "$output" | grep '"alice"')"
  [ "$(json_field "$alice_line" project)" = "/tmp/project-a" ]
}

@test "api: get teams <team> members is empty for a nonexistent team" {
  run bash "$SCRIPTS/api.sh" get teams ghost-team members
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- get teams <team> messages ---

@test "api: get teams <team> messages returns sent messages oldest-first" {
  bash "$SCRIPTS/send.sh" testteam alice bob "first"
  bash "$SCRIPTS/send.sh" testteam bob alice "second"
  run bash "$SCRIPTS/api.sh" get teams testteam messages
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  local first_line second_line
  first_line="$(echo "$output" | sed -n 1p)"
  second_line="$(echo "$output" | sed -n 2p)"
  [ "$(json_field "$first_line" body)" = "first" ]
  [ "$(json_field "$second_line" body)" = "second" ]
}

@test "api: get teams <team> messages id is a JSON string, not a number" {
  bash "$SCRIPTS/send.sh" testteam alice bob "hi"
  run bash "$SCRIPTS/api.sh" get teams testteam messages
  [ "$status" -eq 0 ]
  # json_type() reports "text" for a JSON string field, "integer" for a bare
  # number — this is the regression aggie-co1's review caught (#289): ids
  # must stay opaque strings, not JSON numbers, to match the driver
  # interface's legacy-id contract.
  [ "$(sqlite_mem "SELECT json_type('$output', '\$.id');")" = "text" ]
}

@test "api: get teams <team> messages is empty for a nonexistent team" {
  run bash "$SCRIPTS/api.sh" get teams ghost-team messages
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "api: get teams <team> messages --agent filters to that agent's thread" {
  bash "$SCRIPTS/join.sh" testteam carol claude-code /tmp/project-c
  bash "$SCRIPTS/send.sh" testteam alice bob "to bob"
  bash "$SCRIPTS/send.sh" testteam alice carol "to carol"
  run bash "$SCRIPTS/api.sh" get teams testteam messages --agent bob
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(json_field "$output" body)" = "to bob" ]
}

@test "api: get teams <team> messages --limit caps to the most recent N" {
  bash "$SCRIPTS/send.sh" testteam alice bob "one"
  bash "$SCRIPTS/send.sh" testteam alice bob "two"
  bash "$SCRIPTS/send.sh" testteam alice bob "three"
  run bash "$SCRIPTS/api.sh" get teams testteam messages --limit 2
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 2 ]
  # oldest-first ordering still holds within the capped set — the 2 MOST
  # RECENT, not the first 2.
  [ "$(json_field "$(echo "$output" | sed -n 1p)" body)" = "two" ]
  [ "$(json_field "$(echo "$output" | sed -n 2p)" body)" = "three" ]
}

@test "api: get teams <team> messages --before-id pages further back" {
  bash "$SCRIPTS/send.sh" testteam alice bob "one"
  bash "$SCRIPTS/send.sh" testteam alice bob "two"
  bash "$SCRIPTS/send.sh" testteam alice bob "three"
  local first_page oldest_id
  first_page="$(bash "$SCRIPTS/api.sh" get teams testteam messages --limit 2)"
  oldest_id="$(json_field "$(echo "$first_page" | sed -n 1p)" id)"
  run bash "$SCRIPTS/api.sh" get teams testteam messages --before-id "$oldest_id"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(json_field "$output" body)" = "one" ]
}

@test "api: get teams <team> messages emits valid JSON for a body containing a quote" {
  bash "$SCRIPTS/send.sh" testteam alice bob "she said \"hi\""
  run bash "$SCRIPTS/api.sh" get teams testteam messages
  [ "$status" -eq 0 ]
  [ "$(json_valid_line "$output")" = "1" ]
  [ "$(json_field "$output" body)" = 'she said "hi"' ]
}

@test "api: get teams <team> messages --agent with a quote in the name doesn't break the query" {
  bash "$SCRIPTS/join.sh" testteam "o'brien" claude-code /tmp/project-o
  bash "$SCRIPTS/send.sh" testteam alice "o'brien" "hello"
  run bash "$SCRIPTS/api.sh" get teams testteam messages --agent "o'brien"
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(json_field "$output" body)" = "hello" ]
}

# --- routing / error paths ---

@test "api: unknown verb fails" {
  run bash "$SCRIPTS/api.sh" post teams
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown verb" ]]
}

@test "api: unknown top-level resource fails" {
  run bash "$SCRIPTS/api.sh" get bogus
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown resource" ]]
}

@test "api: unknown team sub-resource fails" {
  run bash "$SCRIPTS/api.sh" get teams testteam bogus
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown resource" ]]
}

@test "api: no arguments fails with a usage message" {
  run bash "$SCRIPTS/api.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Usage" ]]
}
