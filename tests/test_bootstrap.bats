#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  LIVE_PIDS=""
  export PROJ="$TEST_SKILL_DIR/project"
  mkdir -p "$PROJ"
}

teardown() {
  for pid in $LIVE_PIDS; do kill "$pid" 2>/dev/null || true; done
  teardown_test_env
}

@test "bootstrap: creates a deterministic team and session-scoped identity" {
  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-a --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == status=ready* ]]
  [[ "$output" == *" type=codex "* ]]
  [[ "$output" == *" created=1 "* ]]

  first="$output"
  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-a --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == *" created=0 "* ]]

  first_team="$(printf '%s\n' "$first" | sed -n 's/.* team=\([^ ]*\).*/\1/p')"
  first_agent="$(printf '%s\n' "$first" | sed -n 's/.* agent=\([^ ]*\).*/\1/p')"
  [[ "$output" == *" team=$first_team "* ]]
  [[ "$output" == *" agent=$first_agent "* ]]
}

@test "bootstrap: an empty optional session id falls back instead of stopping" {
  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id "" --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == status=ready* ]]
}

@test "bootstrap: parallel sessions share the project team but not the agent identity" {
  a="$(bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-a --no-delivery)"
  b="$(bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-b --no-delivery)"

  team_a="$(printf '%s\n' "$a" | sed -n 's/.* team=\([^ ]*\).*/\1/p')"
  team_b="$(printf '%s\n' "$b" | sed -n 's/.* team=\([^ ]*\).*/\1/p')"
  agent_a="$(printf '%s\n' "$a" | sed -n 's/.* agent=\([^ ]*\).*/\1/p')"
  agent_b="$(printf '%s\n' "$b" | sed -n 's/.* agent=\([^ ]*\).*/\1/p')"

  [ "$team_a" = "$team_b" ]
  [ "$agent_a" != "$agent_b" ]

  run bash "$SCRIPTS/team.sh" "$team_a"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$agent_a"* ]]
  [[ "$output" == *"$agent_b"* ]]
}

@test "bootstrap: concurrent first calls do not lose either session" {
  bash "$SCRIPTS/bootstrap.sh" "$PROJ" claude-code --session-id session-a --no-delivery > "$TEST_SKILL_DIR/a.out" &
  pa=$!
  bash "$SCRIPTS/bootstrap.sh" "$PROJ" claude-code --session-id session-b --no-delivery > "$TEST_SKILL_DIR/b.out" &
  pb=$!
  wait "$pa"
  wait "$pb"

  team="$(sed -n 's/.* team=\([^ ]*\).*/\1/p' "$TEST_SKILL_DIR/a.out")"
  run bash "$SCRIPTS/team.sh" "$team"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 member(s)"* ]]
}

@test "bootstrap: explicit team and agent preserve an integration-owned identity" {
  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" claude-code \
    --session-id session-a --team bridge-team --agent bridge-claude --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == *" team=bridge-team "* ]]
  [[ "$output" == *" agent=bridge-claude "* ]]
}

@test "bootstrap: configures automatic delivery once without overwriting it on later sessions" {
  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-a --delivery turn
  [ "$status" -eq 0 ]
  [[ "$output" == *" delivery=turn "* ]]
  [[ "$output" == *" delivery_configured=1"* ]]

  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-b --delivery turn
  [ "$status" -eq 0 ]
  [[ "$output" == *" delivery_configured=0"* ]]
}

@test "bootstrap: Claude monitor directive subscribes only to this session identity" {
  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" claude-code \
    --session-id session-a --delivery monitor
  [ "$status" -eq 0 ]
  agent="$(printf '%s\n' "$output" | sed -n 's/.* agent=\([^ ]*\).*/\1/p' | head -1)"
  [[ "$output" == *"watch.sh"* ]]
  [[ "$output" == *" $agent"* ]]
  [[ "$output" == *"do not consume each other's replies"* ]]
}

@test "bootstrap: turn delivery selects the identity owned by this parallel session" {
  sleep 300 & first_pid=$!
  sleep 300 & second_pid=$!
  LIVE_PIDS="$first_pid $second_pid"

  first="$(bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-a \
    --instance-id "thread-a.$first_pid" --no-delivery)"
  second="$(bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id thread-b \
    --instance-id "thread-b.$second_pid" --no-delivery)"
  team="$(printf '%s\n' "$first" | sed -n 's/.* team=\([^ ]*\).*/\1/p')"
  old_agent="$(printf '%s\n' "$first" | sed -n 's/.* agent=\([^ ]*\).*/\1/p')"
  current_agent="$(printf '%s\n' "$second" | sed -n 's/.* agent=\([^ ]*\).*/\1/p')"
  bash "$SCRIPTS/join.sh" "$team" sender claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/send.sh" "$team" sender "$old_agent" "old-session-reply" >/dev/null
  bash "$SCRIPTS/send.sh" "$team" sender "$current_agent" "current-session-reply" >/dev/null

  run env AGMSG_AGENT_PID="$second_pid" CODEX_THREAD_ID=thread-b \
    bash "$SCRIPTS/check-inbox.sh" codex "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current-session-reply"* ]]
  [[ "$output" != *"old-session-reply"* ]]
}

@test "bootstrap: parallel resumes sharing a bare session id get different live identities" {
  sleep 300 & first_pid=$!
  sleep 300 & second_pid=$!
  LIVE_PIDS="$first_pid $second_pid"

  first="$(bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id shared-thread \
    --instance-id "shared-thread.$first_pid" --no-delivery)"
  team="$(printf '%s\n' "$first" | sed -n 's/.* team=\([^ ]*\).*/\1/p')"
  stable_agent="$(printf '%s\n' "$first" | sed -n 's/.* agent=\([^ ]*\).*/\1/p')"

  run bash "$SCRIPTS/bootstrap.sh" "$PROJ" codex --session-id shared-thread \
    --instance-id "shared-thread.$second_pid" --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == *" team=$team "* ]]
  [[ "$output" != *" agent=$stable_agent "* ]]
}
