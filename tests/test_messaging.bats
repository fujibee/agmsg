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
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM events WHERE type='message_sent' AND team='brandnewteam';")
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

# --- send.sh: --stdin (#378) ---
#
# A positional body goes through the sender's shell (backticks / $(...) can
# execute or vanish) and, on Windows, through MSYS's argv-conversion path
# (silent truncation at 8186 bytes). A body sent via --stdin meets neither,
# because it never touches argv. The positional form remains available
# (deprecated) and still carries both hazards.

@test "send: -- keeps a body that is literally --stdin working (backwards compat)" {
  # Before --stdin existed, "--stdin" was just an ordinary body. Adding the
  # flag must not silently reinterpret it.
  run bash "$SCRIPTS/send.sh" testteam alice bob -- --stdin
  [ "$status" -eq 0 ]
  local stored
  stored=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT body FROM messages WHERE to_agent='bob';")
  [ "$stored" = "--stdin" ]
}

@test "send: -- keeps a body that is literally --force working" {
  run bash "$SCRIPTS/send.sh" testteam alice bob -- --force
  [ "$status" -eq 0 ]
  local stored
  stored=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT body FROM messages WHERE to_agent='bob';")
  [ "$stored" = "--force" ]
}

# The two tests below are a pair, and only mean something together: the
# second is the control for the first. `-- --force --force` sends the body
# "--force" to an UNREGISTERED team/recipient, which the roster check (#355)
# refuses unless force mode is on — so the send succeeding is what proves the
# trailing --force was still parsed as a flag after `--` consumed the body.
# Without the control, that success could just as well mean the roster check
# never ran for an unknown team, and the test would assert nothing.
@test "send: a --force after a '--' body still turns force mode on" {
  run bash "$SCRIPTS/send.sh" brandnewteam ghost nobody -- --force --force
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- "Sent to nobody"
  local stored
  stored=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT body FROM messages WHERE to_agent='nobody';")
  [ "$stored" = "--force" ]
}

@test "send: control — the same '--' body without a trailing --force is still roster-checked" {
  run bash "$SCRIPTS/send.sh" brandnewteam ghost nobody -- --force
  [ "$status" -ne 0 ]
  # Assert WHICH failure this is. A bare status check would also pass on an
  # argument-parsing error, and then the pair would only show that the extra
  # argument turns failure into success — not that it turned force mode on.
  printf '%s' "$output" | grep -qF -- "has no registered agents"
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

# `--` itself was a valid positional body before the flag existed (only
# argument 5 was inspected, so argument 4 was taken verbatim). It is now
# consumed as the terminator, which is the third and least obvious of the
# literal bodies this change breaks — `-- --` is its migration form.
@test "send: -- keeps a body that is literally -- working (backwards compat)" {
  run bash "$SCRIPTS/send.sh" testteam alice bob -- --
  [ "$status" -eq 0 ]
  local stored
  stored=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT body FROM messages WHERE to_agent='bob';")
  [ "$stored" = "--" ]
}

@test "send: -- with no body after it is an error, not an empty message" {
  run bash "$SCRIPTS/send.sh" testteam alice bob --
  [ "$status" -ne 0 ]
  [[ "$output" =~ "missing message body after" ]]
}

@test "send: --stdin delivers a body containing backticks and \$(...) byte-identical" {
  local body='price is `echo hi` and $(whoami) literally'
  run bash -c "printf '%s' \"\$1\" | bash \"\$2\" testteam alice bob --stdin" _ "$body" "$SCRIPTS/send.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- "Sent to bob"
  local stored
  stored=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT body FROM messages WHERE to_agent='bob';")
  [ "$stored" = "$body" ]
}

@test "send: --stdin preserves an explicit trailing newline byte-for-byte" {
  # A plain `stored=$(sqlite3 ... SELECT body ...)` capture would strip ALL
  # trailing newlines via command substitution on the assertion side too,
  # so it would pass whether the stored body kept zero, one, or several
  # trailing newlines — it would not actually test what this test claims.
  # hex()/length() sidestep that: the exact byte sequence of "line1\nline2\n"
  # is 6c696e65310a6c696e65320a (12 bytes), independent of shell capture.
  run bash -c "printf 'line1\nline2\n' | bash \"\$1\" testteam alice bob --stdin" _ "$SCRIPTS/send.sh"
  [ "$status" -eq 0 ]
  local body_hex body_len
  # sqlite3's hex() emits uppercase A-F.
  body_hex=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT hex(body) FROM messages WHERE to_agent='bob';")
  body_len=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT length(body) FROM messages WHERE to_agent='bob';")
  [ "$body_hex" = "6C696E65310A6C696E65320A" ]
  [ "$body_len" -eq 12 ]
}

@test "send: positional body still works unchanged alongside the new flag" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "hello"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
}

@test "send: rejects an option-like positional body without a '--' separator" {
  run bash "$SCRIPTS/send.sh" testteam alice bob --body-fiel
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "option-like body: use -- separator"
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

@test "send: an option-like body still sends verbatim after the '--' separator" {
  run bash "$SCRIPTS/send.sh" testteam alice bob -- --body-fiel
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to bob" ]]
}

@test "send: --stdin composes with --force" {
  run bash -c "printf 'hi' | bash \"\$1\" brandnewteam ghost nobody --stdin --force" _ "$SCRIPTS/send.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Sent to nobody" ]]
}

@test "send: rejects a positional body combined with --stdin instead of silently picking one" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "hello" --stdin
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "was already given"
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

@test "send: rejects empty stdin with a clear error, not an empty message" {
  run bash -c "printf '' | bash \"\$1\" testteam alice bob --stdin" _ "$SCRIPTS/send.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "no data was read"
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

# A bash string cannot hold a NUL byte, so `IFS= read -r -d ''` stops at the
# first one. Storing the shortened value with a success exit would report a
# whole body sent when it was not, so the input is refused instead. Note the
# NUL must be written by printf's FORMAT string: passing it through an
# argument (printf '%s' "$var") cannot work, because argv cannot carry NUL
# either — a test written that way would silently exercise NUL-free input.
@test "send: rejects --stdin input containing a NUL byte instead of truncating it" {
  run bash -c "printf 'before\000after' | bash \"\$1\" testteam alice bob --stdin" _ "$SCRIPTS/send.sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "NUL byte"
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 0 ]
}

# A leading NUL leaves the read with an empty value AND a zero exit, so the
# NUL check has to come before the "no data" check — otherwise this input
# would be blamed on an empty stdin rather than on the byte that caused it.
@test "send: reports a leading NUL as a NUL, not as empty input" {
  run bash -c "printf '\000trailing' | bash \"\$1\" testteam alice bob --stdin" _ "$SCRIPTS/send.sh"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "NUL byte" ]]
}

@test "send: rejects an unexpected extra argument after the message" {
  run bash "$SCRIPTS/send.sh" testteam alice bob "hello" extra
  [ "$status" -ne 0 ]
  [[ "$output" =~ "unexpected extra argument" ]]
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
