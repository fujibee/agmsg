#!/usr/bin/env bats

# #1872 — SessionStart used to re-establish WHICH seat a resumed session holds
# (role-aware resume, #339) but never re-published that seat's
# `messaging_socket`. Claude Code hands every process a fresh
# CLAUDE_CODE_MESSAGING_SOCKET, so the record kept pointing at the PREVIOUS
# process's dead socket after a resume/restart/compact/clear, with nothing to
# recover it short of the model explicitly re-running `/agmsg actas <name>`.
# agmsgd then reports the seat `unaddressable (messaging_socket_missing)`.
#
# These tests run session-start.sh exactly as the earlier #339/#982 suite does
# (test_resume_seat_guard.bats) and read the record back afterward — the
# behaviour (what landed in the record), not the directive text.

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export PROJ="/tmp/agmsg-republish-socket-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob   claude-code "$PROJ" >/dev/null
}

teardown() { teardown_test_env; }

_mark_sid_alive() { echo "$1" > "$RUN_DIR/cc-instance.$$"; }

_seed_actas_lock() {
  local team="$1" agent="$2" sid="$3"
  echo "$sid" > "$RUN_DIR/actas.${team}__${agent}.session"
}

_seed_role_record() {
  local team="$1" agent="$2" sid="$3" proj="$4" type="${5:-claude-code}"
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_record "$2" "$3" "$4" "$5" "$6"
  ' _ "$SCRIPTS" "$team" "$agent" "$sid" "$proj" "$type"
}

_messaging_socket_of() {
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_get "$2" "$3" messaging_socket
  ' _ "$SCRIPTS" "$1" "$2"
}

_run_session_start_as() {   # <type> <sid> [extra env already exported by caller]
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" "$1" "$PROJ" <<< "{\"session_id\":\"$2\"}"
}

_registry_lock_dir() {
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/actas-lock.sh"
    _actas_lock_dir
  ' _ "$SCRIPTS"
}

@test "republish socket: a proven record-basis seat gets the live socket written" {
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code
  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/alice-fresh.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-alice"
  run _run_session_start_as claude-code "sid-alice"
  [ "$status" -eq 0 ]
  local got; got="$(_messaging_socket_of team alice)"
  [ "$got" = "/tmp/cc-socks/alice-fresh.sock" ]
}

@test "republish socket: a proven, narrowed (actas-lock-only) seat writes nothing -- record basis only (review round 1)" {
  # #339's narrowing path has only an actas lock, no role-session record yet
  # (creating one here is actas-claim.sh's job, never session-start.sh's --
  # see the comment above agmsg_role_session_set_messaging in role-session.sh
  # and this fix's own comment in session-start.sh). Deliberately NOT covered:
  # the alternative (session-start.sh calling agmsg_role_session_record) was
  # found, in review, to widen a TOCTOU window where a different session that
  # reclaimed this exact role in between would have its fresh record stomped
  # by this one's stale claim.
  _mark_sid_alive "sid-bob"
  _seed_actas_lock team bob "sid-bob"
  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/bob-should-not-land.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-bob"
  run _run_session_start_as claude-code "sid-bob"
  [ "$status" -eq 0 ]
  grep -qF "acting as bob" <<<"$output"
  [ -z "$(_messaging_socket_of team bob)" ]
}

@test "republish socket: a resumed, dead-socket record is overwritten by the new one, not left stale" {
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_publish_messaging team alice /tmp/cc-socks/dead-42208.sock "$2/claude-config-alice" sid-alice ""
  ' _ "$SCRIPTS" "$TEST_SKILL_DIR"
  [ "$(_messaging_socket_of team alice)" = /tmp/cc-socks/dead-42208.sock ]

  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/alice-newpid.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-alice"
  run _run_session_start_as claude-code "sid-alice"
  [ "$status" -eq 0 ]
  [ "$(_messaging_socket_of team alice)" = /tmp/cc-socks/alice-newpid.sock ]
}

@test "republish socket: an unidentified seat (no role established) writes nothing" {
  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/nobody.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-nobody"
  run _run_session_start_as claude-code "sid-nobody"
  [ "$status" -eq 0 ]
  grep -qF "standing down" <<<"$output"
  [ -z "$(_messaging_socket_of team alice)" ]
  [ -z "$(_messaging_socket_of team bob)" ]
}

@test "republish socket: no CLAUDE_CODE_MESSAGING_SOCKET in the environment writes nothing, and does not fail the hook" {
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code
  unset CLAUDE_CODE_MESSAGING_SOCKET
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-alice"
  run _run_session_start_as claude-code "sid-alice"
  [ "$status" -eq 0 ]
  [ -z "$(_messaging_socket_of team alice)" ]
}

@test "republish socket: a non-claude-code type never writes it, even with a proven seat" {
  bash "$SCRIPTS/join.sh" team carol codex "$PROJ" >/dev/null
  _seed_role_record team carol "sid-carol" "$PROJ" codex
  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/carol-should-not-land.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-carol"
  run _run_session_start_as codex "sid-carol"
  [ -z "$(_messaging_socket_of team carol)" ]
}

@test "republish socket: a different session's record won by the time of the write is never stomped (review round 1 BLOCKING)" {
  # The exact race review found: this session's role lookup, far above the
  # write, observed itself as the owner of (team, alice) -- but by the time
  # the write actually runs, a DIFFERENT session has claimed and re-recorded
  # that same pair (the shape a real actas-claim.sh run from another seat
  # would produce). The write must see THAT fact, not the stale observation,
  # and refuse rather than overwrite the newer owner's socket with its own.
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code

  # Simulate the race by re-recording the pair under a DIFFERENT session,
  # with its OWN already-published socket, between the lookup and the write --
  # done here via a PATH shim on agmsg_role_session_lookup_by_sid's own
  # backing read is impractical from a black-box test, so this test instead
  # asserts the CAS primitive session-start.sh now calls directly: the write
  # must refuse once the record's session= no longer matches.
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_record team alice sid-newowner "$2" claude-code
    agmsg_role_session_publish_messaging team alice /tmp/cc-socks/newowner.sock "$2/claude-config-newowner" sid-newowner ""
  ' _ "$SCRIPTS" "$PROJ"
  [ "$(_messaging_socket_of team alice)" = /tmp/cc-socks/newowner.sock ]

  run env SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_publish_messaging_if_owner team alice /tmp/cc-socks/old-resumer.sock "$2/claude-config-oldresumer" sid-alice sid-alice ""
  ' _ "$SCRIPTS" "$PROJ"
  [ "$status" -ne 0 ]
  [ "$(_messaging_socket_of team alice)" = /tmp/cc-socks/newowner.sock ]
}

@test "republish socket: a fully contended registry lock does not add a seconds-scale wait to the hook (review round 2 BLOCKING, performance)" {
  # The default registry-lock budget is AGMSG_LOCK_SECONDS (10s) -- fine for a
  # background writer, wrong for a SessionStart hook a person is waiting on.
  # This call overrides it to 0 for its own write only: exactly one mkdir
  # attempt, no sleep, so losing the race costs microseconds, not seconds.
  # Seize the lock in THIS test process for the whole call, the same shape a
  # genuinely contended write would see, and assert on WALL TIME, not just
  # that the call eventually returned.
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code
  local lockdir; lockdir="$(_registry_lock_dir)/.config.lock"
  mkdir -p "$lockdir"
  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/alice-contended.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-alice"
  local start end elapsed
  start="$(date +%s)"
  run _run_session_start_as claude-code "sid-alice"
  end="$(date +%s)"
  rmdir "$lockdir" 2>/dev/null || true
  elapsed=$((end - start))
  [ "$status" -eq 0 ]
  # Generous ceiling (bats/CI overhead, not the lock): a genuine wait for the
  # default 10s budget would clear this easily; losing a single-mkdir probe
  # should not.
  [ "$elapsed" -le 3 ]
  # And the write genuinely lost the race (lock was held the whole time), so
  # this is really exercising the contended path, not an accidental free lock.
  [ -z "$(_messaging_socket_of team alice)" ]
}

@test "republish socket: a resume with an already-alive watcher still refreshes the socket (review round 1 NEEDS FIX)" {
  # /compact (and similar same-process re-fires) hit the "watcher already
  # streaming" early exit (WATCHER_PIDFILE), which used to sit BEFORE the
  # republish block -- so the exact re-fire this whole fix targets never
  # reached it. The republish now runs before that early exit.
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_publish_messaging team alice /tmp/cc-socks/dead-before-compact.sock "$2/claude-config-alice" sid-alice ""
  ' _ "$SCRIPTS" "$TEST_SKILL_DIR"

  # Seed a live watcher pidfile for this exact instance id (sid-alice, no pid
  # suffix -- AGMSG_AGENT_PID is "" in setup, matching agmsg_instance_id_from_pid's
  # bare-sid fallback), owned by this test process itself so it reads alive.
  echo "$$" > "$RUN_DIR/watch.sid-alice.pid"

  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/alice-after-compact.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-alice"
  run _run_session_start_as claude-code "sid-alice"
  [ "$status" -eq 0 ]
  grep -qF "already streaming" <<<"$output"
  [ "$(_messaging_socket_of team alice)" = /tmp/cc-socks/alice-after-compact.sock ]
}
