#!/usr/bin/env bats

# Integration tests for the actas exclusivity lock wiring:
#   - actas-claim.sh
#   - reset.sh with session_id releases lock
#   - session-end.sh releases this session's locks
#   - session-start.sh GCs stale locks
#   - watch.sh excludes pairs held by other live sessions
# Primitive-level coverage is in test_actas_lock.bats.

load test_helper

setup() {
  setup_test_env
  # Pin bare instance-id keying (#93): owner tokens / pidfiles stay keyed on the
  # raw session_id these tests pass, deterministic whether the suite runs under
  # an agent process (composite) or in CI (bare). The composite path has
  # dedicated coverage in test_instance_id.bats / test_watch.bats.
  export AGMSG_AGENT_PID=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # Source the lib so we can call its functions directly from the test body.
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
}

teardown() { teardown_test_env; }

# Helper: register a (team, agent) pair for the test project under claude-code.
fake_register() {
  local team="$1" agent="$2" proj="${3:-/tmp/p1}"
  bash "$SKILL_DIR/scripts/join.sh" "$team" "$agent" claude-code "$proj"
}

# Helper: fake that this test process owns a session_id (use our own pid for
# the cc-instance file so liveness checks pass).
fake_session() {
  local sid="$1"
  echo "$sid" > "$RUN_DIR/cc-instance.$$"
  printf '%s' "$sid"
}

# --- actas-claim.sh ---

@test "actas-claim: status=ok and claim recorded when role is free" {
  fake_register T alice
  fake_session "sid-me" >/dev/null

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=ok" ]]
  [[ "$output" =~ "team=T" ]]
  [ "$(actas_lock_owner T alice)" = "sid-me" ]
}

@test "actas-claim: status=held when role is held by another live session" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_register T alice
  fake_session "sid-owner" >/dev/null     # this test process is the "live owner"
  echo "sid-owner" > "$(actas_lock_path T alice)"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-thief"
  [ "$status" -eq 1 ]
  [[ "$output" =~ "status=held" ]]
  [[ "$output" =~ "team=T" ]]
  [[ "$output" =~ "owner=sid-owner" ]]
  [ "$(actas_lock_owner T alice)" = "sid-owner" ]   # not stolen
}

@test "actas-claim: status=not_registered when name is unknown" {
  fake_register T alice
  fake_session "sid-me" >/dev/null

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code unknown "sid-me"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=not_registered" ]]
}

# --- reset.sh releases the lock when session_id is passed ---

@test "reset: with session_id, releases the lock for the dropped role" {
  fake_register T alice
  actas_lock_claim T alice "sid-me"
  [ -f "$(actas_lock_path T alice)" ]

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice "sid-me" >/dev/null

  [ ! -f "$(actas_lock_path T alice)" ]
}

@test "reset: without session_id, does not touch lock (back-compat)" {
  fake_register T alice
  actas_lock_claim T alice "sid-me"

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice >/dev/null

  [ -f "$(actas_lock_path T alice)" ]
  [ "$(actas_lock_owner T alice)" = "sid-me" ]
}

# --- session-end.sh releases all locks owned by the exiting session ---

@test "session-end: releases all locks owned by the exiting session_id" {
  fake_register T alice
  fake_register T bob
  fake_register U alice /tmp/p2
  actas_lock_claim T alice "sid-going"
  actas_lock_claim T bob   "sid-going"
  fake_session "sid-keeper" >/dev/null
  echo "sid-keeper" > "$(actas_lock_path U alice)"

  printf '{"session_id":"sid-going"}' | bash "$SKILL_DIR/scripts/session-end.sh" claude-code /tmp/p1

  [ ! -f "$(actas_lock_path T alice)" ]
  [ ! -f "$(actas_lock_path T bob)" ]
  [ -f   "$(actas_lock_path U alice)" ]
}

# --- session-start.sh GCs stale locks ---

@test "session-start: GCs stale locks (owner sid no longer alive)" {
  # Stale lock — owner sid has no cc-instance.
  echo "sid-ghost" > "$(actas_lock_path T alice)"
  # Need an identity so session-start doesn't short-circuit.
  fake_register T alice
  echo "sid-current" > "$RUN_DIR/cc-instance.$$"

  printf '{"session_id":"sid-current"}' \
    | bash "$SKILL_DIR/scripts/session-start.sh" claude-code /tmp/p1 >/dev/null 2>&1 || true

  [ ! -f "$(actas_lock_path T alice)" ]
}

# --- watch.sh subscription exclusion ---
# Run watch.sh briefly and inspect its stderr for the exclusion message.

@test "watch: excludes pairs held by another live session (stderr message)" {
  skip_on_windows "actas watcher liveness under Git Bash (#182)"
  fake_register T alice
  fake_register T bob
  fake_session "sid-other" >/dev/null
  # Lock alice for sid-other (this test process pretends to be sid-other).
  echo "sid-other" > "$(actas_lock_path T alice)"

  # Run watch.sh in background with a tiny interval, capture stderr quickly.
  AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-mine" /tmp/p1 claude-code \
    >/dev/null 2> "$BATS_TEST_TMPDIR/watch.err" &
  local wpid=$!
  # Give it just enough time to resolve subscription and print stderr.
  sleep 1
  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true

  run cat "$BATS_TEST_TMPDIR/watch.err"
  [[ "$output" =~ "skipping pairs held by other sessions" ]]
  [[ "$output" =~ "T/alice" ]]
}

@test "watch: with active_name held by other session, exits with held error" {
  skip_on_windows "actas watcher liveness under Git Bash (#182)"
  fake_register T alice
  fake_session "sid-other" >/dev/null
  echo "sid-other" > "$(actas_lock_path T alice)"

  run env AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-mine" /tmp/p1 claude-code alice
  [ "$status" -eq 1 ]
  [[ "$output" =~ "cannot claim" ]]
  [[ "$output" =~ "T/alice" ]]
  # Lock was not stolen.
  [ "$(actas_lock_owner T alice)" = "sid-other" ]
}

@test "watch: with active_name on a free pair, claims and continues" {
  skip_on_windows "actas watcher process mgmt under Git Bash (#182)"
  fake_register T alice

  AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" "sid-me" /tmp/p1 claude-code alice \
    >/dev/null 2> "$BATS_TEST_TMPDIR/watch.err" &
  local wpid=$!
  sleep 1

  # Should now own the lock.
  [ "$(actas_lock_owner T alice)" = "sid-me" ]

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}
