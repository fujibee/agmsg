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
  [ -f "$TEST_SKILL_DIR/run/watch.sess-wm.watermark" ]
}

@test "session-end: removes the session watermark file" {
  local wm="$TEST_SKILL_DIR/run/watch.sess-end.watermark"
  mkdir -p "$TEST_SKILL_DIR/run"
  echo 5 > "$wm"
  printf '{"session_id":"sess-end"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  [ ! -f "$wm" ]
}
