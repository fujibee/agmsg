#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

# Builds a real completion record for $TEST_SKILL_DIR/scripts (which
# setup_test_env already populated with a full, real copy of this repo's
# scripts/ tree, this PR's new scripts/daemon/* files included) and a real
# install.db whose meta.install_id matches it -- an end-to-end fixture for
# agmsgd's own self-verification, not a synthetic one.
_write_completion_record() {
  # watchForDrift() compares the live VERSION file against the manifest's
  # copy of it every poll cycle; without a matching VERSION file,
  # this test only avoids that drift by finishing inside the 5s poll
  # interval -- fragile on a slower machine. Write it for real.
  echo "test" > "$TEST_SKILL_DIR/VERSION"
  local install_id="test-install-id"
  mkdir -p "$TEST_SKILL_DIR/run"
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
      install_id: process.argv[2],
      gen: 1,
      version: 'test',
      bootstrap_version: bootstrapVersion,
      created_at: new Date().toISOString(),
      digest_algo: 'sha256',
      files,
    }));
  " "$TEST_SKILL_DIR" "$install_id"

  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE meta SET install_id = '$install_id', node_path = '$(command -v node)'; UPDATE daemon_intent SET desired = 'on', op_gen = 0;"
}

@test "agmsgd end-to-end: starts, answers status over its real control socket, and stops cleanly on request" {
  _write_completion_record

  node "$SCRIPTS/daemon/agmsgd" "$TEST_SKILL_DIR" on 0 > "$TEST_SKILL_DIR/run/agmsgd.stdout" 2>&1 &
  local daemon_pid=$!

  local socket="" waited=0
  while [ -z "$socket" ]; do
    socket="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT socket FROM daemon_owner WHERE state = 'ready';" 2>/dev/null)"
    [ -n "$socket" ] && break
    waited=$((waited + 1))
    if [ "$waited" -ge 100 ]; then
      echo "agmsgd never became ready; stdout was:" >&2
      cat "$TEST_SKILL_DIR/run/agmsgd.stdout" >&2
      kill "$daemon_pid" 2>/dev/null || true
      false
    fi
    sleep 0.05
  done

  run node -e "
    const net = require('node:net');
    const s = net.createConnection(process.argv[1]);
    let buf = '';
    s.on('connect', () => {
      s.write(JSON.stringify({type:'hello',protocol:1,role:'control'}) + '\n');
      s.write(JSON.stringify({type:'status'}) + '\n');
    });
    s.on('data', (c) => { buf += c.toString('utf8'); if (buf.split('\n').filter(Boolean).length >= 2) { console.log(buf); s.end(); } });
    s.on('error', (e) => { console.error(e.message); process.exit(1); });
  " "$socket"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq '"type":"hello_ok"'
  printf '%s\n' "$output" | grep -Fq '"type":"status"'

  run node -e "
    const net = require('node:net');
    const s = net.createConnection(process.argv[1]);
    s.on('connect', () => {
      s.write(JSON.stringify({type:'hello',protocol:1,role:'control'}) + '\n');
      s.write(JSON.stringify({type:'stop'}) + '\n');
    });
    s.on('close', () => process.exit(0));
    s.on('error', (e) => { console.error(e.message); process.exit(1); });
  " "$socket"
  [ "$status" -eq 0 ]

  wait "$daemon_pid"
  [ "$?" -eq 0 ]

  local final_state
  final_state="$(sqlite3 "$TEST_SKILL_DIR/run/install.db" "SELECT state FROM daemon_owner;")"
  [ "$final_state" = "none" ]
}
