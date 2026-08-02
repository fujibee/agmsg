#!/usr/bin/env bats

# Tests for despawn (#109): a leader tears down a spawned member. Graceful path
# is watcher-driven (watch.sh sees ctrl:despawn, drops its own role); --force is
# leader-driven from the recorded placement.

load test_helper

setup() {
  setup_test_env
  # Never inherit a real herdr environment from the test runner. A watcher
  # started here that keeps the host's HERDR_PANE_ID will, on ctrl:despawn,
  # close the developer's own pane — the suite kills the session running it.
  # This belongs in setup, not on individual watch.sh launches: guarding each
  # launch site means every test added later has to remember, and one that
  # did not (the #439 read_at test, added after this file first grew herdr
  # awareness) is exactly how a real host pane got closed.
  unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID
  export PROJ="/tmp/agmsg-despawn-proj"
  export RUN="$TEST_SKILL_DIR/run"
  mkdir -p "$RUN"
  # Force despawn tests use synthetic %pane records. Keep every tmux lookup
  # hermetic so a local developer's default server can never receive a kill.
  local tmux_stub_dir="$TEST_SKILL_DIR/tmux-stub-bin"
  mkdir -p "$tmux_stub_dir"
  cat > "$tmux_stub_dir/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_CALL_LOG"
STUB
  chmod +x "$tmux_stub_dir/tmux"
  export TMUX_CALL_LOG="$TEST_SKILL_DIR/tmux-calls.log"
  export PATH="$tmux_stub_dir:$PATH"
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

@test "despawn: graceful — ctrl:despawn makes the member drop its role" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  # Make the member session look alive so the leader sees a live lock to wait on.
  setup_live_owner "$RUN" sess-m

  # Unset TMUX_PANE and HERDR_PANE_ID: the ctrl:despawn handler runs
  # `tmux kill-pane` / `herdr pane close`, and a watcher launched from inside
  # the developer's environment would inherit the REAL pane id and close the
  # session running the tests. With both empty, the handler takes the "close
  # manually" branch — role-drop is still asserted.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$! i
  track_test_child "$wpid"
  # Wait for the watcher to attach (it claims the lock + writes the ready sentinel).
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$RUN/ready.team__alice" ] && break; sleep 0.5; done
  [ -e "$RUN/ready.team__alice" ]
  [ -f "$RUN/actas.team__alice.session" ]

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]

  # Member dropped its role: lock released and registration gone.
  [ ! -f "$RUN/actas.team__alice.session" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]

  kill "$wpid" 2>/dev/null || true; wait_test_child "$wpid" 2>/dev/null || true
}

@test "despawn: graceful active-name teardown resets its frozen multiteam launch set and ignores a later join" {
  # `aux` sorts before `target`, so it is the non-target pair that must commit
  # first. `late` joins only after startup and must never enter this watcher's
  # frozen teardown set (#556).
  bash "$SCRIPTS/join.sh" aux alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target leader claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"
  setup_live_owner "$RUN" sess-multiteam

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-multiteam "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$!
  track_test_child "$wpid"
  wait_for_file "$RUN/ready.aux__alice"
  wait_for_file "$RUN/ready.target__alice"

  # This pair did not exist in PAIRS/TEARDOWN_PAIRS at watcher startup.
  bash "$SCRIPTS/join.sh" late alice claude-code "$PROJ" >/dev/null
  printf 'late-owner\n' > "$RUN/actas.late__alice.session"
  printf 'late-owner\n' > "$RUN/ready.late__alice"

  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]

  [ ! -e "$RUN/actas.aux__alice.session" ]
  [ ! -e "$RUN/actas.target__alice.session" ]
  wait_for_missing "$RUN/ready.aux__alice"
  wait_for_missing "$RUN/ready.target__alice"
  [ ! -e "$TEST_SKILL_DIR/teams/aux/config.json" ]
  ! grep -Fq '"alice"' "$TEST_SKILL_DIR/teams/target/config.json"
  grep -Fq '"leader"' "$TEST_SKILL_DIR/teams/target/config.json"
  [ ! -e "$RUN/spawn.target__alice" ]

  # The post-start join is outside the static subscription/teardown snapshot.
  [ -e "$TEST_SKILL_DIR/teams/late/config.json" ]
  grep -Fq '"alice"' "$TEST_SKILL_DIR/teams/late/config.json"
  [ "$(cat "$RUN/actas.late__alice.session")" = "late-owner" ]
  [ "$(cat "$RUN/ready.late__alice")" = "late-owner" ]
  wait_for_pid_exit "$wpid"
  wait_test_child "$wpid"
}

@test "despawn: watcher accepts a proven-release empty-team finalization warning for a non-target pair" {
  local aux_config="$TEST_SKILL_DIR/teams/aux/config.json"
  local stub_bin="$TEST_SKILL_DIR/finalize-warning-bin"
  bash "$SCRIPTS/join.sh" aux alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target leader claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/rm" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" = "$AGMSG_TEST_FAIL_FINALIZE_PATH" ] && exit 1
done
exec /bin/rm "$@"
STUB
  chmod +x "$stub_bin/rm"
  setup_live_owner "$RUN" sess-finalize-warning

  AGMSG_WATCH_INTERVAL=1 AGMSG_TEST_FAIL_FINALIZE_PATH="$aux_config" \
    env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV PATH="$stub_bin:$PATH" \
    bash "$SCRIPTS/watch.sh" sess-finalize-warning "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$!
  track_test_child "$wpid"
  wait_for_file "$RUN/ready.aux__alice"
  wait_for_file "$RUN/ready.target__alice"

  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 10
  [ "$status" -eq 0 ]
  [ -e "$aux_config" ]
  ! grep -Fq '"alice"' "$aux_config"
  [ ! -e "$RUN/actas.aux__alice.session" ]
  wait_for_missing "$RUN/ready.aux__alice"
  [ ! -e "$RUN/spawn.target__alice" ]
  wait_for_pid_exit "$wpid"
  wait_test_child "$wpid"
}

# read_at for the most recent message with the given body, empty if unread.
_read_at_for_body() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_sqlite "$(agmsg_db_path)" \
      "SELECT read_at FROM messages WHERE body='$1' ORDER BY id DESC LIMIT 1;" )
}

@test "despawn: graceful — ctrl:despawn control row is marked read (does not linger as unread)" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$! i
  track_test_child "$wpid"
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$RUN/ready.team__alice" ] && break; sleep 0.5; done
  [ -e "$RUN/ready.team__alice" ]

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]

  # The ctrl:despawn row itself must not be left permanently unread — a
  # broad (non-actas) watcher that later scans this project's inbox must not
  # see it resurface as a "new" message (2026-07-19 review finding).
  [ -n "$(_read_at_for_body "ctrl:despawn")" ]

  kill "$wpid" 2>/dev/null || true; wait_test_child "$wpid" 2>/dev/null || true
}

@test "despawn --force: kills recorded placement and drops registration without the member" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # Placement as spawn would have recorded it (pane %99 doesn't exist; kill is
  # best-effort/no-op here — we assert the registration + lock + record effects).
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'bare-owner\n' > "$RUN/actas.team__alice.session"

  # The leader can resolve a different composite instance id than this old bare
  # record. Force must pass the raw owner into reset's internal exact-owner
  # mode, not normalize it and leave the lock behind.
  run env AGMSG_AGENT_PID=4242 bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__alice" ]                 # placement record cleaned
  [ ! -f "$RUN/actas.team__alice.session" ]         # lock released
  grep -Fq 'kill-pane -t %99' "$TMUX_CALL_LOG"       # synthetic placement only
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]                        # registration dropped
}

@test "despawn --force: refuses a valid multiteam same-name spawn before provider or registration mutation" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" secondary alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'secondary-owner\n' > "$RUN/actas.secondary__alice.session"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force

  [ "$status" -ne 0 ]
  [[ "$output" == *"reason=multiple-registrations"* ]]
  [[ "$output" == *"remaining=secondary/alice"* ]]
  [ -e "$RUN/spawn.team__alice" ]
  [ -e "$TEST_SKILL_DIR/teams/team/config.json" ]
  [ -e "$TEST_SKILL_DIR/teams/secondary/config.json" ]
  grep -Fq '"alice"' "$TEST_SKILL_DIR/teams/secondary/config.json"
  [ "$(cat "$RUN/actas.secondary__alice.session")" = "secondary-owner" ]
  [ ! -e "$TMUX_CALL_LOG" ]
}

@test "despawn --force: a no-lock retry accepts only the exact target's no-release result" {
  # The target lock was already removed by a prior attempt. The scoped machine
  # reset may legitimately emit `release=not-requested`, followed by force's
  # lock-absent postcheck; it must not touch other (differently named) roles.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" secondary bob claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force

  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -e "$RUN/spawn.team__alice" ]
  [ ! -e "$TEST_SKILL_DIR/teams/team/config.json" ]
  [ -e "$TEST_SKILL_DIR/teams/secondary/config.json" ]
  grep -Fq '"bob"' "$TEST_SKILL_DIR/teams/secondary/config.json"
}

@test "despawn --force: retains spawn, registration, and lock on reset release failure then recovers" {
  local lock="$RUN/actas.team__alice.session"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$lock"
  mkdir "${lock}.reclaim.d"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force

  [ "$status" -ne 0 ]
  [[ "$output" == *"status=error"* ]]
  [[ "$output" == *"reason=reset-failed"* ]]
  [[ "$output" == *"locked=team/alice"* ]]
  [[ "$output" != *"status=forced"* ]]
  [ -f "$RUN/spawn.team__alice" ]
  [ -f "$lock" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" == *alice* ]]

  rmdir "${lock}.reclaim.d"
  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -e "$RUN/spawn.team__alice" ]
  [ ! -e "$lock" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]
}

@test "despawn --force: errors when there is no placement record" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no placement record" ]]
}

@test "despawn: times out (exit 3) when the member never drops" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m
  printf 'sess-m\n' > "$RUN/actas.team__alice.session"   # held live, no watcher to act

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
}

@test "despawn: graceful reset failure keeps watcher alive for a retry" {
  local lock="$RUN/actas.team__alice.session"
  local errlog="$BATS_TEST_TMPDIR/despawn-reset-failure.err"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>"$errlog" 3>&- &
  local wpid=$!
  track_test_child "$wpid"
  wait_for_file "$RUN/ready.team__alice"
  [ -f "$lock" ]
  mkdir "${lock}.reclaim.d"

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
  [ -f "$lock" ]
  kill -0 "$wpid" 2>/dev/null
  wait_for_file_contains "$errlog" "despawn reset failed"
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" == *alice* ]]

  rmdir "${lock}.reclaim.d"
  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]
  [ ! -e "$lock" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]

  kill "$wpid" 2>/dev/null || true; wait_test_child "$wpid" 2>/dev/null || true
}

@test "despawn: a failed non-target reset retains target state and succeeds on leader retry" {
  local aux_lock="$RUN/actas.aux__alice.session"
  local target_lock="$RUN/actas.target__alice.session"
  local errlog="$BATS_TEST_TMPDIR/non-target-reset-failure.err"
  bash "$SCRIPTS/join.sh" aux alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target leader claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"
  setup_live_owner "$RUN" sess-non-target-failure

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-non-target-failure "$PROJ" claude-code alice \
    >/dev/null 2>"$errlog" 3>&- &
  local wpid=$!
  track_test_child "$wpid"
  wait_for_file "$RUN/ready.aux__alice"
  wait_for_file "$RUN/ready.target__alice"
  mkdir "${aux_lock}.reclaim.d"

  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
  [ -f "$aux_lock" ]
  [ -f "$target_lock" ]
  [ -e "$TEST_SKILL_DIR/teams/aux/config.json" ]
  [ -e "$TEST_SKILL_DIR/teams/target/config.json" ]
  [ -f "$RUN/ready.aux__alice" ]
  [ -f "$RUN/ready.target__alice" ]
  [ -f "$RUN/spawn.target__alice" ]
  kill -0 "$wpid" 2>/dev/null
  wait_for_file_contains "$errlog" "despawn reset failed for 'aux/alice'"

  rmdir "${aux_lock}.reclaim.d"
  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 10
  [ "$status" -eq 0 ]
  [ ! -e "$aux_lock" ]
  [ ! -e "$target_lock" ]
  [ ! -e "$RUN/spawn.target__alice" ]
  wait_for_pid_exit "$wpid"
  wait_test_child "$wpid"
}

@test "despawn: a committed non-target ready cleanup failure keeps target retryable" {
  local aux_ready="$RUN/ready.aux__alice"
  local target_lock="$RUN/actas.target__alice.session"
  local errlog="$BATS_TEST_TMPDIR/non-target-ready-retry.err"
  local stub_bin="$TEST_SKILL_DIR/ready-retry-bin"
  bash "$SCRIPTS/join.sh" aux alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target leader claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/rm" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$AGMSG_TEST_BLOCK_READY_PATH" ] \
    && [ -d "${AGMSG_TEST_BLOCK_READY_PATH}.block.d" ]; then
    exit 1
  fi
done
exec /bin/rm "$@"
STUB
  chmod +x "$stub_bin/rm"
  setup_live_owner "$RUN" sess-ready-retry

  AGMSG_WATCH_INTERVAL=1 AGMSG_TEST_BLOCK_READY_PATH="$aux_ready" \
    env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV PATH="$stub_bin:$PATH" \
    bash "$SCRIPTS/watch.sh" sess-ready-retry "$PROJ" claude-code alice \
    >/dev/null 2>"$errlog" 3>&- &
  local wpid=$!
  track_test_child "$wpid"
  wait_for_file "$aux_ready"
  wait_for_file "$RUN/ready.target__alice"
  mkdir "${aux_ready}.block.d"

  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 2
  [ "$status" -eq 3 ]
  # The leader's timeout can precede the watcher's in-flight scoped reset by
  # a poll tick; wait for the committed non-target state instead of racing it.
  wait_for_missing "$TEST_SKILL_DIR/teams/aux/config.json"
  wait_for_missing "$RUN/actas.aux__alice.session"
  [ -f "$aux_ready" ]
  [ -f "$target_lock" ]
  [ -e "$TEST_SKILL_DIR/teams/target/config.json" ]
  [ -f "$RUN/ready.target__alice" ]
  [ -f "$RUN/spawn.target__alice" ]
  kill -0 "$wpid" 2>/dev/null
  wait_for_file_contains "$errlog" "retaining watcher for ctrl:despawn retry"

  rmdir "${aux_ready}.block.d"
  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 10
  [ "$status" -eq 0 ]
  wait_for_missing "$aux_ready"
  [ ! -e "$RUN/spawn.target__alice" ]
  wait_for_pid_exit "$wpid"
  wait_test_child "$wpid"
}

@test "despawn: a committed non-target reset drops stale batch rows before target retry" {
  local target_lock="$RUN/actas.target__alice.session"
  local out="$BATS_TEST_TMPDIR/partial-target-failure.out"
  local db="$TEST_SKILL_DIR/db/messages.db"
  bash "$SCRIPTS/join.sh" aux alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" target leader claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"
  setup_live_owner "$RUN" sess-partial-target

  # The control/stale/sentinel rows are committed atomically, so whichever
  # future poll sees them gets one deterministic batch without a slow timer.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-partial-target "$PROJ" claude-code alice \
    >"$out" 2>&1 3>&- &
  local wpid=$!
  track_test_child "$wpid"
  wait_for_file "$RUN/ready.aux__alice"
  wait_for_file "$RUN/ready.target__alice"
  mkdir "${target_lock}.reclaim.d"

  sqlite3 "$db" "
    BEGIN;
    INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('target', 'leader', 'alice', 'ctrl:despawn');
    INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('aux', 'system', 'alice', 'released-pair-stale');
    INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('target', 'system', 'alice', 'target-sentinel-after-stale');
    COMMIT;
  "

  # Seeing the later target row proves this watcher restarted the query with
  # rebuilt WHERE_PAIRS; the earlier aux row must neither print nor mark read.
  wait_for_file_contains "$out" "target-sentinel-after-stale"
  ! grep -Fq "released-pair-stale" "$out"
  [ -z "$(_read_at_for_body "released-pair-stale")" ]
  [ ! -e "$RUN/actas.aux__alice.session" ]
  [ ! -e "$TEST_SKILL_DIR/teams/aux/config.json" ]
  wait_for_missing "$RUN/ready.aux__alice"
  [ -f "$target_lock" ]
  [ -e "$TEST_SKILL_DIR/teams/target/config.json" ]
  [ -f "$RUN/ready.target__alice" ]
  [ -f "$RUN/spawn.target__alice" ]
  kill -0 "$wpid" 2>/dev/null

  rmdir "${target_lock}.reclaim.d"
  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 10
  [ "$status" -eq 0 ]
  [ ! -e "$RUN/spawn.target__alice" ]
  wait_for_pid_exit "$wpid"
  wait_test_child "$wpid"
}

@test "despawn: a broad (non-actas) watcher ignores ctrl:despawn and does not self-destruct" {
  # Regression for the self-kill bug: a leader's default watcher subscribes to
  # EVERY project role. If it acted on a ctrl:despawn addressed to one of them,
  # it would run `tmux kill-pane -t $TMUX_PANE` against the leader's OWN pane and
  # take down the leader session. A broad watcher must skip the control message.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team boss claude-code "$PROJ" >/dev/null

  # Broad watcher (no actas arg) — subscribes to both alice and leader.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-broad "$PROJ" claude-code \
    >/dev/null 2>&1 3>&- &
  local wpid=$! i
  track_test_child "$wpid"
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$wpid" 2>/dev/null && break; sleep 0.5; done

  # Deliver a despawn aimed at alice straight into the stream.
  bash "$SCRIPTS/send.sh" team boss alice "ctrl:despawn" >/dev/null
  sleep 2

  kill -0 "$wpid" 2>/dev/null            # watcher still alive — did NOT self-destruct
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" == *alice* ]]             # broad watcher did not drop alice's role

  kill "$wpid" 2>/dev/null || true; wait_test_child "$wpid" 2>/dev/null || true
}

@test "despawn: graceful no-op when the member holds no live lock (e.g. codex)" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  # No ready sentinel was ever created for this monitor-less launch. A valid
  # placement record must still use the ordinary no-live-lock completion path.
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  run bash "$SCRIPTS/despawn.sh" team leader alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-lock"* ]]
  [ ! -e "$RUN/spawn.team__alice" ]
}

@test "despawn: an early-free target with a captured ready sentinel keeps its spawn record until readiness clears" {
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"
  printf 'old-ready-owner\n' > "$RUN/ready.target__alice"

  # There is no target lock and no watcher to remove the stale sentinel. This
  # must not take the old no-live-lock success path or delete the only recovery
  # record merely because readiness is best-effort for other launches.
  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
  [ -f "$RUN/spawn.target__alice" ]
  [ "$(cat "$RUN/ready.target__alice")" = "old-ready-owner" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT count(*) FROM messages WHERE body='ctrl:despawn';")" = "1" ]
  [ -z "$(_read_at_for_body "ctrl:despawn")" ]
}

@test "despawn: a replacement ready sentinel is not completion for a captured early-free placement" {
  local despawn_out="$BATS_TEST_TMPDIR/replaced-ready.out"
  local dpid child_status=0 i control_rows=""
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"
  printf 'old-ready-owner\n' > "$RUN/ready.target__alice"

  bash "$SCRIPTS/despawn.sh" target leader alice --timeout 2 \
    >"$despawn_out" 2>&1 3>&- &
  dpid=$!
  track_test_child "$dpid"
  for i in $(seq 1 40); do
    control_rows="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT count(*) FROM messages WHERE body='ctrl:despawn';")"
    [ "$control_rows" = "1" ] && break
    sleep 0.05
  done
  [ "$control_rows" = "1" ]
  printf 'successor-ready-owner\n' > "$RUN/ready.target__alice"
  # Model a successor that reused both names after the control message.  A
  # different ready owner alone is not enough evidence to delete this record.
  printf '%s\t%s\t%s\n' '@777' "$PROJ" claude-code > "$RUN/spawn.target__alice"

  if wait_test_child "$dpid"; then
    child_status=0
  else
    child_status=$?
  fi
  [ "$child_status" -eq 3 ]
  grep -Fq 'status=timeout' "$despawn_out"
  [ -f "$RUN/spawn.target__alice" ]
  [ "$(cat "$RUN/spawn.target__alice")" = "$(printf '%s\t%s\t%s' '@777' "$PROJ" claude-code)" ]
  [ "$(cat "$RUN/ready.target__alice")" = "successor-ready-owner" ]
}

@test "despawn: early-free valid multiteam metadata preserves the sole spawn recovery record" {
  bash "$SCRIPTS/join.sh" target alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" aux alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.target__alice"

  run bash "$SCRIPTS/despawn.sh" target leader alice --timeout 2

  [ "$status" -ne 0 ]
  [[ "$output" == *"reason=multiple-registrations"* ]]
  [ -f "$RUN/spawn.target__alice" ]
  [ -e "$TEST_SKILL_DIR/teams/target/config.json" ]
  [ -e "$TEST_SKILL_DIR/teams/aux/config.json" ]
}

@test "despawn --force: rejects a no-release machine record when a target lock was initially present" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'force-owner\n' > "$RUN/actas.team__alice.session"
  cat > "$SCRIPTS/reset.sh" <<'STUB'
#!/usr/bin/env bash
printf 'status=ok team=team registration=removed release=not-requested\n'
STUB
  chmod +x "$SCRIPTS/reset.sh"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force

  [ "$status" -ne 0 ]
  [[ "$output" == *"reason=reset-failed"* ]]
  [ -f "$RUN/spawn.team__alice" ]
  [ -f "$RUN/actas.team__alice.session" ]
}

@test "despawn: watcher rejects a no-release machine record and remains retryable" {
  local errlog="$BATS_TEST_TMPDIR/watch-parser-negative.err"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  setup_live_owner "$RUN" sess-parser-negative

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-parser-negative "$PROJ" claude-code alice \
    >/dev/null 2>"$errlog" 3>&- &
  local wpid=$!
  track_test_child "$wpid"
  wait_for_file "$RUN/ready.team__alice"
  cat > "$SCRIPTS/reset.sh" <<'STUB'
#!/usr/bin/env bash
printf 'status=ok team=team registration=removed release=not-requested\n'
STUB
  chmod +x "$SCRIPTS/reset.sh"

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 2
  [ "$status" -eq 3 ]
  [ -f "$RUN/actas.team__alice.session" ]
  [ -f "$TEST_SKILL_DIR/teams/team/config.json" ]
  [ -f "$RUN/ready.team__alice" ]
  [ -f "$RUN/spawn.team__alice" ]
  kill -0 "$wpid" 2>/dev/null
  wait_for_file_contains "$errlog" "invalid target outcome"

  kill "$wpid" 2>/dev/null || true
  wait_test_child "$wpid" 2>/dev/null || true
}

@test "despawn --force: kills a herdr: placement via herdr pane close" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # Record a herdr-tagged placement (herdr: scheme prefix).
  printf 'herdr:wC:p99\t%s\tclaude-code\n' "$PROJ" > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"

  # Stub herdr so we can assert the pane close call without touching real herdr.
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
echo '{"id":"cli:pane:close","result":{"type":"ok"}}'
STUB
  chmod +x "$stub_bin/herdr"
  export HERDR_CALL_LOG="$TEST_SKILL_DIR/herdr-calls.log"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__alice" ]
  # herdr was called with "pane close wC:p99" (prefix stripped).
  grep -q "pane close wC:p99" "$HERDR_CALL_LOG"
}
