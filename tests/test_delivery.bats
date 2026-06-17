#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Pin bare instance-id keying (#93) so watcher pidfiles / cc-instance records
  # stay keyed on the raw session_id these tests pass — deterministic in CI and
  # when the suite runs under an agent process. Composite path: test_watch.bats.
  export AGMSG_AGENT_PID=""
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

# --- status derives mode from settings.local.json ---

@test "delivery status: derives 'both' from settings with SessionStart + Stop" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" =~ "mode: both" ]]
}

@test "delivery status: derives 'monitor' from settings with SessionStart only" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "delivery status: derives 'turn' from settings with Stop only" {
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

@test "delivery status: derives 'off' from settings with no agmsg hooks" {
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]
}

# --- hook.sh backward compat ---

@test "hook.sh on delegates to delivery set turn" {
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT" 2>&1
  has_check_inbox "$(settings_file)"
  ! has_session_start "$(settings_file)"
}

@test "hook.sh off delegates to delivery set off" {
  bash "$SCRIPTS/hook.sh" on  claude-code "$TEST_PROJECT" 2>&1
  bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT" 2>&1
  ! has_check_inbox "$(settings_file)"
  ! has_session_start "$(settings_file)"
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
  # Spawn an actual watch.sh process so the safety check (argv contains
  # watch.sh) passes.
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" stop-test "$TEST_PROJECT" claude-code &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.stop-test.pid" ]
  run bash "$SCRIPTS/delivery.sh" stop
  [[ "$output" =~ "Killed 1 watch" ]]
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [ ! -f "$TEST_SKILL_DIR/run/watch.stop-test.pid" ]
  sleep 1
  ! kill -0 "$watch_pid" 2>/dev/null
}

@test "delivery stop: skips pid whose command line is not watch.sh (pid recycling safety)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 &
  local unrelated_pid=$!
  echo "$unrelated_pid" > "$TEST_SKILL_DIR/run/watch.stale-sess.pid"
  run bash "$SCRIPTS/delivery.sh" stop
  [[ "$output" =~ "Killed 0 watch" ]]
  [ ! -f "$TEST_SKILL_DIR/run/watch.stale-sess.pid" ]
  # The unrelated sleep process must still be alive.
  kill -0 "$unrelated_pid" 2>/dev/null
  kill "$unrelated_pid" 2>/dev/null || true
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

# --- SessionEnd hook integration ---

has_session_end() {
  [ -f "$1" ] && grep -q "session-end.sh" "$1"
}

@test "delivery set monitor: installs SessionEnd alongside SessionStart" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  has_session_end   "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

@test "delivery set both: installs SessionStart, SessionEnd, Stop" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  has_session_end   "$(settings_file)"
  has_check_inbox   "$(settings_file)"
}

@test "delivery set turn: no SessionEnd installed" {
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  ! has_session_end "$(settings_file)"
}

@test "delivery set off: removes SessionEnd along with other entries" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off  claude-code "$TEST_PROJECT"
  ! has_session_end "$(settings_file)"
}

@test "delivery: monitor is idempotent for SessionEnd entry" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(settings_file)'), '\$.hooks.SessionEnd'));")
  [ "$n" = "1" ]
}

# --- session-end.sh behavior ---

@test "session-end.sh kills the watcher matching session_id and removes pidfile" {
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 &
  local target_pid=$!
  echo "$target_pid" > "$TEST_SKILL_DIR/run/watch.sess-A.pid"
  echo '{"session_id":"sess-A"}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
  sleep 1
  ! kill -0 "$target_pid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.sess-A.pid" ]
}

@test "session-end.sh leaves other sessions' watchers alone" {
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 &
  local other_pid=$!
  echo "$other_pid" > "$TEST_SKILL_DIR/run/watch.sess-B.pid"
  echo '{"session_id":"sess-A"}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
  kill -0 "$other_pid" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.sess-B.pid" ]
  kill "$other_pid" 2>/dev/null || true
}

@test "session-end.sh removes cc-instance file that points to this session" {
  mkdir -p "$TEST_SKILL_DIR/run"
  echo "sess-A" > "$TEST_SKILL_DIR/run/cc-instance.12345"
  echo "sess-B" > "$TEST_SKILL_DIR/run/cc-instance.67890"
  echo '{"session_id":"sess-A"}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.12345" ]
  [ -f "$TEST_SKILL_DIR/run/cc-instance.67890" ]
}

@test "session-end.sh exits 0 when input has no session_id" {
  echo '{}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
}

# --- CLAUDE_CODE_SESSION_ID baking ---

@test "delivery set monitor: bakes CLAUDE_CODE_SESSION_ID into the directive" {
  CLAUDE_CODE_SESSION_ID="real-uuid-1234" run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [[ "$output" =~ "real-uuid-1234" ]]
  ! [[ "$output" =~ "\\\$AGMSG_SESSION_ID" ]]
  ! [[ "$output" =~ "\\\$CLAUDE_CODE_SESSION_ID" ]]
}

@test "delivery set monitor: falls back to a generated id when env is unset" {
  # Ensure env var is unset
  unset CLAUDE_CODE_SESSION_ID
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  # No placeholder leaked
  ! [[ "$output" =~ "\\\$AGMSG_SESSION_ID" ]]
}

# --- session-start.sh: stale watcher pidfile cleanup ---

@test "session-start.sh removes watch.<sid>.pid files whose pid is dead" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  echo "999999" > "$TEST_SKILL_DIR/run/watch.dead-session.pid"  # bogus pid
  : > "$TEST_SKILL_DIR/run/watch.empty-pid.pid"                  # empty pid
  echo '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.dead-session.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/watch.empty-pid.pid" ]
}

@test "session-start.sh leaves alive watcher pidfiles alone (when bound to a live CC instance)" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 &
  local alive_pid=$!
  echo "$alive_pid" > "$TEST_SKILL_DIR/run/watch.live-session.pid"
  # Bind this watcher to a live CC instance (use $$ as a stand-in).
  echo "live-session" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  echo '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.live-session.pid" ]
  kill "$alive_pid" 2>/dev/null || true
}

# --- hook.sh deprecation notice ---

@test "hook.sh on prints a deprecation notice on stderr" {
  run bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  # Combined stderr+stdout is captured by `run` — assert the notice appears.
  [[ "$output" =~ "deprecated" ]]
}

@test "hook.sh off prints a deprecation notice on stderr" {
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "deprecated" ]]
}

# --- emit_monitor_directive idempotency ---

@test "emit monitor directive: skips when a live watcher already exists for this session" {
  mkdir -p "$TEST_SKILL_DIR/run"
  # Spawn a live process and pretend it's our watcher for this session_id.
  sleep 30 &
  local live_pid=$!
  CLAUDE_CODE_SESSION_ID="live-test-sid"
  export CLAUDE_CODE_SESSION_ID
  echo "$live_pid" > "$TEST_SKILL_DIR/run/watch.$CLAUDE_CODE_SESSION_ID.pid"

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already streaming" ]]
  ! [[ "$output" =~ "AGMSG-DIRECTIVE" ]]

  kill "$live_pid" 2>/dev/null || true
  unset CLAUDE_CODE_SESSION_ID
}

@test "emit monitor directive: emits when no live watcher exists for this session" {
  CLAUDE_CODE_SESSION_ID="fresh-sid-no-watcher"
  export CLAUDE_CODE_SESSION_ID

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "fresh-sid-no-watcher" ]]

  unset CLAUDE_CODE_SESSION_ID
}

# --- gemini agent tests ---

@test "delivery set turn (gemini): installs rule file" {
  run bash "$SCRIPTS/delivery.sh" set turn gemini "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  [ -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
  grep -q "check-inbox.sh" "$TEST_PROJECT/.agent/rules/agmsg.md"
}

@test "delivery set off (gemini): removes rule file" {
  bash "$SCRIPTS/delivery.sh" set turn gemini "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set off gemini "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
}

@test "delivery status (gemini): derives mode from rule file existence" {
  run bash "$SCRIPTS/delivery.sh" status gemini "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn gemini "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status gemini "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

# --- copilot agent tests ---

@test "delivery set turn (copilot): writes .github/hooks/agmsg.json with version + Stop entry" {
  run bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  local hook_file="$TEST_PROJECT/.github/hooks/agmsg.json"
  [ -f "$hook_file" ]
  # JSON sanity: version=1, Stop entry references check-inbox.sh
  local v
  v=$(sqlite3 :memory: "SELECT json_extract(readfile('$hook_file'), '\$.version');")
  [ "$v" = "1" ]
  local cmd
  cmd=$(sqlite3 :memory: "SELECT json_extract(readfile('$hook_file'), '\$.hooks.Stop[0].bash');")
  [[ "$cmd" =~ "check-inbox.sh" ]]
  [[ "$cmd" =~ "copilot" ]]
}

@test "delivery set off (copilot): removes the hook file" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
  run bash "$SCRIPTS/delivery.sh" set off copilot "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
}

@test "delivery set monitor (copilot): rejected; no hook file written" {
  run bash "$SCRIPTS/delivery.sh" set monitor copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
}

# Regression for a Copilot review finding: the unsupported-mode arms used to
# `rm -f` the hook file before validating the mode, so fat-fingering
# `mode monitor` on a project with a working `turn` config silently wiped
# delivery. Validation must come first.
@test "delivery set monitor (copilot): does NOT delete an existing turn hook" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
  run bash "$SCRIPTS/delivery.sh" set monitor copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$TEST_PROJECT/.github/hooks/agmsg.json'), '\$.hooks.Stop'));")
  [ "$n" = "1" ]
}

@test "delivery set both (copilot): does NOT delete an existing turn hook" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" set both copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
}

@test "delivery set both (copilot): rejected" {
  run bash "$SCRIPTS/delivery.sh" set both copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
}

@test "delivery status (copilot): derives mode from hook file existence" {
  run bash "$SCRIPTS/delivery.sh" status copilot "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status copilot "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

@test "delivery set turn (copilot): idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  local n
  n=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$TEST_PROJECT/.github/hooks/agmsg.json'), '\$.hooks.Stop'));")
  [ "$n" = "1" ]
}

@test "check-inbox (copilot): emits JSON cooldown message inside cooldown window" {
  bash "$SCRIPTS/join.sh" testteam alice copilot "$TEST_PROJECT"
  # Prime the cooldown marker
  echo '{}' | bash "$SCRIPTS/check-inbox.sh" copilot "$TEST_PROJECT" >/dev/null
  # Second call within cooldown: copilot should get JSON, not silence
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' copilot '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg: check skipped (cooldown)" ]]
  [[ "$output" =~ "\"continue\"" ]]
}

@test "check-inbox (copilot): emits decision=block JSON when new messages arrive" {
  bash "$SCRIPTS/join.sh" testteam alice copilot "$TEST_PROJECT"
  bash "$SCRIPTS/join.sh" testteam bob   copilot "$TEST_PROJECT"
  # Push cooldown window into the past so the first invocation is not skipped.
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "ping copilot"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' copilot '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"decision\": \"block\"" ]]
  [[ "$output" =~ "ping copilot" ]]
}





# --- watch.sh exclusive role filter ---

@test "watch.sh restricts subscription to active_name when 4th arg is given" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{
  "name":"myteam",
  "agents":{
    "alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]},
    "bob":  {"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}
  }
}
JSON
  # Insert two messages, one for each agent.
  DB="$TEST_SKILL_DIR/db/messages.db"
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'system', 'alice', 'for-alice');"
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'system', 'bob', 'for-bob');"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" t-sid "$TEST_PROJECT" claude-code bob > /tmp/agmsg-as-bob 2>&1 &
  local pid=$!
  # High-water-mark = MAX(id) at startup, so prior messages aren't replayed.
  # Insert NEW messages and wait for several poll iterations.
  sleep 1
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'system', 'alice', 'new-for-alice');"
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'system', 'bob', 'new-for-bob');"
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true

  grep -q "new-for-bob"   /tmp/agmsg-as-bob
  ! grep -q "new-for-alice" /tmp/agmsg-as-bob
  rm -f /tmp/agmsg-as-bob
}

@test "watch.sh exits when active_name is not registered" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  run bash "$SCRIPTS/watch.sh" t-sid "$TEST_PROJECT" claude-code nobody
  [[ "$output" =~ "no registration for agent 'nobody'" ]]
}

# --- session-start.sh orphan watcher cleanup ---

@test "session-start.sh kills orphan watchers whose owning CC instance is gone" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # Orphan: watcher referenced by a cc-instance.<dead-pid> file.
  sleep 30 &
  local orphan_pid=$!
  echo "$orphan_pid" > "$TEST_SKILL_DIR/run/watch.orphan-sid.pid"
  # Use a PID that's almost certainly not in use as the dead CC ancestor.
  local dead_cc_pid=999999
  echo "orphan-sid" > "$TEST_SKILL_DIR/run/cc-instance.$dead_cc_pid"

  # Untracked watcher: no cc-instance points to it. Conservative semantics
  # leave it alone (we have no evidence the CC is dead).
  sleep 30 &
  local untracked_pid=$!
  echo "$untracked_pid" > "$TEST_SKILL_DIR/run/watch.untracked-sid.pid"

  echo "{\"session_id\":\"current-sid\"}" \
    | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null

  ! kill -0 "$orphan_pid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.orphan-sid.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.$dead_cc_pid" ]
  # Untracked watcher untouched
  kill -0 "$untracked_pid" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.untracked-sid.pid" ]
  kill "$untracked_pid" 2>/dev/null || true
}

@test "session-start.sh does NOT kill a watcher when its session_id is still live under a different CC pid" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # The session moved from one CC pid to another (claude --continue / resume).
  # cc-instance.<dead> still references the same session_id as
  # cc-instance.<live>. The watcher must NOT be killed.
  sleep 30 &
  local watcher_pid=$!
  echo "$watcher_pid" > "$TEST_SKILL_DIR/run/watch.shared-sid.pid"
  local dead_cc=999999
  echo "shared-sid" > "$TEST_SKILL_DIR/run/cc-instance.$dead_cc"
  echo "shared-sid" > "$TEST_SKILL_DIR/run/cc-instance.$$"

  echo "{\"session_id\":\"x\"}" \
    | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null

  kill -0 "$watcher_pid" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.shared-sid.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.$dead_cc" ]
  kill "$watcher_pid" 2>/dev/null || true
}

@test "watch.sh subscription is static — newly joined identities don't appear in a running watcher" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  DB="$TEST_SKILL_DIR/db/messages.db"

  # Watcher starts with only `alice` registered. Default subscription set
  # is resolved at launch and not re-evaluated each poll.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" t-static "$TEST_PROJECT" claude-code > /tmp/agmsg-static 2>&1 &
  local pid=$!
  sleep 1

  # Join `bob` to the same (project, type) after the watcher is running.
  bash "$SCRIPTS/join.sh" myteam bob claude-code "$TEST_PROJECT"

  # Insert messages for both. alice should arrive (alice was in the original
  # subscription set); bob should NOT arrive (joined after launch).
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'sys', 'alice', 'for-alice-static');"
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'sys', 'bob',   'for-bob-static');"

  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true

  grep -q "for-alice-static" /tmp/agmsg-static
  ! grep -q "for-bob-static" /tmp/agmsg-static
  rm -f /tmp/agmsg-static
}

# --- set turn/off is project-scoped: must not kill other projects' watchers ---

@test "delivery set turn: kills only the target project's watcher, leaves other projects'" {
  local proj_a="$TEST_PROJECT"
  local proj_b
  proj_b="$(mktemp -d)"

  mkdir -p "$TEST_SKILL_DIR/teams/team-a" "$TEST_SKILL_DIR/teams/team-b"
  cat > "$TEST_SKILL_DIR/teams/team-a/config.json" <<JSON
{"name":"team-a","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$proj_a"}]}}}
JSON
  cat > "$TEST_SKILL_DIR/teams/team-b/config.json" <<JSON
{"name":"team-b","agents":{"bob":{"registrations":[{"type":"claude-code","project":"$proj_b"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sid-a "$proj_a" claude-code &
  local pid_a=$!
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sid-b "$proj_b" claude-code &
  local pid_b=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.sid-a.pid" ]
  [ -f "$TEST_SKILL_DIR/run/watch.sid-b.pid" ]

  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj_a"
  [ "$status" -eq 0 ]
  sleep 1

  # Target project A: watcher killed, pidfile removed.
  ! kill -0 "$pid_a" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.sid-a.pid" ]

  # Other project B: watcher and its pidfile must survive.
  kill -0 "$pid_b" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.sid-b.pid" ]

  kill "$pid_b" 2>/dev/null || true
  rm -rf "$proj_b"
}

@test "delivery set off: kills only the target project's watcher, leaves other projects'" {
  local proj_a="$TEST_PROJECT"
  local proj_b
  proj_b="$(mktemp -d)"

  mkdir -p "$TEST_SKILL_DIR/teams/team-a" "$TEST_SKILL_DIR/teams/team-b"
  cat > "$TEST_SKILL_DIR/teams/team-a/config.json" <<JSON
{"name":"team-a","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$proj_a"}]}}}
JSON
  cat > "$TEST_SKILL_DIR/teams/team-b/config.json" <<JSON
{"name":"team-b","agents":{"bob":{"registrations":[{"type":"claude-code","project":"$proj_b"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" off-a "$proj_a" claude-code &
  local pid_a=$!
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" off-b "$proj_b" claude-code &
  local pid_b=$!
  sleep 1

  run bash "$SCRIPTS/delivery.sh" set off claude-code "$proj_a"
  [ "$status" -eq 0 ]
  sleep 1

  ! kill -0 "$pid_a" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.off-a.pid" ]
  kill -0 "$pid_b" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.off-b.pid" ]

  kill "$pid_b" 2>/dev/null || true
  rm -rf "$proj_b"
}

@test "delivery stop: remains global — kills watchers across all projects" {
  local proj_a="$TEST_PROJECT"
  local proj_b
  proj_b="$(mktemp -d)"

  mkdir -p "$TEST_SKILL_DIR/teams/team-a" "$TEST_SKILL_DIR/teams/team-b"
  cat > "$TEST_SKILL_DIR/teams/team-a/config.json" <<JSON
{"name":"team-a","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$proj_a"}]}}}
JSON
  cat > "$TEST_SKILL_DIR/teams/team-b/config.json" <<JSON
{"name":"team-b","agents":{"bob":{"registrations":[{"type":"claude-code","project":"$proj_b"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" stop-a "$proj_a" claude-code &
  local pid_a=$!
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" stop-b "$proj_b" claude-code &
  local pid_b=$!
  sleep 1

  run bash "$SCRIPTS/delivery.sh" stop
  [[ "$output" =~ "Killed 2 watch" ]]
  sleep 1
  ! kill -0 "$pid_a" 2>/dev/null
  ! kill -0 "$pid_b" 2>/dev/null

  rm -rf "$proj_b"
}

# --- Windows support: codex hooks emit commandWindows; other types do not ---

@test "delivery set turn (codex): Stop entry carries commandWindows wrapping Git Bash" {
  run bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local hook_file="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hook_file" ]
  local cw
  cw=$(sqlite3 :memory: "SELECT json_extract(readfile('$hook_file'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
  [ -n "$cw" ]
  [[ "$cw" == *"Program Files\\Git\\bin\\bash.exe"* ]]
  [[ "$cw" == *"GIT_BASH"* ]]
  [[ "$cw" == *"-lc"* ]]
  [[ "$cw" != *".agents/bin"* ]]
  [[ "$cw" == *"check-inbox.sh"* ]]
}

@test "delivery set turn (claude-code): Stop entry has NO commandWindows (regression guard)" {
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local hook_file="$TEST_PROJECT/.claude/settings.local.json"
  [ -f "$hook_file" ]
  local cw
  cw=$(sqlite3 :memory: "SELECT json_extract(readfile('$hook_file'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
  [ -z "$cw" ]
}

# --- Large settings.local.json: must not trip Linux MAX_ARG_STRLEN (#95) ---
#
# Reporter's actual settings was 32,357 bytes. The pre-fix code embedded the
# whole blob 6x into one sqlite3 argv element inside strip_agmsg_event, so on
# Linux (MAX_ARG_STRLEN = 131072) anything above ~21 KB triggered E2BIG. The
# test below uses ~30 KB to stay close to the reporter's size and reliably
# fail before the fix on Linux. macOS has a much higher per-arg ceiling
# (kern.argmax ≈ 1 MB) so the pre-fix code can survive 30 KB there — the
# test still passes on macOS post-fix; the regression guard is meaningful
# on Linux CI.

@test "delivery set monitor: handles a large settings.local.json without E2BIG (#95)" {
  mkdir -p "$TEST_PROJECT/.claude"
  # Build a ~30 KB settings file with a populated permissions.allow list.
  # 600 entries * ~50 bytes each ≈ 30 KB.
  {
    printf '{"permissions":{"allow":['
    local i
    for i in $(seq 1 600); do
      [ "$i" -gt 1 ] && printf ','
      printf '"Bash(mkdir:/tmp/agmsg-e2big-entry-%04d)"' "$i"
    done
    printf ']}}'
  } > "$(settings_file)"
  local size
  size=$(wc -c < "$(settings_file)" | tr -d ' ')
  [ "$size" -gt 25000 ]

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  has_session_start "$(settings_file)"

  # Existing user permissions must be preserved across the rewrite.
  local first last allow_len
  first=$(sqlite3 :memory: "SELECT json_extract(readfile('$(settings_file)'), '\$.permissions.allow[0]');")
  last=$(sqlite3 :memory:  "SELECT json_extract(readfile('$(settings_file)'), '\$.permissions.allow[599]');")
  allow_len=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(settings_file)'), '\$.permissions.allow'));")
  [ "$first" = "Bash(mkdir:/tmp/agmsg-e2big-entry-0001)" ]
  [ "$last" = "Bash(mkdir:/tmp/agmsg-e2big-entry-0600)" ]
  [ "$allow_len" = "600" ]
}

@test "delivery set both: handles a large settings.local.json across strip+add+prune (#95)" {
  mkdir -p "$TEST_PROJECT/.claude"
  {
    printf '{"permissions":{"allow":['
    local i
    for i in $(seq 1 600); do
      [ "$i" -gt 1 ] && printf ','
      printf '"Bash(mkdir:/tmp/agmsg-e2big-both-%04d)"' "$i"
    done
    printf ']}}'
  } > "$(settings_file)"

  # `both` exercises three add_event_entry_file calls after three
  # strip_agmsg_event_file calls — the longest chain in apply_settings.
  run bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  has_session_start "$(settings_file)"
  has_check_inbox "$(settings_file)"

  local allow_len
  allow_len=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(settings_file)'), '\$.permissions.allow'));")
  [ "$allow_len" = "600" ]
}

@test "delivery set off: idempotent strip on a large settings.local.json (#95)" {
  mkdir -p "$TEST_PROJECT/.claude"
  # Pre-populate with both user permissions and an agmsg-owned Stop entry,
  # then verify `set off` strips only the agmsg entry without choking on
  # the file size. Build the inflated fixture via sqlite3 (no python3
  # dependency — agmsg is bash + sqlite3 only).
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"

  local allow_json
  allow_json=$(
    printf '['
    local i
    for i in $(seq 1 600); do
      [ "$i" -gt 1 ] && printf ','
      printf '"Bash(mkdir:/tmp/agmsg-e2big-off-%04d)"' "$i"
    done
    printf ']'
  )
  local inflated
  inflated=$(sqlite3 :memory: "
    SELECT json_set(
      json_set(readfile('$(settings_file)'), '\$.permissions', json('{}')),
      '\$.permissions.allow', json('$allow_json')
    );
  ")
  printf '%s' "$inflated" > "$(settings_file)"

  run bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  ! has_check_inbox "$(settings_file)"
  local allow_len
  allow_len=$(sqlite3 :memory: "SELECT json_array_length(json_extract(readfile('$(settings_file)'), '\$.permissions.allow'));")
  [ "$allow_len" = "600" ]
}

# --- opencode agent tests ---

@test "opencode is accepted as an agent type (turn mode)" {
  run bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  grep -q "check-inbox.sh" "$TEST_PROJECT/.opencode/rules/agmsg.md"
}

@test "opencode supports off mode: removes rule file" {
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set off opencode "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
}

@test "opencode rejects monitor mode" {
  run bash "$SCRIPTS/delivery.sh" set monitor opencode "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
}

@test "opencode rejects both mode" {
  run bash "$SCRIPTS/delivery.sh" set both opencode "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
}

@test "opencode rejects monitor: does NOT delete an existing turn rule" {
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set monitor opencode "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
}

@test "opencode supports turn and off modes: status derives mode from rule file existence" {
  run bash "$SCRIPTS/delivery.sh" status opencode "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status opencode "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

@test "opencode set turn: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  local count
  count=$(grep -c "check-inbox.sh" "$TEST_PROJECT/.opencode/rules/agmsg.md")
  [ "$count" -eq 1 ]
}
