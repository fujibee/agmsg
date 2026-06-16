#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Pin bare instance-id keying (#93) so check-inbox's watcher-defer and actas
  # owner checks key on the raw session_id these tests pass — deterministic in
  # CI and when the suite runs under an agent process.
  export AGMSG_AGENT_PID=""
  export TEST_PROJECT="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

# --- hook.sh on ---

@test "hook on: creates settings.local.json" {
  run bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.claude/settings.local.json" ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
}

@test "hook on: settings contains Stop hook with check-inbox" {
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  local content=$(cat "$TEST_PROJECT/.claude/settings.local.json")
  [[ "$content" =~ "Stop" ]]
  [[ "$content" =~ "check-inbox.sh" ]]
}

@test "hook on: is idempotent" {
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  local count=$(python3 -c "
import json
d = json.load(open('$TEST_PROJECT/.claude/settings.local.json'))
print(len(d['hooks']['Stop']))
")
  [ "$count" -eq 1 ]
}

@test "hook on: preserves existing settings" {
  mkdir -p "$TEST_PROJECT/.claude"
  echo '{"permissions":{"allow":["Bash"]}}' > "$TEST_PROJECT/.claude/settings.local.json"
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  local content=$(cat "$TEST_PROJECT/.claude/settings.local.json")
  [[ "$content" =~ "permissions" ]]
  [[ "$content" =~ "Stop" ]]
}

@test "hook on: handles path with spaces" {
  local spaced="$(mktemp -d)/my project"
  mkdir -p "$spaced"
  run bash "$SCRIPTS/hook.sh" on claude-code "$spaced"
  [ "$status" -eq 0 ]
  [ -f "$spaced/.claude/settings.local.json" ]
  rm -rf "$spaced"
}

@test "hook on: codex creates hooks.json" {
  run bash "$SCRIPTS/hook.sh" on codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.codex/hooks.json" ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
}

@test "hook off: codex removes hook" {
  bash "$SCRIPTS/hook.sh" on codex "$TEST_PROJECT"
  run bash "$SCRIPTS/hook.sh" off codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]
}

# --- hook.sh off ---

@test "hook off: removes hook from settings" {
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  run bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]
  local content=$(cat "$TEST_PROJECT/.claude/settings.local.json")
  [[ ! "$content" =~ "Stop" ]]
}

@test "hook off: reports no hook when not configured" {
  run bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]
}

@test "hook off: preserves other settings" {
  mkdir -p "$TEST_PROJECT/.claude"
  echo '{"permissions":{"allow":["Bash"]}}' > "$TEST_PROJECT/.claude/settings.local.json"
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT"
  local content=$(cat "$TEST_PROJECT/.claude/settings.local.json")
  [[ "$content" =~ "permissions" ]]
  [[ ! "$content" =~ "Stop" ]]
}

# --- check-inbox.sh ---

@test "check-inbox: respects cooldown" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT"
  # First call creates marker
  echo '{}' | bash "$SCRIPTS/check-inbox.sh" claude-code "$TEST_PROJECT"
  # Send message after marker
  bash "$SCRIPTS/send.sh" testteam bob alice "hello"
  # Second call within cooldown should skip
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' claude-code '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check-inbox: exits silently when not joined" {
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' claude-code /tmp/nowhere"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check-inbox: exits silently when stop_hook_active" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice "hello"
  run bash -c 'echo "{\"stop_hook_active\":true}" | bash "'"$SCRIPTS"'/check-inbox.sh" claude-code "'"$TEST_PROJECT"'"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Stop-hook delivery should respect actas exclusivity locks the same way
# the Monitor-mode watcher does (#62). If a peer session owns (team, alice),
# this session must not consume alice's inbox here — that would defeat the
# whole exclusivity guarantee for codex / claude-code-turn delivery paths.
@test "check-inbox: skips a team when (team, agent) is locked by another live session" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice "should not be delivered here"

  setup_live_owner "$TEST_SKILL_DIR/run" "peer-sid"
  echo "peer-sid" > "$TEST_SKILL_DIR/run/actas.testteam__alice.session"

  run bash -c "echo '{\"session_id\":\"mine-sid\"}' | bash '$SCRIPTS/check-inbox.sh' claude-code '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  # The message should NOT surface — no "block decision" payload, no body.
  [[ ! "$output" =~ "should not be delivered here" ]]
}

@test "check-inbox: still delivers when the lock is owned by this session" {
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/send.sh" testteam bob alice "I am the owner"

  setup_live_owner "$TEST_SKILL_DIR/run" "mine-sid"
  echo "mine-sid" > "$TEST_SKILL_DIR/run/actas.testteam__alice.session"

  run bash -c "echo '{\"session_id\":\"mine-sid\"}' | bash '$SCRIPTS/check-inbox.sh' claude-code '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "I am the owner" ]]
}
