#!/usr/bin/env bats
# The helper's guard against a test changing the real state directory (the machine's
# $AGMSG_HOME or $HOME/.agmsg as seen when bats started), and its unset of AGMSG_HOME and
# AGMSG_INSTALL_HOME. Everything here runs against a base made under the test's own temp
# directory; nothing touches a real home.

load test_helper

setup() {
  GBASE="$BATS_TEST_TMPDIR/real-base"
  mkdir -p "$GBASE/agmsg/run"
  printf '%s\n' "/some/skill" > "$GBASE/agmsg/.owner"
  _AGMSG_GUARD_REAL_BASE="$GBASE"
}

@test "an untouched real state passes" {
  agmsg_guard_real_state_begin
  : > "$GBASE/agmsg/run/live-daemon-churn"
  agmsg_guard_real_state_end
}

@test "a changed owner fails" {
  agmsg_guard_real_state_begin
  printf '%s\n' "/tmp/tmp.X/.agents/skills/agmsg" > "$GBASE/agmsg/.owner"
  if agmsg_guard_real_state_end 2>/dev/null; then return 1; fi
}

@test "an install operation record appearing fails" {
  agmsg_guard_real_state_begin
  : > "$GBASE/agmsg/run/install-op-incomplete.json"
  if agmsg_guard_real_state_end 2>/dev/null; then return 1; fi
}

@test "a state directory appearing or disappearing fails" {
  agmsg_guard_real_state_begin
  mkdir -p "$GBASE/other"
  if agmsg_guard_real_state_end 2>/dev/null; then return 1; fi
  agmsg_guard_real_state_begin
  rmdir "$GBASE/other"
  command rm -r "$GBASE/agmsg"
  if agmsg_guard_real_state_end 2>/dev/null; then return 1; fi
}

@test "a base that does not exist passes while it stays absent and fails once it appears" {
  _AGMSG_GUARD_REAL_BASE="$BATS_TEST_TMPDIR/no-such-base"
  agmsg_guard_real_state_begin
  agmsg_guard_real_state_end
  mkdir -p "$_AGMSG_GUARD_REAL_BASE/agmsg"
  if agmsg_guard_real_state_end 2>/dev/null; then return 1; fi
}

@test "loading the helper clears AGMSG_HOME and AGMSG_INSTALL_HOME and keeps an ambient AGMSG_HOME as the guarded base" {
  run env AGMSG_HOME="$BATS_TEST_TMPDIR/ambient" AGMSG_INSTALL_HOME="$BATS_TEST_TMPDIR/inst" \
    _AGMSG_GUARD_REAL_BASE= \
    bash -c '. "$1"; printf "%s|%s|%s\n" "${AGMSG_HOME-unset}" "${AGMSG_INSTALL_HOME-unset}" "$_AGMSG_GUARD_REAL_BASE"' _ "$BATS_TEST_DIRNAME/test_helper.bash"
  [ "$status" -eq 0 ]
  [ "$output" = "unset|unset|$BATS_TEST_TMPDIR/ambient" ]
}
