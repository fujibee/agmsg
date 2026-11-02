#!/usr/bin/env bats
# agmsg_stop_pid (test_helper.bash): bounded stop of a test's own background job.
# Called directly, not through `run`: `run` is a subshell, which has no jobs.

load test_helper

@test "agmsg_stop_pid: stops this shell's own job, escalating to KILL when TERM is ignored" {
  local err="$BATS_TEST_TMPDIR/stop.err" p rc=0
  bash -c 'trap "" TERM; : > "$1"; while :; do sleep 0.1; done' _ "$BATS_TEST_TMPDIR/ready" 3>&- &
  p=$!
  wait_for_file "$BATS_TEST_TMPDIR/ready"   # TERM is ignored from here on
  agmsg_stop_pid "$p" 2>"$err" || rc=$?
  [ "$rc" -eq 0 ]
  grep -qF "sending KILL" "$err"
  ! kill -0 "$p" 2>/dev/null
}

@test "agmsg_stop_pid: sends no signal to a pid that is not a job of this shell" {
  local pf="$BATS_TEST_TMPDIR/foreign.pid" log="$BATS_TEST_TMPDIR/foreign.log"
  local err="$BATS_TEST_TMPDIR/stop.err" p rc=0
  # Started in a subshell, so it is not a job of this shell, the same as a pid
  # read from a pidfile. It records any TERM it receives.
  ( bash -c 'trap "echo got-term >> \"$1\"" TERM; : > "$2"; while :; do sleep 0.1; done' _ "$log" "$BATS_TEST_TMPDIR/ready" 3>&- &
    echo $! > "$pf" )
  p="$(cat "$pf")"
  wait_for_file "$BATS_TEST_TMPDIR/ready"
  kill -0 "$p"
  agmsg_stop_pid "$p" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  grep -qF "not a background job of this shell" "$err"
  sleep 0.3
  kill -0 "$p"
  [ ! -e "$log" ]
  # This test started it, so it stops it here.
  kill -9 "$p"
  wait_for_pid_exit "$p"
}

@test "agmsg_stop_pid: pids 0 and 1 and non-numbers are ignored" {
  local err="$BATS_TEST_TMPDIR/stop.err" a
  for a in 0 1 abc ''; do
    agmsg_stop_pid "$a" 2>"$err"
    [ ! -s "$err" ]
  done
}
