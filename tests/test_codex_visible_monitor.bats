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

project_hash() {
  local resolved
  resolved="$(cd "$TEST_PROJECT" && pwd)"
  printf '%s' "$resolved" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 )
}

join_codex_roles() {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
}

@test "codex actas persists the selected role and arms visible fallback" {
  join_codex_roles

  run env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=visible_turn_only"* ]]
  [[ "$output" == *"name=bob"* ]]

  local state="$TEST_SKILL_DIR/run/codex-last-actas.$(project_hash).tsv"
  [ -f "$state" ]
  awk -F '\t' '$2 == "codex" && $3 == "team" && $4 == "bob" { found=1 } END { exit !found }' "$state"

  local hooks="$TEST_PROJECT/.codex/hooks.json"
  grep -q "session-start.sh" "$hooks"
  grep -q "check-inbox.sh" "$hooks"
}

@test "codex SessionStart rebinds the last actas role after restart" {
  join_codex_roles
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
  env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123 >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "visible-bob-message" >/dev/null

  run bash "$SCRIPTS/check-inbox.sh" codex "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"visible-bob-message"* ]]
}

@test "codex headless app monitor is disabled unless explicitly opted in" {
  run bash "$TYPES/codex/codex-app-monitor.sh" \
    "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 64 ]
  [[ "$output" == *"disabled"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
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
transport=codex-app-exec-resume
EOF

  run bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopped 1 Codex bridge/app monitor process"* ]]
  ! kill -0 "$app_pid" 2>/dev/null
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid" ]
}
