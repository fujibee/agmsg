#!/usr/bin/env bats

# #1848 (superseded 2026-11-20 decision): a watch used to keep running
# with a warning note when agmsgd was on but no destination was confirmed
# registered for this session. The 2026-11-20 decision makes
# run/delivery-choice the single source of truth for whether this watcher
# should run at all, checked at both startup and the --max-seconds renewal
# point, and deliberately does NOT check whether agmsgd is actually
# alive/registered either way -- "agmsgd" (explicitly chosen, OR never
# chosen while agmsgd is desired on) means this watcher does not run,
# period; `agmsg daemon status --all` is where an actual delivery problem
# is diagnosed now, which the stop message names.

load test_helper

setup() {
  setup_test_env
  # Pin bare instance-id keying (#93) on every host, not only MSYS2: with no
  # agent ancestor (CI) the ps walk to pid 1 finds nothing anyway, and pinned
  # it is skipped.
  export AGMSG_AGENT_PID=""
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
  # A finished install (VERSION written) whose new watch.sh cannot be exec'd. The
  # watcher stays up and says so; stop it once the line is out.
  chmod -x "$SCRIPTS/watch.sh"
  printf 'new-version\n' > "$TEST_SKILL_DIR/VERSION"
  local i
  for i in $(seq 1 100); do
    grep -qF 'installation was updated while this watcher was running' "$OUT" 2>/dev/null && break
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  chmod +x "$SCRIPTS/watch.sh"
}

@test "watch stop: agmsgd on and no recorded choice -> stops immediately at startup, naming daemon status as where to check" {
  _agmsgd_desired on
  OUT="$BATS_TEST_TMPDIR/idle.txt"
  : > "$OUT"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-note "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF "this project's delivery choice is agmsgd, so no watch is started" "$OUT"
  grep -qF 'agmsg daemon status --all' "$OUT"
}

@test "watch stop (no deliveries): agmsgd off -> the message is the plain one" {
  _agmsgd_desired off
  _run_idle_watch
  grep -qF 'agmsg watch: stopping - no messages were delivered' "$OUT"
  refute grep -qF "delivery choice is agmsgd" "$OUT"
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
  refute grep -qF "delivery choice is agmsgd" "$OUT"
}

@test "watch stop (update never finished): the project chose monitor -> plain message regardless of agmsgd, since monitor is an explicit non-agmsgd choice" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'claude-code\t%s\tmonitor\n' "$(cd "$PROJ" && pwd -P)" > "$TEST_SKILL_DIR/run/delivery-choice"
  _agmsgd_desired on
  _run_unfinished_update_watch
  grep -qF 'installation was updated while this watcher was running' "$OUT"
  refute grep -qF 'agmsgd is on for this project' "$OUT"

  _agmsgd_desired off
  _run_unfinished_update_watch
  grep -qF 'installation was updated while this watcher was running' "$OUT"
  refute grep -qF 'agmsgd is on for this project' "$OUT"
}

@test "watch stop (update never finished): agmsgd on and no recorded choice -> stops at startup instead of ever watching the install" {
  _agmsgd_desired on
  OUT="$BATS_TEST_TMPDIR/unfinished.txt"
  : > "$OUT"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_INSTALL_INCOMPLETE_TIMEOUT=2 \
    bash "$SCRIPTS/watch.sh" sid-note-u "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF "this project's delivery choice is agmsgd, so no watch is started" "$OUT"
}

@test "watch stop (no deliveries): a registered destination stops immediately at startup regardless of agmsgd's actual health" {
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

  # 2026-11-20 decision: the stop is decided purely by run/delivery-choice
  # (here: no recorded choice, agmsgd desired on), never by checking
  # whether agmsgd is actually alive/registered -- ready and not-ready
  # both stop identically.
  OUT="$BATS_TEST_TMPDIR/native.txt"
  : > "$OUT"
  AGMSG_AGENT_PID=$$ AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-note-reg "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF "this project's delivery choice is agmsgd, so no watch is started" "$OUT"

  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_owner SET state='stopped';"
  OUT="$BATS_TEST_TMPDIR/notready.txt"
  : > "$OUT"
  AGMSG_AGENT_PID=$$ AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-note-reg "$PROJ" claude-code alice >"$OUT" 2>/dev/null 3>&- 4>&- &
  pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF "this project's delivery choice is agmsgd, so no watch is started" "$OUT"
}

# #1994 (2026-11-20 decision): grok-build and terminal-poke-eligible types
# (e.g. antigravity) are also agmsgd-reachable, not only claude-code, but
# this watcher's own stop-if-agmsgd check used to be claude-code-only --
# their resident watch.sh stayed up until a human or grok itself happened
# to kill it, then got re-armed every time, even though the project had
# explicitly chosen agmsgd. The stop is decided purely by run/delivery-choice
# (2026-11-20 decision), not by checking whether agmsgd is actually alive.
@test "watch: a grok-build seat stops immediately at startup once this project explicitly chose agmsgd" {
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" team carol grok-build "$PROJ" >/dev/null
  printf 'grok-build\t%s\tagmsgd\n' "$(cd "$PROJ" && pwd -P)" > "$TEST_SKILL_DIR/run/delivery-choice"
  OUT="$BATS_TEST_TMPDIR/grok.txt"
  : > "$OUT"
  GROK_SESSION_ID=sid-grok-note AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-grok-note "$PROJ" grok-build >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF "this project's delivery choice is agmsgd" "$OUT"
}

@test "watch: a terminal-poke-eligible seat (antigravity) stops immediately at startup once this project explicitly chose agmsgd" {
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" team dave antigravity "$PROJ" >/dev/null
  printf 'antigravity\t%s\tagmsgd\n' "$(cd "$PROJ" && pwd -P)" > "$TEST_SKILL_DIR/run/delivery-choice"
  OUT="$BATS_TEST_TMPDIR/agy.txt"
  : > "$OUT"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-agy-note "$PROJ" antigravity >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF "this project's delivery choice is agmsgd" "$OUT"
}

@test "watch: a seat with no recorded choice (any type, e.g. gemini) also stops once agmsgd is desired on, same no-choice fallback as status" {
  mkdir -p "$TEST_SKILL_DIR/run"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on';"
  bash "$SCRIPTS/join.sh" team erin gemini "$PROJ" >/dev/null
  OUT="$BATS_TEST_TMPDIR/gemini.txt"
  : > "$OUT"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-gemini-note "$PROJ" gemini >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  grep -qF "this project's delivery choice is agmsgd, so no watch is started" "$OUT"
}

@test "watch: a project that chose turn is NOT stopped by the agmsgd check, even with a stale agmsgd hint elsewhere" {
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" team frank grok-build "$PROJ" >/dev/null
  printf 'grok-build\t%s\tturn\n' "$(cd "$PROJ" && pwd -P)" > "$TEST_SKILL_DIR/run/delivery-choice"
  OUT="$BATS_TEST_TMPDIR/turn.txt"
  : > "$OUT"
  GROK_SESSION_ID=sid-turn-note AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" --max-seconds=2 sid-turn-note "$PROJ" grok-build >"$OUT" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_exit "$pid" || { kill "$pid" 2>/dev/null || true; false; }
  wait "$pid" || true
  refute grep -qF "this project's delivery choice is agmsgd" "$OUT"
}
