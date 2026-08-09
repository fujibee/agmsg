#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  LIVE_PID=""

  export STUB_BIN="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$STUB_BIN"
  for bin in claude codex; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$bin"
    chmod +x "$STUB_BIN/$bin"
  done
  export CAPTURE="$TEST_SKILL_DIR/launch-capture.txt"
  cat > "$STUB_BIN/record.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
EOF
  chmod +x "$STUB_BIN/record.sh"
  export PATH="$STUB_BIN:$PATH"
  export AGMSG_TERMINAL="$STUB_BIN/record.sh {cmd}"
  unset TMUX HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID

  export PROJ="$TEST_SKILL_DIR/project"
  mkdir -p "$PROJ"
}

teardown() {
  [ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null || true
  teardown_test_env
}

field() {
  local line="$1" key="$2"
  printf '%s\n' "$line" | sed -n "s/.* $key=\\([^ ]*\\).*/\\1/p"
}

@test "delegate: first task auto-bootstraps and spawns the opposite agent" {
  run bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "review this change" \
    --session-id codex-thread-a --no-wait --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == status=spawned* ]]
  [[ "$output" == *"conversation=conv-"* ]]
  [[ "$output" == *" to=claude-"* ]]

  boot="$(cat "$CAPTURE")"
  [ -f "$boot" ]
  run cat "$boot"
  [[ "$output" == *"review this change"* ]]
  [[ "$output" == *"agmsg-delegate conversation="* ]]
  [[ "$output" == *"send.sh"* ]]
}

@test "delegate: different caller sessions get different conversations and workers" {
  a="$(bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "task a" --session-id thread-a --no-wait --no-delivery)"
  b="$(bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "task b" --session-id thread-b --no-wait --no-delivery)"

  [ "$(field "$a" conversation)" != "$(field "$b" conversation)" ]
  [ "$(field "$a" to)" != "$(field "$b" to)" ]
  [ "$(field "$a" team)" = "$(field "$b" team)" ]
}

@test "delegate: a live worker receives a continuation instead of another spawn" {
  first="$(bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "first" --session-id thread-a --no-wait --no-delivery)"
  conv="$(field "$first" conversation)"
  team="$(field "$first" team)"
  target="$(field "$first" to)"

  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/actas-lock.sh"
  sleep 300 &
  live_pid=$!
  LIVE_PID="$live_pid"
  actas_lock_claim "$team" "$target" "target-owner.$live_pid" >/dev/null
  : > "$CAPTURE"

  run bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "continue" \
    --session-id thread-a --conversation "$conv" --no-wait \
    --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == status=sent* ]]
  [ ! -s "$CAPTURE" ]

  source_agent="$(field "$first" from)"
  run bash "$SCRIPTS/inbox.sh" "$team" "$target"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$source_agent"* ]]
  [[ "$output" == *"continue"* ]]
}

@test "delegate: replacement worker receives durable history and a higher generation" {
  first="$(bash "$SCRIPTS/delegate.sh" "$PROJ" claude-code codex "first task" --session-id claude-a --no-wait --no-delivery)"
  conv="$(field "$first" conversation)"
  team="$(field "$first" team)"
  source_agent="$(field "$first" from)"
  target="$(field "$first" to)"

  bash "$SCRIPTS/send.sh" "$team" "$target" "$source_agent" \
    "[agmsg-delegate conversation=$conv generation=1 task=old] completed the scan" >/dev/null
  : > "$CAPTURE"

  run bash "$SCRIPTS/delegate.sh" "$PROJ" claude-code codex "next task" \
    --session-id claude-a --conversation "$conv" --fresh --no-wait \
    --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == *" generation=2 "* ]]

  boot="$(cat "$CAPTURE")"
  run cat "$boot"
  [[ "$output" == *"completed the scan"* ]]
  [[ "$output" == *"next task"* ]]
  [[ "$output" == *"generation=2"* ]]
}

@test "delegate: concurrent updates to one conversation allocate distinct generations" {
  conv="conv-concurrent"
  bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "task a" \
    --session-id thread-a --conversation "$conv" --no-wait --no-delivery \
    > "$TEST_SKILL_DIR/a.out" &
  pa=$!
  bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "task b" \
    --session-id thread-a --conversation "$conv" --no-wait --no-delivery \
    > "$TEST_SKILL_DIR/b.out" &
  pb=$!
  wait "$pa"
  wait "$pb"

  generations="$(sed -n 's/.* generation=\([^ ]*\).*/\1/p' "$TEST_SKILL_DIR/a.out" "$TEST_SKILL_DIR/b.out" | sort -n | paste -sd, -)"
  [ "$generations" = "1,2" ]
}

@test "delegate: reclaims a conversation lock whose owner process is gone" {
  conv="conv-stale-lock"
  mkdir -p "$TEST_SKILL_DIR/run/delegations/$conv.lock"
  printf '%s\n' 999999 > "$TEST_SKILL_DIR/run/delegations/$conv.lock/owner"

  run bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "recover" \
    --session-id thread-a --conversation "$conv" --no-wait --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == status=spawned* ]]
  [ ! -d "$TEST_SKILL_DIR/run/delegations/$conv.lock" ]
}

@test "delegate: a failed session launch completes through the direct CLI fallback" {
  cat > "$STUB_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf 'direct fallback answer\n'
EOF
  chmod +x "$STUB_BIN/claude"
  export AGMSG_TERMINAL='false {cmd}'

  run bash "$SCRIPTS/delegate.sh" "$PROJ" codex claude-code "recover without a terminal" \
    --session-id thread-a --no-delivery
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=fallback"* ]]
  [[ "$output" == *"direct fallback answer"* ]]

  team="$(field "$output" team)"
  source_agent="$(field "$output" from)"
  run bash "$SCRIPTS/inbox.sh" "$team" "$source_agent"
  [ "$status" -eq 0 ]
  [[ "$output" == *"direct fallback answer"* ]]
}
