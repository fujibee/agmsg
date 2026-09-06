#!/usr/bin/env bats
#
# Controls for the teardown's failure reporter (#1036).
#
# The reporter only ever runs on a red that appears roughly once a day on one
# platform, so nothing else in the suite would notice it rotting. These pin the
# properties that make it worth having at all — including the arm an earlier
# draft got wrong, where the removal deletes the pid file BEFORE it fails and a
# reporter that scanned afterwards had nothing left to say.
#
# Every claim here is a plain command or a `[ ]`, never a non-last `[[ ]]`: on
# bash 3.2, which is what CI's macOS leg runs, a non-last `[[ ]]` reports `ok`
# with a false claim inside it (#670). A first draft of this file had three of
# them, and check-enforced-assertions.sh is what named them.

load test_helper

setup() {
  PROBE_DIR="$(mktemp -d)"
  unset AGMSG_TEARDOWN_WAITED_PIDS
}

teardown() {
  [ -n "${LIVE_PID:-}" ] && kill "$LIVE_PID" 2>/dev/null
  # `command`, because a test may have replaced `rm` with the seam below.
  [ -n "${PROBE_DIR:-}" ] && command rm -rf "$PROBE_DIR" 2>/dev/null
  return 0
}

# Says so, so a red names which claim fired rather than a bare line number.
_says() {          # <haystack> <needle>
  case "$1" in *"$2"*) return 0 ;; esac
  echo "expected the report to contain: $2" >&2
  return 1
}

# The removal fails, and the pid file is already gone when it does.
#
# A seam, not a filesystem trick. An earlier draft built an unwritable
# subdirectory sorting after `run/` and leaned on `rm` walking it in name order
# and on chmod 500 refusing the delete — two assumptions about the platform,
# neither of which is what this file is asking about. The question is what the
# reporter can still say after a partial delete, so the partial delete is
# stated outright.
_arm_partial_delete() {   # <pid to write into the pid file>
  mkdir -p "$PROBE_DIR/run"
  printf '%s\n' "$1" > "$PROBE_DIR/run/server.pid"
  rm() {
    if [ "${1:-}" = "-rf" ] && [ "${2:-}" = "$PROBE_DIR" ]; then
      command rm -f "$PROBE_DIR/run/server.pid"
      return 1
    fi
    command rm "$@"
  }
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
  _arm_partial_delete "$LIVE_PID"

  run teardown_test_env
  [ "$status" -ne 0 ]                          # the failure is not swallowed
  [ ! -f "$PROBE_DIR/run/server.pid" ]         # the arm under test: it is gone
  _says "$output" "$LIVE_PID STILL ALIVE"      # …and the pid survived anyway
  _says "$output" "CALLED kill AND wait ON"
}

@test "teardown forensics: a pid file nobody signalled is NOT reported as signalled (#1036)" {
  # Provenance: the generic pre-rm scan finds pid FILES. Reporting those in the
  # column for pids the teardown acted on would say something untrue about
  # them, which is the defect this file exists to keep out.
  export TEST_SKILL_DIR="$PROBE_DIR"
  _arm_partial_delete 999001                   # written, never signalled

  run teardown_test_env
  [ "$status" -ne 0 ]
  local acted_block="${output#*CALLED kill AND wait ON}"
  acted_block="${acted_block%%#####*}"
  refute _says "$acted_block" 999001
  _says "$output" "NOT known to have been signalled"
  _says "$output" 999001
}

@test "teardown forensics: a pid is not reported twice when both sources carry it (#1036)" {
  export TEST_SKILL_DIR="$PROBE_DIR"
  export AGMSG_TEARDOWN_WAITED_PIDS="999002 999002"
  _arm_partial_delete 999002

  run teardown_test_env
  [ "$status" -ne 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^  999002 ')" -eq 1 ]
}

@test "teardown forensics: the probe does not change the caller's shell options (#1036)" {
  # Asked of a plain bash, not of this test body: bats manages `set -e` around
  # every command it runs, so a leak inside a @test is invisible — measured,
  # and the mutation that removes the subshell passed in here while leaking for
  # real outside. The property belongs to whatever sources the helper, so that
  # is what gets asked.
  mkdir -p "$PROBE_DIR/run"
  printf '999003\n' > "$PROBE_DIR/run/server.pid"
  run bash -c '
    . "$1/test_helper.bash"
    export TEST_SKILL_DIR="$2"
    rm() { if [ "${1:-}" = "-rf" ]; then return 1; fi; command rm "$@"; }
    set -e
    teardown_test_env >/dev/null 2>&1 || true
    case "$-" in *e*) echo OPTIONS_INTACT ;; *) echo OPTIONS_LEAKED ;; esac
  ' _ "$BATS_TEST_DIRNAME" "$PROBE_DIR"
  [ "$status" -eq 0 ]
  _says "$output" OPTIONS_INTACT
}
