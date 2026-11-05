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
  # A stub child recorded by a test that may have failed half-way is never left
  # behind: kill it by the pid the stub itself wrote, only while that pid is still
  # one of ours (its argv names this test's own stub dir), then confirm it is gone.
  # A child that survives fails the teardown, after everything else is cleaned up.
  local f pid cmd i leaked=0
  for f in "$BATS_TEST_TMPDIR/stubborn-pid" "$BATS_TEST_TMPDIR/child-pid"; do
    [ -s "$f" ] || continue
    pid="$(cat "$f")"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)" || cmd=""
    case "$cmd" in
      *"$BATS_TEST_TMPDIR"*)
        kill -9 "$pid" 2>/dev/null || true
        i=0
        while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do i=$((i + 1)); sleep 0.1; done
        if kill -0 "$pid" 2>/dev/null; then
          echo "teardown: stub child $pid survived kill -9" >&2
          leaked=1
        fi
        ;;
    esac
  done
  teardown_test_env
  [ "$leaked" -eq 0 ]
}

_stub() {   # <name> <body>
  printf '#!/bin/sh\n%s\n' "$2" > "$BATS_TEST_TMPDIR/stubs/$1"
  chmod +x "$BATS_TEST_TMPDIR/stubs/$1"
}
_stub_uname() { _stub uname "echo $1"; }
_stub_ps() { _stub ps "echo '$$ $1 ${3:-3.0} $2'"; }     # <etime> <lstart> [<%cpu>], for the daemon.pid pid
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
  _stub ps "echo ps >> '$BATS_TEST_TMPDIR/ps-calls'; echo '$$ 5-00:00:00 3.0 $START'"
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
  # No exec: the recorded pid is the stub's own shell, whose argv carries this test's stub dir.
  _stub footprint 'echo $$ > '"$BATS_TEST_TMPDIR"'/child-pid; while :; do sleep 1; done'
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
  # The reader itself must have stopped the child (TERM was ignored, so KILL);
  # teardown only backs this up if the assertion fails.
  if kill -0 "$child" 2>/dev/null; then
    echo "stubborn child $child is still running" >&2
    false
  fi
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

@test "bounded read: an unrelated background job of the caller does not make a finished read look running" {
  run bash -c '
    source "$1/lib/codex-daemon-health.sh"
    _AGMSG_CDH_TMP="$2/out"
    sleep 4 3>&- 4>&- &
    unrelated=$!
    AGMSG_CODEX_DAEMON_READ_SECONDS=1 _agmsg_cdh_bounded "$_AGMSG_CDH_TMP" /usr/bin/true
    rc=$?
    kill "$unrelated" 2>/dev/null
    exit "$rc"
  ' _ "$SCRIPTS" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
}

# --- CPU condition: %cpu >= 200 and at least 12 h old ---------------------------

@test "health: exactly 200.0% CPU at 12 h is over with cause cpu even though the footprint is small" {
  _stub_footprint 1228
  _stub_ps "12:00:00" "$START" "200.0"
  _health
  [ "$(_field 7)" = 1 ]
  [ "$(_field 11)" = 200 ]
  [ "$(_field 12)" = cpu ]
}

@test "health: 199.9% CPU, or a young daemon at 570%, is not over; %cpu costs no extra process" {
  _stub_footprint 1228
  _stub_ps "13:00:00" "$START" "199.9"
  _health
  [ "$(_field 7)" = 0 ]
  [ "$(_field 11)" = 199 ]
  _stub_ps "11:59:59" "$START" "570.0"
  _health
  [ "$(_field 7)" = 0 ]
  [ "$(_field 12)" = "" ]
}

@test "health: memory and CPU together say both; memory alone says memory" {
  _stub_footprint 6144
  _stub_ps "13:00:00" "$START" "300.0"
  _health
  [ "$(_field 12)" = "memory+cpu" ]
  _stub_ps "13:00:00" "$START" "10.0"
  _health
  [ "$(_field 12)" = memory ]
}

@test "health: a footprint that cannot be read still reports a CPU-over daemon, and an idle one stays unchecked" {
  _stub footprint 'exit 1'
  _stub_ps "13:00:00" "$START" "250.0"
  _health
  [ "$(_field 2)" = running ]
  [ "$(_field 7)" = 1 ]
  [ "$(_field 12)" = cpu ]
  _stub_ps "13:00:00" "$START" "5.0"
  _health
  [ "$(_field 2)" = unchecked ]
}

@test "doctor: a busy old daemon warns with the CPU wording and the restart command" {
  _stub_footprint 1228
  _stub_ps "13:00:00" "$START" "240.0"
  PATH="$BATS_TEST_TMPDIR/stubs:$PATH" run bash "$SCRIPTS/doctor.sh"
  [ "$status" -eq 1 ]
  case "$output" in *"cpu 240%"*) ;; *) false ;; esac
  case "$output" in *"uses 240% CPU, over the 200% limit"*) ;; *) false ;; esac
  case "$output" in *"daemon restart"*) ;; *) false ;; esac
}
