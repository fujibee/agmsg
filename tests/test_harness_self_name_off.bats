#!/usr/bin/env bats

# #1095: the test harness must default every test to AGMSG_SELF_NAME=off, so a
# naming-capable script (join.sh here — the exact script observed doing this
# on a real machine) never touches the terminal it happens to be running in
# with a fixture team/agent, when that terminal is inherited from a real
# developer pane (bats runs inside whatever pane invoked it).
#
# The one-line default in test_helper.bash is not itself the protection --
# a later edit could delete that line silently and nothing would say so.
# THIS is the protection: this test deliberately does NOT set
# AGMSG_SELF_NAME itself anywhere. It relies entirely on the harness's
# default already being in place before its own setup() runs. If that
# default is ever removed, join.sh's self-naming hook reaches the fake
# terminal below, and this test goes red.

load test_helper

setup() {
  setup_test_env
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$FAKEBIN"
  : > "$ARGV_LOG"
  agmsg_install_fake_tmux
  # Simulate running INSIDE a real terminal -- the exact condition #1095 was
  # observed under. Deliberately NOT touching AGMSG_SELF_NAME here or
  # anywhere else in this file: proving the HARNESS keeps it off is the
  # entire point.
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%3"
}

teardown() { teardown_test_env; }

@test "harness default: join.sh under a real-looking terminal touches it NOT AT ALL (#1095)" {
  # A precondition the rest of this test depends on: confirm the harness
  # actually set it, so a failure below is never mistaken for something else.
  [ "${AGMSG_SELF_NAME:-}" = off ]
  run bash "$SCRIPTS/join.sh" fixtureteam alice claude-code /tmp/project-1095
  [ "$status" -eq 0 ]
  # The naming hook's own terminal call is what must never happen here --
  # not "the label came out right", which a fake could satisfy either way.
  # Any line in this log is tmux having been asked something.
  [ ! -s "$ARGV_LOG" ]
}
