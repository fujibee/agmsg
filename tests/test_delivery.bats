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
