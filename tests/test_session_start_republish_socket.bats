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

@test "republish socket: a proven record-basis seat gets the live socket written" {
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code
  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/alice-fresh.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-alice"
  run _run_session_start_as claude-code "sid-alice"
  [ "$status" -eq 0 ]
  local got; got="$(_messaging_socket_of team alice)"
  [ "$got" = "/tmp/cc-socks/alice-fresh.sock" ]
}

@test "republish socket: a proven narrowed (actas-lock-only) seat also gets it written" {
  _mark_sid_alive "sid-bob"
  _seed_actas_lock team bob "sid-bob"
  export CLAUDE_CODE_MESSAGING_SOCKET="/tmp/cc-socks/bob-fresh.sock"
  export CLAUDE_CONFIG_DIR="$TEST_SKILL_DIR/claude-config-bob"
  run _run_session_start_as claude-code "sid-bob"
  [ "$status" -eq 0 ]
  local got; got="$(_messaging_socket_of team bob)"
  [ "$got" = "/tmp/cc-socks/bob-fresh.sock" ]
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
