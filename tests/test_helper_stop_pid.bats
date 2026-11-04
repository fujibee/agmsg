#!/usr/bin/env bats
# agmsg_stop_pid (test_helper.bash): bounded stop of a test's own background job.
# Called directly, not through `run`: `run` is a subshell, which has no jobs.

load test_helper

# Every fixture process carries this marker as its $0 and is recorded in
# $FIXTURE_PIDS, so teardown can stop it even when an assertion failed first,
# and stops only a recorded pid whose argv still carries the marker.
setup() {
  FIXTURE_MARK="agmsg-stop-pid-fixture.$$.$BATS_TEST_NUMBER"
  FIXTURE_PIDS="$BATS_TEST_TMPDIR/fixture.pids"
  : > "$FIXTURE_PIDS"
}

teardown() {
  local p failed=0
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    case "$(ps -ww -o args= -p "$p" 2>/dev/null || true)" in
      *"$FIXTURE_MARK"*)
        kill -9 "$p" 2>/dev/null || true
        if ! wait_for_pid_exit "$p"; then
          echo "teardown: fixture pid $p still running" >&2
          failed=1
        fi
        ;;
    esac
  done < "$FIXTURE_PIDS"
  return "$failed"
}

@test "agmsg_stop_pid: stops this shell's own job, escalating to KILL when TERM is ignored" {
  local err="$BATS_TEST_TMPDIR/stop.err" p rc=0
  bash -c 'trap "" TERM; : > "$1"; while :; do sleep 0.1; done' "$FIXTURE_MARK" "$BATS_TEST_TMPDIR/ready" 3>&- &
  p=$!
  echo "$p" >> "$FIXTURE_PIDS"
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
  ( bash -c 'trap "echo got-term >> \"$1\"" TERM; : > "$2"; while :; do sleep 0.1; done' "$FIXTURE_MARK" "$log" "$BATS_TEST_TMPDIR/ready" 3>&- &
    echo $! > "$pf" )
  p="$(cat "$pf")"
  echo "$p" >> "$FIXTURE_PIDS"
  wait_for_file "$BATS_TEST_TMPDIR/ready"
  agmsg_stop_pid "$p" 2>"$err" || rc=$?
  [ "$rc" -eq 1 ]
  grep -qF "not a background job of this shell" "$err"
  sleep 0.3
  kill -0 "$p"
  [ ! -e "$log" ]
}

@test "agmsg_stop_pid: pids 0 and 1 and non-numbers are ignored" {
  local err="$BATS_TEST_TMPDIR/stop.err" a
  for a in 0 1 abc ''; do
    agmsg_stop_pid "$a" 2>"$err"
    [ ! -s "$err" ]
  done
}
