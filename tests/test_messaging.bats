#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Create a team and two agents
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
}

teardown() {
  teardown_test_env
}

# --- send.sh ---

@test "send: delivers a message" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "hello"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
}

@test "send: fails without required args" {
  run bash "$SCRIPTS/send.sh"
  [ "$status" -ne 0 ]
}

# --- send.sh: roster validation (#355) ---

@test "send: rejects an unregistered from agent and does not insert" {
  run bash "$SCRIPTS/send.sh" testteam dummy bob "hi"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "from agent 'dummy' is not registered" ]]
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

@test "send: rejects an unregistered to agent and does not insert" {
  run bash "$SCRIPTS/send.sh" testteam alice dummy "hi"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "to agent 'dummy' is not registered" ]]
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

@test "send: rejection lists the currently registered roster" {
  run bash "$SCRIPTS/send.sh" testteam alice dummy "hi"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "registered: alice, bob" ]]
}

@test "send: --force bypasses the roster check even with no team config at all" {
  run bash "$SCRIPTS/send.sh" brandnewteam ghost nobody "hi" --force
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to nobody" ]]
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages WHERE team='brandnewteam';")
  [ "$n" -eq 1 ]
}

# --- send.sh: team-name validation (#414) ---

@test "send: rejects a team name with path traversal (../) and never consults a config outside teams/" {
  local escape_dir
  escape_dir="$(dirname "$TEST_SKILL_DIR")/escape-send"
  mkdir -p "$escape_dir"
  echo '{"agents":{"alice":{},"bob":{}}}' >"$escape_dir/config.json"
  run bash "$SCRIPTS/send.sh" "../../escape-send" alice bob "hi"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
  rm -rf "$escape_dir"
}

@test "send: rejects '..' and '.' as team names" {
  run bash "$SCRIPTS/send.sh" ".." alice bob "hi"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "not allowed" ]]
  run bash "$SCRIPTS/send.sh" "." alice bob "hi"
  [ "$status" -eq 1 ]
}

@test "send: rejects a team name starting with '-'" {
  run bash "$SCRIPTS/send.sh" "-rf" alice bob "hi"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "must not start with" ]]
}

@test "send: rejects an invalid team name even when --force is supplied" {
  run bash "$SCRIPTS/send.sh" "../../escape-force" alice bob "hi" --force
  [ "$status" -eq 1 ]
  [[ "$output" =~ "path traversal" ]]
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

@test "send: still accepts a UTF-8 (Japanese) team name" {
  bash "$SCRIPTS/join.sh" "テストチーム" alice claude-code /tmp/project-jp
  bash "$SCRIPTS/join.sh" "テストチーム" bob claude-code /tmp/project-jp2
  run bash "$SCRIPTS/send.sh" "テストチーム" alice bob "hello"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
}

# --- inbox.sh ---

@test "inbox: shows no messages when empty" {
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]
}

@test "inbox: shows received message" {
  bash "$SCRIPTS/send.sh" testteam alice bob "hello bob"
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello bob" ]]
  [[ "$output" =~ "alice" ]]
}

@test "inbox: marks messages as read" {
  bash "$SCRIPTS/send.sh" testteam alice bob "read me"
  bash "$SCRIPTS/inbox.sh" testteam bob >/dev/null
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]
}

@test "inbox: --quiet suppresses output when no messages" {
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "inbox: --quiet shows output when messages exist" {
  bash "$SCRIPTS/send.sh" testteam bob alice "ping"
  run bash "$SCRIPTS/inbox.sh" testteam alice --quiet
  [ "$status" -eq 0 ]
  [[ "$output" =~ "ping" ]]
}

@test "inbox: handles multiline message body" {
  bash "$SCRIPTS/send.sh" testteam alice bob "line1
line2
line3"
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "1 new message" ]]
  [[ "$output" =~ "alice" ]]
}

@test "inbox: a crafted agent arg cannot inject SQL to delete other messages (#87)" {
  bash "$SCRIPTS/send.sh" testteam alice bob "keepme"
  run bash "$SCRIPTS/inbox.sh" testteam "bob' AND read_at IS NULL; DELETE FROM messages; --"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "keepme" ]]
}

@test "inbox: an agent name containing a quote still receives its own messages (#87)" {
  bash "$SCRIPTS/join.sh" testteam "o'brien" claude-code /tmp/project-c
  bash "$SCRIPTS/send.sh" testteam alice "o'brien" "for quote"
  run bash "$SCRIPTS/inbox.sh" testteam "o'brien"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for quote" ]]
}

@test "check-inbox: a team name containing a quote still delivers without a SQL error (#87)" {
  local project; project="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" "te'am" alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" "te'am" carol claude-code "$project"
  bash "$SCRIPTS/send.sh" "te'am" alice carol "quoted team delivery"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' claude-code '$project'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "quoted team delivery" ]]
}

@test "history: handles multiline message body" {
  bash "$SCRIPTS/send.sh" testteam alice bob "multi
line"
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "alice" ]]
  [[ "$output" =~ "bob" ]]
}

# --- history.sh ---

@test "history: shows message history" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam bob alice "msg2"
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "msg1" ]]
  [[ "$output" =~ "msg2" ]]
}

@test "history: filters by agent" {
  bash "$SCRIPTS/send.sh" testteam alice bob "for bob"
  bash "$SCRIPTS/send.sh" testteam bob alice "for alice"
  run bash "$SCRIPTS/history.sh" testteam alice
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for" ]]
}

@test "history: respects limit" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg2"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg3"
  # limit=1 should return exactly 1 line with arrow
  run bash "$SCRIPTS/history.sh" testteam "" 1
  [ "$status" -eq 0 ]
  local count=$(echo "$output" | grep -c "→")
  [ "$count" -eq 1 ]
}

@test "history: shows no history message when empty" {
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No message history" ]]
}

@test "history: a non-numeric limit falls back to the default instead of injecting SQL (#87)" {
  bash "$SCRIPTS/send.sh" testteam alice bob "msg1"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg2"
  run bash "$SCRIPTS/history.sh" testteam bob "1; DELETE FROM messages; --"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/history.sh" testteam
  [[ "$output" =~ "msg1" ]]
  [[ "$output" =~ "msg2" ]]
}

@test "history: a team/agent name containing a quote does not break the query (#87)" {
  bash "$SCRIPTS/join.sh" testteam "o'brien" claude-code /tmp/project-c
  bash "$SCRIPTS/send.sh" testteam alice "o'brien" "for quote"
  run bash "$SCRIPTS/history.sh" testteam "o'brien"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "for quote" ]]
}
