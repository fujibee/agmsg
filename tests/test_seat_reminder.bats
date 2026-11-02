#!/usr/bin/env bats

# A resumed session that cannot be matched to a seat on a multi-seat project gets
# no watcher (session-start.sh stands down; see test_resume_seat_guard.bats). The
# per-prompt reminder keeps that state from going unnoticed: until the session
# claims a seat, every prompt shows the "pick your seat" list. These tests run the
# hook the way the host does -- hook JSON on stdin -- and observe what it prints
# and what it leaves alone.

load test_helper

setup() {
  setup_test_env
  export AGMSG_AGENT_PID=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export PROJ="/tmp/agmsg-seat-reminder-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob   claude-code "$PROJ" >/dev/null
}

teardown() { teardown_test_env; }

_read_cursor() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    storage_read_cursor_get "$1" "$2" )
}

_session_start() {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$1\"}"
}

# The hook as the host runs it, with an empty PATH: it must need no external command.
_prompt() {
  env PATH= /bin/bash "$SCRIPTS/seat-reminder.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$1\",\"prompt\":\"hi\"}"
}

@test "seat reminder: a session that stood down is shown the seat list on every prompt" {
  run _session_start "sid-deaf"
  [ "$status" -eq 0 ]
  grep -qF "shown again on every prompt" <<<"$output"

  local n
  for n in 1 2 3; do
    run _prompt "sid-deaf"
    [ "$status" -eq 0 ]
    grep -qF "NOT receiving agmsg messages" <<<"$output"
    grep -qF "/agmsg actas alice" <<<"$output"
    grep -qF "/agmsg actas bob" <<<"$output"
    grep -qF "repeats on every prompt" <<<"$output"
  done
}

@test "seat reminder: another session, or no marker, prints nothing" {
  run _session_start "sid-deaf"
  run _prompt "sid-other"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run env PATH= /bin/bash "$SCRIPTS/seat-reminder.sh" claude-code "$PROJ" <<< ''
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "seat reminder: showing it starts no watcher and moves no read cursor" {
  bash "$SCRIPTS/send.sh" team bob alice "to-alice" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "to-bob" >/dev/null
  local a0 b0; a0="$(_read_cursor team alice)"; b0="$(_read_cursor team bob)"
  run _session_start "sid-deaf"
  run _prompt "sid-deaf"
  [ "$(_read_cursor team alice)" = "$a0" ]
  [ "$(_read_cursor team bob)" = "$b0" ]
  run bash -c 'ls "$1" | grep -c "^watch\." || true' _ "$RUN_DIR"
  [ "$output" = 0 ]
}

@test "seat reminder: claiming a seat ends it" {
  run _session_start "sid-deaf"
  run _prompt "sid-deaf"
  grep -qF "NOT receiving" <<<"$output"
  run bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-deaf"
  grep -qF "status=ok" <<<"$output"
  run _prompt "sid-deaf"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "seat reminder: ending the session, or a restart that finds a seat, clears it" {
  run _session_start "sid-deaf"
  [ -f "$RUN_DIR/seat-pending.sid-deaf" ]
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-end.sh" claude-code "$PROJ" <<< '{"session_id":"sid-deaf"}'
  [ ! -f "$RUN_DIR/seat-pending.sid-deaf" ]

  run _session_start "sid-deaf"
  [ -f "$RUN_DIR/seat-pending.sid-deaf" ]
  echo "sid-deaf" > "$RUN_DIR/cc-instance.$$"
  echo "sid-deaf" > "$RUN_DIR/actas.team__alice.session"
  run _session_start "sid-deaf"
  [ ! -f "$RUN_DIR/seat-pending.sid-deaf" ]
}

@test "seat reminder: a single-seat project writes no marker" {
  local one="/tmp/agmsg-seat-reminder-one"
  bash "$SCRIPTS/join.sh" solo carol claude-code "$one" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$one" <<< '{"session_id":"sid-solo"}'
  [ ! -f "$RUN_DIR/seat-pending.sid-solo" ]
}

@test "seat reminder: monitor and both install the prompt hook; turn and off do not" {
  local proj="$BATS_TEST_TMPDIR/hookproj" mode
  mkdir -p "$proj/.claude"
  local f="$proj/.claude/settings.local.json"
  for mode in monitor both; do
    bash "$SCRIPTS/delivery.sh" set "$mode" claude-code "$proj" >/dev/null
    run jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$f"
    grep -qF "seat-reminder.sh" <<<"$output"
  done
  for mode in turn off; do
    bash "$SCRIPTS/delivery.sh" set "$mode" claude-code "$proj" >/dev/null
    run jq -r '(.hooks.UserPromptSubmit // []) | length' "$f"
    [ "$output" = 0 ]
  done
}
