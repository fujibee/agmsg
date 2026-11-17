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

@test "grok-session-start.sh: more than one grok-build seat for the project writes no witness, never guessed" {
  bash "$SCRIPTS/join.sh" t1 g1 grok-build "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 g2 grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  ! ls "$TEST_SKILL_DIR"/run/grok-seat.*.json >/dev/null 2>&1
}

# review on #1979-followup: an ambiguous project (2+ grok-build
# registrations) used to leave BOTH hooks silently doing nothing -- no
# witness (correct, never guess) AND no pending reason either, so `agmsg
# daemon status` could not tell this apart from a project that never
# configured grok-build at all. Both seats' own pending reason now names
# the ambiguity so status can show it (review-criteria §10, class D: a
# silent fallback is a bug).

@test "grok-session-start.sh: an ambiguous project records WHY on every candidate's own pending reason" {
  bash "$SCRIPTS/join.sh" t1 g1 grok-build "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 g2 grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local pending_files=("$TEST_SKILL_DIR"/run/grok-seat-pending.*)
  [ "${#pending_files[@]}" -eq 2 ]
  grep -q "more than one grok-build registration" "${pending_files[0]}"
  grep -q "t1/g1" "${pending_files[0]}"
  grep -q "t1/g2" "${pending_files[0]}"
}

@test "grok-session-start.sh: an ambiguous project IS resolved when exactly one candidate's own witness already names this session" {
  bash "$SCRIPTS/join.sh" t1 g1 grok-build "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 g2 grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  # g1 already has a witness for THIS exact session (e.g. Stop wrote it
  # first, or this is a hook re-fire) -- a confirmed fact, not a guess.
  local key; key="$(printf 't1\x1fg1' | bash -c '. "$1"/lib/hash.sh; agmsg_sha1' _ "$SCRIPTS")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '{"session_id": "sess1", "first_turn_done": false}' > "$TEST_SKILL_DIR/run/grok-seat.$key.json"
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"pid": "17031"' "$TEST_SKILL_DIR/run/grok-seat.$key.json"
  ! ls "$TEST_SKILL_DIR"/run/grok-seat-pending.* >/dev/null 2>&1
}

@test "grok-stop.sh: an ambiguous project also records why on every candidate's own pending reason" {
  bash "$SCRIPTS/join.sh" t1 g1 grok-build "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" t1 g2 grok-build "$TEST_PROJECT" >/dev/null
  run env GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local pending_files=("$TEST_SKILL_DIR"/run/grok-seat-pending.*)
  [ "${#pending_files[@]}" -eq 2 ]
  grep -q "more than one grok-build registration" "${pending_files[0]}"
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

@test "grok-stop.sh: recovers a stale witness from a confirmed-dead old session even under a non-English locale (review on #1979 follow-up)" {
  # On glibc (Linux), kill's own error text is translated by the active
  # locale -- without forcing LC_ALL=C for that one command, "No such
  # process" never matches under e.g. ja_JP.UTF-8, and recovery silently
  # never fires there. macOS's libc does not translate it, so this is the
  # one case that needs a non-default locale to actually exercise the bug
  # this guards against.
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 999999999
  env GROK_SESSION_ID=sess1 AGMSG_GROK_LOOKUP_RETRIES=1 AGMSG_GROK_LOOKUP_INTERVAL=0 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  write_active_sessions sess-other 424242
  run env GROK_SESSION_ID=sess-other LC_ALL=ja_JP.UTF-8 LANG=ja_JP.UTF-8 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -q '"session_id": "sess-other"' "$f"
  grep -q '"first_turn_done": true' "$f"
}

# agmsg_grok_pid_definitely_dead unit cases (review on #1979, round 2): a bare
# `! _agmsg_pid_alive` over-reads "cannot tell" (invalid pid shape, or MSYS
# where only tasklist could answer) as confirmed dead.

@test "agmsg_grok_pid_definitely_dead: pid 0 is not a liveness token, never confirmed dead" {
  run bash -c 'SCRIPT_DIR="$1"; . "$1"/lib/hash.sh; . "$1"/internal/grok-session-witness.sh; agmsg_grok_pid_definitely_dead 0' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

@test "agmsg_grok_pid_definitely_dead: a leading-zero pid is invalid, never confirmed dead" {
  run bash -c 'SCRIPT_DIR="$1"; . "$1"/lib/hash.sh; . "$1"/internal/grok-session-witness.sh; agmsg_grok_pid_definitely_dead 0123' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

@test "agmsg_grok_pid_definitely_dead: an out-of-range pid is invalid, never confirmed dead" {
  run bash -c 'SCRIPT_DIR="$1"; . "$1"/lib/hash.sh; . "$1"/internal/grok-session-witness.sh; agmsg_grok_pid_definitely_dead 99999999999' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

@test "agmsg_grok_pid_definitely_dead: on MSYS a failed tasklist is unobservable, never confirmed dead" {
  run bash -c '
    SCRIPT_DIR="$1"; . "$1"/lib/hash.sh; . "$1"/internal/grok-session-witness.sh
    tasklist() { return 1; }
    MSYSTEM=MINGW64 agmsg_grok_pid_definitely_dead 12345
  ' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
}

@test "agmsg_grok_pid_definitely_dead: a genuinely dead pid is still confirmed dead" {
  run bash -c 'SCRIPT_DIR="$1"; . "$1"/lib/hash.sh; . "$1"/internal/grok-session-witness.sh; agmsg_grok_pid_definitely_dead 999999999' _ "$SCRIPTS"
  [ "$status" -eq 0 ]
}

@test "agmsg_grok_pid_definitely_dead: a live pid is never confirmed dead" {
  run bash -c 'SCRIPT_DIR="$1"; . "$1"/lib/hash.sh; . "$1"/internal/grok-session-witness.sh; agmsg_grok_pid_definitely_dead $$' _ "$SCRIPTS"
  [ "$status" -ne 0 ]
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

# use_leader = true (what `agmsg delivery agmsgd` writes) puts the TUI in
# leader mode without passing GROK_LEADER_SOCKET to its hooks (measured live,
# Grok Build 1.0.77). The leader the TUI starts is its own child process, so
# the hooks find it with one `ps` call. A stub ps stands in for the process
# table: "<ppid> <args>" lines, the shape `ps -A -o ppid= -o args=` prints.
_stub_ps() {   # <lines...>
  mkdir -p "$TEST_SKILL_DIR/psbin"
  { printf '#!/bin/sh\ncat <<"PSEOF"\n'; printf '%s\n' "$@"; printf 'PSEOF\n'; } > "$TEST_SKILL_DIR/psbin/ps"
  chmod +x "$TEST_SKILL_DIR/psbin/ps"
}

@test "grok-session-start.sh: no GROK_LEADER_SOCKET, but the session's own child is a grok leader -> grok's default socket under GROK_HOME" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  _stub_ps "    1 /sbin/launchd" "17031 /Users/x/.grok/bin/grok agent leader --no-exit-on-disconnect --relay-on-demand"
  run env -u GROK_LEADER_SOCKET PATH="$TEST_SKILL_DIR/psbin:$PATH" GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -qF "\"leader_socket\": \"$GROK_HOME/leader.sock\"" "$f"
}

@test "grok-session-start.sh: the child leader's own --leader-socket wins over the default" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  _stub_ps "17031 /usr/local/bin/grok agent leader --leader-socket /tmp/own.sock --relay-on-demand"
  run env -u GROK_LEADER_SOCKET PATH="$TEST_SKILL_DIR/psbin:$PATH" GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -qF '"leader_socket": "/tmp/own.sock"' "$f"
}

@test "grok-session-start.sh: a grok leader that is NOT this session's child is not adopted; leader_socket stays empty" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  _stub_ps "    1 /Users/x/.grok/bin/grok agent leader --no-exit-on-disconnect" "17031 /Users/x/.grok/bin/grok agent stdio"
  run env -u GROK_LEADER_SOCKET PATH="$TEST_SKILL_DIR/psbin:$PATH" GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -qF '"leader_socket": ""' "$f"
}

@test "grok-stop.sh: fills an empty leader_socket in this session's witness once the session's own leader is found" {
  bash "$SCRIPTS/join.sh" t1 gagent grok-build "$TEST_PROJECT" >/dev/null
  write_active_sessions sess1 17031
  _stub_ps "    1 /sbin/launchd"
  env -u GROK_LEADER_SOCKET PATH="$TEST_SKILL_DIR/psbin:$PATH" GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-session-start.sh" "$TEST_PROJECT" <<<'{}' >/dev/null
  local f; f="$(ls "$TEST_SKILL_DIR"/run/grok-seat.*.json)"
  grep -qF '"leader_socket": ""' "$f"
  _stub_ps "17031 /Users/x/.grok/bin/grok agent leader --relay-on-demand"
  run env -u GROK_LEADER_SOCKET PATH="$TEST_SKILL_DIR/psbin:$PATH" GROK_SESSION_ID=sess1 bash "$SCRIPTS/internal/grok-stop.sh" "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  grep -qF "\"leader_socket\": \"$GROK_HOME/leader.sock\"" "$f"
  grep -qF '"first_turn_done": true' "$f"
}
