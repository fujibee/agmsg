import assert from 'node:assert/strict';
import { chmodSync, cpSync, mkdirSync, mkdtempSync, existsSync, readFileSync, realpathSync, unlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { openInstallDb } from '../scripts/daemon/db.mjs';
import { ensureCodexChannelSchema } from '../scripts/daemon/channels/codex-queue-store.mjs';

const repo = fileURLToPath(new URL('../', import.meta.url));
const thread = '01a101a5-3599-7d62-a149-4c8182bcf007';
function fixture(t) {
  const root = mkdtempSync(join(tmpdir(), 'daemon-status-display-'));
  cpSync(join(repo, 'scripts'), join(root, 'scripts'), { recursive: true });
  mkdirSync(join(root, 'run'));
  mkdirSync(join(root, 'teams/test'), { recursive: true });
  const db = openInstallDb(join(root, 'run/install.db'));
  ensureCodexChannelSchema(db);
  t.after(() => db.close());
  const config = { name: 'test', agents: { alice: { registrations: [
    { type: 'codex', project: '/first' }, { type: 'codex', project: '/second' },
  ] } } };
  writeFileSync(join(root, 'teams/test/config.json'), JSON.stringify(config));
  writeFileSync(join(root, 'run/role-session.test__alice'), `type=codex\nsession=${thread}\ncodex_home=${root}\nupdated_at=${new Date().toISOString()}\n`);
  // Read-only liveness evidence points at this test process, never a real seat.
  writeFileSync(join(root, 'run/codex-bridge.test.alice.pid'), `${process.pid}\n`);
  writeFileSync(join(root, 'run/codex-bridge.test.alice.meta'), `pid=${process.pid}\ntype=codex\nproject=/second\n`);
  const status = (...flags) => execFileSync('bash', [join(root, 'scripts/daemon.sh'), 'status', ...flags], {
    encoding: 'utf8', env: { ...process.env, AGMSG_CONFIG: join(root, 'config.json') },
  });
  return { root, db, config, status };
}

function codexStartupFixture(t, names) {
  const setup = fixture(t);
  const { root, config } = setup;
  const profile = join(root, 'profile');
  mkdirSync(profile);
  config.agents = Object.fromEntries(names.map(name => [name, { registrations: [{ type: 'codex', project: root }] }]));
  writeFileSync(join(root, 'teams/test/config.json'), JSON.stringify(config));
  unlinkSync(join(root, 'run/codex-bridge.test.alice.pid'));
  const old = name => `team=test\nagent=${name}\ntype=codex\nproject=${root}\nsession=${thread}\ncodex_home=${root}\n`;
  for (const name of names) writeFileSync(join(root, `run/role-session.test__${name}`), old(name));
  const env = { ...process.env, CODEX_HOME: profile, AGMSG_SELF_NAME: 'off', AGMSG_AGENT_PID: String(process.pid),
    AGMSG_CONFIG: join(root, 'config.json'), AGMSG_STORAGE_PATH: root,
    AGMSG_CODEX_BRIDGE_LAUNCHER: '1', AGMSG_CODEX_SEAT_KEY: 'invalid!', AGMSG_CODEX_BRIDGE_APP_SERVER: '' };
  for (const key of ['CODEX_THREAD_ID', 'CODEX_SESSION_ID', 'HERDR_ENV', 'HERDR_PANE_ID', 'HERDR_SOCKET_PATH', 'TMUX', 'TMUX_PANE', 'TERM_PROGRAM', 'ORCA_TERMINAL_HANDLE', 'AGMSG_TERMINAL_DRIVER']) delete env[key];
  const start = (id, extra = {}) => execFileSync(process.platform === 'darwin' ? '/bin/bash' : 'bash', [join(root, 'scripts/session-start.sh'), 'codex', root], {
    encoding: 'utf8', input: JSON.stringify({ session_id: id }), env: { ...env, ...extra },
  });
  const startAsync = (id, extra = {}) => {
    const child = spawn(process.platform === 'darwin' ? '/bin/bash' : 'bash', [join(root, 'scripts/session-start.sh'), 'codex', root], { env: { ...env, ...extra } });
    child.stdin.end(JSON.stringify({ session_id: id }));
    let output = '';
    child.stdout.on('data', data => { output += data; });
    child.stderr.on('data', data => { output += data; });
    const timer = setTimeout(() => child.kill(), 10000);
    const done = new Promise(resolve => child.on('close', code => { clearTimeout(timer); resolve({ code, output }); }));
    t.after(() => child.kill());
    return { done };
  };
  return { ...setup, profile, old, start, startAsync, record: name => readFileSync(join(root, `run/role-session.test__${name}`), 'utf8') };
}

async function waitForFile(path) {
  const deadline = Date.now() + 5000;
  while (!existsSync(path) && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 10));
  assert.ok(existsSync(path), `timed out waiting for ${path}`);
}

test('Codex startup refreshes the sole destination from the current hook thread without replacing a live owner', async t => {
  const { root, db, profile, start, startAsync, record, old, status } = codexStartupFixture(t, ['alice']);
  const current = '01a13352-3599-7d62-a149-4c8182bcf008';
  start(current);
  assert.match(record('alice'), new RegExp(`session=${current}\\n`));
  assert.ok(record('alice').includes(`codex_home=${realpathSync(profile)}\n`));
  const add = (state, id) => db.prepare("INSERT INTO beta_codex_queue(seat, codex_home, thread, up_to, nonce, state, children, created_at) VALUES (json_array('test','alice'), ?, ?, '1', 'n', ?, '{}', datetime('now'))").run(root, id, state);
  assert.match(status(), /alice: destination recorded\n/);
  add('expired', '01a13352-3599-7d62-a149-4c8182bcf0ff');
  add('confirmed', current);
  assert.doesNotMatch(status(), /actas <name>/);
  add('expired', current);
  assert.ok(status().includes(`$${basename(root)} actas <name>`));
  const live = `${old('alice')}owner=${thread}.${process.pid}\n`;
  writeFileSync(join(root, 'run/role-session.test__alice'), live);
  assert.match(start(current), /not connected to a seat yet.*\$.* actas <name>/);
  assert.equal(record('alice'), live);

  // Gate both writers after the owner decision, but signal lock attempts before
  // acquisition. With no shared lock, B passes the old decision and overwrites A.
  const library = join(root, 'scripts/lib/role-session.sh');
  let source = readFileSync(library, 'utf8');
  source = source.replace('  agmsg_lock_acquire "$dir" || return 1', '  : > "$AGMSG_TEST_WRITE_GATE.attempt.$SESSION_ID"\n  agmsg_lock_acquire "$dir" || return 1');
  source = source.replace('  # The naming mark', '  : > "$AGMSG_TEST_WRITE_GATE.ready.$bare_sid"\n  for gate_tick in {1..500}; do [ -f "$AGMSG_TEST_WRITE_GATE.go.$bare_sid" ] && break; sleep 0.01; done\n  # The naming mark');
  writeFileSync(library, source);
  writeFileSync(join(root, 'run/role-session.test__alice'), old('alice'));
  const second = '01a13352-3599-7d62-a149-4c8182bcf010';
  const gate = join(root, 'writer-gate');
  const first = startAsync(current, { AGMSG_TEST_WRITE_GATE: gate });
  await waitForFile(`${gate}.ready.${current}`);
  const next = startAsync(second, { AGMSG_TEST_WRITE_GATE: gate });
  await waitForFile(`${gate}.attempt.${second}`);
  writeFileSync(`${gate}.go.${current}`, '');
  assert.equal((await first.done).code, 0);
  writeFileSync(`${gate}.go.${second}`, '');
  const result = await next.done;
  assert.equal(result.code, 0);
  assert.match(result.output, /not connected to a seat yet/);
  assert.match(record('alice'), new RegExp(`session=${current}\\n`));
});

test('Codex startup selects a unique matching pane and epoch, and reports ambiguity instead of guessing', t => {
  const { root, start, record, old } = codexStartupFixture(t, ['alice', 'bob']);
  const current = '01a13352-3599-7d62-a149-4c8182bcf009';
  const ref = 'tmux:/tmp/agmsg-hook-tmux:%4';
  const pane = { TMUX: '/tmp/agmsg-hook-tmux,321,0', TMUX_PANE: '%4' };
  const mark = name => `${old(name)}named_ref=${ref}\nnamed_epoch=pid=321\n`;
  writeFileSync(join(root, 'run/spawn.test__bob'), `${ref}\t${root}\tcodex\n`);
  writeFileSync(join(root, 'run/role-session.test__bob'), mark('bob'));
  start(current, pane);
  assert.match(record('bob'), new RegExp(`session=${current}\\n`));
  assert.equal(record('alice'), old('alice'));
  writeFileSync(join(root, 'run/role-session.test__bob'), mark('bob').replace('pid=321', 'pid=320'));
  assert.match(start(current, pane), /not connected to a seat yet.*\$.* actas <name>/);
  assert.match(record('bob'), /named_epoch=pid=320/);
  writeFileSync(join(root, 'run/role-session.test__bob'), mark('bob'));
  writeFileSync(join(root, 'run/spawn.test__alice'), `${ref}\t${root}\tcodex\n`);
  writeFileSync(join(root, 'run/role-session.test__alice'), mark('alice'));
  assert.match(start(current, pane), /not connected to a seat yet.*\$.* actas <name>/);
  assert.equal(record('alice'), mark('alice'));
  assert.equal(record('bob'), mark('bob'));
  assert.match(start(current), /not connected to a seat yet.*\$.* actas <name>/);
});

test('daemon status defaults to readable text and emits only JSON with --json', t => {
  const { status } = fixture(t);
  const text = status();
  assert.match(text, /agmsgd has never been started/);
  assert.doesNotMatch(text, /"exitCode"|"codex_seats"/);
  const json = JSON.parse(status('--json'));
  assert.equal(json.exitCode, 0);
  assert.equal(json.codex_seats.state, 'ok');
});

test('multiple project registrations produce one seat line', t => {
  const { status } = fixture(t);
  assert.equal(status().split('\n').filter(line => line.startsWith('Codex test/alice:')).length, 1);
});

test('bridge display uses every registered project and does not repeat a contradictory cached verdict', t => {
  const { db, status } = fixture(t);
  db.prepare('INSERT INTO beta_codex_seat VALUES (?, ?, ?, ?, ?, ?)').run(JSON.stringify(['test', 'alice']), thread, '/profile', 'blocked', 'bridge_state_unknown', new Date().toISOString());
  const text = status();
  assert.match(text, /bridge process running/);
  assert.doesNotMatch(text, /bridge.*unknown|bridge could not be verified/);
});

test('old destinations are counted by default and available with --all after current seats', t => {
  const { root, db, config, status } = fixture(t);
  config.agents.ancient = { registrations: [{ type: 'codex', project: '/old' }] };
  writeFileSync(join(root, 'teams/test/config.json'), JSON.stringify(config));
  writeFileSync(join(root, 'run/role-session.test__ancient'), 'updated_at=2020-01-01T00:00:00Z\n');
  const text = status();
  assert.doesNotMatch(text, /Codex test\/ancient:/);
  assert.match(text, /1 older destination records hidden.*--all/);
  const all = status('--all');
  assert.match(all, /Codex test\/ancient:/);
  assert.ok(all.indexOf('Codex test/alice:') < all.indexOf('Codex test/ancient:'));
  db.prepare("INSERT INTO beta_codex_queue (seat,codex_home,thread,up_to,nonce,state,children,created_at) VALUES (?, ?, ?, '{}', 'old-pending', 'pending', 'incomplete', '2020-01-01T00:00:00Z')")
    .run(JSON.stringify(['test', 'ancient']), root, thread);
  assert.match(status(), /Codex test\/ancient:.*waiting for delivery confirmation/);
});

test('never-recorded seats are not counted as older destinations, but pending evidence stays visible', t => {
  const { root, db, config, status } = fixture(t);
  config.agents = { fresh: { registrations: [{ type: 'codex', project: '/fresh' }] } };
  writeFileSync(join(root, 'teams/test/config.json'), JSON.stringify(config));
  for (const flags of [[], ['--all']]) {
    const text = status(...flags);
    assert.doesNotMatch(text, /older destination|Older destination|Codex test\/fresh:/);
    assert.match(text, /agmsgd has never been started/);
  }
  db.prepare("INSERT INTO beta_codex_queue (seat,codex_home,thread,up_to,nonce,state,children,created_at) VALUES (?, ?, ?, '{}', 'fresh-pending', 'pending', 'incomplete', '2020-01-01T00:00:00Z')")
    .run(JSON.stringify(['test', 'fresh']), root, thread);
  assert.match(status(), /Codex test\/fresh: no destination record;.*waiting for delivery confirmation/);
});

test('installer restart guidance tells users to resume, refresh their destination, and check status', () => {
  const source = readFileSync(join(repo, 'install.sh'), 'utf8');
  const fn = source.match(/agmsg_install_restart_guidance\(\) \{[\s\S]*?\n\}/)[0];
  const output = execFileSync('bash', ['-c', `${fn}\nSKILL_DIR=/tmp/isolated-install\nagmsg_install_restart_guidance`], { encoding: 'utf8' });
  assert.match(output, /close and reopen/);
  assert.match(output, /Resume the same conversation.*actas/);
  assert.match(output, /\/tmp\/isolated-install\/scripts\/agmsg daemon status/);
  assert.match(output, /does not enable agmsgd/);
  assert.equal((source.match(/^  agmsg_install_restart_guidance$/gm) ?? []).length, 1);
  assert.equal((source.match(/^agmsg_install_restart_guidance$/gm) ?? []).length, 1);
});

test('pending confirmations remain discoverable after a seat registration is removed', t => {
  const { db, root, status } = fixture(t);
  db.prepare("INSERT INTO beta_codex_queue (seat,codex_home,thread,up_to,nonce,state,children,created_at) VALUES (?, ?, ?, '{}', 'removed-pending', 'pending', 'incomplete', '2020-01-01T00:00:00Z')")
    .run(JSON.stringify(['test', 'removed']), root, thread);
  const summary = status();
  assert.match(summary, /Pending confirmations for unregistered seats: 1.*--all/);
  assert.doesNotMatch(summary, /Codex test\/removed:/);
  assert.match(status('--all'), /Codex test\/removed: unregistered; past destination; confirmation pending since 2020-01-01T00:00:00Z/);
  assert.equal(JSON.parse(status('--json')).codex_pending.length, 1);
  assert.equal(db.prepare('SELECT state FROM beta_codex_queue').get().state, 'pending');
});

test('status suppresses managed SQLite experimental notices but retains ordinary warnings', t => {
  const { root } = fixture(t);
  const entry = join(root, 'scripts/daemon/status.mjs');
  writeFileSync(entry, readFileSync(entry, 'utf8') + '\nprocess.emitWarning("SQLite is an experimental feature", "ExperimentalWarning");\nprocess.emitWarning("fixture ordinary warning");\n');
  const result = spawnSync('bash', [join(root, 'scripts/daemon.sh'), 'status'], { encoding: 'utf8', env: { ...process.env, AGMSG_CONFIG: join(root, 'config.json') } });
  assert.equal(result.status, 0);
  assert.doesNotMatch(result.stderr, /ExperimentalWarning|SQLite is an experimental/);
  assert.match(result.stderr, /fixture ordinary warning/);
});

test('launcher ignores temporary npx PATH entries and still gives the permanent command check', () => {
  const root = mkdtempSync(join(tmpdir(), 'launcher-npx-status-'));
  const transient = join(root, '_npx/temporary/node_modules/.bin');
  mkdirSync(transient, { recursive: true });
  const entry = join(transient, 'agmsg');
  writeFileSync(entry, '#!/bin/sh\n# agmsg npm bootstrapper\n');
  chmodSync(entry, 0o755);
  const output = execFileSync('bash', ['-c', 'source "$1"; agmsg_launcher_install "$2"', '_', join(repo, 'scripts/lib/agmsg-launcher.sh'), join(root, 'install')], {
    encoding: 'utf8', env: { ...process.env, AGMSG_BIN_DIR: join(root, 'bin'), PATH: `${transient}:/usr/bin:/bin:/usr/sbin:/sbin` },
  });
  assert.doesNotMatch(output, /currently resolves to|_npx|older npm/);
  assert.match(output, /open a new terminal and run: command -v agmsg/);
});
