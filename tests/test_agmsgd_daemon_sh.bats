#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  DAEMON="$SCRIPTS/daemon.sh"
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
  # node_path is normally recorded by `enable` (T3 "常駐の登録") -- seeded
  # here directly for tests that exercise `start` on its own, without
  # going through `enable` first.
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE meta SET install_id = 'daemon-sh-test', node_path = '$(command -v node)';"
}

_write_completion_record() {
  # watchForDrift() compares the live VERSION file against the manifest's
  # own copy of it every poll cycle (T3); a manifest that names a version
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
  ("$@" > "$outfile" 2>&1; echo "$?" > "$exitfile") &
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

@test "daemon.sh start: a real run against the real entrypoint becomes ready" {
  _seed_install_db
  _write_completion_record
  _run_with_deadline 15 bash "$DAEMON" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"running"* ]]
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

@test "daemon.sh start: a second start while already running is a no-op" {
  _seed_install_db
  _write_completion_record
  _run_with_deadline 15 bash "$DAEMON" start
  [ "$status" -eq 0 ]

  _run_with_deadline 10 bash "$DAEMON" start
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  bash "$DAEMON" stop >/dev/null 2>&1 || true
}

@test "daemon.sh stop: stops a real running daemon, and a second stop is a no-op" {
  _seed_install_db
  _write_completion_record
  _run_with_deadline 15 bash "$DAEMON" start
  [ "$status" -eq 0 ]

  _run_with_deadline 15 bash "$DAEMON" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"stopped"* ]]

  _run_with_deadline 10 bash "$DAEMON" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"already stopped"* ]]
}

# A fake launchctl, never the real one (T6 #3): a bats run
# that gets killed externally mid-test skips its own teardown, and the
# real gui launchd domain is not this test's to leave litter in even when
# nothing goes wrong -- exactly this happened once already while writing
# this file (a real unit left behind after a hung test was killed by
# hand, cleaned up manually). Real registration is exercised only by hand
# (T6 #3), never from an automated run, on any platform.
_fake_launchctl() {
  mkdir -p "$TEST_SKILL_DIR/fake-launchd"
  cat > "$TEST_SKILL_DIR/fake-launchd/launchctl" <<'EOF'
#!/usr/bin/env bash
# Records enough for the test to tell load/bootstrap from unload/bootout
# apart, against a marker file instead of the real launchd.
case "$1" in
  bootstrap|load) touch "${AGMSGD_FAKE_LAUNCHD_MARKER:?}" ;;
  bootout|unload) rm -f "${AGMSGD_FAKE_LAUNCHD_MARKER:?}" ;;
  list) [ -f "${AGMSGD_FAKE_LAUNCHD_MARKER:?}" ] ;;
esac
EOF
  chmod +x "$TEST_SKILL_DIR/fake-launchd/launchctl"
  echo "$TEST_SKILL_DIR/fake-launchd/launchctl"
}

@test "daemon.sh enable/disable: registers a resident unit (via a fake launchctl on macOS) and cleans it up" {
  [ "$(uname -s)" = "Darwin" ] || skip "this test's fake stands in for launchd specifically"
  _seed_install_db
  _write_completion_record
  local fake_launchctl marker
  fake_launchctl="$(_fake_launchctl)"
  marker="$TEST_SKILL_DIR/fake-launchd/registered"

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" \
    run bash "$DAEMON" enable
  [ "$status" -eq 0 ]

  local install_id unit_id label plist
  install_id="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT install_id FROM meta;")"
  unit_id="$(printf '%s:%s' "$TEST_SKILL_DIR" "$install_id" | shasum -a 256 | cut -c1-12)"
  label="cc.agmsg.agmsgd.$unit_id"
  plist="$HOME/Library/LaunchAgents/$label.plist"
  [ -f "$plist" ]
  [ -f "$marker" ]

  AGMSGD_LAUNCHCTL="$fake_launchctl" AGMSGD_FAKE_LAUNCHD_MARKER="$marker" \
    run bash "$DAEMON" disable
  [ "$status" -eq 0 ]
  [ ! -f "$plist" ]
  [ ! -f "$marker" ]
}
