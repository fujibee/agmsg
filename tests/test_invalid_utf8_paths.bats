#!/usr/bin/env bats

# A message body cut in the middle of a multibyte character (a lone E3 81) is
# not valid UTF-8. In a UTF-8 locale the character-aware sed/tr/cut/paste/grep
# reject it ("illegal byte sequence") or cut the line at it, and one such
# message used to stop a whole delivery path. One test per kind of path: every
# message around the cut one is still delivered, the command ends 0, and the
# bad bytes arrive unchanged. test_inbox.bats covers inbox.sh and history.sh and
# test_remote_sync.bats the sync push path.

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
  export PROJ="/tmp/agmsg-utf8-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  BAD="result=$(printf '\xe3\x81')"
  # Continuation bytes with no lead byte: the other way a body comes out invalid.
  BAD2="result=$(printf '\x80\x82')"
}

teardown() {
  teardown_test_env
}

send_three() {
  bash "$SCRIPTS/send.sh" team alice bob "first ok" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "$BAD" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "$BAD2" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "last ok" >/dev/null
}

@test "utf8 cut: the stop hook (check-inbox.sh) delivers every message and ends 0" {
  send_three
  # The hook finds its seat by project, so bob needs one of his own.
  bash "$SCRIPTS/join.sh" team bob claude-code /tmp/agmsg-utf8-proj-bob >/dev/null
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' claude-code /tmp/agmsg-utf8-proj-bob"
  [ "$status" -eq 0 ]
  LC_ALL=C grep -qF "first ok" <<<"$output"
  LC_ALL=C grep -qF "last ok" <<<"$output"
  LC_ALL=C grep -qF "$BAD" <<<"$output"
  LC_ALL=C grep -qF "$BAD2" <<<"$output"
}

@test "utf8 cut: the monitor (watch.sh) delivers every message" {
  send_three
  local out="$BATS_TEST_TMPDIR/watch.out" i
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" sid-utf8 "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  for i in $(seq 1 60); do
    LC_ALL=C grep -qF "last ok" "$out" 2>/dev/null && break
    sleep 0.5
  done
  agmsg_stop_pid "$pid"
  LC_ALL=C grep -qF "first ok" "$out"
  LC_ALL=C grep -qF "last ok" "$out"
  LC_ALL=C grep -qF "$BAD" "$out"
  LC_ALL=C grep -qF "$BAD2" "$out"
}

@test "utf8 cut: export.sh writes every message and ends 0" {
  send_three
  run bash "$SCRIPTS/export.sh" --team team
  [ "$status" -eq 0 ]
  [ "$(LC_ALL=C grep -c '"type":"message_sent"' <<<"$output")" -eq 4 ]
}

@test "utf8 cut: the jsonl storage driver sends, lists unread and reads history" {
  export AGMSG_STORAGE_DRIVER=jsonl
  send_three
  run bash "$SCRIPTS/inbox.sh" team bob
  [ "$status" -eq 0 ]
  LC_ALL=C grep -qF "4 new message(s)" <<<"$output"
  LC_ALL=C grep -qF "last ok" <<<"$output"
  run bash "$SCRIPTS/history.sh" team bob
  [ "$status" -eq 0 ]
  LC_ALL=C grep -qF "last ok" <<<"$output"
}
