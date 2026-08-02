#!/usr/bin/env bats

# Integration tests for the actas exclusivity lock wiring:
#   - actas-claim.sh
#   - reset.sh with session_id releases lock
#   - session-end.sh releases this session's locks
#   - session-start.sh GCs stale locks and dead logical mutex rows
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
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/subscription.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
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

reaped_pid() {
  local child
  sleep 0.01 3>&- & child=$!
  wait "$child"
  printf '%s\n' "$child"
}

# Run the SessionStart cleanup path with a registered identity and an alive
# current session.
run_session_start() {
  fake_register T alice
  echo "sid-current" > "$RUN_DIR/cc-instance.$$"
  printf '{"session_id":"sid-current"}' \
    | bash "$SKILL_DIR/scripts/session-start.sh" claude-code /tmp/p1 >/dev/null
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

@test "actas-claim: held result reports an exact retained pair when rollback infrastructure is unavailable" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_register T alice
  fake_register U alice
  fake_session "sid-owner" >/dev/null
  local first="$(actas_lock_path T alice)"
  local held="$(actas_lock_path U alice)"
  echo sid-owner > "$held"
  mkdir "$RUN_DIR/actas-reclaim.db"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-thief"

  [ "$status" -eq 1 ]
  [ "${lines[${#lines[@]}-1]}" = "status=held team=U owner=sid-owner rollback=incomplete locked=T/alice" ]
  [ "$(cat "$first")" = sid-thief ]
  [ "$(cat "$held")" = sid-owner ]
  [ ! -f "$(_agmsg_role_session_path T alice)" ]
  [ ! -f "$(_agmsg_role_session_path U alice)" ]
}

@test "actas-claim: status=not_registered when name is unknown" {
  fake_register T alice
  fake_session "sid-me" >/dev/null

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code unknown "sid-me"
  [ "$status" -eq 2 ]
  [[ "$output" =~ "status=not_registered" ]]
}

@test "actas-claim: legacy error rolls back prior teams and records no affinity" {
  fake_register T alice
  fake_register U alice
  fake_session "sid-me" >/dev/null
  local blocked="$(actas_lock_path U alice)"
  echo sid-ghost > "$blocked"
  mkdir "${blocked}.reclaim.d"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me"

  [ "$status" -eq 3 ]
  [[ "$output" =~ "status=error" ]]
  [[ "$output" =~ "team=U" ]]
  [[ "$output" =~ "reason=legacy-reclaim-marker" ]]
  [ ! -e "$(actas_lock_path T alice)" ]
  [ "$(cat "$blocked")" = sid-ghost ]
  [ ! -f "$(_agmsg_role_session_path T alice)" ]
  [ ! -f "$(_agmsg_role_session_path U alice)" ]
}

@test "actas-claim: SQLite-unavailable error is visible and a later retry recovers" {
  fake_register T alice
  fake_register U alice
  fake_session "sid-me" >/dev/null
  local first="$(actas_lock_path T alice)"
  local blocked="$(actas_lock_path U alice)"
  echo sid-ghost > "$blocked"
  mkdir "$RUN_DIR/actas-reclaim.db"

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me"
  [ "$status" -eq 3 ]
  [[ "$output" =~ "status=error" ]]
  [[ "$output" =~ "team=U" ]]
  [[ "$output" =~ "reason=reclaim-unavailable" ]]
  [[ "$output" =~ "rollback=incomplete" ]]
  [[ "$output" =~ "locked=T/alice" ]]
  [ ! -f "$(_agmsg_role_session_path T alice)" ]
  [ ! -f "$(_agmsg_role_session_path U alice)" ]
  [ "$(cat "$first")" = sid-me ]
  [ "$(cat "$blocked")" = sid-ghost ]

  rmdir "$RUN_DIR/actas-reclaim.db"
  run bash "$SKILL_DIR/scripts/actas-claim.sh" /tmp/p1 claude-code alice "sid-me"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "status=ok" ]]
  [ "$(actas_lock_owner T alice)" = sid-me ]
  [ "$(actas_lock_owner U alice)" = sid-me ]
}

@test "subscription: claim error aborts, rolls back, and emits no pairs" {
  fake_register T alice
  fake_register U alice
  local blocked="$(actas_lock_path U alice)"
  echo sid-ghost > "$blocked"
  mkdir "${blocked}.reclaim.d"

  run agmsg_subscription_pairs /tmp/p1 claude-code sid-me alice claim

  [ "$status" -eq 2 ]
  [[ "$output" =~ "actas claim failed for U/alice: legacy-reclaim-marker" ]]
  [[ "$output" != *$'T\talice'* ]]
  [ ! -e "$(actas_lock_path T alice)" ]
  [ "$(cat "$blocked")" = sid-ghost ]
}

@test "subscription: SQLite-unavailable rollback reports the exact retained pair" {
  fake_register T alice
  fake_register U alice
  local first="$(actas_lock_path T alice)"
  local blocked="$(actas_lock_path U alice)"
  echo sid-ghost > "$blocked"
  mkdir "$RUN_DIR/actas-reclaim.db"

  run agmsg_subscription_pairs /tmp/p1 claude-code sid-me alice claim

  [ "$status" -eq 2 ]
  [[ "$output" =~ "actas claim failed for U/alice: reclaim-unavailable" ]]
  [[ "$output" =~ "rollback=incomplete locked=T/alice" ]]
  [[ "$output" != *$'T\talice'* ]]
  [ "$(cat "$first")" = sid-me ]
  [ "$(cat "$blocked")" = sid-ghost ]
  [ ! -f "$(_agmsg_role_session_path T alice)" ]
  [ ! -f "$(_agmsg_role_session_path U alice)" ]
}

# --- reset.sh releases the lock when session_id is passed ---

@test "reset: with session_id, releases the lock for the dropped role" {
  fake_register T alice
  actas_lock_claim T alice "sid-me"
  [ -f "$(actas_lock_path T alice)" ]

  bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice "sid-me" >/dev/null

  [ ! -f "$(actas_lock_path T alice)" ]
}

@test "reset: exact-owner preserves a bare lock owner when this process derives a composite" {
  local lock="$(actas_lock_path T alice)"
  fake_register T alice
  printf 'bare-owner\n' > "$lock"

  # Without the internal exact-owner mode, reset would normalize bare-owner to
  # bare-owner.4242, drop the config, and leave this real raw owner behind.
  run env AGMSG_AGENT_PID=4242 bash "$SKILL_DIR/scripts/reset.sh" \
    /tmp/p1 claude-code alice bare-owner --exact-owner

  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
  run bash "$SKILL_DIR/scripts/identities.sh" /tmp/p1 claude-code
  [[ "$output" != *alice* ]]
}

@test "reset: rejects an unknown internal owner-mode argument" {
  fake_register T alice

  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me --not-owner-mode

  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage: reset.sh"* ]]
  [ -f "$SKILL_DIR/teams/T/config.json" ]
}

@test "reset: scoped machine retry releases an orphan lock after its team config is absent" {
  local lock="$(actas_lock_path T alice)"
  printf 'sid-me\n' > "$lock"

  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me --team T --machine

  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "status=ok team=T registration=absent release=proven" ]
  [ ! -e "$lock" ]
}

@test "reset: scoped machine mode touches only the exact target team" {
  local target_lock="$(actas_lock_path T alice)"
  local secondary_lock="$(actas_lock_path T2 alice)"
  fake_register T alice
  fake_register T2 alice
  actas_lock_claim T alice sid-me
  actas_lock_claim T2 alice sid-me

  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me --team T --machine

  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "status=ok team=T registration=removed release=proven" ]
  [ ! -e "$target_lock" ]
  [ ! -e "$SKILL_DIR/teams/T/config.json" ]
  [ -e "$secondary_lock" ]
  [ -e "$SKILL_DIR/teams/T2/config.json" ]
}

@test "reset: scoped machine reports a committed release when empty-team finalization fails" {
  local lock="$(actas_lock_path T alice)"
  local config="$SKILL_DIR/teams/T/config.json"
  local stub_bin="$BATS_TEST_TMPDIR/finalize-rm-bin"
  fake_register T alice
  actas_lock_claim T alice sid-me
  mkdir -p "$stub_bin"
  cat > "$stub_bin/rm" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" = "$AGMSG_TEST_FAIL_FINALIZE_PATH" ] && exit 1
done
exec /bin/rm "$@"
STUB
  chmod +x "$stub_bin/rm"

  run env PATH="$stub_bin:$PATH" AGMSG_TEST_FAIL_FINALIZE_PATH="$config" \
    bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me --team T --machine

  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "status=ok team=T registration=removed release=proven finalize=failed" ]
  [ ! -e "$lock" ]
  [ -e "$config" ]
  grep -Fq '"agents":{}' "$config"
}

@test "reset: legacy reclaim marker retains the last registration and lock for recovery" {
  local lock="$(actas_lock_path T alice)"
  fake_register T alice
  actas_lock_claim T alice sid-me
  mkdir "${lock}.reclaim.d"

  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me

  [ "$status" -ne 0 ]
  [[ "$output" == *"Reset incomplete: retained=T/alice"* ]]
  [[ "$output" != *"Reset complete"* ]]
  [ -f "$SKILL_DIR/teams/T/config.json" ]       # last-team config was restored
  [ "$(actas_lock_owner T alice)" = sid-me ]     # exact owner remains retryable
  run bash "$SKILL_DIR/scripts/identities.sh" /tmp/p1 claude-code
  [[ "$output" == *alice* ]]

  rmdir "${lock}.reclaim.d"
  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me
  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
  run bash "$SKILL_DIR/scripts/identities.sh" /tmp/p1 claude-code
  [[ "$output" != *alice* ]]
}

@test "reset: reclaim SQLite failure retains the last registration and recovers" {
  local lock="$(actas_lock_path T alice)"
  fake_register T alice
  actas_lock_claim T alice sid-me
  mkdir "$RUN_DIR/actas-reclaim.db"

  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me

  [ "$status" -ne 0 ]
  [[ "$output" == *"Reset incomplete: retained=T/alice"* ]]
  [[ "$output" != *"Reset complete"* ]]
  [ -f "$SKILL_DIR/teams/T/config.json" ]
  [ "$(actas_lock_owner T alice)" = sid-me ]
  run bash "$SKILL_DIR/scripts/identities.sh" /tmp/p1 claude-code
  [[ "$output" == *alice* ]]

  rmdir "$RUN_DIR/actas-reclaim.db"
  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me
  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
  run bash "$SKILL_DIR/scripts/identities.sh" /tmp/p1 claude-code
  [[ "$output" != *alice* ]]
}

@test "reset: partial multi-team release reports the exact retained pair and recovers" {
  local first_lock="$(actas_lock_path T1 alice)"
  local retained_lock="$(actas_lock_path T2 alice)"
  fake_register T1 alice
  fake_register T2 alice
  actas_lock_claim T1 alice sid-me
  actas_lock_claim T2 alice sid-me
  mkdir "${retained_lock}.reclaim.d"

  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me

  [ "$status" -ne 0 ]
  [[ "$output" == *"Reset incomplete: removed 1 registration(s) across 1 team(s)"* ]]
  [[ "$output" == *"Reset incomplete: retained=T2/alice"* ]]
  [ ! -e "$first_lock" ]
  [ ! -e "$SKILL_DIR/teams/T1/config.json" ]
  [ -f "$retained_lock" ]
  [ -f "$SKILL_DIR/teams/T2/config.json" ]
  run bash "$SKILL_DIR/scripts/identities.sh" /tmp/p1 claude-code
  [[ "$output" == *alice* ]]

  rmdir "${retained_lock}.reclaim.d"
  run bash "$SKILL_DIR/scripts/reset.sh" /tmp/p1 claude-code alice sid-me
  [ "$status" -eq 0 ]
  [ ! -e "$retained_lock" ]
  run bash "$SKILL_DIR/scripts/identities.sh" /tmp/p1 claude-code
  [[ "$output" != *alice* ]]
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
  local lock="$(actas_lock_path T alice)"
  echo "sid-ghost" > "$lock"

  run_session_start

  [ ! -f "$lock" ]
}

@test "session-start: never removes a markerless legacy reclaim directory" {
  local lock="$(actas_lock_path T alice)"
  local reclaim_dir="$(actas_lock_path T alice).reclaim.d"
  echo "sid-ghost" > "$lock"
  mkdir "$reclaim_dir"

  run run_session_start

  [ "$status" -eq 0 ]
  [[ "$output" =~ "legacy actas reclaim marker detected" ]]
  [[ "$output" =~ "$reclaim_dir" ]]
  [[ "$output" =~ "stop and restart every old agmsg mutator" ]]
  [[ "$output" =~ "Never delete reclaim markers based on age" ]]
  [ -d "$reclaim_dir" ]
  [ -f "$lock" ]
}

@test "session-start: diagnoses legacy markers before the no-identity short-circuit" {
  local reclaim_dir="$RUN_DIR/actas.T__alice.session.reclaim.d"
  mkdir "$reclaim_dir"

  run bash -c \
    'printf '\''{"session_id":"sid-current"}'\'' | bash "$1/scripts/session-start.sh" claude-code /tmp/no-identities' \
    _ "$SKILL_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "legacy actas reclaim marker detected: $reclaim_dir" ]]
  [ -d "$reclaim_dir" ]
}

@test "session-start: removes a readable zero-byte stale lock" {
  local lock="$(actas_lock_path T alice)"
  : > "$lock"

  run_session_start

  [ ! -e "$lock" ]
}

@test "session-start: removes a dead generation-qualified logical mutex row" {
  local dead_pid
  dead_pid="$(reaped_pid)"
  _actas_reclaim_mutex_schema
  _actas_reclaim_sqlite "
    INSERT INTO actas_reclaim_mutexes(lock_key, holder_pid, holder_generation)
    VALUES('dead-key', $dead_pid, 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
  " >/dev/null

  run_session_start

  run _actas_reclaim_sqlite \
    "SELECT count(*) FROM actas_reclaim_mutexes WHERE lock_key = 'dead-key';"
  [ "$status" -eq 0 ]
  [ "$output" = 0 ]
}

@test "session-start: preserves a paused live logical mutex holder" {
  _actas_reclaim_mutex_schema
  _actas_reclaim_sqlite "
    INSERT INTO actas_reclaim_mutexes(lock_key, holder_pid, holder_generation)
    VALUES('live-key', $$, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb');
  " >/dev/null

  run_session_start

  run _actas_reclaim_sqlite \
    "SELECT holder_pid || ':' || holder_generation FROM actas_reclaim_mutexes WHERE lock_key = 'live-key';"
  [ "$status" -eq 0 ]
  [ "$output" = "$$:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ]
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
    >/dev/null 2> "$BATS_TEST_TMPDIR/watch.err" 3>&- &
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
    >/dev/null 2> "$BATS_TEST_TMPDIR/watch.err" 3>&- &
  local wpid=$!
  sleep 1

  # Should now own the lock.
  [ "$(actas_lock_owner T alice)" = "sid-me" ]

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

@test "watch: claim error aborts and rolls back every pair" {
  fake_register T alice
  fake_register U alice
  local blocked="$(actas_lock_path U alice)"
  echo sid-ghost > "$blocked"
  mkdir "${blocked}.reclaim.d"

  run env AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" \
    "sid-me" /tmp/p1 claude-code alice

  [ "$status" -eq 2 ]
  [[ "$output" =~ "actas claim failed for U/alice: legacy-reclaim-marker" ]]
  [ ! -e "$(actas_lock_path T alice)" ]
  [ "$(cat "$blocked")" = sid-ghost ]
}

@test "watch: SQLite-unavailable rollback reports the exact retained pair" {
  fake_register T alice
  fake_register U alice
  local first="$(actas_lock_path T alice)"
  local blocked="$(actas_lock_path U alice)"
  echo sid-ghost > "$blocked"
  mkdir "$RUN_DIR/actas-reclaim.db"

  run env AGMSG_WATCH_INTERVAL=1 bash "$SKILL_DIR/scripts/watch.sh" \
    "sid-me" /tmp/p1 claude-code alice

  [ "$status" -eq 2 ]
  [[ "$output" =~ "actas claim failed for U/alice: reclaim-unavailable" ]]
  [[ "$output" =~ "rollback=incomplete locked=T/alice" ]]
  [ "$(cat "$first")" = sid-me ]
  [ "$(cat "$blocked")" = sid-ghost ]
  [ ! -f "$(_agmsg_role_session_path T alice)" ]
  [ ! -f "$(_agmsg_role_session_path U alice)" ]
}
