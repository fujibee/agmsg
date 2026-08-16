#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # This is a fixture dependency, not the python3 availability under test.
  # Resolve it in the per-test process before a case changes PATH.
  MOCK_PYTHON3="$(command -v python3)"
}

teardown() {
  teardown_test_env
}

json_field() {
  local escaped; escaped="$(printf %s "$1" | sed "s/'/''/g")"
  sqlite_mem "SELECT json_extract('$escaped', '\$.$2');"
}

@test "team list: reports nothing when there are no teams" {
  run bash "$SCRIPTS/team-list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No teams found"* ]]
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  [ "$(json_field "$output" schema_version)" = "1" ]
  [ "$(json_field "$output" teams)" = "[]" ]
}

@test "team list --json: reports every locally known team, canonically sorted by name" {
  bash "$SCRIPTS/join.sh" zteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" ateam bob claude-code /tmp/project-b
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].name');")" = "ateam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[1].name');")" = "zteam" ]
}

@test "team list --json: an unconnected team has binding_state=none, remote_team_id=null" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local team; team="$(sqlite_mem "SELECT json_extract('$(printf %s "$(json_field "$output" teams)" | sed "s/'/''/g")', '\$[0]');")"
  local escaped; escaped="$(printf %s "$team" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.binding_state');")" = "none" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.remote_team_id');")" = "" ]
}

@test "team list --json: an actively connected team has binding_state=active and a real remote_team_id" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a

  "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  local mock_pid=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  local mock_port; mock_port="$(cat "$TEST_SKILL_DIR/server.port")"
  local endpoint="http://127.0.0.1:$mock_port"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$endpoint" myteam
  local committed_remote_team_id
  committed_remote_team_id=$(python3 -c "import json; print(json.load(open('$SCRIPTS/../teams/myteam/config.json'))['remote_binding']['remote_team_id'])")

  run bash "$SCRIPTS/team-list.sh" --json
  kill "$mock_pid" 2>/dev/null || true
  [ "$status" -eq 0 ]
  local escaped; escaped="$(printf %s "$(sqlite_mem "SELECT json_extract('$(printf %s "$(json_field "$output" teams)" | sed "s/'/''/g")', '\$[0]');")" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.binding_state');")" = "active" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.remote_team_id');")" = "$committed_remote_team_id" ]
  # No secret and no absolute filesystem path anywhere in the output.
  [[ "$output" != *"session-credential"* ]]
  [[ "$output" != *"/tmp/project-a"* ]]
}

@test "team list --json: a disconnected team has binding_state=disconnected, remote_team_id retained" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a
  "$MOCK_PYTHON3" "$BATS_TEST_DIRNAME/helpers/mock_remote_server.py" 0 \
    </dev/null > "$TEST_SKILL_DIR/server.port" 2>"$TEST_SKILL_DIR/server.log" 3>&- &
  local mock_pid=$!
  wait_for_file_contains "$TEST_SKILL_DIR/server.port" '^[0-9][0-9]*$'
  local mock_port; mock_port="$(cat "$TEST_SKILL_DIR/server.port")"
  local endpoint="http://127.0.0.1:$mock_port"
  bash "$SCRIPTS/remote.sh" connect --endpoint "$endpoint" myteam
  bash "$SCRIPTS/remote.sh" disconnect myteam
  kill "$mock_pid" 2>/dev/null || true

  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local escaped; escaped="$(printf %s "$(sqlite_mem "SELECT json_extract('$(printf %s "$(json_field "$output" teams)" | sed "s/'/''/g")', '\$[0]');")" | sed "s/'/''/g")"
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.binding_state');")" = "disconnected" ]
  [ "$(sqlite_mem "SELECT json_extract('$escaped', '\$.remote_team_id');")" != "" ]
}

@test "team list --scope project: only includes teams registered for the given project" {
  bash "$SCRIPTS/join.sh" projteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" otherteam bob claude-code /tmp/project-b
  run bash "$SCRIPTS/team-list.sh" --json --scope project /tmp/project-a
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_array_length('$(printf %s "$teams" | sed "s/'/''/g")');")" -eq 1 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].name');")" = "projteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].scope');")" = "project" ]
}

@test "team list --scope all: includes every team, with per-team scope classifying project vs other" {
  bash "$SCRIPTS/join.sh" projteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" otherteam bob claude-code /tmp/project-b
  run bash "$SCRIPTS/team-list.sh" --json --scope all /tmp/project-a
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_array_length('$(printf %s "$teams" | sed "s/'/''/g")');")" -eq 2 ]
  local proj_line other_line
  proj_line="$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0]');" )"
  other_line="$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[1]');" )"
  # ateam-style alphabetical sort: otherteam < projteam
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$proj_line" | sed "s/'/''/g")', '\$.name');")" = "otherteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$proj_line" | sed "s/'/''/g")', '\$.scope');")" = "other" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$other_line" | sed "s/'/''/g")', '\$.name');")" = "projteam" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$other_line" | sed "s/'/''/g")', '\$.scope');")" = "project" ]
}

@test "team list: rejects an invalid --scope value" {
  run bash "$SCRIPTS/team-list.sh" --scope bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"--scope must be"* ]]
}

@test "team list --json: a team name containing a single quote round-trips correctly" {
  local team="o'brien-team"
  bash "$SCRIPTS/join.sh" "$team" carol claude-code /tmp/project-c
  run bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 0 ]
  local teams; teams="$(json_field "$output" teams)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf %s "$teams" | sed "s/'/''/g")', '\$[0].name');")" = "$team" ]
}

@test "team list --json: fails closed (no payload, exit 2) when a team's config has a duplicate JSON key (P2 — never authoritative on a partial list)" {
  mkdir -p "$SCRIPTS/../teams/badteam"
  printf '{"name":"badteam","agents":{},"agents":{}}' > "$SCRIPTS/../teams/badteam/config.json"
  bash "$SCRIPTS/join.sh" goodteam alice claude-code /tmp/project-a

  # bats' `run` merges stdout+stderr into $output — check each stream in
  # its own `run` so a stray warning line can never be mistaken for (or
  # corrupt parsing of) the JSON payload.
  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>/dev/null"
  [ "$status" -eq 2 ]
  [ -z "$output" ]

  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>&1 >/dev/null"
  [[ "$output" == *"skipping 'badteam'"* ]]
  [[ "$output" == *"refusing to print a partial list"* ]]
}

@test "team list --json: fails closed (no payload, exit 2) when a team's config is not valid JSON" {
  mkdir -p "$SCRIPTS/../teams/badteam"
  printf 'not even json' > "$SCRIPTS/../teams/badteam/config.json"

  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>/dev/null"
  [ "$status" -eq 2 ]
  [ -z "$output" ]

  run bash -c "bash '$SCRIPTS/team-list.sh' --json 2>&1 >/dev/null"
  [[ "$output" == *"skipping 'badteam'"* ]]
}

@test "team list --json: fails closed (no payload, exit 2) when the team count is truncated at the bound" {
  bash "$SCRIPTS/join.sh" teama alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" teamb bob claude-code /tmp/project-b

  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=1 bash '$SCRIPTS/team-list.sh' --json 2>/dev/null"
  [ "$status" -eq 2 ]
  [ -z "$output" ]

  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=1 bash '$SCRIPTS/team-list.sh' --json 2>&1 >/dev/null"
  [[ "$output" == *"bounded at 1 teams"* ]]
  [[ "$output" == *"refusing to print a partial list"* ]]
}

@test "team list: rejects a non-numeric AGMSG_TEAM_LIST_MAX_TEAMS override (delta review) — never silently unbounded" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a
  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=not-a-number bash '$SCRIPTS/team-list.sh' --json"
  [ "$status" -ne 0 ]
  [ "$status" -ne 2 ]
  [[ "$output" == *"must be a positive integer"* ]]
  [[ "$output" != *"schema_version"* ]]
}

@test "team list: rejects AGMSG_TEAM_LIST_MAX_TEAMS=0" {
  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=0 bash '$SCRIPTS/team-list.sh' --json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be between 1 and 10000"* ]]
  [[ "$output" != *"schema_version"* ]]
}

@test "team list: rejects a negative AGMSG_TEAM_LIST_MAX_TEAMS override" {
  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=-5 bash '$SCRIPTS/team-list.sh' --json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be a positive integer"* ]]
  [[ "$output" != *"schema_version"* ]]
}

@test "team list: rejects an all-digit AGMSG_TEAM_LIST_MAX_TEAMS override too large for bash's native integer arithmetic (delta review round 2)" {
  # An all-digit string this long overflows bash's fixed-width `test`
  # arithmetic the SAME way a non-numeric value does (silent "integer
  # expression expected", never true, never truncates) — this is the
  # digit-count guard closing that exact bypass, not just the earlier
  # non-numeric/negative checks.
  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=999999999999999999999999999999 bash '$SCRIPTS/team-list.sh' --json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be between 1 and 10000"* ]]
  [[ "$output" != *"schema_version"* ]]
}

@test "team list: rejects an in-range-looking but out-of-bound AGMSG_TEAM_LIST_MAX_TEAMS override (e.g. 99999)" {
  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=99999 bash '$SCRIPTS/team-list.sh' --json"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be between 1 and 10000"* ]]
  [[ "$output" != *"schema_version"* ]]
}

@test "team list: accepts AGMSG_TEAM_LIST_MAX_TEAMS at the exact upper bound (10000)" {
  run bash -c "AGMSG_TEAM_LIST_MAX_TEAMS=10000 bash '$SCRIPTS/team-list.sh' --json"
  [ "$status" -eq 0 ]
}

@test "team list (human, no --json): a bad config or a truncated bound still prints what it found, with a warning, exit 0" {
  mkdir -p "$SCRIPTS/../teams/badteam"
  printf 'not even json' > "$SCRIPTS/../teams/badteam/config.json"
  bash "$SCRIPTS/join.sh" goodteam alice claude-code /tmp/project-a

  run bash "$SCRIPTS/team-list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"goodteam"* ]]
  [[ "$output" == *"skipping 'badteam'"* ]]
  [[ "$output" == *"this list is incomplete"* ]]
}

@test "team list: human-readable output includes name and binding state" {
  bash "$SCRIPTS/join.sh" myteam alice claude-code /tmp/project-a
  run bash "$SCRIPTS/team-list.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"myteam"* ]]
  [[ "$output" == *"none"* ]]
}

# --- python3 preflight (dependency tiering: remote = +python3) -------------

@test "team list: fails fast with an install message when python3 is absent, never hangs (--json)" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/team-list.sh" --json
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
  [[ "$output" == *"brew install python3"* ]]
}

@test "team list: fails fast with an install message when python3 is absent (human mode)" {
  local no_py3; no_py3="$(path_without_python3)"
  run env PATH="$no_py3" bash "$SCRIPTS/team-list.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"requires python3"* ]]
}
