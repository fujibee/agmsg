#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  ACTAS_TEST_CHILD_PIDS=""
}

track_test_child() {
  ACTAS_TEST_CHILD_PIDS="${ACTAS_TEST_CHILD_PIDS:+$ACTAS_TEST_CHILD_PIDS }$1"
}

untrack_test_child() {
  local target="$1" pid kept=""
  for pid in ${ACTAS_TEST_CHILD_PIDS:-}; do
    [ "$pid" = "$target" ] && continue
    kept="${kept:+$kept }$pid"
  done
  ACTAS_TEST_CHILD_PIDS="$kept"
}

wait_test_child() {
  local pid="$1" wait_status
  if wait "$pid"; then
    wait_status=0
  else
    wait_status=$?
  fi
  untrack_test_child "$pid"
  return "$wait_status"
}

wait_test_child_exit_with_deadline() {
  local pid="$1" i
  for i in $(seq 1 20); do
    # Let Bash reap any completed background child before trusting its PID.
    jobs >/dev/null 2>&1 || true
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.05
  done
  return 1
}

teardown() {
  local pid
  # Barrier tests deliberately pause helpers. If an assertion fails before the
  # release sentinel is written, stop only still-tracked children rather than
  # leaving a blocked test process behind for the next Bats case. Both phases
  # are bounded: a child that ignores TERM is escalated to KILL, and teardown
  # never waits forever for an uncooperative helper.
  for pid in ${ACTAS_TEST_CHILD_PIDS:-}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in ${ACTAS_TEST_CHILD_PIDS:-}; do
    if wait_test_child_exit_with_deadline "$pid"; then
      untrack_test_child "$pid"
    fi
  done
  for pid in ${ACTAS_TEST_CHILD_PIDS:-}; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in ${ACTAS_TEST_CHILD_PIDS:-}; do
    if wait_test_child_exit_with_deadline "$pid"; then
      untrack_test_child "$pid"
    fi
  done
  teardown_test_env
}

# Pretend a CC instance with the given pid is alive and owns the given sid.
fake_cc_instance() {
  local pid="$1" sid="$2"
  echo "$sid" > "$RUN_DIR/cc-instance.$pid"
}

# Use the test process's own PID for "live owner" scenarios. It's guaranteed
# alive for the duration of the test. Avoids subshell-vs-stdout hangs that
# bite when you try to spawn a separate long-lived background pid from
# inside command substitution.
live_pid() { echo "$$"; }

# Produce a PID with positive evidence that its process existed and was reaped.
# This avoids magic "probably dead" numbers that can collide with a real PID.
reaped_pid() {
  local child
  sleep 0.01 3>&- & child=$!
  wait "$child"
  printf '%s\n' "$child"
}

# --- path encoding ---

@test "actas_lock_path: percent-encodes special bytes in team/agent" {
  local p
  p=$(actas_lock_path "team/foo" "ag ent")
  [[ "$p" == "$RUN_DIR/actas.team%2Ffoo__ag%20ent.session" ]]
}

@test "actas_lock_path: leaves safe chars alone" {
  local p
  p=$(actas_lock_path "team-A.1" "agent_B")
  [[ "$p" == "$RUN_DIR/actas.team-A.1__agent_B.session" ]]
}

# Regression for #65 review finding 2: the old underscore-replacement scheme
# made "foo bar" and "foo_bar" map to the same lock file. With percent
# encoding the two are unambiguous.
@test "actas_lock_path: names that collided under the old scheme are now distinct" {
  [ "$(actas_lock_path "foo bar" alice)" != "$(actas_lock_path "foo_bar" alice)" ]
  [ "$(actas_lock_path "a/b"   alice)" != "$(actas_lock_path "a_b"     alice)" ]
}

@test "actas_lock_path: encodes non-ASCII (UTF-8) bytes" {
  local p
  p=$(actas_lock_path "チーム" alice)
  # "チ" = E3 83 81, so the encoded prefix must contain that triple.
  [[ "$p" == *"%E3%83%81%E3%83%BC%E3%83%A0"* ]]
}

# --- registry publish / fixed-helper argument contracts ---

@test "registry atomic write: a partial printf failure leaves destination unchanged" {
  local dest="$BATS_TEST_TMPDIR/config.json"
  printf '%s\n' '{"old":true}' > "$dest"

  run bash -c '
    source "$1"
    printf() { command printf "%s" "partial"; return 1; }
    agmsg_write_atomic "$2" "{\"new\":true}"
  ' _ "$SKILL_DIR/scripts/lib/registry-lock.sh" "$dest"

  [ "$status" -eq 1 ]
  [ "$(cat "$dest")" = '{"old":true}' ]
  [ ! -e "$dest.tmp."* ]
}

@test "registry atomic write: a failed move leaves destination unchanged and cleans temp" {
  local dest="$BATS_TEST_TMPDIR/config.json"
  printf '%s\n' '{"old":true}' > "$dest"

  run bash -c '
    source "$1"
    mv() { return 1; }
    agmsg_write_atomic "$2" "{\"new\":true}"
  ' _ "$SKILL_DIR/scripts/lib/registry-lock.sh" "$dest"

  [ "$status" -eq 1 ]
  [ "$(cat "$dest")" = '{"old":true}' ]
  [ ! -e "$dest.tmp."* ]
}

@test "mutator: missing zero or one argument calls return contract status 2" {
  local helper="$SKILL_DIR/scripts/internal/actas-lock-mutate.sh"

  run bash "$helper"
  [ "$status" -eq 2 ]
  run bash "$helper" stale
  [ "$status" -eq 2 ]
}

# --- claim / state ---

@test "claim: succeeds when lock file absent" {
  run actas_lock_claim "T" "alice" "sid-1"
  [ "$status" -eq 0 ]
  [ "$(actas_lock_owner "T" "alice")" = "sid-1" ]
  [ "$(cat "$(actas_lock_path T alice)")" = "sid-1" ]
  [ ! -e "$RUN_DIR/actas-reclaim.db" ]
}

@test "claim: idempotent when caller already owns it" {
  actas_lock_claim "T" "alice" "sid-1"
  run actas_lock_claim "T" "alice" "sid-1"
  [ "$status" -eq 0 ]
}

@test "claim: refuses when held by a live other session" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-other"
  echo "sid-other" > "$(actas_lock_path "T" "alice")"

  run actas_lock_claim "T" "alice" "sid-mine"
  [ "$status" -eq 1 ]
  [[ "$output" == "held:sid-other" ]]
  [ "$(actas_lock_owner "T" "alice")" = "sid-other" ]
}

@test "claim: reclaims a stale lock whose owner is dead" {
  # Lock exists but no live cc-instance references that sid.
  echo "sid-dead" > "$(actas_lock_path "T" "alice")"

  run actas_lock_claim "T" "alice" "sid-mine"
  [ "$status" -eq 0 ]
  [ "$(actas_lock_owner "T" "alice")" = "sid-mine" ]
}

@test "claim: a readable zero-byte record is stale and reclaimable" {
  local lock="$(actas_lock_path T alice)"
  : > "$lock"

  run actas_lock_claim T alice sid-mine

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(cat "$lock")" = sid-mine ]
}

@test "claim: a failed temp record write is structured and never reaches ln" {
  local lock="$(actas_lock_path T alice)"
  _actas_lock_write_temp_record() { return 1; }

  run actas_lock_claim T alice sid-mine

  [ "$status" -eq 2 ]
  [ "$output" = "error:claim-io" ]
  [ ! -e "$lock" ]
  local temp
  for temp in "$RUN_DIR"/.actas-claim.*; do
    [ ! -e "$temp" ]
  done
}

@test "claim: an unreadable existing record is a structured I/O error" {
  local lock="$(actas_lock_path T alice)"
  local shim_dir="$BATS_TEST_TMPDIR/claim-head-shim"
  echo sid-owner > "$lock"
  mkdir "$shim_dir"
  cat > "$shim_dir/head" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$shim_dir/head"

  PATH="$shim_dir:$PATH" run actas_lock_claim T alice sid-mine

  [ "$status" -eq 2 ]
  [ "$output" = "error:lock-io" ]
  [ "$(cat "$lock")" = sid-owner ]
}

@test "claim: markerless legacy reclaim mutex fails closed" {
  local lock="$(actas_lock_path T alice)"
  echo sid-dead > "$lock"
  mkdir "${lock}.reclaim.d"

  run actas_lock_claim T alice sid-mine

  [ "$status" -eq 2 ]
  [ "$output" = "error:legacy-reclaim-marker" ]
  [ "$(cat "$lock")" = sid-dead ]
  [ -d "${lock}.reclaim.d" ]
}

@test "claim: transient SQLite unavailability is structured and recovery is healthy" {
  local lock="$(actas_lock_path T alice)"
  echo sid-dead > "$lock"
  mkdir "$RUN_DIR/actas-reclaim.db"

  run actas_lock_claim T alice sid-mine
  [ "$status" -eq 2 ]
  [ "$output" = "error:reclaim-unavailable" ]
  [ "$(cat "$lock")" = sid-dead ]

  rmdir "$RUN_DIR/actas-reclaim.db"
  run actas_lock_claim T alice sid-mine
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(cat "$lock")" = sid-mine ]
}

# Regression for #65 review finding 1: a naive stale clear reads-then-removes
# lock_path with no guard on the complete record. The fixed helper serializes
# destructors through a pid+generation SQLite row and re-checks after acquiring.
# Its final action is exec-rm, so the helper pid remains alive through unlink.
#
# bats can't truly interleave, so we exercise the invariant via two
# complementary cases:

# Case 1: serial — once a live owner claims, peer is refused (basic
# exclusivity sanity check).
@test "claim: a live owner is never replaced by a serial peer's claim" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  echo "sid-dead" > "$(actas_lock_path "T" "alice")"
  setup_live_owner "$RUN_DIR" "sid-A"
  actas_lock_claim "T" "alice" "sid-A"
  run actas_lock_claim "T" "alice" "sid-B"
  [ "$status" -eq 1 ]
  [[ "$output" == "held:sid-A" ]]
  [ "$(actas_lock_owner "T" "alice")" = "sid-A" ]
}

# Case 2 drives the exact stale-observation/path-replacement boundary directly:
# an exact delete carrying the previous record must preserve the successor.
@test "claim: a fresh live lock survives a concurrent claimer's stale reclaim attempt" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  local lock="$(actas_lock_path T alice)" stale_record
  echo sid-dead > "$lock"
  stale_record="$(head -1 "$lock")"
  command rm "$lock"
  setup_live_owner "$RUN_DIR" sid-A
  actas_lock_claim T alice sid-A

  run _actas_lock_delete_exact "$lock" "$stale_record"

  [ "$status" -eq 3 ]
  [ "$(actas_lock_owner "T" "alice")" = "sid-A" ]
}

@test "claim: a delayed stale contender preserves a live winner and returns held" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  local lock="$(actas_lock_path T alice)"
  local ready="$BATS_TEST_TMPDIR/claim-race-ready" go="$BATS_TEST_TMPDIR/claim-race-go"
  local winner_out="$BATS_TEST_TMPDIR/claim-race-winner.out"
  local loser_out="$BATS_TEST_TMPDIR/claim-race-loser.out"
  local winner_status="$BATS_TEST_TMPDIR/claim-race-winner.status"
  local loser_status="$BATS_TEST_TMPDIR/claim-race-loser.status"

  # Hold the first contender just before it enters the real stale mutator.
  # The second contender removes the stale path and claims it; when the first
  # finally enters the helper, it re-reads that live successor and returns 3.
  # The outer bounded retry must then return held by the winner, never an I/O
  # failure. The distinct absent-race status-7 mapping is tested directly next.
  echo sid-dead > "$lock"
  fake_cc_instance "$(live_pid)" sid-winner
  (
    _actas_lock_delete_stale() {
      : > "$ready"
      wait_for_file "$go" || exit 75
      bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" stale "$1"
    }
    if actas_lock_claim T alice sid-loser > "$loser_out"; then
      echo 0 > "$loser_status"
    else
      echo "$?" > "$loser_status"
    fi
  ) 3>&- &
  local loser_pid=$!
  track_test_child "$loser_pid"
  wait_for_file "$ready"

  (
    if actas_lock_claim T alice sid-winner > "$winner_out"; then
      echo 0 > "$winner_status"
    else
      echo "$?" > "$winner_status"
    fi
  ) 3>&- &
  local winner_pid=$!
  track_test_child "$winner_pid"
  wait_test_child "$winner_pid"
  : > "$go"
  wait_test_child "$loser_pid"

  [ "$(cat "$winner_status")" = 0 ]
  [ "$(cat "$winner_out")" = "" ]
  [ "$(cat "$loser_status")" = 1 ]
  [ "$(cat "$loser_out")" = "held:sid-winner" ]
  [[ "$(cat "$loser_out")" != *"error:lock-io"* ]]
  [ "$(actas_lock_owner T alice)" = sid-winner ]
}

@test "claim: an absent reclaim outcome retries and claims within the bounded loop" {
  local lock="$(actas_lock_path T alice)"
  echo sid-dead > "$lock"

  # Deterministic stand-in for the helper's status 7 contract: a peer removed
  # the stale pathname while this claimant was waiting for the reclaim mutex.
  # The following claim probe must retry its atomic link rather than turn this
  # normal race into error:lock-io.
  _actas_lock_delete_stale() {
    command rm "$1"
    return 7
  }

  run actas_lock_claim T alice sid-mine

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(actas_lock_owner T alice)" = sid-mine ]
}

# --- liveness ---

@test "sid_alive: empty sid is not alive" {
  run actas_lock_sid_alive ""
  [ "$status" -ne 0 ]
}

@test "sid_alive: pid alive + cc-instance content matches -> alive" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-A"
  run actas_lock_sid_alive "sid-A"
  [ "$status" -eq 0 ]
}

@test "sid_alive: pid dead -> not alive" {
  local dead_pid
  dead_pid="$(reaped_pid)"
  fake_cc_instance "$dead_pid" "sid-A"
  run actas_lock_sid_alive "sid-A"
  [ "$status" -ne 0 ]
}

# --- release / release_all ---

@test "release: removes a lock we own" {
  actas_lock_claim "T" "alice" "sid-mine"
  actas_lock_release "T" "alice" "sid-mine"
  [ ! -f "$(actas_lock_path "T" "alice")" ]
}

@test "release: leaves another session's lock alone" {
  fake_cc_instance "$(live_pid)" "sid-other"
  echo "sid-other" > "$(actas_lock_path "T" "alice")"
  actas_lock_release "T" "alice" "sid-mine"
  [ -f "$(actas_lock_path "T" "alice")" ]
}

@test "release_checked: reports retained ownership while SQLite is unavailable, then recovers" {
  local lock="$(actas_lock_path T alice)"
  actas_lock_claim T alice sid-mine
  mkdir "$RUN_DIR/actas-reclaim.db"

  run actas_lock_release_checked T alice sid-mine
  [ "$status" -eq 1 ]
  [ "$(cat "$lock")" = sid-mine ]

  rmdir "$RUN_DIR/actas-reclaim.db"
  run actas_lock_release_checked T alice sid-mine
  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
}

@test "rollback_pairs: prints only exact retained pairs with encoded labels" {
  local retained_lock="$(actas_lock_path "T one" "alice/x")"
  local peer_lock="$(actas_lock_path U bob)"
  actas_lock_claim "T one" "alice/x" sid-mine
  echo sid-other > "$peer_lock"
  mkdir "$RUN_DIR/actas-reclaim.db"

  run actas_lock_rollback_pairs $'T one\talice/x\nU\tbob\nV\tcarol' sid-mine

  [ "$status" -eq 1 ]
  [ "$output" = "T%20one/alice%2Fx" ]
  [ "$(cat "$retained_lock")" = sid-mine ]
  [ "$(cat "$peer_lock")" = sid-other ]
  [ ! -e "$(actas_lock_path V carol)" ]
}

@test "exact mutator: removes a present readable zero-byte record" {
  local lock="$(actas_lock_path T alice)"
  : > "$lock"

  run _actas_lock_delete_exact "$lock" ""

  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
}

@test "exact mutator: missing expected-record argument cannot authorize an empty delete" {
  local lock="$(actas_lock_path T alice)"
  : > "$lock"

  run bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" exact "$lock"

  [ "$status" -eq 2 ]
  [ -f "$lock" ]
}

@test "exact mutator: absent-after-mutex is retryable; unreadable stays fail closed" {
  local lock="$(actas_lock_path T alice)"
  local shim_dir="$BATS_TEST_TMPDIR/head-shim" real_head
  real_head="$(command -v head)"

  run _actas_lock_delete_exact "$lock" sid-owner
  [ "$status" -eq 7 ]

  echo sid-owner > "$lock"
  mkdir "$shim_dir"
  cat > "$shim_dir/head" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$shim_dir/head"
  PATH="$shim_dir:$PATH" run _actas_lock_delete_exact "$lock" sid-owner
  [ "$status" -eq 6 ]
  [ "$("$real_head" -1 "$lock")" = sid-owner ]
}

@test "release: a different-owner successor survives a barrier-delayed release" {
  local lock="$(actas_lock_path T alice)"
  local ready="$BATS_TEST_TMPDIR/release-ready" go="$BATS_TEST_TMPDIR/release-go"
  actas_lock_claim T alice sid-old

  (
    _actas_lock_delete_exact() {
      : > "$ready"
      wait_for_file "$go" || exit 75
      bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" exact "$1" "$2"
    }
    actas_lock_release T alice sid-old
  ) 3>&- &
  local release_pid=$!
  track_test_child "$release_pid"
  wait_for_file "$ready"

  command rm "$lock"
  actas_lock_claim T alice sid-new
  : > "$go"
  wait_test_child "$release_pid"

  [ "$(actas_lock_owner T alice)" = sid-new ]
}

@test "release_all: removes every lock owned by the sid, leaves others" {
  fake_cc_instance "$(live_pid)" "sid-keeper"
  actas_lock_claim "T1" "alice" "sid-going"
  actas_lock_claim "T2" "bob"   "sid-going"
  echo "sid-keeper" > "$(actas_lock_path "T3" "carol")"

  actas_lock_release_all "sid-going"

  [ ! -f "$(actas_lock_path "T1" "alice")" ]
  [ ! -f "$(actas_lock_path "T2" "bob")" ]
  [ -f   "$(actas_lock_path "T3" "carol")" ]
}

@test "release_all: an exact-record snapshot cannot delete a successor" {
  local target="$(actas_lock_path T1 alice)" other="$(actas_lock_path T2 bob)"
  local ready="$BATS_TEST_TMPDIR/all-ready" go="$BATS_TEST_TMPDIR/all-go" successor
  actas_lock_claim T1 alice sid-going
  actas_lock_claim T2 bob sid-going

  (
    _actas_lock_delete_exact() {
      if [ "$1" = "$target" ] && [ ! -f "$ready" ]; then
        : > "$ready"
        wait_for_file "$go" || exit 75
      fi
      bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" exact "$1" "$2"
    }
    actas_lock_release_all sid-going
  ) 3>&- &
  local release_pid=$!
  track_test_child "$release_pid"
  wait_for_file "$ready"

  command rm "$target"
  actas_lock_claim T1 alice sid-new
  successor="$(actas_lock_record T1 alice)"
  : > "$go"
  wait_test_child "$release_pid"

  [ "$(actas_lock_record T1 alice)" = "$successor" ]
  [ ! -f "$other" ]
}

# --- gc_stale ---

@test "gc_stale: removes locks whose owner is dead, returns count" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  echo "sid-dead-1" > "$(actas_lock_path "T1" "alice")"
  echo "sid-dead-2" > "$(actas_lock_path "T2" "bob")"
  fake_cc_instance "$(live_pid)" "sid-live"
  echo "sid-live" > "$(actas_lock_path "T3" "carol")"

  run actas_lock_gc_stale
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ ! -f "$(actas_lock_path "T1" "alice")" ]
  [ ! -f "$(actas_lock_path "T2" "bob")" ]
  [ -f   "$(actas_lock_path "T3" "carol")" ]
}

@test "gc_stale: noop when no stale locks" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-live"
  echo "sid-live" > "$(actas_lock_path "T" "alice")"

  run actas_lock_gc_stale
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [ -f "$(actas_lock_path "T" "alice")" ]
}

@test "gc_stale: counts exactly one removed zero-byte record" {
  local lock="$(actas_lock_path T alice)"
  : > "$lock"

  run actas_lock_gc_stale

  [ "$status" -eq 0 ]
  [ "$output" = 1 ]
  [ ! -e "$lock" ]
}

@test "gc_stale: fresh replacement survives delayed GC and is not counted" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  local lock="$(actas_lock_path T alice)"
  local ready="$BATS_TEST_TMPDIR/gc-ready" go="$BATS_TEST_TMPDIR/gc-go"
  local count_file="$BATS_TEST_TMPDIR/gc-count"
  echo sid-dead > "$lock"

  (
    _actas_lock_delete_stale() {
      : > "$ready"
      wait_for_file "$go" || exit 75
      bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" stale "$1"
    }
    actas_lock_gc_stale > "$count_file"
  ) 3>&- &
  local gc_pid=$!
  track_test_child "$gc_pid"
  wait_for_file "$ready"

  command rm "$lock"
  setup_live_owner "$RUN_DIR" sid-live
  actas_lock_claim T alice sid-live
  : > "$go"
  wait_test_child "$gc_pid"

  [ "$(cat "$count_file")" = 0 ]
  [ "$(actas_lock_owner T alice)" = sid-live ]
}

@test "mutex GC: two collectors cannot delete a replacement row from stale observation" {
  local ready="$BATS_TEST_TMPDIR/mutex-gc-ready" go="$BATS_TEST_TMPDIR/mutex-gc-go"
  local count_file="$BATS_TEST_TMPDIR/mutex-gc-count" dead_pid
  dead_pid="$(reaped_pid)"
  _actas_reclaim_mutex_schema
  _actas_reclaim_sqlite "
    INSERT INTO actas_reclaim_mutexes(lock_key, holder_pid, holder_generation)
    VALUES('reused-key', $dead_pid, 'cccccccccccccccccccccccccccccccc');
  " >/dev/null

  (
    _actas_reclaim_holder_alive() {
      : > "$ready"
      wait_for_file "$go" || exit 75
      return 1
    }
    actas_reclaim_mutex_gc > "$count_file"
  ) 3>&- &
  local first_gc=$!
  track_test_child "$first_gc"
  wait_for_file "$ready"

  [ "$(actas_reclaim_mutex_gc)" = 1 ]
  _actas_reclaim_sqlite "
    INSERT INTO actas_reclaim_mutexes(lock_key, holder_pid, holder_generation)
    VALUES('reused-key', $$, 'dddddddddddddddddddddddddddddddd');
  " >/dev/null
  : > "$go"
  wait_test_child "$first_gc"

  [ "$(cat "$count_file")" = 0 ]
  run _actas_reclaim_sqlite \
    "SELECT holder_pid || ':' || holder_generation FROM actas_reclaim_mutexes WHERE lock_key = 'reused-key';"
  [ "$status" -eq 0 ]
  [ "$output" = "$$:dddddddddddddddddddddddddddddddd" ]
}

@test "mutator: paused exec-rm holder is not stolen and parent-only SIGKILL leaves no orphan delete" {
  local lock="$(actas_lock_path T alice)" record
  local shim_dir="$BATS_TEST_TMPDIR/rm-shim" ready="$BATS_TEST_TMPDIR/rm-ready"
  local go="$BATS_TEST_TMPDIR/rm-go" real_rm helper
  helper="$SKILL_DIR/scripts/internal/actas-lock-mutate.sh"
  real_rm="$(command -v rm)"
  actas_lock_claim T alice sid-old
  record="$(actas_lock_record T alice)"
  mkdir "$shim_dir"
  cat > "$shim_dir/rm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$AGMSG_TEST_RM_READY"
i=0
while [ ! -f "$AGMSG_TEST_RM_GO" ]; do
  i=$((i + 1))
  [ "$i" -lt "${AGMSG_TEST_RM_WAIT_TICKS:-1000}" ] || exit 75
  sleep 0.01
done
exec "$AGMSG_TEST_REAL_RM" "$@"
SH
  chmod +x "$shim_dir/rm"

  PATH="$shim_dir:$PATH" \
    AGMSG_TEST_RM_READY="$ready" \
    AGMSG_TEST_RM_GO="$go" \
    AGMSG_TEST_REAL_RM="$real_rm" \
    bash "$helper" exact "$lock" "$record" 3>&- &
  local helper_pid=$!
  track_test_child "$helper_pid"
  wait_for_file "$ready"
  [ "$(cat "$ready")" = "$helper_pid" ]

  # A live, arbitrarily paused holder must not be timed out or stolen.
  run bash "$helper" exact "$lock" "$record"
  [ "$status" -eq 5 ]
  [ -f "$lock" ]

  # Kill only the process that began as Bash and is now the rm shim. Because
  # the destructive branch used exec, there is no child left to unlink later.
  kill -KILL "$helper_pid"
  wait_test_child "$helper_pid" 2>/dev/null || true
  [ -f "$lock" ]

  run bash "$helper" exact "$lock" "$record"
  [ "$status" -eq 0 ]
  [ ! -e "$lock" ]
}

@test "mutex: malformed holder tuple fails closed" {
  _actas_reclaim_mutex_schema
  _actas_reclaim_sqlite "
    INSERT INTO actas_reclaim_mutexes(lock_key, holder_pid, holder_generation)
    VALUES('malformed-key', 'not-a-pid', 'not-a-generation');
  " >/dev/null

  run actas_reclaim_mutex_acquire malformed-key "$$"

  [ "$status" -ne 0 ]
  run _actas_reclaim_sqlite \
    "SELECT holder_pid || ':' || holder_generation FROM actas_reclaim_mutexes WHERE lock_key = 'malformed-key';"
  [ "$output" = "not-a-pid:not-a-generation" ]
}

@test "mutator: refuses paths outside encoded actas lock scope" {
  local outside="$BATS_TEST_TMPDIR/outside"
  echo sid-owner > "$outside"

  run bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" exact "$outside" sid-owner

  [ "$status" -eq 2 ]
  [ "$(cat "$outside")" = sid-owner ]
}

@test "mutator: refuses lexical traversal and malformed encoded basenames" {
  local outside="$TEST_SKILL_DIR/outside.session"
  local traversal="$RUN_DIR/actas.guard/../../outside.session"
  local malformed="$RUN_DIR/actas.team%GG__alice.session"
  mkdir "$RUN_DIR/actas.guard"
  echo sid-owner > "$outside"
  echo sid-owner > "$malformed"

  run bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" exact "$traversal" sid-owner
  [ "$status" -eq 2 ]
  [ "$(cat "$outside")" = sid-owner ]

  run bash "$SKILL_DIR/scripts/internal/actas-lock-mutate.sh" exact "$malformed" sid-owner
  [ "$status" -eq 2 ]
  [ "$(cat "$malformed")" = sid-owner ]
}

@test "mutator: accepts a relative skill root and lock path" {
  local base="actas.T__relative.session"
  local parent root_name
  parent="$(dirname "$SKILL_DIR")"
  root_name="$(basename "$SKILL_DIR")"
  echo sid-owner > "$RUN_DIR/$base"

  run bash -c '
    cd "$1" || exit 9
    bash "$2/scripts/internal/actas-lock-mutate.sh" exact "$2/run/$3" sid-owner
  ' _ "$parent" "$root_name" "$base"

  [ "$status" -eq 0 ]
  [ ! -e "$RUN_DIR/$base" ]
}

@test "mutator: accepts a trailing-slash and non-normalized skill root" {
  local base="actas.T__trailing.session"
  local non_normal="$SKILL_DIR/scripts/../"
  echo sid-owner > "$RUN_DIR/$base"

  run bash "$non_normal/scripts/internal/actas-lock-mutate.sh" \
    exact "$non_normal/run/$base" sid-owner

  [ "$status" -eq 0 ]
  [ ! -e "$RUN_DIR/$base" ]
}

@test "mutator: accepts an absolute symlink spelling of the skill root" {
  skip_on_windows "symbolic-link creation requires Windows developer mode"
  local base="actas.T__symlink.session"
  local skill_link="$BATS_TEST_TMPDIR/skill-link"
  echo sid-owner > "$RUN_DIR/$base"
  ln -s "$SKILL_DIR" "$skill_link"

  run bash "$skill_link/scripts/internal/actas-lock-mutate.sh" \
    exact "$skill_link/run/$base" sid-owner

  [ "$status" -eq 0 ]
  [ ! -e "$RUN_DIR/$base" ]
}

@test "mutator: rechecks a legacy directory created while waiting for its mutex" {
  local lock="$(actas_lock_path T alice)" held_key record
  local helper="$SKILL_DIR/scripts/internal/actas-lock-mutate.sh"
  local shim_dir="$BATS_TEST_TMPDIR/sleep-shim" ready="$BATS_TEST_TMPDIR/sleep-ready"
  local real_sleep helper_pid helper_status=0
  real_sleep="$(command -v sleep)"
  actas_lock_claim T alice sid-old
  record="$(actas_lock_record T alice)"
  # The fixed helper canonicalizes the run directory with pwd -P before using
  # the pathname as its SQLite mutex key.  Match that physical spelling here:
  # macOS mktemp commonly returns /var/... while pwd -P returns /private/var/....
  held_key="$(cd -P "${lock%/*}" && pwd -P)/${lock##*/}"
  actas_reclaim_mutex_acquire "$held_key" "$$"

  mkdir "$shim_dir"
  cat > "$shim_dir/sleep" <<'SH'
#!/usr/bin/env bash
: > "$AGMSG_TEST_SLEEP_READY"
exec "$AGMSG_TEST_REAL_SLEEP" "$@"
SH
  chmod +x "$shim_dir/sleep"

  PATH="$shim_dir:$PATH" \
    AGMSG_TEST_SLEEP_READY="$ready" \
    AGMSG_TEST_REAL_SLEEP="$real_sleep" \
    bash "$helper" exact "$lock" "$record" 3>&- &
  helper_pid=$!
  track_test_child "$helper_pid"
  wait_for_file "$ready"

  mkdir "${lock}.reclaim.d"
  actas_reclaim_mutex_release
  wait_test_child "$helper_pid" || helper_status=$?

  [ "$helper_status" -eq 4 ]
  [ -f "$lock" ]
  [ -d "${lock}.reclaim.d" ]
  [ "$(_actas_reclaim_sqlite 'SELECT count(*) FROM actas_reclaim_mutexes;')" = 0 ]
}

@test "mutex: Git Bash holder liveness uses the MSYS pid namespace" {
  MSYSTEM=MSYS
  run _actas_reclaim_holder_alive "$$"
  unset MSYSTEM

  [ "$status" -eq 0 ]
}

@test "mutex DB: native sqlite path is cygpath-normalized on Git Bash" {
  cygpath() {
    [ "$1" = -m ] || return 1
    printf 'C:/agmsg/run/actas-reclaim.db\n'
  }

  run _actas_reclaim_db_path

  [ "$status" -eq 0 ]
  [ "$output" = 'C:/agmsg/run/actas-reclaim.db' ]
}

# --- state classification ---

@test "state: free when no lock exists" {
  run actas_lock_state "T" "alice" "sid-me"
  [ "$status" -eq 0 ]
  [ "$output" = "free" ]
}

@test "state: mine when caller owns the lock" {
  actas_lock_claim "T" "alice" "sid-me"
  run actas_lock_state "T" "alice" "sid-me"
  [ "$output" = "mine" ]
}

@test "state: other:<sid> when held by a live different session" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-other"
  echo "sid-other" > "$(actas_lock_path "T" "alice")"
  run actas_lock_state "T" "alice" "sid-me"
  [ "$output" = "other:sid-other" ]
}

@test "state: free when held by a dead session (stale)" {
  echo "sid-dead" > "$(actas_lock_path "T" "alice")"
  run actas_lock_state "T" "alice" "sid-me"
  [ "$output" = "free" ]
}
