#!/usr/bin/env bats

# grok-session-start.sh / grok-stop.sh -- the agmsgd-mode hooks the
# grok-queue channel reads its own per-seat witness file from. Grok Build's
# SessionStart stdout is discarded (measured live, 2026-11-15), so these
# scripts emit nothing on that path; Stop still has to delegate to
# check-inbox.sh's own decision=block contract.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  TEST_PROJECT="$TEST_SKILL_DIR/proj"
  mkdir -p "$TEST_PROJECT"
}
teardown() { teardown_test_env; }

@test "grok-session-start.sh: writes a witness file for the project's single registered grok-build seat" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  run env GROK_SESSION_ID=sess1 GROK_LEADER_SOCKET=/tmp/l.sock bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # SessionStart's own stdout must be empty (discarded by grok)
  local f
  f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  [ -f "$f" ]
  grep -q '"session_id": "sess1"' "$f"
  grep -q '"leader_socket": "/tmp/l.sock"' "$f"
  grep -q '"first_turn_done": false' "$f"
}

@test "grok-session-start.sh: falls back to GROK_HOME/leader.sock when GROK_LEADER_SOCKET is unset" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  run env GROK_SESSION_ID=sess1 GROK_HOME="$TEST_SKILL_DIR/grokhome" bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q "\"leader_socket\": \"$TEST_SKILL_DIR/grokhome/leader.sock\"" "$f"
}

@test "grok-session-start.sh: no session id at all (neither env nor stdin) writes nothing" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  ! ls "$TEST_SKILL_DIR"/run/grok-seat.*.json >/dev/null 2>&1
}

@test "grok-session-start.sh: more than one grok-build seat for the project writes nothing (ambiguous, never guessed)" {
  bash "$SCRIPTS/join.sh" t1 g1 grok-build "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 g2 grok-build "$TEST_PROJECT" >/dev/null
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  ! ls "$TEST_SKILL_DIR"/run/grok-seat.*.json >/dev/null 2>&1
}

@test "grok-stop.sh: marks first_turn_done true on the matching session's witness, and still runs the inbox check" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"first_turn_done": false' "$f"
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"first_turn_done": true' "$f"
}

@test "grok-stop.sh: a Stop for a DIFFERENT (now-replaced) session_id leaves the witness's own session alone" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  run env GROK_SESSION_ID=sess-other bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"first_turn_done": false' "$f"
  grep -q '"session_id": "sess1"' "$f"
}

@test "grok-stop.sh: emits decision=block when the seat has unread messages (grok's own Stop contract)" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 sender claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/send.sh" t1 sender gagent "hello" >/dev/null
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision": "block"'
}

@test "grok-session-start.sh: a re-fire for the SAME session_id does not reset an already-advanced first_turn_done" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"first_turn_done": true' "$f"
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"first_turn_done": true' "$f"
}

@test "grok-session-start.sh: a NEW session_id (/clear or restart) resets first_turn_done" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"first_turn_done": true' "$f"
  run env GROK_SESSION_ID=sess2 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"first_turn_done": false' "$f"
  grep -q '"session_id": "sess2"' "$f"
}
