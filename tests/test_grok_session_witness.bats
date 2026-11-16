#!/usr/bin/env bats

# grok-session-start.sh / grok-stop.sh -- the agmsgd-mode hooks the
# grok-queue channel reads its own per-seat witness file from. Grok Build's
# SessionStart stdout is discarded (measured live, 2026-11-15), so these
# scripts emit nothing on that path; Stop still has to delegate to
# check-inbox.sh's own decision=block contract.
#
# Real-machine round (2026-11-15, NG1): the hook's own $$ is not the real
# session process; the pid, pid_start, and cwd come from
# GROK_HOME/active_sessions.json, keyed by session id -- confirmed live
# keys: cwd, opened_at, pid, pid_start, session_id. Every test that expects
# a witness to be written sets one up via write_active_sessions below.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  TEST_PROJECT="$TEST_SKILL_DIR/proj"
  mkdir -p "$TEST_PROJECT"
  export GROK_HOME="$TEST_SKILL_DIR/grokhome"
  mkdir -p "$GROK_HOME"
}
teardown() { teardown_test_env; }

# write_active_sessions <session_id> <pid> [pid_start] [cwd]
write_active_sessions() {
  local sid="$1" pid="$2" pid_start="${3:-1794767213378370}" cwd="${4:-/somewhere/else}"
  cat > "$GROK_HOME/active_sessions.json" <<EOF
[
  {"session_id": "$sid", "pid": $pid, "pid_start": $pid_start, "cwd": "$cwd", "opened_at": "2026-11-15T00:00:00Z"}
]
EOF
}

@test "grok-session-start.sh: writes a witness file for the project's single registered grok-build seat" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031 1794767213378370
  run env GROK_SESSION_ID=sess1 GROK_LEADER_SOCKET=/tmp/l.sock bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # SessionStart's own stdout must be empty (discarded by grok)
  local f
  f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  [ -f "$f" ]
  grep -q '"session_id": "sess1"' "$f"
  grep -q '"pid": "17031"' "$f"
  grep -q '"pid_start": "1794767213378370"' "$f"
  grep -q '"leader_socket": "/tmp/l.sock"' "$f"
  grep -q '"first_turn_done": false' "$f"
}

@test "grok-session-start.sh: leader_socket is EMPTY when GROK_LEADER_SOCKET is unset, never a guessed default (real-machine review, finding A)" {
  # A plain (non-leader) TUI never sets GROK_LEADER_SOCKET. Defaulting to
  # grok's documented leader.sock path here used to record a socket
  # nothing was listening on -- the channel then spawned the ACP client
  # against it anyway, and the client itself started a brand-new,
  # resident leader process against the user's real ~/.grok. An empty
  # leader_socket is what makes the channel's own connect probe refuse to
  # spawn anything for this seat at all.
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"leader_socket": ""' "$f"
  ! grep -q '\.sock"' "$f"
}

@test "grok-session-start.sh: leader_socket is recorded verbatim when GROK_LEADER_SOCKET IS set (a real leader TUI)" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 GROK_LEADER_SOCKET="$GROK_HOME/leader.sock" bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q "\"leader_socket\": \"$GROK_HOME/leader.sock\"" "$f"
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
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  ! ls "$TEST_SKILL_DIR"/run/grok-seat.*.json >/dev/null 2>&1
}

@test "grok-session-start.sh: no matching active_sessions.json entry writes nothing, warns on stderr, records the pending reason" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions some-other-session 17031
  run env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=1 AGMSG_GROK_LOOKUP_INTERVAL=0 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "could not find session sess1"
  [ ! -e "$TEST_SKILL_DIR"/run/grok-seat.*.json ]
  local pending; pending="$(ls "$TEST_SKILL_DIR"/run/grok-seat-pending.* 2>/dev/null)"
  [ -n "$pending" ]
  grep -q "could not find session sess1" "$pending"
}

@test "grok-session-start.sh: no active_sessions.json at all writes nothing, warns on stderr" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  run env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=1 AGMSG_GROK_LOOKUP_INTERVAL=0 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "could not find session sess1"
  ! ls "$TEST_SKILL_DIR"/run/grok-seat.*.json >/dev/null 2>&1
}

@test "grok-session-start.sh: a Linux real-machine round -- the session is not in active_sessions.json yet, but appears by the Nth retry" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  # Not written yet; a background writer adds it after a couple of
  # retries' worth of (near-zero) delay -- models grok itself writing the
  # session into active_sessions.json slightly after SessionStart fires.
  ( sleep 0.3; write_active_sessions sess1 17031 ) &
  local writer_pid=$!
  run env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=20 AGMSG_GROK_LOOKUP_INTERVAL=0.05 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  wait "$writer_pid"
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"pid": "17031"' "$f"
  ! ls "$TEST_SKILL_DIR"/run/grok-seat-pending.* >/dev/null 2>&1
}

@test "grok-session-start.sh: a successful witness clears any earlier pending-reason file for this seat" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions some-other-session 17031
  env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=1 AGMSG_GROK_LOOKUP_INTERVAL=0 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local pending; pending="$(ls "$TEST_SKILL_DIR"/run/grok-seat-pending.*)"
  [ -n "$pending" ]
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=1 AGMSG_GROK_LOOKUP_INTERVAL=0 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  [ ! -f "$pending" ]
}

@test "grok-session-start.sh: a second, unrelated session in active_sessions.json does not confuse the match" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  cat > "$GROK_HOME/active_sessions.json" <<'EOF'
[
  {"session_id": "other-session", "pid": 99999, "pid_start": 1, "cwd": "/x"},
  {"session_id": "sess1", "pid": 17031, "pid_start": 1794767213378370, "cwd": "/a/project"}
]
EOF
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"pid": "17031"' "$f"
}

@test "grok-session-start.sh: cwd comes from active_sessions.json's own entry, never the hook's \$PWD (2026-11-15 review: macOS /tmp symlink broke session/resume)" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031 1794767213378370 /the/real/canonical/path
  run env GROK_SESSION_ID=sess1 bash -c "cd '$TEST_PROJECT' && '$SCRIPTS/internal/grok-session-start.sh' '$TEST_PROJECT' <<<'{}'"
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"cwd": "/the/real/canonical/path"' "$f"
  ! grep -q "\"cwd\": \"$TEST_PROJECT\"" "$f"
}

@test "grok-stop.sh: marks first_turn_done true on the matching session's witness, and still runs the inbox check" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"first_turn_done": false' "$f"
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"first_turn_done": true' "$f"
}

@test "grok-stop.sh: a DIFFERENT session's Stop never touches a witness whose own pid is still ALIVE, even when the new session IS in active_sessions.json" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  # The witness's own pid is THIS TEST's pid -- guaranteed alive, so its
  # owning session must never be read as gone no matter what the new
  # session's own Stop sees in active_sessions.json.
  write_active_sessions sess1 "$$"
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  write_active_sessions sess-other 424242
  run env GROK_SESSION_ID=sess-other bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"first_turn_done": false' "$f"
  grep -q '"session_id": "sess1"' "$f"
}

@test "grok-stop.sh: a DIFFERENT session's Stop never touches a witness whose own pid cannot be confirmed dead (e.g. permission denied), stays conservative" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  # pid 1 (launchd/init) is never ours to signal -- kill -0 answers
  # "Operation not permitted", which must read as "cannot tell", not
  # "confirmed dead".
  write_active_sessions sess1 1
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  write_active_sessions sess-other 424242
  run env GROK_SESSION_ID=sess-other bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"session_id": "sess1"' "$f"
}

@test "grok-stop.sh: a DIFFERENT session's Stop recovers the witness when the OLD session's own pid is confirmed dead and the NEW session IS in active_sessions.json (review on #1979, finding 1)" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  # SessionStart's own bounded retry for sess-other ran out and left no
  # witness of its own (not simulated directly here; what matters is
  # that the OLD witness, for sess1, is confirmed abandoned).
  write_active_sessions sess1 999999999
  env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=1 AGMSG_GROK_LOOKUP_INTERVAL=0 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"session_id": "sess1"' "$f"
  write_active_sessions sess-other 424242
  run env GROK_SESSION_ID=sess-other bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"session_id": "sess-other"' "$f"
  grep -q '"pid": "424242"' "$f"
  grep -q '"first_turn_done": true' "$f"
}

@test "grok-stop.sh: emits decision=block when the seat has unread messages (grok's own Stop contract)" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 sender claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/send.sh" t1 sender gagent "hello" >/dev/null
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"decision": "block"'
}

@test "grok-stop.sh: creates the witness itself when SessionStart never managed to (Linux real-machine round) -- first_turn_done true from the start" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  # SessionStart never ran (or ran before the session existed) -- no
  # witness at all. By Stop time, active_sessions.json is populated.
  [ ! -e "$TEST_SKILL_DIR"/run/grok-seat.*.json ]
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"pid": "17031"' "$f"
  grep -q '"session_id": "sess1"' "$f"
  grep -q '"first_turn_done": true' "$f"
}

@test "grok-stop.sh: clears an earlier pending-reason file once it successfully creates the witness itself" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions some-other-session 1
  env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=1 AGMSG_GROK_LOOKUP_INTERVAL=0 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local pending; pending="$(ls "$TEST_SKILL_DIR"/run/grok-seat-pending.*)"
  [ -n "$pending" ]
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  [ ! -f "$pending" ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"first_turn_done": true' "$f"
}

@test "grok-stop.sh: still no witness and no active_sessions.json entry at Stop -- records its own pending reason, still runs the inbox check" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  [ ! -e "$TEST_SKILL_DIR"/run/grok-seat.*.json ]
  local pending; pending="$(ls "$TEST_SKILL_DIR"/run/grok-seat-pending.*)"
  [ -n "$pending" ]
  grep -q "Stop could not find session sess1" "$pending"
}

@test "grok-session-start.sh: a re-fire for the SAME session_id does not reset an already-advanced first_turn_done" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
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
  write_active_sessions sess1 17031
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -q '"first_turn_done": true' "$f"
  write_active_sessions sess2 17032
  run env GROK_SESSION_ID=sess2 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"first_turn_done": false' "$f"
  grep -q '"session_id": "sess2"' "$f"
}
