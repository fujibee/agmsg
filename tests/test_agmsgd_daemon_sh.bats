#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  DAEMON="$SCRIPTS/daemon.sh"
  AGMSGD_TEST_LAUNCH_STDERR_LOG="$TEST_SKILL_DIR/run/agmsgd.stderr.log"
  export AGMSGD_TEST_LAUNCH_STDERR_LOG
  chmod +x "$SCRIPTS/daemon/agmsgd" "$SCRIPTS/daemon/agmsgd-launch.sh"
}

teardown() {
  # Safety net: recompute this test's own unit id/plist path the same way
  # daemon.sh does and remove that exact, deterministic file -- never a
  # glob or a freshly-recomputed variable standing in for "whatever is
  # there now" (the anti-pattern is a rm target built from something that
  # could resolve to someone else's entry; this is the same install
  # re-deriving its own single, fixed name).
  #
  # Deliberately does NOT call the real launchctl here, even as a
  # last-resort cleanup: `launchctl bootstrap "gui/$(id -u)" <plist>`
  # registers into the REAL, system-wide launchd session for this real
  # user regardless of $HOME -- sandboxing $HOME only moves where the
  # PLIST FILE lives, it does nothing to where the registration itself
  # goes (found the hard way: a real unit leaked into the real
  # ~/Library/LaunchAgents even though every path in this file's own
  # $TEST_SKILL_DIR/$HOME was already sandboxed). Tests now only ever
  # drive a fake launchctl (_fake_launchctl, below), so there is nothing
  # real for this teardown to unregister; only the file needs removing.
  if [ -n "${TEST_SKILL_DIR:-}" ] && [ -f "$TEST_SKILL_DIR/run/install.db" ]; then
    local install_id label plist
    install_id="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT install_id FROM meta;" 2>/dev/null || true)"
    if [ -n "$install_id" ]; then
      local unit_id
      unit_id="$(printf '%s:%s' "$TEST_SKILL_DIR" "$install_id" | shasum -a 256 | cut -c1-12)"
      label="cc.agmsg.agmsgd.$unit_id"
      plist="$HOME/Library/LaunchAgents/$label.plist"
      rm -f "$plist"
    fi
  fi
  teardown_test_env
}

_seed_install_db() {
  mkdir -p "$TEST_SKILL_DIR/run"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  # node_path is normally recorded by `enable` -- seeded
  # here directly for tests that exercise `start` on its own, without
  # going through `enable` first.
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE meta SET install_id = 'daemon-sh-test', node_path = '$(command -v node)';"
}

_write_completion_record() {
  # watchForDrift() compares the live VERSION file against the manifest's
  # own copy of it every poll cycle; a manifest that names a version
  # with no matching VERSION file on disk is drift on the very first
  # cycle, indistinguishable from a real one.
  echo "test" > "$TEST_SKILL_DIR/VERSION"
  node -e "
    const { createHash } = require('node:crypto');
    const { readFileSync, readdirSync, writeFileSync } = require('node:fs');
    const { join } = require('node:path');
    const root = process.argv[1];
    const files = [];
    function walk(dir, rel) {
      for (const e of readdirSync(join(root, dir), { withFileTypes: true })) {
        const relPath = rel ? rel + '/' + e.name : e.name;
        if (e.isSymbolicLink()) continue;
        if (e.isDirectory()) walk(dir + '/' + e.name, relPath);
        else if (e.isFile()) {
          const digest = createHash('sha256').update(readFileSync(join(root, dir, e.name))).digest('hex');
          files.push({ path: 'scripts/' + relPath, digest });
        }
      }
    }
    walk('scripts', '');
    files.sort((a, b) => a.path < b.path ? -1 : a.path > b.path ? 1 : 0);
    const bootstrapLine = readFileSync(join(root, 'scripts/daemon/agmsgd'), 'utf8')
      .split('\n').find((l) => l.startsWith('const BOOTSTRAP_VERSION = '));
    const bootstrapVersion = Number(bootstrapLine.match(/= (\d+);/)[1]);
    writeFileSync(join(root, 'run/install-manifest.json'), JSON.stringify({
      install_id: 'daemon-sh-test',
      gen: 1,
      version: 'test',
      bootstrap_version: bootstrapVersion,
      created_at: new Date().toISOString(),
      digest_algo: 'sha256',
      files,
    }));
  " "$TEST_SKILL_DIR"
}

@test "daemon.sh status: no install.db -> exit 1" {
  run bash "$DAEMON" status
  [ "$status" -eq 1 ]
}

@test "daemon.sh status: fresh install.db, no completion record -> Node path reports 'never been started'" {
  _seed_install_db
  run bash "$DAEMON" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"never been started"* ]]
}

@test "daemon.sh status: falls back to a minimal read when Node is not on PATH" {
  _seed_install_db
  local no_node_path
  no_node_path="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -E '/(node|nodejs)([^/]*)?$' | while read -r d; do [ -x "$d/node" ] || printf '%s\n' "$d"; done | paste -sd: -)"
  PATH="$no_node_path" run bash "$DAEMON" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"no usable Node"* ]]
}

# A bare `run` has no ceiling of its own: a real hang in the command
# under test (found twice already while writing this file) stalls the
# whole suite rather than failing the one test. Backgrounds the command,
# races it against a deadline, and reports "timed out" as a status bats
# can act on rather than a wedged bats process.
_run_with_deadline() {
  local deadline_s="$1"; shift
  local outfile exitfile
  outfile="$(mktemp)"
  exitfile="$(mktemp)"
  (if "$@" > "$outfile" 2>&1; then echo 0 > "$exitfile"; else echo "$?" > "$exitfile"; fi) &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -ge $((deadline_s * 10)) ]; then
      kill -9 "$pid" 2>/dev/null || true
      output="(timed out after ${deadline_s}s; partial output: $(cat "$outfile" 2>/dev/null))"
      status=124
      rm -f "$outfile" "$exitfile"
      return 0
    fi
    sleep 0.1
  done
  wait "$pid" 2>/dev/null || true
  output="$(cat "$outfile")"
  status="$(cat "$exitfile")"
  rm -f "$outfile" "$exitfile"
}

_assert_start_result() {
  local expected="$1"
  if [ "$status" -ne 0 ] || [[ "$output" != *"$expected"* ]]; then
    printf '\n--- run/agmsgd.log ---\n' >&2
    if [ -f "$TEST_SKILL_DIR/run/agmsgd.log" ]; then
      tail -n 80 "$TEST_SKILL_DIR/run/agmsgd.log" >&2
    else
      printf '(not present)\n' >&2
    fi
    printf '\n--- run/agmsgd.stderr.log ---\n' >&2
    if [ -f "$AGMSGD_TEST_LAUNCH_STDERR_LOG" ]; then
      tail -n 80 "$AGMSGD_TEST_LAUNCH_STDERR_LOG" >&2
    else
      printf '(not present)\n' >&2
    fi
  fi
  [ "$status" -eq 0 ]
  [[ "$output" == *"$expected"* ]]
}

@test "daemon.sh start: a real run against the real entrypoint becomes ready" {
  _seed_install_db
  _write_completion_record
  _run_with_deadline 15 bash "$DAEMON" start
  _assert_start_result 'running'
  bash "$DAEMON" stop >/dev/null 2>&1 || true
}

@test "daemon.sh status: reports running while the real daemon is up" {
  _seed_install_db
  _write_completion_record
  _run_with_deadline 15 bash "$DAEMON" start
  [ "$status" -eq 0 ]

  _run_with_deadline 10 bash "$DAEMON" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"* ]] || [[ "$output" == *'"exitCode":0'* ]]
  bash "$DAEMON" stop >/dev/null 2>&1 || true
}

@test "daemon.sh start: an install that never recorded Node finds and records it, then starts" {
  _seed_install_db
  _write_completion_record
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE meta SET node_path = NULL, node_version = NULL;"
  _run_with_deadline 15 bash "$DAEMON" start
  _assert_start_result 'running'
  [ -x "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT node_path FROM meta;")" ]
  bash "$DAEMON" stop >/dev/null 2>&1 || true
}

@test "daemon.sh start: a second start while already running is a no-op" {
  _seed_install_db
  _write_completion_record
  _run_with_deadline 15 bash "$DAEMON" start
  _assert_start_result 'running'

  _run_with_deadline 10 bash "$DAEMON" start
  _assert_start_result 'already running'
  bash "$DAEMON" stop >/dev/null 2>&1 || true
}

@test "daemon.sh stop: stops a real running daemon, and a second stop is a no-op" {
  _seed_install_db
  _write_completion_record
  local iteration
  for iteration in 1 2 3; do
    _run_with_deadline 15 bash "$DAEMON" start
    _assert_start_result 'running'

    _run_with_deadline 10 bash "$DAEMON" status
    [ "$status" -eq 0 ]
    [[ "$output" == *"running"* ]] || [[ "$output" == *'"exitCode":0'* ]]

    _run_with_deadline 10 bash "$DAEMON" start
    [ "$status" -eq 0 ]
    [[ "$output" == *"already running"* ]]

    _run_with_deadline 15 bash "$DAEMON" stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"stopped"* ]]

    _run_with_deadline 10 bash "$DAEMON" stop
    [ "$status" -eq 0 ]
    [[ "$output" == *"already stopped"* ]]
  done
}

# A fake launchctl, never the real one: if a bats run is killed externally
# mid-test, it skips its own teardown, and the
# real gui launchd domain is not this test's to leave litter in even when
# nothing goes wrong -- exactly this happened once already while writing
# this file. Real registration is exercised only by hand, never from an
# automated run on any platform.
_fake_launchctl() {
  mkdir -p "$TEST_SKILL_DIR/fake-launchd"
  cat > "$TEST_SKILL_DIR/fake-launchd/launchctl" <<'EOF'
#!/usr/bin/env bash
# Records enough for the test to tell load/bootstrap from unload/bootout
# apart, against a marker file instead of the real launchd.
if [ -n "${AGMSGD_FAKE_OP_LOCK_DB:-}" ]; then
  if ! sqlite3 -cmd 'PRAGMA busy_timeout=0;' "$AGMSGD_FAKE_OP_LOCK_DB" 'BEGIN EXCLUSIVE; ROLLBACK;' >/dev/null 2>&1; then
    printf 'locked %s\n' "$1" >> "${AGMSGD_FAKE_LAUNCHD_EVENTS:?}"
  else
    printf 'unlocked %s\n' "$1" >> "${AGMSGD_FAKE_LAUNCHD_EVENTS:?}"
  fi
fi
printf 'call %s\n' "$*" >> "${AGMSGD_FAKE_LAUNCHD_EVENTS:-/dev/null}"
case "$1" in
  bootstrap|load) touch "${AGMSGD_FAKE_LAUNCHD_MARKER:?}" ;;
  bootout|unload)
    [ "${AGMSGD_FAKE_LAUNCHD_FAIL_UNREGISTER:-0}" != 1 ] || exit 1
    rm -f "${AGMSGD_FAKE_LAUNCHD_MARKER:?}"
    ;;
  list) [ -f "${AGMSGD_FAKE_LAUNCHD_MARKER:?}" ] ;;
  kickstart)
    printf '%s\n' "$*" >> "${AGMSGD_FAKE_LAUNCHD_EVENTS:?}"
    if [ "${AGMSGD_FAKE_LAUNCHD_FAIL_UNREGISTER:-0}" = 1 ]; then exit 1; fi
    bash "${AGMSGD_TEST_LAUNCHER:?}" </dev/null >/dev/null 2>&1 3>&- &
    ;;
esac
EOF
  chmod +x "$TEST_SKILL_DIR/fake-launchd/launchctl"
  echo "$TEST_SKILL_DIR/fake-launchd/launchctl"
}

_fake_windows_manager() {
  mkdir -p "$TEST_SKILL_DIR/fake-windows"
  cat > "$TEST_SKILL_DIR/fake-windows/uname" <<'EOF'
#!/usr/bin/env bash
echo MINGW64_NT-10.0
EOF
  cat > "$TEST_SKILL_DIR/fake-windows/schtasks" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  /Create)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = /XML ]; then cp "$2" "${AGMSGD_FAKE_TASK_XML:?}"; fi
      shift
    done
    touch "${AGMSGD_FAKE_TASK_MARKER:?}"
    ;;
  /Run) bash "${AGMSGD_TEST_LAUNCHER:?}" </dev/null >/dev/null 2>&1 3>&- & ;;
  /Delete) rm -f "${AGMSGD_FAKE_TASK_MARKER:?}" ;;
esac
EOF
  # Passes the path through and records what was asked to be converted: the
  # native sqlite3 on Windows cannot open a Git Bash path named inside SQL.
  cat > "$TEST_SKILL_DIR/fake-windows/cygpath" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "${AGMSGD_FAKE_CYGPATH_LOG:?}"
if [ "$1 $2" = "-m /" ]; then printf '%s/\n' "${AGMSGD_FAKE_GIT_ROOT:?}"; exit 0; fi
printf '%s\n' "$2"
EOF
  chmod +x "$TEST_SKILL_DIR/fake-windows/uname" "$TEST_SKILL_DIR/fake-windows/schtasks" "$TEST_SKILL_DIR/fake-windows/cygpath"
}

@test "daemon.sh enable/disable: registers a resident unit (via a fake launchctl on macOS) and cleans it up" {
  [ "$(uname -s)" = "Darwin" ] || skip "this test's fake stands in for launchd specifically"
  _seed_install_db
  _write_completion_record
  local fake_launchctl marker events
  fake_launchctl="$(_fake_launchctl)"
  marker="$TEST_SKILL_DIR/fake-launchd/registered"
  events="$TEST_SKILL_DIR/fake-launchd/events"

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" AGMSGD_FAKE_LAUNCHD_EVENTS="$events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" AGMSGD_TEST_LAUNCHER="$SCRIPTS/daemon/agmsgd-launch.sh" \
    run bash "$DAEMON" enable
  [ "$status" -eq 0 ]

  local install_id unit_id label plist
  install_id="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT install_id FROM meta;")"
  unit_id="$(printf '%s:%s' "$TEST_SKILL_DIR" "$install_id" | shasum -a 256 | cut -c1-12)"
  label="cc.agmsg.agmsgd.$unit_id"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  [ -f "$plist" ]
  [ -f "$marker" ]

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" AGMSGD_FAKE_LAUNCHD_EVENTS="$events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" \
    run bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ ! -f "$plist" ]
  [ ! -f "$marker" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT state FROM daemon_owner;")" = "none" ]
  grep -q '^locked bootstrap$' "$events"
  grep -q '^locked bootout$' "$events"

  # A record from an older version (boot id in kern.boottime seconds) whose
  # pid still exists and that has no control socket cannot be checked; disable
  # drops it rather than failing.
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_owner SET state='ready', executor_pid=$$, executor_boot_id='1', socket=NULL, executor_started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now');"
  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" AGMSGD_FAKE_LAUNCHD_EVENTS="$events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" \
    run bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT state FROM daemon_owner;")" = "none" ]
}

@test "daemon.sh: an install.db with only the 2-column meta -- status only reads, enable and disable bring it up to date" {
  [ "$(uname -s)" = "Darwin" ] || skip "this test's fake stands in for launchd specifically"
  mkdir -p "$TEST_SKILL_DIR/run"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "CREATE TABLE meta (schema_version INTEGER NOT NULL, install_id TEXT NOT NULL); INSERT INTO meta VALUES (1, 'daemon-sh-test');"
  _write_completion_record
  local fake_launchctl
  fake_launchctl="$(_fake_launchctl)"

  run bash "$DAEMON" status
  [ "$status" -eq 0 ]
  [ "${output#*not in use yet}" != "$output" ]
  [ -z "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT name FROM sqlite_master WHERE name='daemon_owner';")" ]
  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$TEST_SKILL_DIR/fake-launchd/registered" AGMSGD_FAKE_LAUNCHD_EVENTS="$TEST_SKILL_DIR/fake-launchd/events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" AGMSGD_TEST_LAUNCHER="$SCRIPTS/daemon/agmsgd-launch.sh" \
    run bash "$DAEMON" enable
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT install_id FROM meta;")" = "daemon-sh-test" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT desired FROM daemon_intent;")" = "on" ]
  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$TEST_SKILL_DIR/fake-launchd/registered" AGMSGD_FAKE_LAUNCHD_EVENTS="$TEST_SKILL_DIR/fake-launchd/events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" \
    run bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  printf 'not a sqlite database' > "$TEST_SKILL_DIR/run/install.db"
  run bash "$DAEMON" status
  [ "$status" -ne 0 ]
  [ "${output#*not in use yet}" = "$output" ]
}

@test "daemon.sh start: stale ready state asks the registered manager to start the service" {
  [ "$(uname -s)" = "Darwin" ] || skip "this test's fake stands in for launchd specifically"
  _seed_install_db
  _write_completion_record
  local fake_launchctl marker events install_id unit_id label plist
  fake_launchctl="$(_fake_launchctl)"
  marker="$TEST_SKILL_DIR/fake-launchd/registered"
  events="$TEST_SKILL_DIR/fake-launchd/events"
  install_id="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT install_id FROM meta;")"
  unit_id="$(printf '%s:%s' "$TEST_SKILL_DIR" "$install_id" | shasum -a 256 | cut -c1-12)"
  label="cc.agmsg.agmsgd.$unit_id"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$(dirname "$plist")"
  : > "$plist"
  touch "$marker"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on'; UPDATE daemon_owner SET state='ready', gen=1, executor_pid=99999999, executor_boot_id='stale', socket='$TEST_SKILL_DIR/run/missing.sock';"

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" AGMSGD_FAKE_LAUNCHD_EVENTS="$events" AGMSGD_TEST_LAUNCHER="$SCRIPTS/daemon/agmsgd-launch.sh" \
    run bash "$DAEMON" start
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'running'
  grep -q 'kickstart gui/' "$events"
  bash "$DAEMON" stop >/dev/null 2>&1 || true
}

@test "daemon.sh disable: unregister failure is reported and preserves registration" {
  [ "$(uname -s)" = "Darwin" ] || skip "this test's fake stands in for launchd specifically"
  _seed_install_db
  _write_completion_record
  local fake_launchctl marker events install_id unit_id label plist
  fake_launchctl="$(_fake_launchctl)"
  marker="$TEST_SKILL_DIR/fake-launchd/registered"
  events="$TEST_SKILL_DIR/fake-launchd/events"
  install_id="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT install_id FROM meta;")"
  unit_id="$(printf '%s:%s' "$TEST_SKILL_DIR" "$install_id" | shasum -a 256 | cut -c1-12)"
  label="cc.agmsg.agmsgd.$unit_id"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  mkdir -p "$(dirname "$plist")"
  : > "$plist"
  touch "$marker"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on';"

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" AGMSGD_FAKE_LAUNCHD_EVENTS="$events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" AGMSGD_FAKE_LAUNCHD_FAIL_UNREGISTER=1 \
    run bash "$DAEMON" disable
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'could not unregister launchd service'
  [ -f "$plist" ]
  [ -f "$marker" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT desired FROM daemon_intent;")" = "on" ]
  grep -q '^locked bootout$' "$events"
}

@test "daemon.sh disable: a running daemon is stopped before the service is unregistered, so its record returns to none" {
  _seed_install_db
  _write_completion_record
  _run_with_deadline 15 bash "$DAEMON" start
  [ "$status" -eq 0 ]
  mkdir -p "$TEST_SKILL_DIR/fake-linux"
  printf '#!/usr/bin/env bash\necho Linux\n' > "$TEST_SKILL_DIR/fake-linux/uname"
  # Like systemd, "disable --now" terminates the daemon and waits for it to go.
  # The pid is read now: install.db cannot be read while disable holds the lock.
  local daemon_pid
  daemon_pid="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT executor_pid FROM daemon_owner;")"
  [ -n "$daemon_pid" ]
  cat > "$TEST_SKILL_DIR/fake-linux/systemctl" <<EOF
#!/usr/bin/env bash
case "\$2" in
  disable)
    pid=$daemon_pid
    if kill -0 "\$pid" 2>/dev/null; then
      kill -TERM "\$pid"
      for _ in \$(seq 1 150); do kill -0 "\$pid" 2>/dev/null || break; sleep 0.1; done
    fi ;;
esac
exit 0
EOF
  chmod +x "$TEST_SKILL_DIR/fake-linux/uname" "$TEST_SKILL_DIR/fake-linux/systemctl"
  local unit_id unit
  unit_id="$(printf '%s:%s' "$TEST_SKILL_DIR" daemon-sh-test | shasum -a 256 | cut -c1-12)"
  unit="$HOME/.config/systemd/user/agmsgd-$unit_id.service"
  mkdir -p "$(dirname "$unit")"
  : > "$unit"

  PATH="$TEST_SKILL_DIR/fake-linux:$PATH" AGMSGD_SYSTEMCTL="$TEST_SKILL_DIR/fake-linux/systemctl" \
    _run_with_deadline 40 bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT state FROM daemon_owner;")" = "none" ]
  [ ! -e "$unit" ]
}

@test "daemon.sh disable: only touches the intent and service its own step owns" {
  _seed_install_db
  _write_completion_record
  local db="$TEST_SKILL_DIR/run/install.db" fns="$SCRIPTS/daemon-fns.sh"
  # daemon.sh without its trailing dispatch, so the steps can be overridden.
  awk '/^case "\$\{1:-\}" in/ {exit} {print}' "$DAEMON" > "$fns"
  # (a) already off, and unregistering fails: the intent must stay off.
  sqlite3 "$db" "UPDATE daemon_intent SET desired='off';"
  run bash -c 'set -u; source "$1"; _unregister() { return 1; }; cmd_disable' _ "$fns"
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$db" "SELECT desired FROM daemon_intent;")" = "off" ]
  # (b) a newer enable lands while disable waits: its service is left alone.
  sqlite3 "$db" "UPDATE daemon_intent SET desired='on';"
  DB="$db" MARKER="$TEST_SKILL_DIR/unregistered" run bash -c 'set -u; source "$1"; _unregister() { echo unregistered >> "$MARKER"; }
    _wait_owner_none() { sqlite3 "$DB" "UPDATE daemon_intent SET desired='"'"'on'"'"', op_gen = op_gen + 1;"; printf none; }
    cmd_disable' _ "$fns"
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_SKILL_DIR/unregistered" ]
  [ "$(sqlite3 "$db" "SELECT desired FROM daemon_intent;")" = "on" ]
}

@test "daemon.sh start: an empty meta.codex_path is filled from PATH, and a path already recorded is kept" {
  _seed_install_db
  _write_completion_record
  local db="$TEST_SKILL_DIR/run/install.db" fake="$TEST_SKILL_DIR/fake-codex"
  mkdir -p "$fake"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake/codex"
  chmod +x "$fake/codex"
  [ -z "$(sqlite3 "$db" "SELECT COALESCE(codex_path, '') FROM meta;")" ]
  AGMSG_REAL_CODEX="$fake/codex" _run_with_deadline 15 bash "$DAEMON" start
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT codex_path FROM meta;")" = "$(cd "$fake" && pwd -P)/codex" ]
  bash "$DAEMON" stop
  sqlite3 "$db" "UPDATE meta SET codex_path = '/already/recorded/codex';"
  AGMSG_REAL_CODEX="$fake/codex" _run_with_deadline 15 bash "$DAEMON" start
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT codex_path FROM meta;")" = "/already/recorded/codex" ]
}

@test "daemon.sh start --only-if-op-gen: a stop or disable after that op_gen is not undone" {
  _seed_install_db
  _write_completion_record
  local db="$TEST_SKILL_DIR/run/install.db" seen
  sqlite3 "$db" "UPDATE daemon_intent SET desired = 'on', op_gen = op_gen + 1;"
  seen="$(sqlite3 "$db" "SELECT op_gen FROM daemon_intent;")"
  # a person turns it off after the update looked
  sqlite3 "$db" "UPDATE daemon_intent SET desired = 'off', op_gen = op_gen + 1, set_by = 'disable';"
  _run_with_deadline 15 bash "$DAEMON" start --only-if-op-gen "$seen"
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT desired FROM daemon_intent;")" = "off" ]
  [ "$(sqlite3 "$db" "SELECT state FROM daemon_owner;")" = "none" ]
  [ "${output#*left as it is now}" != "$output" ]
}

@test "daemon.sh Windows registration writes the declared UTF-16 task XML" {
  _seed_install_db
  _write_completion_record
  _fake_windows_manager
  local capture marker
  capture="$TEST_SKILL_DIR/fake-windows/captured.xml"
  marker="$TEST_SKILL_DIR/fake-windows/registered"

  export AGMSGD_FAKE_CYGPATH_LOG="$TEST_SKILL_DIR/fake-windows/cygpath.log"
  export AGMSGD_FAKE_GIT_ROOT="$TEST_SKILL_DIR/fake-windows/Git & Root"
  # Without a Git Bash to name, nothing is registered.
  PATH="$TEST_SKILL_DIR/fake-windows:$PATH" AGMSGD_SCHTASKS="$TEST_SKILL_DIR/fake-windows/schtasks" AGMSGD_FAKE_TASK_XML="$capture" AGMSGD_FAKE_TASK_MARKER="$marker" AGMSGD_TEST_LAUNCHER="$SCRIPTS/daemon/agmsgd-launch.sh" \
    _run_with_deadline 15 bash "$DAEMON" enable
  [ "$status" -ne 0 ]
  grep -q "cannot find Git Bash" <<<"$output"
  [ ! -f "$marker" ]
  mkdir -p "$AGMSGD_FAKE_GIT_ROOT/bin"
  : > "$AGMSGD_FAKE_GIT_ROOT/bin/bash.exe"
  PATH="$TEST_SKILL_DIR/fake-windows:$PATH" AGMSGD_SCHTASKS="$TEST_SKILL_DIR/fake-windows/schtasks" AGMSGD_FAKE_TASK_XML="$capture" AGMSGD_FAKE_TASK_MARKER="$marker" AGMSGD_TEST_LAUNCHER="$SCRIPTS/daemon/agmsgd-launch.sh" \
    _run_with_deadline 15 bash "$DAEMON" enable
  [ "$status" -eq 0 ]
  # The task runs Git Bash by full path, not a bare bash.exe that Task
  # Scheduler would resolve to WSL's launcher in System32.
  # A & in the path is escaped in the XML.
  iconv -f UTF-16LE -t UTF-8 "$capture" | grep -Fq "<Command>${AGMSGD_FAKE_GIT_ROOT//&/&amp;}/bin/bash.exe</Command>"
  # Every path named inside SQL went through the native-path conversion.
  grep -Fq "$TEST_SKILL_DIR/run/install-manifest.json" "$AGMSGD_FAKE_CYGPATH_LOG"
  grep -Fq "$TEST_SKILL_DIR/run/install.db" "$AGMSGD_FAKE_CYGPATH_LOG"
  [ "$(od -An -tx1 -N2 "$capture" | tr -d ' \n')" = "fffe" ]
  iconv -f UTF-16LE -t UTF-8 "$capture" | grep -q 'encoding="UTF-16"'

  PATH="$TEST_SKILL_DIR/fake-windows:$PATH" AGMSGD_SCHTASKS="$TEST_SKILL_DIR/fake-windows/schtasks" AGMSGD_FAKE_TASK_MARKER="$marker" \
    _run_with_deadline 15 bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ ! -f "$marker" ]
  [ ! -f "$TEST_SKILL_DIR/run/agmsgd-$(_unit_id).xml" ]
}

# A wrapper named `sqlite3`, placed ahead of the real one on PATH, that
# behaves exactly like the real binary except every line of its stdout gets a
# synthetic \r appended right before the \n -- simulating the \r\n Windows'
# sqlite3.exe emits at each row boundary (measured: 3.53.4). Same technique as
# test_sqlite_crlf.bats's `_stub_sqlite3_crlf`, duplicated locally rather than
# shared: bats only loads `test_helper` automatically, not another test file.
#
# The real binary's path is resolved HERE, before this directory is ever
# prepended to PATH, so the wrapper's exec target does not resolve back to
# itself once PATH includes this directory.
_stub_sqlite3_crlf() {
  local dir="$TEST_SKILL_DIR/crlfbin" real
  real="$(command -v sqlite3)"
  mkdir -p "$dir"
  cat > "$dir/sqlite3" <<EOF
#!/usr/bin/env bash
set -o pipefail
# -u (unbuffered): this stub also stands in for the interactive coprocess
# _with_op_lock_run drives over anonymous pipes (#1631/#1667) -- several
# round trips on the SAME long-lived sqlite3 process, not one shot read to
# EOF. sed's default full buffering on a non-tty stdout would sit on each
# reply until enough output piled up or the process exited, which never
# happens here before the 10s read timeout, hanging every round trip.
"$real" "\$@" | sed -u 's/\$/\r/'
EOF
  chmod +x "$dir/sqlite3"
  printf '%s' "$dir"
}

@test "daemon.sh enable: acquires the install operation lock when sqlite3 answers with CRLF line endings (Windows sqlite3.exe)" {
  _seed_install_db
  _write_completion_record
  _fake_windows_manager
  local crlf_stub capture marker
  crlf_stub="$(_stub_sqlite3_crlf)"
  capture="$TEST_SKILL_DIR/fake-windows/captured.xml"
  marker="$TEST_SKILL_DIR/fake-windows/registered"
  export AGMSGD_FAKE_CYGPATH_LOG="$TEST_SKILL_DIR/fake-windows/cygpath.log"
  export AGMSGD_FAKE_GIT_ROOT="$TEST_SKILL_DIR/fake-windows/Git Root"
  mkdir -p "$AGMSGD_FAKE_GIT_ROOT/bin"
  : > "$AGMSGD_FAKE_GIT_ROOT/bin/bash.exe"

  # crlf_stub ahead of fake-windows ahead of the real PATH: `_os` still sees
  # the fake-windows `uname` (routing _with_op_lock_run into the coproc
  # branch #1631/#1667 added for native Windows sqlite3), while every
  # `sqlite3` call -- including the coproc's own replies on fd 9 -- goes
  # through the CRLF stub instead of the real, LF-only Linux binary.
  PATH="$crlf_stub:$TEST_SKILL_DIR/fake-windows:$PATH" AGMSGD_SCHTASKS="$TEST_SKILL_DIR/fake-windows/schtasks" AGMSGD_FAKE_TASK_XML="$capture" AGMSGD_FAKE_TASK_MARKER="$marker" AGMSGD_TEST_LAUNCHER="$SCRIPTS/daemon/agmsgd-launch.sh" \
    _run_with_deadline 15 bash "$DAEMON" enable
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "could not acquire the install operation lock" || false
  [ -f "$marker" ]
  [ "$(PATH="$crlf_stub:$PATH" sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT desired FROM daemon_intent;" | tr -d '\r')" = "on" ]

  PATH="$crlf_stub:$TEST_SKILL_DIR/fake-windows:$PATH" AGMSGD_SCHTASKS="$TEST_SKILL_DIR/fake-windows/schtasks" AGMSGD_FAKE_TASK_MARKER="$marker" \
    _run_with_deadline 15 bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ ! -f "$marker" ]
}

# `/bin/bash` on this runner's macOS (Apple's stock, 3.2.57) still inherits a
# `read`'s temporary `IFS='|'` into a process substitution's subshell, while
# the bash on PATH here (homebrew, 5.x) does not -- the exact fork review
# flagged on #1668 (_install_generation's `IFS='|' read ... < <(agmsg_sqlite
# ...)`). daemon.sh's `#!/usr/bin/env bash` resolves to whichever bash is
# first on PATH, so this only reproduces under the shell that actually has
# the old behavior; skipped where /bin/bash is unavailable or already fixed
# upstream (a future macOS could ship a non-vulnerable /bin/bash).
@test "daemon.sh enable: _install_generation's manifest read survives a bash whose process substitution inherits IFS" {
  [ "$(uname -s)" = "Darwin" ] || skip "this test's fake stands in for launchd specifically"
  [ -x /bin/bash ] || skip "no /bin/bash on this runner to exercise the old IFS-inheriting behavior"
  /bin/bash -c '
    f() { case "$IFS" in *"|"*) echo inherited ;; *) echo not-inherited ;; esac; }
    IFS="|" read -r seen < <(f)
    [ "$seen" = inherited ]
  ' || skip "/bin/bash here does not inherit IFS into process substitution; nothing to reproduce"
  _seed_install_db
  _write_completion_record
  local fake_launchctl marker events
  fake_launchctl="$(_fake_launchctl)"
  marker="$TEST_SKILL_DIR/fake-launchd/registered"
  events="$TEST_SKILL_DIR/fake-launchd/events"

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" AGMSGD_FAKE_LAUNCHD_EVENTS="$events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" AGMSGD_TEST_LAUNCHER="$SCRIPTS/daemon/agmsgd-launch.sh" \
    run /bin/bash "$DAEMON" enable
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qi "could not read this install's record" || false
  [ -f "$marker" ]

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" AGMSGD_FAKE_LAUNCHD_EVENTS="$events" AGMSGD_FAKE_OP_LOCK_DB="$TEST_SKILL_DIR/run/install-op.lock.db" \
    run /bin/bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ ! -f "$marker" ]
}

@test "daemon.sh enable/disable: without a systemd user manager enable explains and changes nothing, disable still works" {
  _seed_install_db
  _write_completion_record
  mkdir -p "$TEST_SKILL_DIR/fake-linux"
  printf '#!/usr/bin/env bash\necho Linux\n' > "$TEST_SKILL_DIR/fake-linux/uname"
  chmod +x "$TEST_SKILL_DIR/fake-linux/uname"
  local before
  before="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT coalesce(desired, '') || '|' || (SELECT node_path FROM meta) FROM daemon_intent;")"

  PATH="$TEST_SKILL_DIR/fake-linux:$PATH" AGMSGD_SYSTEMCTL="$TEST_SKILL_DIR/no-such-systemctl" \
    run bash "$DAEMON" enable
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "systemd user services are not available"
  ! echo "$output" | grep -q "command not found" || false
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT coalesce(desired, '') || '|' || (SELECT node_path FROM meta) FROM daemon_intent;")" = "$before" ]
  [ ! -e "$HOME/.config/systemd/user" ]

  # A unit file left by an earlier enable must not make disable fail either.
  local unit_id unit
  unit_id="$(printf '%s:%s' "$TEST_SKILL_DIR" daemon-sh-test | shasum -a 256 | cut -c1-12)"
  unit="$HOME/.config/systemd/user/agmsgd-$unit_id.service"
  mkdir -p "$(dirname "$unit")"
  : > "$unit"
  PATH="$TEST_SKILL_DIR/fake-linux:$PATH" AGMSGD_SYSTEMCTL="$TEST_SKILL_DIR/no-such-systemctl" \
    run bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ ! -e "$unit" ]
}
