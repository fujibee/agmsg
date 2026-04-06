#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
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
  [[ "$output" =~ "Hook enabled" ]]
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
  [[ "$output" =~ "Hook enabled" ]]
}

@test "hook off: codex removes hook" {
  bash "$SCRIPTS/hook.sh" on codex "$TEST_PROJECT"
  run bash "$SCRIPTS/hook.sh" off codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Hook disabled" ]]
}

# --- hook.sh off ---

@test "hook off: removes hook from settings" {
  bash "$SCRIPTS/hook.sh" on claude-code "$TEST_PROJECT"
  run bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Hook disabled" ]]
  local content=$(cat "$TEST_PROJECT/.claude/settings.local.json")
  [[ ! "$content" =~ "Stop" ]]
}

@test "hook off: reports no hook when not configured" {
  run bash "$SCRIPTS/hook.sh" off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No hook configured" ]]
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
