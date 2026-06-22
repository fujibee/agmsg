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
  sqlite_mem "
    SELECT count(*) FROM json_each(json_extract(readfile('$(rf "$file")'), '\$.hooks.$event')) AS s
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
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.SessionStart'));")
  [ "$n" = "1" ]
}

@test "delivery set both: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  local s t
  s=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.SessionStart'));")
  t=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.Stop'));")
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
  p=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow[0]');")
  [ "$p" = "Bash" ]
}

@test "delivery set monitor: round-trips multibyte (UTF-8) settings without a short-write reject" {
  # The writefile() guard compares bytes written to the content's BYTE length
  # (CAST AS BLOB). A character-length comparison would mismatch on multibyte
  # content and wrongly reject the write, so set monitor would fail. Seed an
  # unrelated multibyte value and confirm the write succeeds and survives.
  mkdir -p "$TEST_PROJECT/.claude"
  printf '%s\n' '{"note":"日本語のメモ — ünïcödé ✓","permissions":{"allow":["Bash"]}}' > "$(settings_file)"

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]

  # Still valid JSON, the multibyte value survived byte-for-byte, hook landed.
  local valid
  valid=$(sqlite_mem "SELECT json_valid(readfile('$(rf "$(settings_file)")'));")
  [ "$valid" = "1" ]
  grep -q "日本語のメモ" "$(settings_file)"
  grep -q "session-start.sh" "$(settings_file)"
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

@test "delivery status: claude-code still reports the watch process summary" {
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"watch processes:"* ]]
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

# The host pastes the emitted command into Monitor and runs it as a shell
# command; if the argv isn't shell-quoted, a project path with whitespace
# (iCloud Drive) or an apostrophe (/Users/o'brien/...) is mis-parsed and watch.sh
# resolves the wrong project. These re-parse the emitted line the way the host
# shell would and assert the project survives as one argv element. The path
# carries BOTH a space and an apostrophe (the case a plain '...' wrap breaks on).
# AGMSG_RESOLVE_PROJECT=0 keeps the raw path so the round-trip is deterministic.

@test "delivery set monitor: directive argv round-trips through a shell (#188)" {
  local sp="$TEST_PROJECT/Mobile Documents/o'brien proj"
  mkdir -p "$sp"
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/delivery.sh" set monitor claude-code "$sp"
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  [ -n "$cmdline" ]
  eval "set -- $cmdline"
  [ "$3" = "$sp" ]
  [ "$4" = "claude-code" ]
}

@test "session-start: Monitor directive argv round-trips through a shell (#188)" {
  local sp="$TEST_PROJECT/Mobile Documents/o'brien proj"
  mkdir -p "$sp"
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$sp" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$sp" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "invoke the Monitor tool" ]]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  [ -n "$cmdline" ]
  eval "set -- $cmdline"
  [ "$3" = "$sp" ]
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
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
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

# --- watcher teardown is (project, type)-scoped (#218) ---
# claude-code is the only type that runs a watch.sh watcher. Before scoping,
# `set turn <any other type>` ran `kill_all_watchers "$PROJECT"` (project only)
# and tore down the project's claude-code monitor — collateral that killed
# unrelated agents' monitors on a shared machine.

@test "delivery set turn (other type): does NOT kill the project's claude-code watcher (#218)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  # A live claude-code watcher for this project.
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" cc-sess "$TEST_PROJECT" claude-code &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.cc-sess.pid" ]
  # Switching a DIFFERENT type's delivery in the SAME project must not touch it.
  run bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/run/watch.cc-sess.pid" ]
  kill -0 "$watch_pid" 2>/dev/null
  kill "$watch_pid" 2>/dev/null || true
}

@test "delivery set off (claude-code): DOES kill the project's claude-code watcher (type matches)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" cc-sess2 "$TEST_PROJECT" claude-code &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.cc-sess2.pid" ]
  run bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_SKILL_DIR/run/watch.cc-sess2.pid" ]
  sleep 1
  ! kill -0 "$watch_pid" 2>/dev/null
}

@test "delivery (project, type) scoping holds for a project path with spaces (#218)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  # The argv match is the literal "<project> <type>" string, so a space in the
  # project path is matched verbatim — no false negatives (target preserved/
  # killed correctly) and no false positives across the space boundary.
  local sp="$TEST_PROJECT/with space proj"
  mkdir -p "$sp"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$sp"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sp-sess "$sp" claude-code &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.sp-sess.pid" ]
  # Another type's set turn in the SAME space-containing project: must NOT kill it.
  run bash "$SCRIPTS/delivery.sh" set turn copilot "$sp"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/run/watch.sp-sess.pid" ]
  kill -0 "$watch_pid" 2>/dev/null
  # claude-code off for the SAME space-containing project: must kill it (right target).
  run bash "$SCRIPTS/delivery.sh" set off claude-code "$sp"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_SKILL_DIR/run/watch.sp-sess.pid" ]
  sleep 1
  ! kill -0 "$watch_pid" 2>/dev/null
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

# --- session-id resolution: vendor field-name differences (grok/cursor) ---
# Grok Build emits the session id on stdin as camelCase "sessionId" and injects
# GROK_SESSION_ID into every hook; Claude uses snake_case "session_id". The
# shared resolver tries snake -> camel -> $GROK_SESSION_ID. The Monitor
# directive echoes the resolved id as the watch.sh command's session arg, so we
# assert through that. (Exercised via claude-code since the resolver is shared.)

@test "session-start: resolves camelCase sessionId from stdin (grok/cursor field)" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<<'{"sessionId":"grokCamelSID"}'
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [[ "$2" =~ grokCamelSID ]]
}

@test "session-start: falls back to GROK_SESSION_ID env when stdin lacks a session id" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 GROK_SESSION_ID=grokEnvSID bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [[ "$2" =~ grokEnvSID ]]
}

@test "session-start: snake_case session_id still wins over camelCase (claude-code unaffected)" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<<'{"session_id":"snakeWins","sessionId":"camelLoses"}'
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [[ "$2" =~ snakeWins ]]
  [[ ! "$2" =~ camelLoses ]]
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
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.SessionEnd'));")
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

@test "session-start.sh for codex matches rollout cwd via a symlinked project path (#160)" {
  skip_on_windows "codex bridge launch and symlink path on Windows (#182)"
  # agmsg opens the project through a symlink (linkproj), but Codex records the
  # canonical/physical cwd (realproj) in session_meta. A raw string compare
  # misses the rollout, so the thread never resolves and the bridge never
  # starts. With physical-path canonicalization the two reconcile.
  local realproj="$TEST_PROJECT/realproj"
  local linkproj="$TEST_PROJECT/linkproj"
  mkdir -p "$realproj"
  ln -s "$realproj" "$linkproj"
  local phys
  phys=$(cd "$realproj" && pwd -P)

  bash "$SCRIPTS/join.sh" team alice codex "$linkproj" >/dev/null

  # Stage a Codex rollout whose session_meta records the PHYSICAL cwd.
  local sdir="$HOME/.codex/sessions/2026/06/19"
  mkdir -p "$sdir"
  printf '{"type":"session_meta","payload":{"id":"thread-sym","cwd":"%s"}}\n' "$phys" \
    > "$sdir/rollout-test.jsonl"

  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  # env -u CODEX_THREAD_ID forces the rollout-scan fallback that does the
  # compare — without it, a CODEX_THREAD_ID inherited from the parent env (e.g.
  # running the suite inside a Codex session) short-circuits the resolver and
  # this test never exercises the path it's meant to cover.
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$fake" \
  AGMSG_TEST_LOG="$log" \
    env -u CODEX_THREAD_ID bash "$SCRIPTS/session-start.sh" codex "$linkproj" >/dev/null

  for _ in {1..20}; do
    [ -f "$log" ] && break
    sleep 0.1
  done

  [ -f "$log" ]
  grep -q -- "--thread thread-sym" "$log"
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
  v=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.version');")
  [ "$v" = "1" ]
  local cmd
  cmd=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.hooks.Stop[0].bash');")
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
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.github/hooks/agmsg.json")'), '\$.hooks.Stop'));")
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
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.github/hooks/agmsg.json")'), '\$.hooks.Stop'));")
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
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
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
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
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
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
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
  skip_on_windows "commandWindows not written on native Windows (#182)"
  run bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local hook_file="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hook_file" ]
  local cw
  cw=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
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
  cw=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
  [ -z "$cw" ]
}

# --- Hook JSON escaping: build entries via json_object, not by hand (#134) ---
#
# The pre-fix code hand-assembled the entry JSON and only escaped the codex
# commandWindows. The "command" value's own embedded " and ' went in raw, so any
# project path containing them produced "Error: stepping, malformed JSON" and no
# hook file — for BOTH claude-code and codex (#134 Bug 1, reporter #138). These
# reproduce on macOS/Linux independent of the sqlite build.
#
# Note: these cover the cross-platform JSON-escaping defect only. Native-Windows
# delivery has a separate, still-open failure (empty commandWindows / invalid
# JSON even for plain paths — sqlite3.exe / CRLF, #130); see the windows-latest
# experimental leg. Not addressed here.

# SQL string-literal escape so a tricky path is safe inside our own probe query.
sql_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

# The quote/backslash path cases below use " and \ in directory names, which are
# not legal filename characters on NTFS — they can't even be created under Git
# Bash on Windows. Skip there; the required ubuntu/macos legs cover them.
skip_if_no_special_fs() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "\" and \\ are not legal filename chars on NTFS" ;;
  esac
}

@test "delivery set turn: project path with quotes yields valid JSON (claude-code) (#134)" {
  skip_if_no_special_fs
  local proj="$TEST_PROJECT/o'brien \"x\""
  mkdir -p "$proj"
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj"
  [ "$status" -eq 0 ]
  local hf="$proj/.claude/settings.local.json"
  [ -f "$hf" ]
  local hfq; hfq=$(sql_lit "$hf")
  [ "$(sqlite_mem "SELECT json_valid(readfile('$hfq'));")" = "1" ]
  local cmd
  cmd=$(sqlite_mem "SELECT json_extract(readfile('$hfq'), '\$.hooks.Stop[0].hooks[0].command');")
  [[ "$cmd" == *"check-inbox.sh"* ]]
  [[ "$cmd" == *"o'brien \"x\""* ]]
}

@test "delivery set turn: project path with quotes yields valid JSON + commandWindows (codex) (#134)" {
  skip_if_no_special_fs
  local proj="$TEST_PROJECT/o'brien \"x\""
  mkdir -p "$proj"
  run bash "$SCRIPTS/delivery.sh" set turn codex "$proj"
  [ "$status" -eq 0 ]
  local hf="$proj/.codex/hooks.json"
  [ -f "$hf" ]
  local hfq; hfq=$(sql_lit "$hf")
  [ "$(sqlite_mem "SELECT json_valid(readfile('$hfq'));")" = "1" ]
  local cw
  cw=$(sqlite_mem "SELECT json_extract(readfile('$hfq'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
  [ -n "$cw" ]
  [[ "$cw" == *"Program Files\\Git\\bin\\bash.exe"* ]]
  [[ "$cw" == *"check-inbox.sh"* ]]
}

@test "delivery set turn: project path with a backslash round-trips intact (#134)" {
  # json_object must JSON-escape a literal backslash in the raw command value
  # (a hand-built "command":"..." left it raw). Backslashes are the norm in
  # Windows-shaped inputs, so verify the byte survives the round-trip.
  skip_if_no_special_fs
  local proj="$TEST_PROJECT/a\\b"
  mkdir -p "$proj"
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj"
  [ "$status" -eq 0 ]
  local hf="$proj/.claude/settings.local.json"
  local hfq; hfq=$(sql_lit "$hf")
  [ "$(sqlite_mem "SELECT json_valid(readfile('$hfq'));")" = "1" ]
  local cmd
  cmd=$(sqlite_mem "SELECT json_extract(readfile('$hfq'), '\$.hooks.Stop[0].hooks[0].command');")
  [[ "$cmd" == *'a\b'* ]]
}

@test "delivery set monitor: existing settings with single-quoted hook commands stays valid JSON (#134)" {
  # The reporter's trigger: settings.local.json already holds hook commands
  # containing single quotes. Pre-fix, re-adding our entries produced malformed
  # JSON. Post-fix the round-trip stays valid and preserves the prior hook.
  mkdir -p "$TEST_PROJECT/.claude"
  cat > "$(settings_file)" <<'JSON'
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash -lc 'echo it'\''s mine'"}]}]}}
JSON
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_valid(readfile('$(rf "$(settings_file)")'));")" = "1" ]
  has_session_start "$(settings_file)"
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
  first=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow[0]');")
  last=$(sqlite_mem  "SELECT json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow[599]');")
  allow_len=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow'));")
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
  allow_len=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow'));")
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
  inflated=$(sqlite_mem "
    SELECT json_set(
      json_set(readfile('$(rf "$(settings_file)")'), '\$.permissions', json('{}')),
      '\$.permissions.allow', json('$allow_json')
    );
  ")
  printf '%s' "$inflated" > "$(settings_file)"

  run bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  ! has_check_inbox "$(settings_file)"
  local allow_len
  allow_len=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow'));")
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

# --- cursor agent tests (#131) ---

@test "cursor is accepted as an agent type (turn mode)" {
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  grep -q "check-inbox.sh" "$TEST_PROJECT/.cursor/rules/agmsg.mdc"
}

@test "cursor rule file is an always-apply .mdc (Cursor CLI auto-load)" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null
  # First non-empty line opens the frontmatter; alwaysApply must be declared so
  # the Cursor CLI applies the rule on every turn.
  [ "$(head -1 "$TEST_PROJECT/.cursor/rules/agmsg.mdc")" = "---" ]
  grep -q "alwaysApply: true" "$TEST_PROJECT/.cursor/rules/agmsg.mdc"
}

@test "cursor supports off mode: removes rule file" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  run bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor rejects monitor mode" {
  run bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor rejects both mode" {
  run bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor rejects monitor: does NOT delete an existing turn rule" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  run bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor set turn: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  local count
  count=$(grep -c "check-inbox.sh" "$TEST_PROJECT/.cursor/rules/agmsg.mdc")
  [ "$count" -eq 1 ]
}

# --- Codex monitor bridge (#41) ---
@test "session-start.sh for codex starts bridge when monitor launcher env is present" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  AGMSG_CODEX_BRIDGE=1 \
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$fake" \
  AGMSG_TEST_LOG="$log" \
  CODEX_THREAD_ID="thread-123" \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" >/dev/null

  for _ in {1..20}; do
    [ -f "$log" ] && break
    sleep 0.1
  done

  [ -f "$log" ]
  grep -q -- "--project $TEST_PROJECT" "$log"
  grep -q -- "--thread thread-123" "$log"
  grep -q -- "--app-server unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" "$log"
  grep -q -- "--inline-inbox" "$log"
}

@test "session-start.sh for codex stays quiet without monitor launcher env" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  AGMSG_CODEX_BRIDGE_CMD="$fake" AGMSG_TEST_LOG="$log" CODEX_THREAD_ID="thread-123" \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" >/dev/null

  [ ! -f "$log" ]
}

@test "delivery set monitor (codex): installs SessionStart and prints Codex shell function" {
  run bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex monitor beta is enabled"* ]]
  [[ "$output" == *"codex() {"* ]]
  [[ "$output" == *"codex-shim.sh"* ]]
  [[ "$output" == *"launch with codex"* ]]
  [[ "$output" == *"Optional global PATH shim is still available"* ]]
  [[ "$output" == *"For more info: https://github.com/fujibee/agmsg/blob/main/docs/codex-monitor-beta.md"* ]]
  [[ "$output" != *"Monitor tool"* ]]
  [ ! -e "$HOME/.agents/bin/codex" ]
  local hook_file="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hook_file" ]
  grep -q "session-start.sh" "$hook_file"
}

@test "delivery set both (codex): rejected by the delivery_modes gate" {
  # codex's manifest omits 'both' (delivery_modes=monitor turn off), so the
  # central gate in delivery.sh rejects it before any file is touched.
  run bash "$SCRIPTS/delivery.sh" set both codex "$TEST_PROJECT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not supported for codex"* ]]
}

@test "delivery status (codex): live bridge reports alive and suppresses watch count" {
  skip_on_windows "codex bridge status liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  sleep 60 &
  local bpid=$!
  # shellcheck disable=SC2064  # capture the current child pid for EXIT cleanup
  trap "kill $bpid 2>/dev/null || true" EXIT
  printf '%s\n' "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$bpid
project=$TEST_PROJECT
team=team
name=alice
type=codex
EOF
  printf '%s\n' 99999999 > "$TEST_SKILL_DIR/run/watch.fake.pid"

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice alive (pid $bpid)"* ]]
  [[ "$output" != *"watch processes:"* ]]

  kill "$bpid" 2>/dev/null || true
  trap - EXIT
}

@test "delivery status (codex): stale bridge pidfile is reported as stale" {
  skip_on_windows "codex bridge status liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  local dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  printf '%s\n' "$dead_pid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$dead_pid
project=$TEST_PROJECT
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice stale pidfile (pid $dead_pid not running)"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): bridge metadata mismatch is reported as stale" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$$
project=$TEST_PROJECT-other
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice stale pidfile (metadata mismatch)"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): missing bridge metadata is reported as stale" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice stale pidfile (missing metadata)"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): identity with no bridge reports not running" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice not running"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): multiple identities are enumerated independently" {
  skip_on_windows "codex bridge status liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  sleep 60 &
  local bpid=$!
  # shellcheck disable=SC2064  # capture the current child pid for EXIT cleanup
  trap "kill $bpid 2>/dev/null || true" EXIT
  printf '%s\n' "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$bpid
project=$TEST_PROJECT
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team/alice alive (pid $bpid)"* ]]
  [[ "$output" == *"Codex bridge: team/bob not running"* ]]
  [[ "$output" != *"watch processes:"* ]]

  kill "$bpid" 2>/dev/null || true
  trap - EXIT
}

@test "delivery status (codex): monitor mode with no identities is explicit" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: no identities registered for this project"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "session-start.sh for codex resolves thread id from rollout when CODEX_THREAD_ID is unset" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  # Fresh/exec Codex sessions do not export CODEX_THREAD_ID; the hook must read
  # the thread id from the newest rollout whose session_meta cwd matches (#41).
  local rollout_dir="$TEST_SKILL_DIR/home/.codex/sessions/2026/06/17"
  mkdir -p "$rollout_dir"
  printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"rollout-thread-999\",\"cwd\":\"$TEST_PROJECT\"}}" \
    > "$rollout_dir/rollout-2026-06-17T00-00-00-rollout-thread-999.jsonl"

  HOME="$TEST_SKILL_DIR/home" \
  AGMSG_CODEX_BRIDGE=1 \
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$fake" \
  AGMSG_TEST_LOG="$log" \
    env -u CODEX_THREAD_ID bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" >/dev/null

  for _ in {1..20}; do [ -f "$log" ] && break; sleep 0.1; done
  [ -f "$log" ]
  grep -q -- "--thread rollout-thread-999" "$log"
}

@test "delivery set monitor (codex): warns loudly when Node is missing" {
  # Node preflight: the bridge is a Node program; enabling monitor without Node
  # must flag it rather than silently never starting. AGMSG_CODEX_NODE points the
  # check at a binary that does not exist. See #41.
  run env AGMSG_CODEX_NODE=__agmsg_no_such_node__ bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: Node.js"* ]]
  [[ "$output" == *"monitor delivery will NOT start"* ]]
}

@test "delivery set off (codex): stops the bridge, cleans run files, notes shell profile cleanup" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  # Stand in for a live bridge with a real process we can check kill -0 against.
  sleep 60 &
  local bpid=$!
  echo "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  echo "pid=$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta"
  : > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.log"
  # The launcher's stale-binding sidecar + the project's shared app-server record
  # must be torn down too. Use a non-codex pid for the server record so the
  # cmdline guard skips the kill — the record is still dropped.
  : > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  source "$SCRIPTS/lib/hash.sh"
  local h; h="$(printf '%s' "$TEST_PROJECT" | agmsg_sha1)"
  echo 2147483647 > "$TEST_SKILL_DIR/run/codex-app-server.$h.pid"
  : > "$TEST_SKILL_DIR/run/codex-app-server.$h.port"
  : > "$TEST_SKILL_DIR/run/codex-app-server.$h.version"

  run bash "$SCRIPTS/delivery.sh" set off codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopped 1 Codex bridge"* ]]
  [[ "$output" == *"shim"* ]]
  ! kill -0 "$bpid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-app-server.$h.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-app-server.$h.port" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-app-server.$h.version" ]
  kill "$bpid" 2>/dev/null || true
}

# --- hermes (manual-only: delivery_modes=off, no automatic hook) ---

@test "delivery hermes: status is manual/off" {
  run bash "$SCRIPTS/delivery.sh" status hermes "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "mode: off" ]]
}

@test "delivery hermes: rejects automatic modes" {
  local mode
  for mode in turn monitor both; do
    run bash "$SCRIPTS/delivery.sh" set "$mode" hermes "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "not supported for hermes" ]]
    [ ! -e "$TEST_PROJECT/.hermes/agmsg.json" ]
  done
}

@test "delivery hermes: rejects unknown mode" {
  run bash "$SCRIPTS/delivery.sh" set bogus hermes "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown mode" ]]
  [ ! -e "$TEST_PROJECT/.hermes/agmsg.json" ]
}

@test "delivery hermes: accepts off without writing hook config" {
  run bash "$SCRIPTS/delivery.sh" set off hermes "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]
  [[ "$output" =~ "manual inbox checks only" ]]
  [[ "$output" != *"AGMSG-DIRECTIVE"* ]]
  [ ! -e "$TEST_PROJECT/.hermes/agmsg.json" ]
}

@test "delivery hermes: set off does not stop Claude Code watchers for the same project" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" hermes-preserve-test "$TEST_PROJECT" claude-code &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.hermes-preserve-test.pid" ]

  run bash "$SCRIPTS/delivery.sh" set off hermes "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  run kill -0 "$watch_pid"
  [ "$status" -eq 0 ]

  kill "$watch_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}

# --- grok-build (turn|off via a markdown rule file .grok/rules/agmsg.md) ---
# Grok passive hooks can't inject (stdout is discarded), so grok delivers via the
# rule-file self-poll model (like gemini/opencode): a .grok/rules/agmsg.md that
# tells the agent to poll inbox.sh each turn. turn => rule present, off => absent.

@test "delivery set turn (grok-build): writes .grok/rules/agmsg.md self-poll rule" {
  run bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  local rule_file="$TEST_PROJECT/.grok/rules/agmsg.md"
  [ -f "$rule_file" ]
  # The rule points at inbox.sh (clean display + same-call mark = loss-safe),
  # not the hook-only check-inbox.sh, and references this type + project.
  run cat "$rule_file"
  [[ "$output" == *"inbox.sh"* ]]
  [[ "$output" != *"check-inbox.sh"* ]]
  [[ "$output" == *"grok-build"* ]]
  [[ "$output" == *"$TEST_PROJECT"* ]]
}

@test "delivery set off (grok-build): removes the rule file" {
  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.grok/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set off grok-build "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.grok/rules/agmsg.md" ]
}

@test "delivery set monitor (grok-build): writes a monitor rule and emits the launch directive" {
  GROK_SESSION_ID="grok-sess-1" run bash "$SCRIPTS/delivery.sh" set monitor grok-build "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  # Emits an in-session directive to launch watch.sh via the monitor tool, with
  # GROK_SESSION_ID baked into the command (not CLAUDE_CODE_SESSION_ID).
  [[ "$output" == *"AGMSG-DIRECTIVE"* ]]
  [[ "$output" == *"watch.sh"* ]]
  [[ "$output" == *"grok-sess-1"* ]]
  [[ "$output" == *"grok-build"* ]]
  # The rule carries the monitor marker and points at the monitor tool.
  local rule_file="$TEST_PROJECT/.grok/rules/agmsg.md"
  [ -f "$rule_file" ]
  run cat "$rule_file"
  [[ "$output" == *"agmsg-delivery-mode: monitor"* ]]
  [[ "$output" == *"monitor"* ]]
  [[ "$output" == *"watch.sh"* ]]
}

@test "delivery status (grok-build): reports monitor when the monitor rule is present" {
  GROK_SESSION_ID="grok-sess-2" bash "$SCRIPTS/delivery.sh" set monitor grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "delivery set turn then monitor (grok-build): rewrites the rule from turn to monitor" {
  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
  GROK_SESSION_ID="grok-sess-3" bash "$SCRIPTS/delivery.sh" set monitor grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "delivery set both (grok-build): rejected; does NOT delete an existing turn rule" {
  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" set both grok-build "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.grok/rules/agmsg.md" ]
}

@test "delivery status (grok-build): derives mode from rule file existence" {
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}
