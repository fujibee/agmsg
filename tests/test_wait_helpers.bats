#!/usr/bin/env bats
#
# The bounded condition waits in test_helper.bash decide whether many other
# tests' assertions mean anything. `wait_for_pid_exit` in particular is the
# evidence that a process was killed, so if it can report "gone" for a live
# process, every test that uses it becomes a green that proves nothing — which
# is exactly the failure that was found in the session-end test it replaced.

setup() { load 'test_helper'; }

@test "_pid_gone: reports a live process as alive" {
  sleep 5 &
  local p=$!
  run _pid_gone "$p"
  kill "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "_pid_gone: reports a pid that never existed as gone" {
  # Far above any live pid on the platforms this suite runs on.
  run _pid_gone 4194303
  [ "$status" -eq 0 ]
}

@test "_pid_gone: reports an exited child as gone, zombie or not" {
  sleep 0.1 &
  local p=$!
  wait "$p" 2>/dev/null || true
  run _pid_gone "$p"
  [ "$status" -eq 0 ]
}

@test "_pid_gone: a failed kill -0 that is not ESRCH counts as ALIVE" {
  # The EPERM case cannot be produced portably in-suite, so pin the decision
  # rule itself: anything other than "no such process" must not be read as
  # death. This is the branch that keeps a sandboxed, unsignalable-but-running
  # process from being reported as exited.
  local decided
  decided=$(
    kill() { echo "bash: kill: (1234) - Operation not permitted" >&2; return 1; }
    ps() { return 1; }   # even with no process-table evidence
    _pid_gone 1234 && echo GONE || echo ALIVE
  )
  [ "$decided" = "ALIVE" ]
}

@test "wait_for_pid_exit: returns promptly once the process is gone" {
  sleep 0.2 &
  local p=$!
  run wait_for_pid_exit "$p"
  [ "$status" -eq 0 ]
}

@test "wait_for_pid_exit: times out rather than claiming a live process exited" {
  sleep 30 &
  local p=$!
  # Shrink the budget so the negative case does not cost the full ceiling.
  _WAIT_TICKS=3 run wait_for_pid_exit "$p"
  kill "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  [ "$status" -ne 0 ]
}

@test "wait_for_file / wait_for_missing / wait_for_file_is agree with the filesystem" {
  local f="$BATS_TEST_TMPDIR/probe"
  run wait_for_file "$f"
  [ "$status" -ne 0 ] || false   # absent file must not be reported present

  echo "42" > "$f"
  run wait_for_file "$f"
  [ "$status" -eq 0 ]
  run wait_for_file_is "$f" "42"
  [ "$status" -eq 0 ]
  run wait_for_file_is "$f" "43"
  [ "$status" -ne 0 ]

  rm -f "$f"
  run wait_for_missing "$f"
  [ "$status" -eq 0 ]
}
