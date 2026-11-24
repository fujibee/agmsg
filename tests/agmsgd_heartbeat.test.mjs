import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { spawn } from 'node:child_process';
import test from 'node:test';
import { openInstallDb } from '../scripts/daemon/db.mjs';
import { createControlServer } from '../scripts/daemon/control.mjs';
import { controlSocketPath } from '../scripts/daemon/owner.mjs';
import { classify } from '../scripts/daemon/status.mjs';
import { readHeartbeat, writeHeartbeat, clearHeartbeat, heartbeatPath, observeLiveness, checkStartLiveness } from '../scripts/daemon/heartbeat.mjs';

function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'agmsgd-heartbeat-'));
  mkdirSync(join(root, 'run'));
  const db = openInstallDb(join(root, 'run', 'install.db'));
  db.exec("UPDATE meta SET install_id='heartbeat-test'; UPDATE daemon_intent SET desired='on', op_gen=3; UPDATE daemon_owner SET gen=2, state='ready';");
  return { root, db, identity: { installId: 'heartbeat-test', gen: 2 } };
}
const now = Date.parse('2026-11-23T00:00:30Z');
function put(root, fields = {}) {
  writeFileSync(heartbeatPath(root), JSON.stringify({ install_id: 'heartbeat-test', gen: 2, sequence: 1, at: new Date(now).toISOString(), ...fields }));
}

test('freshness includes 20 seconds; future timestamps and foreign identities never prove liveness', () => {
  const { root, db, identity } = fixture();
  try {
    assert.equal(readHeartbeat(root, identity, now).state, 'missing');
    for (const [age, state] of [[0, 'fresh'], [20000, 'fresh'], [20001, 'stale'], [-1, 'stale']]) {
      put(root, { at: new Date(now - age).toISOString() });
      assert.equal(readHeartbeat(root, identity, now).state, state);
    }
    put(root, { install_id: 'another-install' });
    assert.equal(readHeartbeat(root, identity, now).state, 'invalid');
    put(root, { gen: 1 });
    assert.equal(readHeartbeat(root, identity, now).state, 'invalid');
    put(root, { sequence: 0 });
    assert.equal(readHeartbeat(root, identity, now).state, 'invalid');
  } finally { db.close(); }
});

test('only the current ready owner with unchanged intent publishes; an old owner cannot erase a new heartbeat', () => {
  const { root, db } = fixture();
  try {
    assert.equal(writeHeartbeat(db, root, { gen: 2, expectedOpGen: 3 }, 1, now), true);
    const first = readFileSync(heartbeatPath(root), 'utf8');
    assert.equal(writeHeartbeat(db, root, { gen: 1, expectedOpGen: 3 }, 2, now), false);
    assert.equal(writeHeartbeat(db, root, { gen: 2, expectedOpGen: 2 }, 2, now), false);
    clearHeartbeat(db, root, 1);
    assert.equal(readFileSync(heartbeatPath(root), 'utf8'), first);
    put(root, { install_id: 'replacement-install' });
    clearHeartbeat(db, root, 2);
    assert.equal(JSON.parse(readFileSync(heartbeatPath(root), 'utf8')).install_id, 'replacement-install');
    put(root);
    db.exec("UPDATE daemon_intent SET desired='off'");
    assert.equal(writeHeartbeat(db, root, { gen: 2, expectedOpGen: 3 }, 3, now), false);
    clearHeartbeat(db, root, 2);
    assert.equal(existsSync(heartbeatPath(root)), false);
  } finally { db.close(); }
});

test('a real matching socket response precedes even a stale heartbeat', async () => {
  const { root, db } = fixture();
  // Keep the Unix socket path below the macOS limit despite long TMPDIR.
  const socketRoot = process.platform === 'win32' ? root : mkdtempSync('/tmp/aghb-');
  mkdirSync(join(socketRoot, 'run'), { recursive: true });
  const socket = controlSocketPath(socketRoot, 2, 'heartbeat-test');
  const server = await createControlServer(socket, { onStatus: () => ({ gen: 2 }) });
  try {
    put(root, { at: new Date(now - 90000).toISOString() });
    const result = await observeLiveness(root, { installId: 'heartbeat-test', owner: { state: 'ready', gen: 2, socket } });
    assert.equal(result.source, 'socket');
  } finally { await server.close(); db.close(); }
});

test('a missing or wrong-generation socket falls back to heartbeat without PID inspection', async () => {
  const { root, db } = fixture();
  try {
    put(root);
    const result = await observeLiveness(root, { installId: 'heartbeat-test', owner: { state: 'ready', gen: 2, socket: 'unreachable' } }, { now: () => now, query: async () => ({ type: 'status', gen: 1 }) });
    assert.equal(result.source, 'heartbeat');
    const verdict = classify({ owner: { state: 'ready', gen: 2 }, intent: { desired: 'on' }, alive: false, reachable: false, heartbeatFresh: true });
    assert.equal(verdict.exitCode, 0);
    assert.match(verdict.text, /running.*heartbeat/);
  } finally { db.close(); }
});

for (const refresh of [false, true]) test(`stale heartbeat waits exactly once and ${refresh ? 'becomes running when refreshed' : 'allows start when still stale'}`, async () => {
  const { root, db } = fixture();
  let reads = 0, waits = [];
  const record = { installId: 'heartbeat-test', owner: { state: 'ready', gen: 2 } };
  try {
    put(root, { at: new Date(now - 21000).toISOString() });
    const result = await checkStartLiveness(root, {
      read: () => { reads++; return record; },
      observe: (r, data) => observeLiveness(r, data, { now: () => now }),
      wait: async ms => { waits.push(ms); if (refresh) put(root, { sequence: 2 }); },
    });
    assert.deepEqual(waits, [5000]);
    assert.equal(reads, 2);
    assert.equal(result.running, refresh);
  } finally { db.close(); }
});

test('no heartbeat proceeds immediately; a fresh heartbeat also never waits', async () => {
  const { root, db } = fixture();
  const options = { read: () => ({ installId: 'heartbeat-test', owner: { state: 'ready', gen: 2 } }), observe: (r, data) => observeLiveness(r, data, { now: () => now }), wait: () => assert.fail('must not wait') };
  try {
    assert.equal((await checkStartLiveness(root, options)).running, false);
    put(root);
    assert.equal((await checkStartLiveness(root, options)).running, true);
  } finally { db.close(); }
});

test('the CLI really waits five seconds and sees a heartbeat refreshed during the wait', async () => {
  const { root, db } = fixture();
  try {
    put(root, { at: new Date(Date.now() - 30000).toISOString() });
    const begin = performance.now();
    const child = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', 'scripts/daemon/heartbeat.mjs', root, '--start']);
    let output = '';
    child.stdout.on('data', b => { output += b; });
    const refresh = setTimeout(() => put(root, { sequence: 2, at: new Date().toISOString() }), 300);
    const code = await new Promise(resolve => child.on('exit', resolve));
    clearTimeout(refresh);
    assert.equal(code, 0);
    assert.equal(output.trim(), 'running:heartbeat');
    assert.ok(performance.now() - begin >= 4900);
  } finally { db.close(); }
});
