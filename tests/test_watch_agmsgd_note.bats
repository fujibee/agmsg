#!/usr/bin/env bats

# #1848: a watch that ends while agmsgd is on for the project but has no
# destination for this session leaves nothing delivering. Its stop message says
# so (and how to register one). The note is text only: no stop condition moves.

load test_helper

setup() {
  setup_test_env
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export AGMSG_AGENT_PID="" ;; esac
  export PROJ="$BATS_TEST_TMPDIR/proj"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

_wait_exit() {
  local i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

_agmsgd_desired() {   # on|off
  mkdir -p "$TEST_SKILL_DIR/run"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='$1';"
}

# Runs a watcher with --max-seconds=2 and no messages; leaves its output in $OUT.
_run_idle_watch() {
  OUT="$BATS_TEST_TMPDIR/idle.txt"
  : > "$OUT"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-note "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
}

# Runs a watcher through an update that never finishes; leaves its output in $OUT.
_run_unfinished_update_watch() {
  OUT="$BATS_TEST_TMPDIR/unfinished.txt"
  : > "$OUT"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=2 \
    bash "$SCRIPTS/watch.sh" sid-note-u "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  sleep 2
  touch "$SCRIPTS/config.sh"
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
}

@test "watch stop (no deliveries): agmsgd on and no destination for this session -> the message says nothing will be delivered and how to register, without claiming which cause" {
  _agmsgd_desired on
  _run_idle_watch
  grep -qF 'agmsg watch: stopping - no messages were delivered' "$OUT"
  grep -qF 'agmsgd is on for this project but is not delivering to this session yet' "$OUT"
  grep -qF '/agmsg actas <name>' "$OUT"
}

@test "watch stop (no deliveries): agmsgd off -> the message is the plain one" {
  _agmsgd_desired off
  _run_idle_watch
  grep -qF 'agmsg watch: stopping - no messages were delivered' "$OUT"
  refute grep -qF 'agmsgd is on for this project' "$OUT"
}

@test "watch stop (no deliveries): no agmsgd install.db at all -> the message is the plain one" {
  _run_idle_watch
  grep -qF 'agmsg watch: stopping - no messages were delivered' "$OUT"
  refute grep -qF 'agmsgd' "$OUT"
}

@test "watch stop (no deliveries): the project chose monitor -> the message is the plain one" {
  _agmsgd_desired on
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'claude-code\t%s\tmonitor\n' "$(cd "$PROJ" && pwd -P)" > "$TEST_SKILL_DIR/run/delivery-choice"
  _run_idle_watch
  grep -qF 'agmsg watch: stopping - no messages were delivered' "$OUT"
  refute grep -qF 'agmsgd is on for this project' "$OUT"
}

@test "watch stop (update never finished): agmsgd on -> same note after the existing restart advice; agmsgd off -> plain" {
  _agmsgd_desired on
  _run_unfinished_update_watch
  grep -qF 'installation was updated while this watcher was running' "$OUT"
  grep -qF 'to resume delivery. agmsgd is on for this project but is not delivering' "$OUT"

  _agmsgd_desired off
  _run_unfinished_update_watch
  grep -qF 'installation was updated while this watcher was running' "$OUT"
  refute grep -qF 'agmsgd is on for this project' "$OUT"
}
