#!/usr/bin/env bats

# Regression tests for the watch.sh per-session watermark (#107): a Monitor
# restart must deliver messages that arrived during the restart gap, without
# re-delivering anything already streamed, while a fresh session still starts
# from "now" rather than replaying history.

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watch-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

# Run watch.sh in the background for <secs> seconds, capturing stdout to <out>.
# Returns once the watcher has been stopped.
run_watcher_for() {
  local sid="$1" out="$2" secs="$3"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Compute the per-process instance id (#93) that watch.sh / session-end key on
# for <sid>, the same way the scripts do. Resolves to a composite "<sid>.<pid>"
# when an agent ancestor is present (e.g. running the suite under a Claude Code
# session) and to the bare sid otherwise (e.g. CI) — so filename/owner
# assertions hold in both environments instead of hardcoding the bare form.
_iid() {
  ( export SKILL_DIR="$TEST_SKILL_DIR"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/resolve-project.sh"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/instance-id.sh"
    agmsg_normalize_instance_id "$1" claude-code 2>/dev/null )
}

_max_message_id() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_sqlite "$(agmsg_db_path)" "SELECT COALESCE(MAX(id), 0) FROM messages;" )
}

_wait_for_file() {
  local file="$1" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && return 0
    sleep 0.1
  done
  return 1
}

_wait_for_missing() {
  local file="$1" i
  for i in $(seq 1 100); do
    [ ! -e "$file" ] && return 0
    sleep 0.1
  done
  return 1
}

_wait_for_file_contains() {
  local file="$1" needle="$2" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && grep -q "$needle" "$file" && return 0
    sleep 0.1
  done
  return 1
}

@test "watch: restart delivers messages that arrived while the watcher was down" {
  local sid="sess-restart"

  # First watcher: fresh session, takes its mark at MAX(id)=0, then streams M1.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out1.log" 2>/dev/null &
  local w1=$!
  sleep 1.5
  bash "$SCRIPTS/send.sh" team bob alice "M1-before-stop" >/dev/null
  sleep 2
  kill "$w1" 2>/dev/null || true
  wait "$w1" 2>/dev/null || true
  grep -q "M1-before-stop" "$TEST_SKILL_DIR/out1.log"

  # A message arrives while NO watcher is running for this session.
  bash "$SCRIPTS/send.sh" team bob alice "M2-in-gap" >/dev/null

  # Restart the SAME session_id — should resume from the persisted watermark.
  run_watcher_for "$sid" "$TEST_SKILL_DIR/out2.log" 2

  # In-gap message is delivered on restart...
  grep -q "M2-in-gap" "$TEST_SKILL_DIR/out2.log"
  # ...and the already-streamed message is NOT re-delivered.
  ! grep -q "M1-before-stop" "$TEST_SKILL_DIR/out2.log"
}

@test "watch: a fresh session starts from now and does not replay history" {
  # Pre-existing message before any watcher for this session ever runs.
  bash "$SCRIPTS/send.sh" team bob alice "M0-history" >/dev/null

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-fresh" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/fresh.log" 2>/dev/null &
  local w=$!
  sleep 1.5
  bash "$SCRIPTS/send.sh" team bob alice "M-live" >/dev/null
  sleep 2
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  # Live message after attach is delivered; pre-existing history is not replayed.
  grep -q "M-live" "$TEST_SKILL_DIR/fresh.log"
  ! grep -q "M0-history" "$TEST_SKILL_DIR/fresh.log"
}

@test "watch: persists a watermark file for the session" {
  run_watcher_for "sess-wm" "$TEST_SKILL_DIR/wm.log" 1.5
  [ -f "$TEST_SKILL_DIR/run/watch.$(_iid sess-wm).watermark" ]
}

@test "watch: closed consumer does not advance watermark past an undelivered row" {
  local sid="sess-consumer-close"
  local iid="$(_iid "$sid")"
  local wm="$TEST_SKILL_DIR/run/watch.$iid.watermark"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"
  local first_out="$TEST_SKILL_DIR/first-delivery.log"

  ( AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
      | head -n 1 > "$first_out" ) 2>/dev/null &
  local pipeline=$!

  _wait_for_file "$wm"
  [ -f "$pf" ]
  local w="$(cat "$pf")"

  bash "$SCRIPTS/send.sh" team bob alice "M1-before-consumer-close" >/dev/null
  local first_id="$(_max_message_id)"
  _wait_for_file_contains "$first_out" "M1-before-consumer-close"

  bash "$SCRIPTS/send.sh" team bob alice "M2-after-consumer-close" >/dev/null
  local second_id="$(_max_message_id)"
  _wait_for_missing "$pf" || {
    kill "$w" "$pipeline" 2>/dev/null || true
    wait "$pipeline" 2>/dev/null || true
    false
  }
  wait "$pipeline" 2>/dev/null || true

  [ "$first_id" != "$second_id" ]
  [ "$(cat "$wm")" = "$first_id" ]

  run_watcher_for "$sid" "$TEST_SKILL_DIR/redelivery.log" 2
  grep -q "M2-after-consumer-close" "$TEST_SKILL_DIR/redelivery.log"
  ! grep -q "M1-before-consumer-close" "$TEST_SKILL_DIR/redelivery.log"
}

@test "watch: closed stdout exits without advancing the watermark" {
  local sid="sess-stdout-closed"
  local iid="$(_iid "$sid")"
  local wm="$TEST_SKILL_DIR/run/watch.$iid.watermark"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    1>&- 2>/dev/null &
  local w=$!

  _wait_for_file "$wm"
  [ -f "$pf" ]
  local initial="$(cat "$wm")"

  bash "$SCRIPTS/send.sh" team bob alice "M-after-closed-stdout" >/dev/null

  _wait_for_missing "$pf" || {
    kill "$w" 2>/dev/null || true
    wait "$w" 2>/dev/null || true
    false
  }
  wait "$w" 2>/dev/null || true

  [ "$(cat "$wm")" = "$initial" ]

  run_watcher_for "$sid" "$TEST_SKILL_DIR/closed-redelivery.log" 2
  grep -q "M-after-closed-stdout" "$TEST_SKILL_DIR/closed-redelivery.log"
}

@test "session-end: removes the session watermark file" {
  # Key the watermark under the same instance id session-end will derive.
  local wm="$TEST_SKILL_DIR/run/watch.$(_iid sess-end).watermark"
  mkdir -p "$TEST_SKILL_DIR/run"
  echo 5 > "$wm"
  printf '{"session_id":"sess-end"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  [ ! -f "$wm" ]
}

@test "watch: actas-mode watcher creates a ready sentinel and removes it on exit" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-ready" "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
  local w=$!
  # Wait for the watcher to attach and signal readiness.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$ready" ] && break
    sleep 0.5
  done
  [ -e "$ready" ]
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  # Removed on exit (sentinel tracks a live watcher).
  [ ! -e "$ready" ]
}

@test "watch: a broad (non-actas) watcher does not create a ready sentinel" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  run_watcher_for "sess-broad" "$TEST_SKILL_DIR/broad.log" 1.5
  [ ! -e "$TEST_SKILL_DIR/run/ready.team__alice" ]
  [ ! -e "$TEST_SKILL_DIR/run/ready.team__bob" ]
}

@test "watch: ready sentinel records the owner session_id" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-own" "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
  local w=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$ready" ] && break; sleep 0.5; done
  # watch.sh stamps the instance id (composite under an agent ancestor).
  [ "$(cat "$ready")" = "$(_iid sess-own)" ]
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
}

@test "watch: cleanup leaves a sentinel that a successor session re-owned" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-old" "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
  local w=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$ready" ] && break; sleep 0.5; done
  # A successor watcher overwrites the sentinel with its own id.
  printf 'sess-new\n' > "$ready"
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  # The old watcher must NOT delete the successor's live sentinel.
  [ -f "$ready" ]
  [ "$(cat "$ready")" = "sess-new" ]
}

@test "session-start: GCs stale watermark/ready but keeps live ones" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  # Stale (owner has no live cc-instance).
  echo 5 > "$TEST_SKILL_DIR/run/watch.deadsid.watermark"
  echo deadsid > "$TEST_SKILL_DIR/run/ready.team__ghost"
  # Live owner.
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  echo 7 > "$TEST_SKILL_DIR/run/watch.LIVESID.watermark"
  echo LIVESID > "$TEST_SKILL_DIR/run/ready.team__live"

  printf '{"session_id":"somesess"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ ! -f "$TEST_SKILL_DIR/run/watch.deadsid.watermark" ]
  [ ! -f "$TEST_SKILL_DIR/run/ready.team__ghost" ]
  [ -f "$TEST_SKILL_DIR/run/watch.LIVESID.watermark" ]
  [ -f "$TEST_SKILL_DIR/run/ready.team__live" ]
}

# --- #93: parallel --continue/--resume sessions sharing a session_id ---

# Poll up to ~3s for <pidfile> to record <want_pid>.
_wait_pidfile() {
  local pf="$1" want="$2" i
  for i in $(seq 1 30); do
    [ -f "$pf" ] && [ "$(cat "$pf" 2>/dev/null)" = "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

@test "watch: two sessions sharing a session_id keep independent watchers (#93)" {
  # Pre-composite instance ids (same sid prefix, different agent pid) — what
  # session-start bakes into the directive for two parallel resume processes.
  local pf1="$TEST_SKILL_DIR/run/watch.shared.1001.pid"
  local pf2="$TEST_SKILL_DIR/run/watch.shared.1002.pid"

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "shared.1001" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
  local w1=$!
  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "shared.1002" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
  local w2=$!

  _wait_pidfile "$pf1" "$w1"
  _wait_pidfile "$pf2" "$w2"

  # Distinct pidfiles, and crucially neither watcher killed the other.
  run kill -0 "$w1"; [ "$status" -eq 0 ]
  run kill -0 "$w2"; [ "$status" -eq 0 ]
  [ "$(cat "$pf1")" = "$w1" ]
  [ "$(cat "$pf2")" = "$w2" ]

  kill "$w1" "$w2" 2>/dev/null || true
  wait "$w1" 2>/dev/null || true
  wait "$w2" 2>/dev/null || true
}

@test "watch: relaunch with the SAME instance id replaces the previous watcher (#66 preserved)" {
  local pf="$TEST_SKILL_DIR/run/watch.solo.2002.pid"

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "solo.2002" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
  local w1=$!
  _wait_pidfile "$pf" "$w1"

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "solo.2002" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
  local w2=$!
  # Successor claims the pidfile slot...
  _wait_pidfile "$pf" "$w2"
  # ...and the previous holder was killed.
  run kill -0 "$w1"; [ "$status" -ne 0 ]

  kill "$w2" 2>/dev/null || true
  wait "$w2" 2>/dev/null || true
}
