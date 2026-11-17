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

# The holder (a single sqlite3 that ends by itself) is this test's own child; wait
# for it rather than signal anything. Nothing is removed here: the runner removes
# BATS_TEST_TMPDIR.
teardown() {
  if [ -n "$HOLDER_PID" ]; then
    wait "$HOLDER_PID" 2>/dev/null || true
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

# Another sqlite3 takes install.db's write lock and holds it for <seconds>, then
# ends by itself (one process: BEGIN EXCLUSIVE, then a bounded sleep).
hold_install_db() {   # <seconds>
  # .timeout first: the readiness probe below writes too, and a holder that met it
  # mid-write without a wait would give up at once and never hold anything.
  sqlite3 "$SK/run/install.db" ".timeout 10000" "BEGIN EXCLUSIVE;" ".shell sleep $1" >/dev/null 2>&1 &
  HOLDER_PID=$!
  # Wait until the hold is real: a second writer must be refused.
  local i=0
  while sqlite3 "$SK/run/install.db" "CREATE TABLE IF NOT EXISTS probe_hold(x);" >/dev/null 2>&1; do
    sqlite3 "$SK/run/install.db" "DROP TABLE probe_hold;" >/dev/null 2>&1
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
  hold_install_db 6
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

@test "install.db held, the wait is bounded by AGMSG_INSTALL_DB_BUSY_MS: the update stops near it, not after the default" {
  hold_install_db 8
  export AGMSG_INSTALL_DB_BUSY_MS=500
  local t0=$SECONDS
  update
  [ "$status" -eq 1 ]
  has "creating the meta table failed"
  # The holder lets go after 8 s; stopping earlier than that is the bound at work.
  [ $((SECONDS - t0)) -lt 8 ]
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
