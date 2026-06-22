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

@test "send: stores quoted team, agents, and body as values" {
  run bash "$SCRIPTS/send.sh" "team'one" "ali'ce" "bo'b" "it's fine"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bo'b in team team'one" ]]

  local count
  count=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "
    SELECT COUNT(*)
    FROM messages
    WHERE team='team''one'
      AND from_agent='ali''ce'
      AND to_agent='bo''b'
      AND body='it''s fine';
  " | tr -d '\r')
  [ "$count" = "1" ]
}

@test "send: treats injected to_agent SQL as data" {
  bash "$SCRIPTS/send.sh" testteam alice bob "safe" >/dev/null

  run bash "$SCRIPTS/send.sh" testteam alice "bob','payload'); DELETE FROM messages; --" "ignored"
  [ "$status" -eq 0 ]

  local count
  count=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;" | tr -d '\r')
  [ "$count" = "2" ]
}

@test "send: fails without required args" {
  run bash "$SCRIPTS/send.sh"
  [ "$status" -ne 0 ]
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

@test "inbox: shows quoted team and agent messages" {
  bash "$SCRIPTS/send.sh" "team'one" "ali'ce" "bo'b" "quoted hello"
  run bash "$SCRIPTS/inbox.sh" "team'one" "bo'b"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "quoted hello" ]]
  [[ "$output" =~ "ali'ce" ]]
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

@test "inbox: predicate-widening team input does not expose or mark unrelated messages" {
  bash "$SCRIPTS/send.sh" team1 alice bob "bob-only" >/dev/null
  bash "$SCRIPTS/send.sh" team2 alice carol "carol-only" >/dev/null

  run bash "$SCRIPTS/inbox.sh" "x' OR 1=1 --" bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No new messages" ]]

  local read_count
  read_count=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;" | tr -d '\r')
  [ "$read_count" = "0" ]
}

@test "check-inbox: predicate-widening team input does not mark unrelated messages" {
  local project
  project="$BATS_TEST_TMPDIR/project-evil"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" "x' OR 1=1 --" bob claude-code "$project"
  bash "$SCRIPTS/send.sh" testteam alice bob "normal-bob" >/dev/null

  run bash "$SCRIPTS/check-inbox.sh" claude-code "$project"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  local read_count
  read_count=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;" | tr -d '\r')
  [ "$read_count" = "0" ]
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

@test "history: filters quoted team and agent as values" {
  bash "$SCRIPTS/send.sh" "team'one" "ali'ce" "bo'b" "quoted history"
  run bash "$SCRIPTS/history.sh" "team'one" "bo'b"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "quoted history" ]]
  [[ "$output" =~ "ali'ce" ]]
  [[ "$output" =~ "bo'b" ]]
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

@test "history: rejects injected limit without executing it" {
  bash "$SCRIPTS/send.sh" testteam alice bob "limit target" >/dev/null

  run bash "$SCRIPTS/history.sh" testteam "" "1; UPDATE messages SET read_at='pwned' WHERE 1=1; --"
  [ "$status" -ne 0 ]

  local read_at
  read_at=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COALESCE(read_at, '') FROM messages WHERE body='limit target';" | tr -d '\r')
  [ -z "$read_at" ]
}

@test "history: shows no history message when empty" {
  run bash "$SCRIPTS/history.sh" testteam
  [ "$status" -eq 0 ]
  [[ "$output" =~ "No message history" ]]
}
