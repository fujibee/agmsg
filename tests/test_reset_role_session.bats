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

@test "reset keeps the record while the SAME (team,agent) is still registered under another project (#1052)" {
  # The record is keyed on (team, agent) ALONE; project is a field inside it. A
  # peer registered under a different project shares this one file, so removing it
  # whenever any registration drops tears it out from under a live seat. Removal is
  # gated on REMAINING==0 -- the same count the config removal uses. Reverting to an
  # unconditional rm (dropping the REMAINING gate) turns this red.
  fake_register T alice /tmp/p1
  fake_register T alice /tmp/p2
  agmsg_role_session_record T alice sid-live /tmp/p2 claude-code
  [ -f "$(rs_path T alice)" ]

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-other >/dev/null

  run bash "$SKILL_DIR/scripts/whoami.sh" /tmp/p2 claude-code
  grep -q 'agent=alice' <<<"$output"                # control: p2's seat is still live
  [ -f "$(rs_path T alice)" ]                        # so its record must survive
}

@test "reset removes the record BEFORE releasing the actas lock, not after (#1052)" {
  # actas-claim acquires the lock THEN writes the record, so a peer that claims in
  # the window between our release and our rm would have its fresh record deleted.
  # Removal must precede the release. Seam: actas_lock_release stands in for a peer
  # that claims exactly at release time by writing its own record; if the rm ran
  # first the peer's record survives, if it ran after the peer's record is gone.
  # Swapping the two lines in reset.sh turns this red.
  cat >> "$SKILL_DIR/scripts/lib/actas-lock.sh" <<'SEAM'
actas_lock_release() {
  _agmsg_role_session_path_into "$1" "$2"
  printf 'session=PEER\n' > "$_AGMSG_ROLE_SESSION_PATH"
}
SEAM
  fake_register T alice /tmp/p1
  agmsg_role_session_record T alice sid-me /tmp/p1 claude-code

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me >/dev/null

  # The peer's record (written by the release seam) must survive -> rm ran first.
  [ -f "$(rs_path T alice)" ]
  grep -q '^session=PEER$' "$(rs_path T alice)"
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
