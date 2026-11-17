#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# An `install.sh --update` that ends between "Updating agmsg..." and the first
# progress line used to end with no word about why: several steps in that stretch
# return 1, or fail under errexit, and the script just ends. A CI run twice ended a
# test that way (the output stopped at "Updating agmsg...", status non-zero) with
# nothing to say which step it was. Each case here makes one of those steps fail and
# checks that the update names the step, the command and the path, and ends with
# the same status and at the same place as before.
#
# Every run uses a throwaway HOME inside the test's own temp directory.

load test_helper

setup() {
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SK="$FAKE_HOME/.agents/skills/agmsg"
  unset CODEX_HOME
  unset AGMSG_STORAGE_PATH AGMSG_CONFIG AGMSG_STORAGE_DRIVER AGMSG_APP_BASE AGMSG_SPAWN_OPTIONS_FILE
  export AGMSG_AGENT_PID=""
  SHIMS="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$SHIMS"
  HOLDER_PID=""
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg >/dev/null 2>&1
}

# The holder (a single sqlite3 that ends by itself) is this test's own child; it is
# released by creating a file it watches, and waited for, never signalled. Nothing is
# removed here: the runner removes BATS_TEST_TMPDIR.
teardown() {
  release_install_db
}

# Let go of the hold now (a file the holder is watching) and wait for it to end.
release_install_db() {
  if [ -n "$HOLDER_PID" ]; then
    : > "$BATS_TEST_TMPDIR/release-hold"
    wait "$HOLDER_PID" 2>/dev/null || true
    HOLDER_PID=""
  fi
}

# A command that fails when any argument matches <pattern>, and otherwise runs
# the real one found after the shim directory.
shim_fail_on() {   # <command> <glob pattern for an argument> [exit status]
  local real
  real="$(command -v "$1")"
  printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do' \
    "  case \"\$a\" in $2) exit ${3:-1} ;; esac" \
    'done' \
    "exec $real \"\$@\"" > "$SHIMS/$1"
  chmod +x "$SHIMS/$1"
}

update() {
  HOME="$FAKE_HOME" PATH="$SHIMS:$PATH" run bash "$REPO_ROOT/install.sh" --update
}

has() { printf '%s\n' "$output" | grep -qF -- "$1"; }

# Another sqlite3 takes install.db's write lock and holds it, then ends by itself
# (one process: BEGIN EXCLUSIVE, then a wait). With <seconds> it holds for that long;
# with none it holds until release_install_db, so a test that needs the update to
# meet the hold does not depend on how fast the runner is (a 120 s bound ends a test
# that forgot to release).
hold_install_db() {   # [seconds]
  local wait_cmd
  if [ -n "${1:-}" ]; then
    wait_cmd="sleep $1"
  else
    wait_cmd="n=0; while [ ! -e '$BATS_TEST_TMPDIR/release-hold' ] && [ \$n -lt 1200 ]; do sleep 0.1; n=\$((n + 1)); done"
  fi
  # .timeout first: the readiness probe below writes too, and a holder that met it
  # mid-write without a wait would give up at once and never hold anything.
  sqlite3 "$SK/run/install.db" ".timeout 10000" "BEGIN EXCLUSIVE;" ".shell $wait_cmd" >/dev/null 2>&1 &
  HOLDER_PID=$!
  # Wait until the hold is real: a second writer must be refused.
  local i=0
  while sqlite3 "$SK/run/install.db" "CREATE TABLE IF NOT EXISTS probe_hold(x);" >/dev/null 2>&1; do
    sqlite3 "$SK/run/install.db" "DROP TABLE probe_hold;" >/dev/null 2>&1 || true
    i=$((i + 1)); [ "$i" -lt 300 ] || break
    sleep 0.1
  done
  [ "$i" -lt 300 ]
}

@test "an update that goes through names no stopping step" {
  update
  [ "$status" -eq 0 ]
  refute has "update stopped at"
}

@test "install.db held past the wait: the update names the table, sqlite's rc and the file, and still exits 1" {
  hold_install_db
  export AGMSG_INSTALL_DB_BUSY_MS=300
  update
  [ "$status" -eq 1 ]
  has "install.db: creating the meta table failed (sqlite3 rc="
  has "$SK/run/install.db"
  has "could not read or create install.db's meta row"
  has "update stopped at: starting the install operation"
  has "(exit status 1)"
}

# The helpers themselves, called straight after the hold is confirmed: with no wait
# they fail at once (so removing the .timeout turns these red every time, whatever
# the runner's speed), with it they come back only after the writer lets go.
@test "ensure_meta waits for a writer that lets go instead of failing at once" {
  hold_install_db 4
  AGMSG_INSTALL_DB_BUSY_MS=15000 run bash -c '. "$1/scripts/lib/install-db.sh"; agmsg_install_db_ensure_meta "$2"' _ "$REPO_ROOT" "$SK/run/install.db"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

@test "apply_schema waits for a writer that lets go instead of failing at once" {
  hold_install_db 4
  AGMSG_INSTALL_DB_BUSY_MS=15000 run bash -c '. "$1/scripts/lib/install-db.sh"; agmsg_install_db_apply_schema "$2" "$1/scripts/daemon/schema.sql"' _ "$REPO_ROOT" "$SK/run/install.db"
  [ "$status" -eq 0 ]
}

@test "the wait knob: empty, text and negative use the default; 0 is no wait; a huge number is capped" {
  busy() { AGMSG_INSTALL_DB_BUSY_MS="$1" bash -c '. "$1/scripts/lib/install-db.sh"; _agmsg_install_db_busy_ms' _ "$REPO_ROOT"; }
  [ "$(busy '')" = 5000 ]
  [ "$(busy abc)" = 5000 ]
  [ "$(busy -1)" = 5000 ]
  [ "$(busy 0)" = 0 ]
  [ "$(busy 00500)" = 500 ]
  [ "$(busy 0000000000)" = 0 ]
  [ "$(busy 0000000500)" = 500 ]
  [ "$(busy 000000000000000000000500)" = 500 ]
  [ "$(busy 600001)" = 600000 ]
  [ "$(busy 99999999999999999999)" = 600000 ]
  [ "$(busy 2147483648)" = 600000 ]
  [ "$(env -u AGMSG_INSTALL_DB_BUSY_MS bash -c '. "$1/scripts/lib/install-db.sh"; _agmsg_install_db_busy_ms' _ "$REPO_ROOT")" = 5000 ]
}

@test "install.db held, the wait is bounded by AGMSG_INSTALL_DB_BUSY_MS: ensure_meta gives up near it, not after the default" {
  hold_install_db
  local t0=$SECONDS
  AGMSG_INSTALL_DB_BUSY_MS=700 run bash -c '. "$1/scripts/lib/install-db.sh"; agmsg_install_db_ensure_meta "$2"' _ "$REPO_ROOT" "$SK/run/install.db"
  # 3 = install.db was there and its first statement failed on a busy file.
  [ "$status" -eq 3 ]
  # The default wait is 5 s; a call that gave up in under 4 s used the knob.
  [ $((SECONDS - t0)) -lt 4 ]
}

@test "the incomplete-operation record cannot be made: mktemp failure names the step and the directory" {
  shim_fail_on mktemp '*.install-op-incomplete*'
  update
  [ "$status" -eq 1 ]
  has "incomplete-operation record: mktemp failed in $SK/run"
  has "could not record the incomplete-operation marker: $SK/run/install-op-incomplete.json"
  has "update stopped at: starting the install operation"
}

@test "the recovery helper cannot be made: mktemp failure names the helper's directory" {
  shim_fail_on mktemp '*.install-op-recovery*'
  update
  [ "$status" -eq 1 ]
  has "recovery helper: mktemp failed in $SK/run"
  has "update stopped at: writing the recovery helper ($SK/run/install-op-recovery.sh)"
}

@test "the recovery helper cannot be made: chmod failure names the file" {
  shim_fail_on chmod '*.install-op-recovery*'
  update
  [ "$status" -eq 1 ]
  has "recovery helper: chmod 600 failed on"
  has "update stopped at: writing the recovery helper"
}

@test "the trash directory cannot be recreated: names the directory" {
  shim_fail_on mkdir '*/.trash'
  update
  [ "$status" -eq 1 ]
  has "could not recreate the trash directory"
  has "update stopped at: resetting $SK/.trash"
}

@test "CHANGELOG.md cannot be copied: names the target" {
  shim_fail_on cp '*/CHANGELOG.md'
  update
  [ "$status" -eq 1 ]
  has "update stopped at: copying CHANGELOG.md to $SK/CHANGELOG.md"
}

# The two below fail under errexit with no message of their own. The status and the
# place the update stops at are exactly what they were; only the line is new.

@test "moving the state: a failing readlink ends the update with its own status, and names the step" {
  shim_fail_on readlink '*/run' 7
  update
  [ "$status" -eq 7 ]
  has "update stopped at: moving the state of $SK (exit status 7)"
  refute has "file(s) backed up"
}

@test "listing the built-in drivers: a failing sort ends the update with its own status, before any progress line" {
  printf '%s\n' '#!/usr/bin/env bash' \
    '[ "${LC_ALL:-}" = C ] && [ "$#" -eq 0 ] && exit 9' \
    "exec $(command -v sort) \"\$@\"" > "$SHIMS/sort"
  chmod +x "$SHIMS/sort"
  update
  [ "$status" -eq 9 ]
  has "update stopped at: listing the built-in drivers of $SK (exit status 9)"
  refute has "file(s) backed up"
}

@test "the note is best effort: with stderr closed the update still ends with its own status and releases the lock" {
  shim_fail_on readlink '*/run' 7
  HOME="$FAKE_HOME" PATH="$SHIMS:$PATH" run bash -c 'exec 2>&-; exec bash "$1" --update' _ "$REPO_ROOT/install.sh"
  [ "$status" -eq 7 ]
  # The lock database is free again: a writer with no wait gets it at once.
  local i=0
  until sqlite3 "$SK/.install-op/lock.db" "BEGIN EXCLUSIVE; COMMIT;" >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 50 ] || break
    sleep 0.1
  done
  [ "$i" -lt 50 ]
}

# An update that stops after it has recorded its incomplete-operation marker but
# before it changed anything used to leave that marker behind, and the next update
# refused until someone ran --recover. Now it takes back its own marker, only in that
# case (an existing refusal narrowed to the updates that changed something).

marker() { printf '%s' "$SK/run/install-op-incomplete.json"; }

@test "stopped before any change: the marker is taken back, and the next update goes through" {
  hold_install_db
  export AGMSG_INSTALL_DB_BUSY_MS=300
  update
  [ "$status" -eq 1 ]
  has "update stopped at: starting the install operation"
  has "nothing was changed, so no incomplete-operation record is kept"
  [ ! -e "$(marker)" ]
  # Let go now (the holder watches a file), then wait for it to end.
  release_install_db
  unset AGMSG_INSTALL_DB_BUSY_MS
  update
  [ "$status" -eq 0 ]
  refute has "incomplete"
  refute has "update stopped at"
}

@test "stopped after a change: the marker stays and the next update refuses, as before" {
  shim_fail_on mv '*install-manifest.json.prev'
  update
  [ "$status" -eq 1 ]
  has "could not move the previous completion record aside"
  refute has "nothing was changed"
  [ -f "$(marker)" ]
  rm -f "$SHIMS/mv"
  update
  [ "$status" -eq 1 ]
  has "is incomplete; install (update) will not start"
}

@test "a marker that is not this run's own is left alone" {
  shim_fail_on mv '*install-manifest.json.prev'
  update
  [ -f "$(marker)" ]
  cp "$(marker)" "$BATS_TEST_TMPDIR/marker.before"
  rm -f "$SHIMS/mv"
  hold_install_db
  export AGMSG_INSTALL_DB_BUSY_MS=300
  update
  [ "$status" -eq 1 ]
  has "is incomplete; install (update) will not start"
  refute has "nothing was changed"
  cmp "$(marker)" "$BATS_TEST_TMPDIR/marker.before"
}

@test "a marker that cannot be taken back stays, with the reason and the recovery command" {
  hold_install_db
  export AGMSG_INSTALL_DB_BUSY_MS=300
  shim_fail_on rm '*install-op-incomplete.json'
  update
  [ "$status" -eq 1 ]
  has "could not take back the incomplete-operation record"
  has "it may still be there"
  has "--update --recover "
  refute has "nothing was changed"
  [ -f "$(marker)" ]
}

@test "stopped after ensure_meta already created the table: the marker stays" {
  # The meta table is gone, so the CREATE that runs first makes it, and only then
  # does the read of the install id fail. That is a change, so no marker is taken back.
  sqlite3 "$SK/run/install.db" "DROP TABLE meta;"
  shim_fail_on sqlite3 '*SELECT\ install_id*' 5
  update
  [ "$status" -eq 1 ]
  has "reading the install id failed"
  refute has "nothing was changed"
  [ -f "$(marker)" ]
}

# What the withdraw says follows the status pending_remove returns, not a look at
# whether the file can be seen (a parent directory that cannot be searched hides a
# file that is still there).
withdraw_with() {   # <stub body for agmsg_install_op_pending_remove> <marker path>
  awk '/^agmsg_install_op_withdraw_unchanged\(\) \{/,/^\}/' "$REPO_ROOT/install.sh" > "$BATS_TEST_TMPDIR/withdraw.sh"
  [ -s "$BATS_TEST_TMPDIR/withdraw.sh" ]
  AGMSG_INSTALL_OP_MARKER="$2" AGMSG_INSTALL_OP_ID=abc SCRIPT_DIR=/x CMD_NAME=y \
    run bash -c 'source "$1"; agmsg_install_op_pending_remove() { '"$3"'; }; agmsg_install_op_withdraw_unchanged; echo "ID=[$AGMSG_INSTALL_OP_ID]"' _ "$BATS_TEST_TMPDIR/withdraw.sh"
}

@test "withdraw: status 0 (removed) says nothing was changed and clears the operation id" {
  local m="$BATS_TEST_TMPDIR/marker.json"; : > "$m"
  withdraw_with x "$m" 'rm -f "$1"; return 0'
  [ "$status" -eq 0 ]
  has "nothing was changed, so no incomplete-operation record is kept"
  refute has "lock could not be confirmed"
  has "ID=[]"
}

@test "withdraw: status 2 (removed, then the lock re-check failed) says so, and clears the operation id" {
  local m="$BATS_TEST_TMPDIR/marker.json"; : > "$m"
  withdraw_with x "$m" 'rm -f "$1"; return 2'
  [ "$status" -eq 0 ]
  has "nothing was changed, so no incomplete-operation record is kept (the lock could not be confirmed again after it was removed)"
  has "ID=[]"
}

@test "withdraw: status 1 says the record may still be there and names the recovery command, even if the file cannot be seen" {
  local m="$BATS_TEST_TMPDIR/no-such-dir/marker.json"
  withdraw_with x "$m" 'return 1'
  [ "$status" -eq 0 ]
  has "could not take back the incomplete-operation record"
  has "it may still be there"
  has "--update --recover abc"
  refute has "nothing was changed"
  has "ID=[abc]"
}

@test "pending_remove: removed, then the lock re-check fails: status 2 and the file is gone" {
  local m="$BATS_TEST_TMPDIR/marker.json"; : > "$m"
  run bash -c '. "$1/scripts/lib/install-op-lock.sh"
    n=0
    agmsg_install_op_require() { n=$((n + 1)); [ "$n" -lt 2 ]; }
    agmsg_install_op_pending_validate() { AGMSG_INSTALL_OP_PENDING_ID=abc; }
    agmsg_install_op_pending_remove "$2" abc' _ "$REPO_ROOT" "$m"
  [ "$status" -eq 2 ]
  [ ! -e "$m" ]
}

@test "pending_remove: a first lock check that fails removes nothing: status 1 and the file stays" {
  local m="$BATS_TEST_TMPDIR/marker.json"; : > "$m"
  run bash -c '. "$1/scripts/lib/install-op-lock.sh"
    agmsg_install_op_require() { return 1; }
    agmsg_install_op_pending_remove "$2" abc' _ "$REPO_ROOT" "$m"
  [ "$status" -eq 1 ]
  [ -f "$m" ]
}

# ensure_meta says "nothing was written" (status 3) only for an install.db that was
# there before the call, when its first statement failed on a busy or locked file.
ensure_meta_rc() {   # <sqlite3 status the first statement fails with> <db path>
  shim_fail_on sqlite3 '*CREATE\ TABLE\ IF\ NOT\ EXISTS\ meta*' "$1"
  PATH="$SHIMS:$PATH" run bash -c '. "$1/scripts/lib/install-db.sh"; agmsg_install_db_ensure_meta "$2"' _ "$REPO_ROOT" "$2"
}

@test "ensure_meta: an existing install.db whose first statement is busy (5) or locked (6) returns 3" {
  ensure_meta_rc 5 "$SK/run/install.db"
  [ "$status" -eq 3 ]
  ensure_meta_rc 6 "$SK/run/install.db"
  [ "$status" -eq 3 ]
}

@test "ensure_meta: a full disk (13) on an existing install.db returns 1, not 3" {
  ensure_meta_rc 13 "$SK/run/install.db"
  [ "$status" -eq 1 ]
}

@test "ensure_meta: busy on an install.db that was not there returns 1, not 3" {
  ensure_meta_rc 5 "$BATS_TEST_TMPDIR/fresh/install.db"
  [ "$status" -eq 1 ]
}

@test "a full disk on the first statement of an existing install.db: the update stops and the marker stays" {
  shim_fail_on sqlite3 '*CREATE\ TABLE\ IF\ NOT\ EXISTS\ meta*' 13
  update
  [ "$status" -eq 1 ]
  has "creating the meta table failed"
  refute has "nothing was changed"
  [ -f "$(marker)" ]
}
