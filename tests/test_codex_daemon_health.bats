#!/usr/bin/env bats

# #1886: a read-only health check of the Codex app-server daemon. ps, top, lsof
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
  _stub_top "1.5G"
}

teardown() {
  teardown_test_env
}

_stub() {   # <name> <body>
  printf '#!/bin/sh\n%s\n' "$2" > "$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
}
_stub_uname() { _stub uname "echo $1"; }
_stub_ps() { _stub ps "echo '$1 $2'"; }       # <etime> <lstart>
_stub_top() { _stub top "printf 'MEM \\n%s\\n' '$1'"; }

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

@test "health: a daemon younger than 12 h is not over, and top is not run for it" {
  _stub_top "9.0G"
  _stub top 'echo top-was-called >> '"$BATS_TEST_TMPDIR"'/spawned'
  _stub_ps "11:59:59" "$START"
  _health
  [ "$(_field 2)" = running ]
  [ "$(_field 5)" = 43199 ]
  [ "$(_field 7)" = 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/spawned" ]
}

@test "health: 6 GB and 12 h is over, and the client count is read only then" {
  _stub_top "6.0G"
  _stub_ps "12:00:00" "$START"
  mkdir -p "$CODEX_HOME/app-server-control"
  ln -s "$BATS_TEST_TMPDIR/ctl.sock" "$CODEX_HOME/app-server-control/app-server-control.sock"
  _stub lsof "printf 'n a\\n%s\\n%s\\n%s\\n' '$BATS_TEST_TMPDIR/ctl.sock' '$BATS_TEST_TMPDIR/ctl.sock' '$BATS_TEST_TMPDIR/ctl.sock'"
  _health
  [ "$(_field 7)" = 1 ]
  [ "$(_field 8)" = 2 ]
}

@test "health: just under 6 GB with a long age is not over" {
  _stub_top "6143M"
  _stub_ps "30-00:00:00" "$START"
  _health
  [ "$(_field 7)" = 0 ]
  [ "$(_field 8)" = "" ]
}

@test "health: a pid that is not running is stale, and nothing is read from ps or top" {
  printf '{"pid":999999,"processStartTime":"%s"}\n' "$START" > "$CODEX_HOME/app-server-daemon/daemon.pid"
  _stub ps 'echo ps-was-called >> '"$BATS_TEST_TMPDIR"'/spawned'
  _stub top 'echo top-was-called >> '"$BATS_TEST_TMPDIR"'/spawned'
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
  _stub_top "7.0G"
  _stub_ps "13:00:00" "$START"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  case "$output" in *"Codex app-server daemon:"*"pid $$"*) ;; *) false ;; esac
  case "$output" in *"codex app-server daemon restart"*) ;; *) false ;; esac
  case "$output" in *"It keeps running"*) ;; *) false ;; esac
  kill -0 $$
}

@test "doctor: a young daemon still shows its footprint (doctor always reads it)" {
  _stub_top "3.0G"
  _stub_ps "01:00:00" "$START"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"footprint 3.0 GB"*) ;; *) false ;; esac
}

@test "doctor: a healthy daemon adds no warning" {
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 0 ]
  case "$output" in *"Codex app-server daemon:"*"footprint 1.5 GB"*) ;; *) false ;; esac
}
