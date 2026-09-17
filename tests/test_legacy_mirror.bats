#!/usr/bin/env bats

# The legacy `messages` table is a read interface other software depends on:
# the desktop app and any external viewer open the store and read that table.
# Those readers do not restart when we ship, and we cannot enumerate them, so it
# is a contract rather than a migration step.
#
# The event log replaced it as the source of truth and nothing writes to it any
# more, which means a message sent by a current build is invisible to every one
# of those readers. These tests read the table the way such a reader does —
# directly, with no agmsg code in between — because that is the only way to
# check a promise made to code we do not control.
#
# Scope: the legacy table exists only in the sqlite driver (created in
# drivers/storage/sqlite.sh and internal/init-db.sh, nowhere else). A team on
# the jsonl driver has no such table at all and is invisible to those readers
# regardless; mirroring cannot change that and does not try.

load test_helper

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" mteam alice claude-code /tmp/mp-a
  bash "$SCRIPTS/join.sh" mteam bob   claude-code /tmp/mp-b
  DB="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_storage_load; agmsg_db_path mteam')"
}

teardown() { teardown_test_env; }

# What an external reader runs. No agmsg helpers: if this stops matching what
# they see, the test has stopped testing the contract.
legacy_rows() {
  sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='mteam' AND to_agent='alice' AND body='$1';" 2>/dev/null | tr -d '\r'
}

legacy_read_at() {
  sqlite3 "$DB" "SELECT COALESCE(read_at,'') FROM messages WHERE team='mteam' AND to_agent='alice' AND body='$1';" 2>/dev/null | tr -d '\r'
}

@test "legacy mirror: a sent message is visible to a reader of the legacy table (#689)" {
  bash "$SCRIPTS/send.sh" mteam bob alice "visible to old readers"
  [ "$(legacy_rows 'visible to old readers')" -eq 1 ]
}

@test "legacy mirror: reading a message marks it read for a reader of the legacy table (#689)" {
  # Read state is mirrored as well as the message, and that is the harder half
  # to argue for: mirroring it means two copies of the same fact, which can
  # disagree. Not mirroring it is worse. An old viewer reads read_at from the
  # legacy table, so leaving it null shows every message as unread forever --
  # a permanent wrong answer, against a disagreement that only appears if the
  # two writes come apart.
  bash "$SCRIPTS/send.sh" mteam bob alice "read state travels"
  [ -z "$(legacy_read_at 'read state travels')" ]

  run bash "$SCRIPTS/inbox.sh" mteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"read state travels"* ]]

  [ -n "$(legacy_read_at 'read state travels')" ]
}

@test "legacy mirror: a mirrored message is still delivered exactly once (#689)" {
  # The cost of mirroring, and the reason the correspondence has to be recorded
  # rather than just written: storage_list_unread and storage_history each UNION
  # the event log with the legacy table, and before this the two branches had no
  # way to recognise the same message — measured, the same message was listed
  # twice and inbox announced "2 new message(s)".
  bash "$SCRIPTS/send.sh" mteam bob alice "exactly once"

  run bash "$SCRIPTS/inbox.sh" mteam alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 new message(s)"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'exactly once')" -eq 1 ]

  run bash "$SCRIPTS/history.sh" mteam alice
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'exactly once')" -eq 1 ]
}
