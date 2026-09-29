#!/usr/bin/env bats

# The install/uninstall operation lock (agmsgd beta): a
# single sqlite3 coprocess bash keeps alive across a whole install.sh /
# uninstall.sh run, fed through a pair of named pipes so BEGIN EXCLUSIVE
# stays open while bash does its own work in between. This file also covers
# the case where only the sqlite3 lock-holding child dies while bash remains
# alive and unaware.

load test_helper

setup() {
  setup_test_env
  LOCKLIB="$SCRIPTS/lib/install-op-lock.sh"
  LOCK_DB="$BATS_TEST_TMPDIR/install-op.lock.db"
}

@test "install-op-lock: acquires, confirms, blocks a second acquirer, and releases cleanly" {
  run bash -c '
    source "$1"
    agmsg_install_op_lock "$2" 3000 || { echo "acquire failed"; exit 1; }
    agmsg_install_op_confirm || { echo "confirm failed while alive"; exit 1; }
    echo "held pid=$_AGMSG_LOCK_PID"

    # A second, independent process trying the SAME db must fail fast, not
    # hang for the full busy_timeout of its own accord succeeding.
    ( source "$1"
      if agmsg_install_op_lock "$2" 500; then
        echo "second UNEXPECTEDLY acquired"
        exit 1
      fi
      echo "second correctly failed to acquire"
    )

    agmsg_install_op_unlock

    # The lock DB is never deleted and must be reusable immediately after.
    agmsg_install_op_lock "$2" 3000 || { echo "re-acquire after unlock failed"; exit 1; }
    agmsg_install_op_unlock
    echo "re-acquire after unlock ok"
  ' _ "$LOCKLIB" "$LOCK_DB"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "held pid="
  printf '%s\n' "$output" | grep -qF "second correctly failed to acquire"
  printf '%s\n' "$output" | grep -qF "re-acquire after unlock ok"
}

@test "install-op-lock: detects when only the lock-holding sqlite3 child dies" {
  run bash -c '
    source "$1"
    agmsg_install_op_lock "$2" 3000 || { echo "acquire failed"; exit 1; }

    # Kill ONLY the sqlite3 coprocess -- this process (the "bash" role in
    # This process stays alive and unaware, as after a child-only crash
    # during an install operation.
    kill -9 "$_AGMSG_LOCK_PID"
    sleep 0.3

    if agmsg_install_op_confirm; then
      echo "confirm WRONGLY reported the lock still held"
      exit 1
    fi
    echo "confirm correctly detected the dead lock-holder"

    # The OS file lock must be genuinely gone -- a fresh, independent
    # acquirer (standing in for a retried operation) can now get it. This is
    # the property that makes "abort rather than continue unprotected" safe
    # to do here instead of trying to resurrect the same lock.
    ( source "$1"
      if ! agmsg_install_op_lock "$2" 3000; then
        echo "independent re-acquire after the child died UNEXPECTEDLY failed"
        exit 1
      fi
      agmsg_install_op_unlock
      echo "independent re-acquire after the child died ok"
    )
  ' _ "$LOCKLIB" "$LOCK_DB"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF "confirm correctly detected the dead lock-holder"
  printf '%s\n' "$output" | grep -qF "independent re-acquire after the child died ok"
}

@test "install-op-lock: unlock does not silently redirect the caller's stderr for the rest of the script" {
  # Regression test: `exec 9>&- 2>/dev/null` (no command -- redirections on
  # a bare `exec` apply to the CURRENT SHELL, not to that one statement)
  # silently sent every later stderr write in the calling script to
  # /dev/null for good, including a completely unrelated command's own
  # error message. Caught because install.sh's own Codex-shim ownership
  # refusal (written to stderr) stopped appearing in its output after any
  # lock/unlock cycle earlier in the same run.
  run bash -c '
    source "$1"
    agmsg_install_op_lock "$2" 3000 || { echo "acquire failed"; exit 1; }
    agmsg_install_op_unlock
    echo "stderr still works after unlock" >&2
  ' _ "$LOCKLIB" "$LOCK_DB"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stderr still works after unlock"* ]]
}

@test "install-op-lock: the lock DB never holds any tables of its own" {
  run bash -c '
    source "$1"
    agmsg_install_op_lock "$2" 3000 || { echo "acquire failed"; exit 1; }
    agmsg_install_op_unlock
  ' _ "$LOCKLIB" "$LOCK_DB"
  [ "$status" -eq 0 ]
  [ -f "$LOCK_DB" ]
  run sqlite3 "$LOCK_DB" "SELECT count(*) FROM sqlite_master WHERE type='table';"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}
