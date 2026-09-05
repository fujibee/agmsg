#!/usr/bin/env bats

# #1041: despawn left run/role-session.<team>__<member> behind on BOTH teardown
# paths (graceful and --force), because nothing removed it -- every other seat
# record had a removal site, this one had zero. Both paths converge on reset.sh
# (graceful: the member's watcher runs it with a session_id; --force: despawn.sh
# runs it with none), so reset.sh removes the record for the (team, agent) it is
# dropping, on either path.

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
}
teardown() { teardown_test_env; }

fake_register() { bash "$SKILL_DIR/scripts/join.sh" "$1" "$2" claude-code "${3:-/tmp/p1}"; }

# Path of the (team, agent) role-session record.
rs_path() { _agmsg_role_session_path_into "$1" "$2"; printf '%s' "$_AGMSG_ROLE_SESSION_PATH"; }

@test "reset (graceful, with session_id) removes the role-session record (#1041)" {
  fake_register T alice
  agmsg_role_session_record T alice sid-me /tmp/p1 claude-code
  [ -f "$(rs_path T alice)" ]                     # present before

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me >/dev/null

  [ ! -f "$(rs_path T alice)" ]                   # gone after
}

@test "reset (--force, no session_id) removes the role-session record (#1041)" {
  # The --force teardown calls reset.sh WITHOUT a session_id; the record must go
  # on this path too (the bug was present on both). Removal must not be gated on
  # session_id the way the lock release is.
  fake_register T alice
  agmsg_role_session_record T alice sid-me /tmp/p1 claude-code
  [ -f "$(rs_path T alice)" ]

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice >/dev/null

  [ ! -f "$(rs_path T alice)" ]
}

@test "reset removes only the dropped role's record, not a peer's (#1041)" {
  fake_register T alice
  fake_register T bob
  agmsg_role_session_record T alice sid-a /tmp/p1 claude-code
  agmsg_role_session_record T bob   sid-b /tmp/p1 claude-code

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-a >/dev/null

  [ ! -f "$(rs_path T alice)" ]
  [ -f "$(rs_path T bob)" ]                       # bob's seat untouched
}

@test "reset still drops the registration when it removes the record (positive control) (#1041)" {
  fake_register T alice
  agmsg_role_session_record T alice sid-me /tmp/p1 claude-code

  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me
  [ "$status" -eq 0 ]
  # the record removal did not replace the existing teardown: registration gone too
  run bash "$SKILL_DIR/scripts/whoami.sh" /tmp/p1 claude-code
  ! grep -q 'agent=alice' <<<"$output"
}
