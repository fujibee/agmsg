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
  # A finished install (VERSION written) whose new watch.sh cannot be exec'd.
  chmod -x "$SCRIPTS/watch.sh"
  printf 'new-version\n' > "$TEST_SKILL_DIR/VERSION"
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; chmod +x "$SCRIPTS/watch.sh"; false; }
  wait "$pid" || true
  chmod +x "$SCRIPTS/watch.sh"
}

@test "watch renewal (no deliveries): agmsgd on and no destination for this session -> the watch re-arms, it does not stop and say nothing will be delivered" {
  _agmsgd_desired on
  _run_idle_watch
  grep -qF 'agmsg watch: re-arm' "$OUT"
  refute grep -qF 'agmsg watch: stopping' "$OUT"
  refute grep -qF 'nothing will be delivered' "$OUT"
}

@test "watch renewal (no deliveries): agmsgd off -> re-arms, no agmsgd text" {
  _agmsgd_desired off
  _run_idle_watch
  grep -qF 'agmsg watch: re-arm' "$OUT"
  refute grep -qF 'agmsg watch: stopping' "$OUT"
  refute grep -qF 'agmsgd is on for this project' "$OUT"
}

@test "watch renewal (no deliveries): no agmsgd install.db at all -> re-arms, no agmsgd text" {
  _run_idle_watch
  grep -qF 'agmsg watch: re-arm' "$OUT"
  refute grep -qF 'agmsg watch: stopping' "$OUT"
  refute grep -qF 'agmsgd' "$OUT"
}

@test "watch renewal (no deliveries): the project chose monitor -> re-arms, no agmsgd text" {
  _agmsgd_desired on
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'claude-code\t%s\tmonitor\n' "$(cd "$PROJ" && pwd -P)" > "$TEST_SKILL_DIR/run/delivery-choice"
  _run_idle_watch
  grep -qF 'agmsg watch: re-arm' "$OUT"
  refute grep -qF 'agmsg watch: stopping' "$OUT"
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

@test "watch renewal: a registered destination stops the watch only while agmsgd is ready; once it is not ready the watch re-arms" {
  local boot
  case "$(uname -s)" in
    Darwin) boot="$(sysctl -n kern.bootsessionuuid)" ;;
    Linux) boot="$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id 2>/dev/null || sed -n 's/^btime //p' /proc/stat)" ;;
    *) skip 'POSIX beta executor evidence' ;;
  esac
  _agmsgd_desired on
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE meta SET node_path='$(command -v node)';
    UPDATE daemon_owner SET state='ready', executor_pid=$$, executor_boot_id='$boot', executor_started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  AGMSG_AGENT_PID=$$ CLAUDE_CODE_MESSAGING_SOCKET="uds:/tmp/cc-socks/s-note-reg.sock" \
    bash "$SCRIPTS/actas-claim.sh" "$PROJ" claude-code alice "sid-note-reg" | grep -qx "delivery=native"

  # Registered and ready: the watch stops because delivery moved to agmsgd, with no note.
  OUT="$BATS_TEST_TMPDIR/native.txt"
  : > "$OUT"
  AGMSG_AGENT_PID=$$ AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-note-reg "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF 'delivery has moved to agmsgd' "$OUT"
  refute grep -qF 'agmsgd is on for this project' "$OUT"

  # The same registration with agmsgd no longer ready: native delivery is not
  # confirmed any more, so the watch renews instead of leaving the seat deaf.
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_owner SET state='stopped';"
  OUT="$BATS_TEST_TMPDIR/notready.txt"
  : > "$OUT"
  AGMSG_AGENT_PID=$$ AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-note-reg "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF 'agmsg watch: re-arm' "$OUT"
  refute grep -qF 'agmsg watch: stopping' "$OUT"
}
