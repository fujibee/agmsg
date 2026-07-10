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

# --- send.sh --all / multi-recipient (#25/#26) ---

@test "send --all: broadcasts to every member except the sender" {
  bash "$SCRIPTS/join.sh" testteam carol claude-code /tmp/project-c
  run bash "$SCRIPTS/send.sh" testteam alice --all "team ping"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
  [[ "$output" =~ "Sent to carol" ]]
  [[ ! "$output" =~ "Sent to alice" ]]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "team ping" ]]
  run bash "$SCRIPTS/inbox.sh" testteam carol
  [[ "$output" =~ "team ping" ]]
  run bash "$SCRIPTS/inbox.sh" testteam alice
  [[ "$output" =~ "No new messages" ]]
}

@test "send @all: alias works" {
  bash "$SCRIPTS/join.sh" testteam carol claude-code /tmp/project-c
  run bash "$SCRIPTS/send.sh" testteam alice @all "alias ping"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
  [[ "$output" =~ "Sent to carol" ]]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "alias ping" ]]
  run bash "$SCRIPTS/inbox.sh" testteam carol
  [[ "$output" =~ "alias ping" ]]
}

@test "send --all: fails when team does not exist" {
  run bash "$SCRIPTS/send.sh" ghostteam alice --all "nobody home"
  [ "$status" -ne 0 ]
}

@test "send --all: fails when sender is the only member" {
  bash "$SCRIPTS/join.sh" soloteam alice claude-code /tmp/project-a
  run bash "$SCRIPTS/send.sh" soloteam alice --all "echo chamber"
  [ "$status" -ne 0 ]
}

@test "send: comma-separated recipients each get the message" {
  bash "$SCRIPTS/join.sh" testteam carol claude-code /tmp/project-c
  run bash "$SCRIPTS/send.sh" testteam alice bob,carol "pair ping"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
  [[ "$output" =~ "Sent to carol" ]]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "pair ping" ]]
  run bash "$SCRIPTS/inbox.sh" testteam carol
  [[ "$output" =~ "pair ping" ]]
}

@test "send: comma-separated recipients tolerate spaces after commas" {
  bash "$SCRIPTS/join.sh" testteam carol claude-code /tmp/project-c
  run bash "$SCRIPTS/send.sh" testteam alice "bob, carol" "spaced pair ping"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
  [[ "$output" =~ "Sent to carol" ]]
  [[ ! "$output" =~ "Sent to  carol" ]]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "spaced pair ping" ]]
  run bash "$SCRIPTS/inbox.sh" testteam carol
  [[ "$output" =~ "spaced pair ping" ]]
}

@test "send: comma-separated recipients skip empty middle entries" {
  bash "$SCRIPTS/join.sh" testteam carol claude-code /tmp/project-c
  run bash "$SCRIPTS/send.sh" testteam alice bob,,carol "empty middle ping"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
  [[ "$output" =~ "Sent to carol" ]]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "empty middle ping" ]]
  run bash "$SCRIPTS/inbox.sh" testteam carol
  [[ "$output" =~ "empty middle ping" ]]
}

@test "send: comma-separated recipients skip trailing empty entries" {
  run bash "$SCRIPTS/send.sh" testteam alice bob, "trailing empty ping"
  [ "$status" -eq 0 ]
  [ "$output" = "Sent to bob in team testteam" ]
  run bash "$SCRIPTS/inbox.sh" testteam bob
  [[ "$output" =~ "trailing empty ping" ]]
}

@test "send: single recipient still works unchanged" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "solo hello"
  [ "$status" -eq 0 ]
  [ "$output" = "Sent to bob in team testteam" ]
}
