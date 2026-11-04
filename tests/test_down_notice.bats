#!/usr/bin/env bats

# scripts/lib/down-notice.sh: a durable "down or degraded" record under
# run/down/<component>.json that status, doctor and the session-start hook show.

load test_helper

setup() {
  setup_test_env
  unset AGMSG_SYNC_CONNECTION_DIR
  mkdir -p "$TEST_SKILL_DIR/run"
  # shellcheck disable=SC1091
  . "$TEST_SKILL_DIR/scripts/lib/down-notice.sh"
  DIR="$TEST_SKILL_DIR/run/down"
}

teardown() { teardown_test_env; }

@test "set writes run/down/<component>.json; list and print show state, reason and recovery" {
  down_notice_set sync.t1 down "the engine is down" "bash remote.sh sync start t1"
  [ -f "$DIR/sync.t1.json" ]
  grep -qF '"state":"down"' "$DIR/sync.t1.json"
  run down_notice_list
  [ "$(printf '%s\n' "$output" | awk -F'\t' '{print $1 "|" $2 "|" $4 "|" $5}')" = "sync.t1|down|the engine is down|bash remote.sh sync start t1" ]
  run down_notice_print
  printf '%s\n' "$output" | grep -qF "sync.t1 is down since"
  printf '%s\n' "$output" | grep -qF "recover with: bash remote.sh sync start t1"
}

@test "the install root is the helper's own, not the caller's SKILL_DIR" {
  export SKILL_DIR="$BATS_TEST_TMPDIR/somewhere-else"
  down_notice_set c0 degraded "r" "c"
  [ -f "$TEST_SKILL_DIR/run/down/c0.json" ]
  [ ! -e "$BATS_TEST_TMPDIR/somewhere-else" ]
}

@test "since is kept while the state is the same, restarts when the state changes; clear removes only that record" {
  down_notice_set c1 degraded "first" "do x"
  down_notice_set other down "x" "y"
  local before after
  before="$(down_notice_list | awk -F'\t' '$1 == "c1" {print $3}')"
  sleep 1
  down_notice_set c1 degraded "second" "do y"
  after="$(down_notice_list | awk -F'\t' '$1 == "c1" {print $3}')"
  [ "$before" = "$after" ]
  grep -qF "second" "$DIR/c1.json"
  sleep 1
  down_notice_set c1 down "worse" "do z"
  [ "$(down_notice_list | awk -F'\t' '$1 == "c1" {print $3}')" != "$before" ]
  down_notice_clear c1
  [ ! -e "$DIR/c1.json" ]
  [ -f "$DIR/other.json" ]
}

@test "free text with quotes, backslashes, newlines and tabs stays one valid JSON line" {
  down_notice_set c2 down $'two\nlines\tand "quotes" and \\ slash' "cmd"
  [ "$(wc -l < "$DIR/c2.json" | tr -d ' ')" -eq 1 ]
  run sqlite_mem "SELECT json_valid(CAST(readfile('$DIR/c2.json') AS TEXT));"
  [ "$output" = 1 ]
  run sqlite_mem "SELECT json_extract(CAST(readfile('$DIR/c2.json') AS TEXT), '\$.component');"
  [ "$output" = c2 ]
}

@test "an invalid component or state is refused with status 2 and writes nothing" {
  run down_notice_set "../evil" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set "Upper" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set "a b" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set ".hidden" down "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_set ok-key broken "r" "c"
  [ "$status" -eq 2 ]
  run down_notice_clear "../evil"
  [ "$status" -eq 2 ]
  [ ! -e "$DIR" ] || [ -z "$(ls -A "$DIR")" ]
}

@test "down_notice_key makes a valid key from free text" {
  [ "$(down_notice_key sync "My Team/1")" = "sync.my-team-1" ]
  down_notice_set "$(down_notice_key sync "My Team/1")" down r c
  [ -f "$DIR/sync.my-team-1.json" ]
}

@test "print_once shows a record once, and again only when it changes" {
  down_notice_set c3 down "down" "fix"
  run down_notice_print_once
  printf '%s\n' "$output" | grep -qF "c3 is down since"
  run down_notice_print_once
  [ -z "$output" ]
  down_notice_set c3 down "down differently" "fix"
  run down_notice_print_once
  printf '%s\n' "$output" | grep -qF "down differently"
}

@test "an unwritable run directory is not an error for the caller" {
  mkdir -p "$TEST_SKILL_DIR/run"
  : > "$TEST_SKILL_DIR/run/down"      # a file where the directory should be
  run down_notice_set c4 down "r" "c"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "could not record that c4 is down"
  run down_notice_print
  [ "$status" -eq 0 ]
}

@test "doctor shows every record" {
  down_notice_set sync.t1 down "the engine is down" "bash remote.sh sync start t1"
  down_notice_set watch.s1 degraded "slow" "restart it"
  run bash "$SCRIPTS/remote.sh" doctor
  printf '%s\n' "$output" | grep -qF "AGMSG: sync.t1 is down since"
  printf '%s\n' "$output" | grep -qF "recover with: bash remote.sh sync start t1"
  printf '%s\n' "$output" | grep -qF "AGMSG: watch.s1 is degraded since"
}

@test "doctor prints nothing extra when there is no record" {
  run bash "$SCRIPTS/remote.sh" doctor
  refute grep -qF "is down since" <<<"$output"
  refute grep -qF "is degraded since" <<<"$output"
}

@test "the session-start hook shows a record once, and again after it changes" {
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a >/dev/null
  down_notice_set sync.testteam down "the engine is down" "bash remote.sh sync start testteam"
  run bash -c 'printf "{\"session_id\":\"sid-one\"}" | bash "$1" claude-code /tmp/project-a' _ "$SCRIPTS/session-start.sh"
  printf '%s\n' "$output" | grep -qF "AGMSG: sync.testteam is down since"
  run bash -c 'printf "{\"session_id\":\"sid-two\"}" | bash "$1" claude-code /tmp/project-a' _ "$SCRIPTS/session-start.sh"
  refute grep -qF "AGMSG: sync.testteam is down since" <<<"$output"
  down_notice_set sync.testteam down "now for another reason" "bash remote.sh sync start testteam"
  run bash -c 'printf "{\"session_id\":\"sid-three\"}" | bash "$1" claude-code /tmp/project-a' _ "$SCRIPTS/session-start.sh"
  printf '%s\n' "$output" | grep -qF "now for another reason"
}
