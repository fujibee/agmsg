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
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
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
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/agmsg-storage-test-bob

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
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a
  bash "$SCRIPTS/join.sh" testteam bob claude-code /tmp/project-b
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

@test "storage: runtime lock replacement is compare-and-swap" {
  source "$SCRIPTS/lib/storage.sh"
  local resource="codex-dispatcher:test" owner

  owner="$(agmsg_runtime_lock_acquire "$resource" 111)"
  [ "$owner" = 111 ]
  owner="$(agmsg_runtime_lock_acquire "$resource" 222 111)"
  [ "$owner" = 222 ]
  # A contender that observed the old generation cannot delete its successor.
  owner="$(agmsg_runtime_lock_acquire "$resource" 333 111)"
  [ "$owner" = 222 ]
  agmsg_runtime_lock_verify "$resource" 222
  ! agmsg_runtime_lock_verify "$resource" 333
  agmsg_runtime_lock_release "$resource" 333
  agmsg_runtime_lock_verify "$resource" 222
  agmsg_runtime_lock_release "$resource" 222
  [ -z "$(agmsg_runtime_lock_owner "$resource")" ]
}

@test "storage: runtime lock initializes a fresh store before send" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/lock-first-store"
  source "$SCRIPTS/lib/storage.sh"

  [ "$(agmsg_runtime_lock_acquire codex-dispatcher:test 111)" = 111 ]
  bash "$SCRIPTS/send.sh" team alice bob "after lock init" --force
  [ "$(agmsg_sqlite "$(agmsg_db_path)" "SELECT COUNT(*) FROM messages WHERE body = 'after lock init';")" = 1 ]
}

@test "send: concurrent fan-out to N recipients all land (no SQLITE_BUSY)" {
  # Without a busy_timeout, concurrent writers fail with SQLITE_BUSY(5) and the
  # sends silently drop. With the wrapper they wait and all land. See #114.
  local x
  for x in 1 2 3 4 5 6 7 8 9 10; do
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" --force >/dev/null 2>&1 ) &
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
    ( bash "$SCRIPTS/send.sh" team leader "tgt$x" "job $x" --force >/dev/null 2>&1 ) &
  done
  wait
  local n
  n=$(sqlite3 "$AGMSG_STORAGE_PATH/messages.db" "SELECT COUNT(*) FROM messages;")
  [ "$n" -eq 10 ]
}
