#!/usr/bin/env bats

# A body that contains a NUL byte is kept byte for byte (it cannot live in a
# shell variable, so send.sh keeps it in a file and the store reads it from
# there), and every place that shows a body shows the message instead of cutting
# the row at the NUL (the cut used to drop the message from the inbox and leave
# it unread forever). The jsonl driver carries it as the JSON escape for it.

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  bash "$SCRIPTS/join.sh" team alice claude-code /tmp/agmsg-nul-a >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code /tmp/agmsg-nul-b >/dev/null
  NULBODY="$BATS_TEST_TMPDIR/nul-body"
  printf 'a\0b' > "$NULBODY"
}

teardown() {
  teardown_test_env
}

# The stored body of the most recent message, as hex (the store holds the bytes).
stored_body_hex() {
  local db
  db="$(bash -c 'source "$1/lib/storage.sh"; agmsg_storage_load; agmsg_db_path team' _ "$SCRIPTS")"
  sqlite3 "$db" "SELECT hex(body) FROM events WHERE type='message_sent' ORDER BY seq DESC LIMIT 1;"
}

@test "send --body-file: the bytes of a body with a NUL are stored unchanged" {
  run bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY"
  [ "$status" -eq 0 ]
  [ "$(stored_body_hex)" = "610062" ]
}

@test "send --body -: a body with a NUL on stdin is stored unchanged" {
  run bash -c "printf 'a\\0b' | bash '$SCRIPTS/send.sh' team alice bob --body -"
  [ "$status" -eq 0 ]
  [ "$(stored_body_hex)" = "610062" ]
}

@test "send --body-file: a body that is only a NUL is not called empty" {
  printf '\0' > "$NULBODY"
  run bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY"
  [ "$status" -eq 0 ]
  [ "$(stored_body_hex)" = "00" ]
}

@test "send --body-file: a body without a NUL is stored as before, trailing newlines dropped" {
  printf 'plain\n\n' > "$NULBODY"
  run bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY"
  [ "$status" -eq 0 ]
  [ "$(stored_body_hex)" = "706C61696E" ]
}

@test "inbox: a message whose body has a NUL is shown (the NUL as U+2400), marked read, and the others still show" {
  bash "$SCRIPTS/send.sh" team alice bob "first ok" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "last ok" >/dev/null
  run bash "$SCRIPTS/inbox.sh" team bob
  [ "$status" -eq 0 ]
  grep -qF "3 new message(s)" <<<"$output"
  grep -qF "first ok" <<<"$output"
  grep -qF "last ok" <<<"$output"
  grep -qF "a␀b" <<<"$output"
  run bash "$SCRIPTS/inbox.sh" team bob
  grep -qF "No new messages." <<<"$output"
}

@test "history: a message whose body has a NUL keeps its time and shows the whole body" {
  bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY" >/dev/null
  run bash "$SCRIPTS/history.sh" team bob
  [ "$status" -eq 0 ]
  grep -qF "a␀b" <<<"$output"
  grep -qE '\[20[0-9]{2}-' <<<"$output"
}

@test "stop hook: a message whose body has a NUL is delivered and the rest of the batch with it" {
  bash "$SCRIPTS/send.sh" team alice bob "first ok" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY" >/dev/null
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' claude-code /tmp/agmsg-nul-b"
  [ "$status" -eq 0 ]
  grep -qF "first ok" <<<"$output"
  grep -qF "a␀b" <<<"$output"
}

@test "send with the jsonl driver: the NUL body is carried and read back as the same bytes" {
  export AGMSG_STORAGE_DRIVER=jsonl
  run bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY"
  [ "$status" -eq 0 ]
  # What the log hands back for that body, byte for byte.
  bash "$SCRIPTS/export.sh" --team team | jq -j 'select(.type=="message_sent") | .body' > "$BATS_TEST_TMPDIR/back"
  cmp "$NULBODY" "$BATS_TEST_TMPDIR/back"
  run bash "$SCRIPTS/inbox.sh" team bob
  [ "$status" -eq 0 ]
  grep -qF "a␀b" <<<"$output"
  run bash "$SCRIPTS/inbox.sh" team bob
  grep -qF "No new messages." <<<"$output"
}

@test "monitor (watch.sh): a message whose body has a NUL is delivered, with the others" {
  bash "$SCRIPTS/send.sh" team alice bob "first ok" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "last ok" >/dev/null
  local out="$BATS_TEST_TMPDIR/watch.out" i
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" sid-nul /tmp/agmsg-nul-b claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  for i in $(seq 1 60); do
    LC_ALL=C grep -qF "last ok" "$out" 2>/dev/null && break
    sleep 0.5
  done
  agmsg_stop_pid "$pid"
  LC_ALL=C grep -qF "first ok" "$out"
  LC_ALL=C grep -qF "last ok" "$out"
  grep -qF "a␀b" "$out"
}

@test "export: a body with a NUL is carried as the JSON escape for it" {
  bash "$SCRIPTS/send.sh" team alice bob --body-file "$NULBODY" >/dev/null
  run bash "$SCRIPTS/export.sh" --team team
  [ "$status" -eq 0 ]
  grep -qF 'a\u0000b' <<<"$output"
}

@test "a body of many NULs is sent and shown in linear time: the display is bounded and says how big the body is" {
  head -c 100000 /dev/zero > "$BATS_TEST_TMPDIR/many-nul"
  bash "$SCRIPTS/send.sh" team alice bob --body-file "$BATS_TEST_TMPDIR/many-nul" >/dev/null
  [ "$(stored_body_hex | wc -c | tr -d ' ')" -eq 200001 ]
  run bash "$SCRIPTS/inbox.sh" team bob
  [ "$status" -eq 0 ]
  grep -qF "[100000 bytes]" <<<"$output"
  run bash "$SCRIPTS/inbox.sh" team bob
  grep -qF "No new messages." <<<"$output"
}
