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

# --- agmsg_db_path() Windows path conversion (#197) ---

@test "storage: agmsg_db_path applies cygpath -m on Windows so sqlite3.exe can open it (#197)" {
  # The native sqlite3.exe cannot open a Git Bash /c/... path; cygpath -m maps it
  # to the mixed C:/... form both the shell and sqlite3.exe accept. cygpath is
  # absent off Windows, so inject a shim on PATH to exercise the branch.
  local bindir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bindir"
  cat > "$bindir/cygpath" <<'SH'
#!/usr/bin/env bash
# Minimal stand-in: `cygpath -m /c/x` -> C:/x (BSD- and GNU-sed portable).
shift  # drop the -m flag
printf '%s\n' "$1" | sed -E 's#^/c/#C:/#'
SH
  chmod +x "$bindir/cygpath"
  run env PATH="$bindir:$PATH" AGMSG_STORAGE_PATH="/c/Users/test/db" \
    bash -c 'source "'"$SCRIPTS"'/lib/storage.sh"; agmsg_db_path'
  [ "$status" -eq 0 ]
  [ "$output" = "C:/Users/test/db/messages.db" ]
}

@test "storage: agmsg_db_path is a no-op without cygpath (off Windows)" {
  source "$SCRIPTS/lib/storage.sh"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  # cygpath is absent on the test host, so the path is returned unchanged.
  [ "$(agmsg_db_path)" = "$BATS_TEST_TMPDIR/store/messages.db" ]
}

# --- init-db.sh honoring the override ---

@test "storage: init-db creates the db at the overridden path (and makes the dir)" {
  local custom="$BATS_TEST_TMPDIR/nested/store"
  [ ! -d "$custom" ]
  AGMSG_STORAGE_PATH="$custom" bash "$SCRIPTS/internal/init-db.sh"
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

# --- append-only read-state events (transition: dual-write with read_at) ---

@test "storage: reading appends message_read events and dual-writes read_at" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg one"
  bash "$SCRIPTS/send.sh" testteam alice bob "msg two"
  local db="$AGMSG_STORAGE_PATH/messages.db"

  # read-state log starts empty
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events;")" -eq 0 ]

  run bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$status" -eq 0 ]
  # dual-write: read_at set AND an append-only message_read event per message
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;")" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read' AND team='testteam' AND agent='bob';")" -eq 2 ]

  # re-reading is a no-op: no duplicate read-state events
  bash "$SCRIPTS/inbox.sh" testteam bob
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events;")" -eq 2 ]
}

@test "storage: message content is never written to the events table (read-state only)" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  bash "$SCRIPTS/send.sh" testteam alice bob "secret body"
  bash "$SCRIPTS/inbox.sh" testteam bob >/dev/null
  local db="$AGMSG_STORAGE_PATH/messages.db"

  # events holds ONLY read-state rows — no other event types, no body column.
  # (Guards against the storage-axis regression of moving content into events.)
  [ -z "$(sqlite3 "$db" "SELECT type FROM events WHERE type<>'message_read';")" ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE body='secret body';")" -eq 1 ]
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

@test "storage: agmsg_sqlite sets a busy timeout without polluting output" {
  # .timeout (not PRAGMA) so the timeout value is never echoed into results.
  source "$SCRIPTS/lib/storage.sh"
  run agmsg_sqlite ":memory:" "SELECT 'only-this';"
  [ "$status" -eq 0 ]
  [ "$output" = "only-this" ]
}

@test "storage: agmsg_sqlite emits a raw char(31) separator, not caret '^_' (#102)" {
  # sqlite3 >= 3.50 renders control bytes with caret notation by default, which
  # would turn the char(31) record separator into the two chars "^_" and break
  # the IFS=$'\x1f' field splitting in inbox/history/check-inbox + the watch
  # stream. agmsg_sqlite must pass -escape off so the byte stays raw. On older
  # sqlite3 the byte is raw anyway, so this holds on every supported version.
  source "$SCRIPTS/lib/storage.sh"
  run agmsg_sqlite ":memory:" "SELECT 'a'||char(31)||'b';"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q $'\x1f'
  ! printf '%s' "$output" | grep -q '\^_'
}

@test "send: concurrent fan-out to N recipients all land (no SQLITE_BUSY)" {
  # Without a busy_timeout, concurrent writers fail with SQLITE_BUSY(5) and the
  # sends silently drop. With the wrapper they wait and all land. See #114.
  local x
  for x in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" >/dev/null 2>&1 ) &
  done
  wait
  local n
  n=$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
    "SELECT COUNT(*) FROM messages WHERE from_agent='leader';")
  [ "$n" -eq 10 ]
}

@test "send: concurrent fan-out to a FRESH (uninitialized) store all lands" {
  # No init-db first — every send races to initialize an override store that
  # doesn't exist yet. Without idempotent init + INSERT retry, the losers abort
  # on "already exists" / "no such table" and drop. See #114.
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/freshstore"
  local x
  for x in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" >/dev/null 2>&1 ) &
  done
  wait
  local n
  n=$(sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 10 ]
}
