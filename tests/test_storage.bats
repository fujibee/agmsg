#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# --- agmsg_db_path() resolution ---

@test "storage: default path resolves under the skill dir" {
  source "$SCRIPTS/lib/storage.sh"
  unset AGMSG_STORAGE_PATH
  [ "$(agmsg_db_path)" = "$TEST_SKILL_DIR/db/messages.db" ]
}

@test "storage: AGMSG_STORAGE_PATH overrides the storage dir" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  [ "$(agmsg_db_path)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

@test "storage: trailing slash on the override is normalized" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store/"
  [ "$(agmsg_db_path)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

# --- init-db.sh honoring the override ---

@test "storage: init-db creates the db at the overridden path (and makes the dir)" {
  local custom="$BATS_TEST_TMPDIR/nested/store"
  [ ! -d "$custom" ]
  AGMSG_STORAGE_PATH="$custom" bash "$SCRIPTS/init-db.sh"
  [ -f "$custom/messages.db" ]
}

# --- end-to-end roundtrip through the override ---

@test "storage: send and inbox share the overridden db" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "hi via override"
  [ -f "$AGMSG_STORAGE_PATH/messages.db" ]

  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hi via override" ]]
}

@test "storage: stop-hook delivery works when the default db dir is absent but the override is populated" {
  local store="$BATS_TEST_TMPDIR/store"
  local project="/tmp/agmsg-storage-test-proj"

  # Register an agent so check-inbox can resolve identity via whoami.
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$project"

  # A message addressed to alice lives only in the overridden store.
  AGMSG_STORAGE_PATH="$store" bash "$SCRIPTS/send.sh" testteam bob alice "via override store"

  # Simulate a clean install whose default skill db dir never existed.
  rm -rf "$TEST_SKILL_DIR/db"

  # Stop-hook delivery must still succeed (exit 0) and surface the message —
  # the cooldown marker now lives in run/, not the (absent) db dir.
  run bash -c "echo '{}' | AGMSG_STORAGE_PATH='$store' bash '$SCRIPTS/check-inbox.sh' claude-code '$project'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "via override store" ]]
}

@test "storage: default db is untouched when the override is set" {
  # The default store was initialized in setup; writing through an override
  # must not add rows to it.
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "isolated"

  local default_count
  default_count=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$default_count" -eq 0 ]
}
