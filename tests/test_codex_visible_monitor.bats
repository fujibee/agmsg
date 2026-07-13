#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  TEST_RECEIVER_PIDS=""
  # Failure-path tests must not emit real macOS notifications to the user.
  export AGMSG_CODEX_APP_MONITOR_DISABLE_NOTIFY=1
}

teardown() {
  local pid
  for pid in ${TEST_RECEIVER_PIDS:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

project_hash() {
  local resolved
  resolved="$(cd "$TEST_PROJECT" && pwd)"
  printf '%s' "$resolved" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 )
}

join_codex_roles() {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
}

@test "codex actas in turn mode persists the selected role without a background receiver" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  run env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=visible_turn_only"* ]]
  [[ "$output" == *"name=bob"* ]]

  local state="$TEST_SKILL_DIR/run/codex-last-actas.$(project_hash).tsv"
  [ -f "$state" ]
  awk -F '\t' '$2 == "codex" && $3 == "team" && $4 == "bob" { found=1 } END { exit !found }' "$state"

  local hooks="$TEST_PROJECT/.codex/hooks.json"
  grep -q "check-inbox.sh" "$hooks"
  [[ "$output" != *"lease_id=codex-monitor-lease."* ]]
  run ! grep -q "session-start.sh" "$hooks"
}

@test "codex SessionStart rebinds the last actas role after restart" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  env CODEX_THREAD_ID=thread-before \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-before >/dev/null
  rm -f "$TEST_SKILL_DIR/run/codex-chat-visible.team.bob.meta"

  run env CODEX_THREAD_ID=thread-after \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]

  local meta="$TEST_SKILL_DIR/run/codex-chat-visible.team.bob.meta"
  [ -f "$meta" ]
  grep -qx "name=bob" "$meta"
  grep -qx "thread=thread-after" "$meta"
  grep -qx "transport=codex-chat-visible-turn" "$meta"
}

@test "codex visible Stop hook reads the last actas inbox, not the first registration" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123 >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "visible-bob-message" >/dev/null

  run bash "$SCRIPTS/check-inbox.sh" codex "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"visible-bob-message"* ]]
}

@test "codex background thread receiver is disabled unless monitor explicitly opts in" {
  run bash "$TYPES/codex/codex-app-monitor.sh" \
    "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 64 ]
  [[ "$output" == *"disabled"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
}

make_fake_codex() {
  local fake="$TEST_SKILL_DIR/fake-codex"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS' >> "$AGMSG_FAKE_CODEX_LOG"
printf ' <%s>' "$@" >> "$AGMSG_FAKE_CODEX_LOG"
printf '\n' >> "$AGMSG_FAKE_CODEX_LOG"
printf 'BACKGROUND <%s>\n' "${AGMSG_CODEX_BACKGROUND_RESUME:-}" >> "$AGMSG_FAKE_CODEX_LOG"
if [ "${1:-}" = "mcp" ]; then
  exit 0
fi
if [ "${1:-}" = "exec" ]; then
  prompt="$(cat)"
  printf '%s\n' "$prompt" > "$AGMSG_FAKE_CODEX_PROMPT"
  if [ "${AGMSG_FAKE_CODEX_CONSUME:-}" = "1" ]; then
    bash "$AGMSG_FAKE_CODEX_INBOX" team bob >/dev/null
  fi
  exit "${AGMSG_FAKE_CODEX_EXEC_STATUS:-0}"
fi
exit 0
EOF
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

@test "codex monitor does not start a model while inbox is empty" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  local fake log prompt monitor_pid
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_CODEX_APP_MONITOR_TIMEOUT=1 \
    AGMSG_CODEX_APP_MONITOR_INTERVAL=1 \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-empty >/dev/null 2>&1 &
  monitor_pid=$!

  for _ in {1..30}; do
    grep -qx "status=ready" "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health" 2>/dev/null && break
    sleep 0.1
  done
  sleep 1.2
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true

  grep -q "<mcp> <list>" "$log"
  run ! grep -q "<exec>" "$log"
  [ ! -e "$prompt" ]
}

@test "codex monitor resumes the same thread and leaves body ownership to inbox.sh" {
  join_codex_roles
  bash "$SCRIPTS/send.sh" team alice bob "secret-body-must-not-be-in-wake-prompt" >/dev/null
  local fake log prompt
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_CODEX_APP_MONITOR_TIMEOUT=0 \
    AGMSG_CODEX_APP_MONITOR_MAX_WAKES=1 \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    AGMSG_FAKE_CODEX_CONSUME=1 \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 0 ]

  grep -q "<resume> <thread-123>" "$log"
  grep -q '<-s> <workspace-write>' "$log"
  grep -q '<-c> <approval_policy="never">' "$log"
  grep -q 'BACKGROUND <1>' "$log"
  run ! grep -q -- "--dangerously-bypass-approvals-and-sandbox" "$log"
  grep -q "$SCRIPTS/inbox.sh team bob" "$prompt"
  run ! grep -q "secret-body-must-not-be-in-wake-prompt" "$prompt"

  run bash "$TYPES/codex/watch-once.sh" "$TEST_PROJECT" codex \
    --team team --name bob --timeout 0
  [ "$status" -eq 2 ]
}

@test "codex monitor never marks unread mail when resumed thread fails to consume it" {
  join_codex_roles
  bash "$SCRIPTS/send.sh" team alice bob "preserve-me" >/dev/null
  local fake log prompt
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_CODEX_APP_MONITOR_TIMEOUT=0 \
    AGMSG_CODEX_APP_MONITOR_MAX_FAILURES=1 \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 70 ]
  [ "$(grep -c '<exec>' "$log")" -eq 1 ]
  grep -qx "last_error=thread_did_not_consume_inbox" \
    "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health"

  run bash "$TYPES/codex/watch-once.sh" "$TEST_PROJECT" codex \
    --team team --name bob --timeout 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=1"* ]]
}

@test "codex monitor never retries an unread id after resume returns an error" {
  join_codex_roles
  bash "$SCRIPTS/send.sh" team alice bob "one-wake-only" >/dev/null
  local fake log prompt
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_CODEX_APP_MONITOR_TIMEOUT=0 \
    AGMSG_CODEX_APP_MONITOR_MAX_FAILURES=3 \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    AGMSG_FAKE_CODEX_EXEC_STATUS=42 \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 70 ]
  [ "$(grep -c '<exec>' "$log")" -eq 1 ]

  run bash "$TYPES/codex/watch-once.sh" "$TEST_PROJECT" codex \
    --team team --name bob --timeout 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=1"* ]]
}

@test "supervised codex monitor exits successfully after one failed wake" {
  join_codex_roles
  bash "$SCRIPTS/send.sh" team alice bob "supervisor-must-not-restart" >/dev/null
  local fake log prompt
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_SUPERVISED=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_CODEX_APP_MONITOR_TIMEOUT=0 \
    AGMSG_CODEX_APP_MONITOR_MAX_FAILURES=3 \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    AGMSG_FAKE_CODEX_EXEC_STATUS=42 \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 0 ]
  [ "$(grep -c '<exec>' "$log")" -eq 1 ]
  grep -qx "last_error=codex_exec_resume_failed_42" \
    "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health"

  run bash "$TYPES/codex/watch-once.sh" "$TEST_PROJECT" codex \
    --team team --name bob --timeout 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=1"* ]]
}

@test "delivery turn stops an app monitor even when no bridge pidfile exists" {
  skip_on_windows "process liveness assertion uses POSIX kill semantics"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  sleep 60 &
  local app_pid=$!
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$app_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=alice
thread=thread-123
transport=codex-background-thread-resume
EOF
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.plist"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.health"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.log"
  bash "$TYPES/codex/codex-monitor-lease.sh" arm \
    "$TEST_PROJECT" team alice thread-123 >/dev/null
  bash "$TYPES/codex/codex-monitor-lease.sh" automation \
    "$TEST_PROJECT" team alice thread-123 heartbeat-id watchdog-id >/dev/null

  run bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopped 1 Codex bridge/app monitor process"* ]]
  [[ "$output" == *"heartbeat_automation_id=heartbeat-id"* ]]
  [[ "$output" == *"watchdog_automation_id=watchdog-id"* ]]
  run ! kill -0 "$app_pid"
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.plist" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.health" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.log" ]

  run bash "$TYPES/codex/codex-monitor-lease.sh" status \
    "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=inactive"* ]]
}

@test "dropping one codex role stops only that role's background receiver" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  local sleeper="$TEST_SKILL_DIR/codex-app-monitor.sh" bob_pid alice_pid
  cat > "$sleeper" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
EOF
  chmod +x "$sleeper"

  "$sleeper" &
  bob_pid=$!
  "$sleeper" &
  alice_pid=$!
  TEST_RECEIVER_PIDS="$bob_pid $alice_pid"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$bob_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=bob
thread=thread-bob
transport=codex-background-thread-resume
EOF
  printf '%s\n' "$alice_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=alice
thread=thread-alice
transport=codex-background-thread-resume
EOF

  run bash "$SCRIPTS/reset.sh" "$TEST_PROJECT" codex bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reset complete"* ]]
  run ! kill -0 "$bob_pid"
  kill -0 "$alice_pid" 2>/dev/null
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
  [ -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid" ]

  kill "$alice_pid" 2>/dev/null || true
  wait "$alice_pid" 2>/dev/null || true
  TEST_RECEIVER_PIDS=""
}

@test "codex monitor rejects a second receiver for the same role" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  local fake log prompt first_pid owner_pid
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_CODEX_APP_MONITOR_TIMEOUT=30 \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-owner >/dev/null 2>&1 &
  first_pid=$!
  TEST_RECEIVER_PIDS="$first_pid"
  for _ in {1..30}; do
    grep -qx "status=ready" "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health" 2>/dev/null && break
    sleep 0.1
  done
  owner_pid="$(cat "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid")"

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_CODEX_APP_MONITOR_TIMEOUT=0 \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-duplicate
  [ "$status" -eq 73 ]
  [[ "$output" == *"receiver already owns team/bob"* ]]
  [ "$(cat "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid")" = "$owner_pid" ]
  kill -0 "$first_pid" 2>/dev/null
}

@test "background resume hooks do not rebind or stop their parent receiver" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  env CODEX_THREAD_ID=thread-parent \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-parent >/dev/null
  rm -f "$TEST_SKILL_DIR/run/codex-chat-visible.team.bob.meta"

  env AGMSG_CODEX_BACKGROUND_RESUME=1 CODEX_THREAD_ID=thread-parent \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" </dev/null
  [ ! -e "$TEST_SKILL_DIR/run/codex-chat-visible.team.bob.meta" ]

  local sleeper="$TEST_SKILL_DIR/codex-app-monitor.sh" receiver_pid
  cat > "$sleeper" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "$sleeper"
  "$sleeper" &
  receiver_pid=$!
  TEST_RECEIVER_PIDS="$receiver_pid"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$receiver_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=bob
thread=thread-parent
transport=codex-background-thread-resume
EOF

  printf '%s\n' '{"session_id":"thread-parent"}' | \
    env AGMSG_CODEX_BACKGROUND_RESUME=1 bash "$SCRIPTS/session-end.sh" codex "$TEST_PROJECT"
  kill -0 "$receiver_pid" 2>/dev/null
  [ -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
}

@test "codex SessionEnd stops only the receiver bound to that visible thread" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  local sleeper="$TEST_SKILL_DIR/codex-app-monitor.sh" receiver_pid
  cat > "$sleeper" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "$sleeper"
  "$sleeper" &
  receiver_pid=$!
  TEST_RECEIVER_PIDS="$receiver_pid"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$receiver_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=bob
thread=thread-ending
transport=codex-background-thread-resume
EOF
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.plist"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.log"

  printf '%s\n' '{"session_id":"thread-ending"}' | \
    bash "$SCRIPTS/session-end.sh" codex "$TEST_PROJECT"

  run ! kill -0 "$receiver_pid"
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.plist" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.log" ]
  TEST_RECEIVER_PIDS=""
}

@test "codex monitor supervisor restarts crashes but never falls back to a new task" {
  grep -q '<key>AGMSG_CODEX_APP_MONITOR_SUPERVISED</key>' "$TYPES/codex/actas-monitor.sh"
  grep -A3 -q '<key>SuccessfulExit</key>' "$TYPES/codex/actas-monitor.sh"
  run grep -q 'start_bridge ""' "$TYPES/codex/actas-monitor.sh"
  [ "$status" -ne 0 ]
  run grep -q 'THREAD_ID="new"' "$TYPES/codex/actas-monitor.sh"
  [ "$status" -ne 0 ]
}
