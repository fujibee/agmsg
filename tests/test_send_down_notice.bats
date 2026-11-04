#!/usr/bin/env bats

# send.sh tells the sender when agmsgd has a down record for the recipient's
# seat (#1910): the message is stored, but not delivered yet.

load test_helper

setup() {
  setup_test_env
  unset AGMSG_SYNC_CONNECTION_DIR
  PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ" "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  # shellcheck disable=SC1091
  . "$TEST_SKILL_DIR/scripts/lib/down-notice.sh"
}

teardown() { teardown_test_env; }

@test "no record: send prints only the usual line" {
  run bash "$SCRIPTS/send.sh" team alice bob "hi"
  [ "$status" -eq 0 ]
  [ "$output" = "Sent to bob in team team" ]
}

@test "a down record for the recipient adds a stored-but-not-delivered note; other seats are not mentioned" {
  down_notice_set "$(down_notice_key agmsgd.seat team/bob)" down "socket gone" "run /agmsg actas bob in that session"
  run bash "$SCRIPTS/send.sh" team bob alice "hi"
  [ "$output" = "Sent to alice in team team" ]
  run bash "$SCRIPTS/send.sh" team alice bob "hi"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "Sent to bob in team team"
  printf '%s\n' "$output" | grep -qF "bob is not reachable by agmsgd since"
  printf '%s\n' "$output" | grep -qF "stored but not delivered"
  down_notice_clear "$(down_notice_key agmsgd.seat team/bob)"
  run bash "$SCRIPTS/send.sh" team alice bob "hi"
  [ "$output" = "Sent to bob in team team" ]
}
