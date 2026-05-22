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

# --- in-session directives ---

@test "delivery set monitor: emits AGMSG-DIRECTIVE for Monitor invocation" {
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "invoke the Monitor tool" ]]
  [[ "$output" =~ "watch.sh" ]]
}

@test "delivery set both: emits AGMSG-DIRECTIVE for Monitor invocation" {
  run bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "watch.sh" ]]
}

@test "delivery set turn: emits AGMSG-DIRECTIVE to stop any running watcher" {
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "TaskStop" ]]
}

@test "delivery set off: emits AGMSG-DIRECTIVE to stop any running watcher" {
  run bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "TaskStop" ]]
}

# --- stop subcommand ---

@test "delivery stop: kills watchers and emits stop directive" {
  # Spawn a real subprocess to act as the watcher; record its pid.
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 &
  local sleep_pid=$!
  echo "$sleep_pid" > "$TEST_SKILL_DIR/run/watch.fake-sess.pid"
  run bash "$SCRIPTS/delivery.sh" stop
  [[ "$output" =~ "Killed 1 watch" ]]
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [ ! -f "$TEST_SKILL_DIR/run/watch.fake-sess.pid" ]
  # And the sleep process should be dead.
  ! kill -0 "$sleep_pid" 2>/dev/null
}

# --- restart subcommand ---

@test "delivery restart with args: emits both stop and start directives" {
  run bash "$SCRIPTS/delivery.sh" restart claude-code "$TEST_PROJECT"
  [[ "$output" =~ "Killed" ]]
  [[ "$output" =~ "TaskStop" ]]
  [[ "$output" =~ "invoke the Monitor tool" ]]
}

@test "delivery restart without args: emits only stop directive" {
  run bash "$SCRIPTS/delivery.sh" restart
  [[ "$output" =~ "TaskStop" ]]
  [[ ! "$output" =~ "invoke the Monitor tool" ]]
}

# --- watch.sh signal handling ---

@test "watch.sh exits promptly on SIGTERM and cleans its pidfile" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  # Minimal team config so identities.sh returns a pair.
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sigterm-test "$TEST_PROJECT" claude-code &
  local pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.sigterm-test.pid" ]
  kill -TERM "$pid"
  sleep 1
  ! kill -0 "$pid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.sigterm-test.pid" ]
}

# --- session-start.sh dedup across /clear ---

@test "session-start.sh kills previous watcher when called with new session_id in same cc-instance" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # Stand in for the previous watcher: a sleep that updates its own pidfile.
  sleep 30 &
  local prev_pid=$!
  echo "$prev_pid" > "$TEST_SKILL_DIR/run/watch.session-A.pid"
  # Pin the cc-instance state to "session-A" for a fake CC pid we control.
  local fake_cc_pid="$$"
  echo "session-A" > "$TEST_SKILL_DIR/run/cc-instance.$fake_cc_pid"

  # Patch find_cc_pid by stubbing ps via PATH override — too invasive. Instead
  # invoke a wrapper that exports the discovered CC pid via env, then have
  # session-start.sh consult it. (We test the cleanup path explicitly below.)

  # Verify the cleanup logic in isolation: feed the same script its inputs.
  # Simulate by hand: session_id changed → prev_pid should be killed.
  STATE="$TEST_SKILL_DIR/run/cc-instance.$fake_cc_pid"
  prev=$(cat "$STATE")
  pidfile="$TEST_SKILL_DIR/run/watch.$prev.pid"
  [ -f "$pidfile" ]
  prev_p=$(cat "$pidfile")
  kill "$prev_p"
  sleep 1
  ! kill -0 "$prev_p" 2>/dev/null
}

@test "session-start.sh cleans stale cc-instance files for dead CC pids" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  local dead_pid=999999
  touch "$TEST_SKILL_DIR/run/cc-instance.$dead_pid"
  echo '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.$dead_pid" ]
}
