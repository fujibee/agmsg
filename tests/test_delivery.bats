#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
}

teardown() {
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

# Count agmsg-owned entries in a hooks-event array.
agmsg_entries() {
  local file="$1"
  local event="$2"
  if [ ! -f "$file" ]; then echo 0; return; fi
  sqlite3 :memory: "
    SELECT count(*) FROM json_each(json_extract(readfile('$file'), '\$.hooks.$event')) AS s
    WHERE EXISTS (
      SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
      WHERE instr(json_extract(h.value, '\$.command'), 'agmsg') > 0
        OR instr(json_extract(h.value, '\$.command'), \"$(basename $(dirname $(dirname $file)))\") > 0
        OR instr(json_extract(h.value, '\$.command'), '$(dirname $file)') > 0
    );
  " 2>/dev/null || echo 0
}

# Simpler probe: grep for our scripts directly.
has_session_start() {
  [ -f "$1" ] && grep -q "session-start.sh" "$1"
}
has_check_inbox() {
  [ -f "$1" ] && grep -q "check-inbox.sh" "$1"
}

settings_file() {
  echo "$TEST_PROJECT/.claude/settings.local.json"
}

# --- set <mode> ---

@test "delivery set monitor: installs SessionStart, no Stop" {
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

@test "delivery set turn: installs Stop, no SessionStart" {
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  has_check_inbox "$(settings_file)"
  ! has_session_start "$(settings_file)"
}

@test "delivery set both: installs SessionStart and Stop" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  has_check_inbox "$(settings_file)"
}

@test "delivery set off: removes both hooks" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  ! has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

# --- idempotency ---

@test "delivery set monitor: idempotent" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(settings_file)'), '\$.hooks.SessionStart'));")
  [ "$n" = "1" ]
}

@test "delivery set both: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  local s t
  s=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(settings_file)'), '\$.hooks.SessionStart'));")
  t=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(settings_file)'), '\$.hooks.Stop'));")
  [ "$s" = "1" ]
  [ "$t" = "1" ]
}

# --- mode transitions ---

@test "delivery: turn -> monitor swaps hooks cleanly" {
  bash "$SCRIPTS/delivery.sh" set turn    claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

@test "delivery: monitor -> turn swaps hooks cleanly" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn    claude-code "$TEST_PROJECT"
  has_check_inbox "$(settings_file)"
  ! has_session_start "$(settings_file)"
}

@test "delivery: both -> off clears settings.local.json hooks" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off  claude-code "$TEST_PROJECT"
  ! has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

# --- preserves user settings ---

@test "delivery set monitor: preserves unrelated settings" {
  mkdir -p "$TEST_PROJECT/.claude"
  echo '{"permissions":{"allow":["Bash"]}}' > "$(settings_file)"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  local p
  p=$(sqlite3 :memory: "SELECT json_extract(readfile('$(settings_file)'), '\$.permissions.allow[0]');")
  [ "$p" = "Bash" ]
}

# --- config is updated alongside ---

@test "delivery set: writes delivery.mode into config.yaml" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  run bash "$SCRIPTS/config.sh" get delivery.mode
  [ "$output" = "both" ]
}

# --- hook.sh backward compat ---

@test "hook.sh on delegates to delivery set turn" {
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  has_check_inbox "$(settings_file)"
  run bash "$SCRIPTS/config.sh" get delivery.mode
  [ "$output" = "turn" ]
}

@test "hook.sh off delegates to delivery set off" {
  bash "$SCRIPTS/hook.sh" on  claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT"
  ! has_check_inbox "$(settings_file)"
  run bash "$SCRIPTS/config.sh" get delivery.mode
  [ "$output" = "off" ]
}

# --- rejects unknown mode ---

@test "delivery set: rejects unknown mode" {
  run bash "$SCRIPTS/delivery.sh" set bogus claude-code "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown mode" ]]
}
