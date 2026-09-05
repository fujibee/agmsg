#!/usr/bin/env bats
#
# Controls for the teardown's failure reporter (#1036).
#
# The reporter only ever runs on a red that appears roughly once a day on one
# platform, so nothing else in the suite would notice it rotting. These pin the
# properties that make it worth having at all — including the arm that an
# earlier draft got wrong, where the removal deletes the pid file BEFORE it
# fails and a reporter that scanned afterwards had nothing left to say.

load test_helper

setup() {
  PROBE_DIR="$(mktemp -d)"
  unset AGMSG_TEARDOWN_WAITED_PIDS
}

teardown() {
  [ -n "${LIVE_PID:-}" ] && kill "$LIVE_PID" 2>/dev/null
  [ -d "${PROBE_DIR:-}/zlocked" ] && chmod 700 "$PROBE_DIR/zlocked" 2>/dev/null
  [ -n "${PROBE_DIR:-}" ] && rm -rf "$PROBE_DIR" 2>/dev/null
  return 0
}

# Build a directory whose `rm -rf` removes run/ (and the pid file in it) and
# THEN fails on an unwritable subdirectory. `zlocked` sorts after `run`, which is
# what puts the deletion first — the partial-delete arm.
_unremovable_with_pidfile() {   # <pid to record>
  mkdir -p "$PROBE_DIR/run" "$PROBE_DIR/zlocked"
  printf '%s\n' "$1" > "$PROBE_DIR/run/server.pid"
  : > "$PROBE_DIR/zlocked/inner"
  chmod 500 "$PROBE_DIR/zlocked"
}

@test "teardown forensics: a successful removal says nothing at all (#1036)" {
  export TEST_SKILL_DIR="$PROBE_DIR"
  mkdir -p "$TEST_SKILL_DIR/run"
  run teardown_test_env
  [ "$status" -eq 0 ]
  # Not "few bytes" — none. A probe that chatters on green trains people to
  # ignore it on red.
  [ -z "$output" ]
}

@test "teardown forensics: the rm deletes the pid file first, and the report still names it (#1036)" {
  sleep 30 & LIVE_PID=$!
  export TEST_SKILL_DIR="$PROBE_DIR"
  export AGMSG_TEARDOWN_WAITED_PIDS="$LIVE_PID"
  _unremovable_with_pidfile "$LIVE_PID"

  run teardown_test_env
  [ "$status" -ne 0 ]                              # the failure is not swallowed
  [ ! -f "$PROBE_DIR/run/server.pid" ]             # the arm under test: it is gone
  [[ "$output" == *"$LIVE_PID STILL ALIVE"* ]]     # …and the pid survived anyway
  [[ "$output" == *"SIGNALLED and WAITED FOR"* ]]
}

@test "teardown forensics: a pid file nobody waited on is NOT reported as waited (#1036)" {
  # Provenance: the generic pre-rm scan finds pid FILES. Reporting those under
  # the "signalled and waited for" heading would say something untrue about
  # them, which is the defect this file exists to keep out.
  export TEST_SKILL_DIR="$PROBE_DIR"
  _unremovable_with_pidfile 999001                 # written, never signalled

  run teardown_test_env
  [ "$status" -ne 0 ]
  local waited_block="${output#*SIGNALLED and WAITED FOR}"
  waited_block="${waited_block%%#####*}"
  [[ "$waited_block" != *999001* ]]
  [[ "$output" == *"NOT known to have been waited on"* ]]
  [[ "$output" == *999001* ]]
}

@test "teardown forensics: a pid is not reported twice when both sources carry it (#1036)" {
  export TEST_SKILL_DIR="$PROBE_DIR"
  export AGMSG_TEARDOWN_WAITED_PIDS="999002 999002"
  _unremovable_with_pidfile 999002

  run teardown_test_env
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^  999002 ')" -eq 1 ]
}

@test "teardown forensics: the probe does not change the caller's shell options (#1036)" {
  # Asked of a plain bash, not of this test body: bats manages `set -e` around
  # every command it runs, so a leak inside a @test is invisible — checked, and
  # the mutation that removes the subshell passes in here while leaking for real
  # outside. The property belongs to whatever sources the helper, so that is
  # what gets asked.
  _unremovable_with_pidfile 999003
  run bash -c '
    . "$1/test_helper.bash"
    export TEST_SKILL_DIR="$2"
    set -e
    teardown_test_env >/dev/null 2>&1 || true
    case "$-" in *e*) echo OPTIONS_INTACT ;; *) echo OPTIONS_LEAKED ;; esac
  ' _ "$BATS_TEST_DIRNAME" "$PROBE_DIR"
  [[ "$output" == *OPTIONS_INTACT* ]]
}
