#!/usr/bin/env bats

# #1886: a read-only health check of the Codex app-server daemon. ps, footprint, lsof
# and uname are stubbed on PATH for the command under test only, and CODEX_HOME
# is a throwaway directory; no real daemon is ever read, stopped or restarted.

load test_helper

setup() {
  setup_test_env
  export CODEX_HOME="$BATS_TEST_TMPDIR/profile"
  mkdir -p "$CODEX_HOME/app-server-daemon" "$BATS_TEST_TMPDIR/stubs"
  START="Tue Nov  3 12:50:37 2026"
  printf '{"pid":%s,"processStartTime":"%s"}\n' "$$" "$START" > "$CODEX_HOME/app-server-daemon/daemon.pid"
  _stub_uname Darwin
  _stub_ps "5-00:00:00" "$START"
  _stub_footprint 1536
}

teardown() {
  teardown_test_env
}

_stub() {   # <name> <body>
  printf '#!/bin/sh\n%s\n' "$2" > "$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
}
_stub_uname() { _stub uname "echo $1"; }
_stub_ps() { _stub ps "echo '$$ $1 $2'"; }     # <etime> <lstart>, for the daemon.pid pid
# <MB>; phys_footprint in bytes as `footprint -f bytes` prints it, peak twice that
_stub_footprint() { _stub footprint "printf 'Auxiliary data:\\n    phys_footprint: %s B\\n    phys_footprint_peak: %s B\\n' $(( $1 * 1048576 )) $(( $1 * 2097152 ))"; }

_health() {
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/codex-daemon-health.sh"
}

_field() {   # <n>  (1-based tab field of the first line)
  printf '%s\n' "$output" | head -n 1 | cut -f "$1"
}

@test "health: a daemon under the footprint limit is running and not over" {
  _health
  [ "$status" -eq 0 ]
  [ "$(_field 2)" = running ]
  [ "$(_field 3)" = "$$" ]
  [ "$(_field 6)" = 1536 ]
  [ "$(_field 7)" = 0 ]
}

@test "health: a daemon younger than 12 h is not over, and its footprint is not read" {
  _stub footprint 'echo footprint-was-called >> '"$BATS_TEST_TMPDIR"'/spawned'
  _stub_ps "11:59:59" "$START"
  _health
  [ "$(_field 2)" = running ]
  [ "$(_field 5)" = 43199 ]
  [ "$(_field 6)" = "" ]
  [ "$(_field 7)" = 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/spawned" ]
}

@test "health: 6 GB and 12 h is over, and the client count is read only then" {
  _stub_footprint 6144
  _stub_ps "12:00:00" "$START"
  mkdir -p "$CODEX_HOME/app-server-control"
  ln -s "$BATS_TEST_TMPDIR/ctl.sock" "$CODEX_HOME/app-server-control/app-server-control.sock"
  _stub lsof "printf 'n a\\n%s\\n%s\\n%s\\n' '$BATS_TEST_TMPDIR/ctl.sock' '$BATS_TEST_TMPDIR/ctl.sock' '$BATS_TEST_TMPDIR/ctl.sock'"
  _health
  [ "$(_field 7)" = 1 ]
  [ "$(_field 8)" = 2 ]
}

@test "health: just under 6 GB with a long age is not over" {
  _stub_footprint 6143
  _stub_ps "30-00:00:00" "$START"
  _health
  [ "$(_field 7)" = 0 ]
  [ "$(_field 8)" = "" ]
}

@test "health: a pid that is not running is stale, and footprint is not read" {
  printf '{"pid":999999,"processStartTime":"%s"}\n' "$START" > "$CODEX_HOME/app-server-daemon/daemon.pid"
  # The liveness helper cross-checks with the real ps, so the ps stub goes.
  rm -f "$BATS_TEST_TMPDIR/stubs/ps"
  _stub footprint 'echo footprint-was-called >> '"$BATS_TEST_TMPDIR"'/spawned'
  _health
  [ "$(_field 2)" = stale ]
  [ ! -e "$BATS_TEST_TMPDIR/spawned" ]
}

@test "health: a live pid with another start time is stale (pid reuse)" {
  _stub_ps "5-00:00:00" "Wed Nov  4 01:02:03 2026"
  _health
  [ "$(_field 2)" = stale ]
}

@test "health: no daemon.pid is absent" {
  rm -f "$CODEX_HOME/app-server-daemon/daemon.pid"
  _health
  [ "$(_field 2)" = absent ]
}

@test "health: another platform is skipped with one line and reads nothing" {
  _stub_uname Linux
  _health
  [ "$(_field 2)" = unchecked ]
  case "$output" in *"not checked on this platform"*) ;; *) false ;; esac
}

@test "health: seats' recorded profiles are checked too, each once" {
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other/app-server-daemon"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'codex_home=%s\ncodex_home=%s\n' "$other" "$CODEX_HOME" > "$TEST_SKILL_DIR/run/role-session.a"
  printf 'codex_home=%s\n' "$other" > "$TEST_SKILL_DIR/run/role-session.b"
  _health
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 2 ]
}

@test "doctor: prints the daemon line, warns over the limit with the restart command, and does not touch the daemon" {
  _stub_footprint 7168
  _stub_ps "13:00:00" "$START"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  case "$output" in *"Codex app-server daemon:"*"pid $$"*) ;; *) false ;; esac
  case "$output" in *"codex app-server daemon restart"*) ;; *) false ;; esac
  case "$output" in *"It keeps running"*) ;; *) false ;; esac
  kill -0 $$
}

@test "doctor: shows footprint and peak for an old daemon; a young one is not read" {
  _stub_footprint 3072
  _stub_ps "13:00:00" "$START"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"footprint 3.0 GB, peak 6.0 GB"*) ;; *) false ;; esac
  _stub footprint 'echo footprint-was-called >> '"$BATS_TEST_TMPDIR"'/spawned'
  _stub_ps "01:00:00" "$START"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"footprint is read from 12 h on"*) ;; *) false ;; esac
  [ ! -e "$BATS_TEST_TMPDIR/spawned" ]
}

@test "doctor: a healthy daemon adds no warning" {
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"Codex app-server daemon:"*"footprint 1.5 GB"*) ;; *) false ;; esac
}

@test "health: several profiles cost one single-pid ps each, and footprint only for the old daemons" {
  local i
  for i in 1 2 3; do
    mkdir -p "$BATS_TEST_TMPDIR/p$i/app-server-daemon"
    cp "$CODEX_HOME/app-server-daemon/daemon.pid" "$BATS_TEST_TMPDIR/p$i/app-server-daemon/daemon.pid"
    printf 'codex_home=%s\n' "$BATS_TEST_TMPDIR/p$i" >> "$TEST_SKILL_DIR/run/role-session.x" 2>/dev/null || { mkdir -p "$TEST_SKILL_DIR/run"; printf 'codex_home=%s\n' "$BATS_TEST_TMPDIR/p$i" >> "$TEST_SKILL_DIR/run/role-session.x"; }
  done
  _stub ps "echo ps >> '$BATS_TEST_TMPDIR/ps-calls'; echo '$$ 5-00:00:00 $START'"
  _stub footprint "echo fp >> '$BATS_TEST_TMPDIR/fp-calls'; printf 'phys_footprint: 1048576 B\\nphys_footprint_peak: 2097152 B\\n'"
  _health
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 4 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/ps-calls" | tr -d ' ')" = 4 ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/fp-calls" | tr -d ' ')" = 4 ]
}

@test "health: a profile whose footprint hangs is unchecked after the read limit and does not starve the next one" {
  mkdir -p "$BATS_TEST_TMPDIR/p2/app-server-daemon" "$TEST_SKILL_DIR/run"
  cp "$CODEX_HOME/app-server-daemon/daemon.pid" "$BATS_TEST_TMPDIR/p2/app-server-daemon/daemon.pid"
  printf 'codex_home=%s\n' "$BATS_TEST_TMPDIR/p2" > "$TEST_SKILL_DIR/run/role-session.x"
  # First call hangs (exec, so the killed pid is the sleep itself), the second answers over the limit.
  _stub footprint 'if [ ! -e '"$BATS_TEST_TMPDIR"'/first-done ]; then : > '"$BATS_TEST_TMPDIR"'/first-done; exec sleep 30; fi; printf "phys_footprint: 7516192768 B\nphys_footprint_peak: 8589934592 B\n"'
  _stub_ps "5-00:00:00" "$START"
  AGMSG_CODEX_DAEMON_READ_SECONDS=1 _health
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f2)" = unchecked ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f2)" = running ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f7)" = 1 ]
  case "$(printf '%s\n' "$output" | sed -n 1p | cut -f9)" in *footprint*) ;; *) false ;; esac
}

@test "health: stopping the reader mid-read takes its footprint child down with it" {
  _stub footprint 'echo $$ > '"$BATS_TEST_TMPDIR"'/child-pid; exec sleep 3141'
  _stub_ps "5-00:00:00" "$START"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" bash "$SCRIPTS/codex-daemon-health.sh" > /dev/null 2>&1 3>&- 4>&- &
  local reader=$!
  _wait_child_pid
  local child
  child="$(cat "$BATS_TEST_TMPDIR/child-pid")"
  kill -0 "$child"
  kill "$reader"
  wait "$reader" 2>/dev/null || true
  local i=0
  while kill -0 "$child" 2>/dev/null && [ "$i" -lt 30 ]; do i=$((i + 1)); sleep 0.1; done
  ! kill -0 "$child" 2>/dev/null
}

_wait_child_pid() {
  local i=0
  while [ ! -s "$BATS_TEST_TMPDIR/child-pid" ] && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
  [ -s "$BATS_TEST_TMPDIR/child-pid" ]
}

@test "health: a footprint that ignores TERM is killed after the read limit and the next profile is read" {
  mkdir -p "$BATS_TEST_TMPDIR/p2/app-server-daemon" "$TEST_SKILL_DIR/run"
  cp "$CODEX_HOME/app-server-daemon/daemon.pid" "$BATS_TEST_TMPDIR/p2/app-server-daemon/daemon.pid"
  printf 'codex_home=%s\n' "$BATS_TEST_TMPDIR/p2" > "$TEST_SKILL_DIR/run/role-session.x"
  # The first call ignores TERM and records its pid; the second answers.
  _stub footprint 'if [ ! -e '"$BATS_TEST_TMPDIR"'/first-done ]; then : > '"$BATS_TEST_TMPDIR"'/first-done; echo $$ > '"$BATS_TEST_TMPDIR"'/stubborn-pid; trap "" TERM; while :; do sleep 1; done; fi; printf "phys_footprint: 1048576 B\n"'
  _stub_ps "5-00:00:00" "$START"
  AGMSG_CODEX_DAEMON_READ_SECONDS=1 _health
  local child
  child="$(cat "$BATS_TEST_TMPDIR/stubborn-pid")"
  # Whatever the outcome, never leave the stub behind.
  kill -9 "$child" 2>/dev/null || true
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f2)" = unchecked ]
  [ "$(printf '%s\n' "$output" | sed -n 2p | cut -f2)" = running ]
}

@test "health: AGMSG_CODEX_DAEMON_START_AT rotates which profile is read first" {
  local i
  mkdir -p "$TEST_SKILL_DIR/run"
  for i in 1 2; do
    mkdir -p "$BATS_TEST_TMPDIR/p$i/app-server-daemon"
    cp "$CODEX_HOME/app-server-daemon/daemon.pid" "$BATS_TEST_TMPDIR/p$i/app-server-daemon/daemon.pid"
    printf 'codex_home=%s\n' "$BATS_TEST_TMPDIR/p$i" >> "$TEST_SKILL_DIR/run/role-session.x"
  done
  _health
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1)" = "$CODEX_HOME" ]
  AGMSG_CODEX_DAEMON_START_AT=1 _health
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1)" = "$BATS_TEST_TMPDIR/p1" ]
  AGMSG_CODEX_DAEMON_START_AT=5 _health   # 5 mod 3 = 2
  [ "$(printf '%s\n' "$output" | sed -n 1p | cut -f1)" = "$BATS_TEST_TMPDIR/p2" ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = 3 ]
}
