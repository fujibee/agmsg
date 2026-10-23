import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { chmodSync, mkdtempSync, mkdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import { DatabaseSync } from 'node:sqlite';
import test from 'node:test';

import {
  classifyCodexSeat,
  inboxNudge,
  newNonce,
  readQueuedItem,
  readRolloutNonce,
  resolvePendingQueue,
  rolloutStateOf,
  runCodexQueue,
  verifyPendingDelivery,
} from '../scripts/daemon/channels/codex-queue-io.mjs';
import {
  CODEX_CHANNEL_SCHEMA,
  ensureCodexChannelSchema,
  listCodexRegistrations,
  messageStorePath,
  readRoleSession,
  readStorageDriver,
  readUnreadSnapshot,
} from '../scripts/daemon/channels/codex-queue-store.mjs';
import { createCodexQueueChannel } from '../scripts/daemon/channels/codex-queue.mjs';
import { openInstallDb } from '../scripts/daemon/db.mjs';
import { readOwnerAndIntentReadOnly } from '../scripts/daemon/status.mjs';
import { processStartWitness } from '../scripts/daemon/channels/process-group.mjs';
import { checkWindowsCodexQueueGate, resolveWindowsCodexExe } from '../scripts/daemon/channels/windows-codex-queue.mjs';

const thread = '01a0ea97-c011-73f3-8470-fd59db15adba';
const itemId = '01a0ea98-2235-7f02-b477-7c130e602fcd';
const notYetVisibleItemId = '01a0ea99-3509-7d03-a588-8d241f7130de';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-codex-queue-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function fakeChild({ stdout, stderr = '', code = 0, autoClose = true }) {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.pid = 4242;
  child.kill = () => true;
  if (autoClose) {
    setImmediate(() => {
      child.emit('spawn');
      child.stdout.end(stdout);
      child.stderr.end(stderr);
      child.emit('close', code, null);
    });
  }
  return child;
}

function executableFixture(t) {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'));
  const home = path.join(root, 'profile');
  mkdirSync(path.join(home, 'sessions'), { recursive: true });
  writeFileSync(path.join(home, 'sessions', `rollout-test-${thread}.jsonl`), [
    JSON.stringify({ type: 'session_meta', payload: { id: thread } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', message: 'earlier prompt' } }), '',
  ].join('\n'));
  const db = openInstallDb(path.join(root, 'run', 'install.db'));
  ensureCodexChannelSchema(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => db.close());
  const options = {
    db, installRoot: root, expectedOpGen: 1,
    env: { PATH: '/usr/bin:/bin:/usr/sbin:/sbin', AGMSG_STORAGE_PATH: root },
    listSeats: () => ({ state: 'ok', seats: [{ team: 'test', agent: 'alice', teamConfig: { agents: { alice: { registrations: [{ type: 'codex', project: root }] } } } }] }),
    readSession: () => ({ state: 'present', record: { team: 'test', agent: 'alice', type: 'codex', project: root, thread, codex_home: home } }),
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: () => ({ state: 'ok', unread: true, upTo: '{}' }),
    captureGroup: () => ({ state: 'absent' }),
  };
  return { root, db, options };
}

test('recorded absolute Codex runs with an env-node shebang under a minimal service PATH', async (t) => {
  if (process.platform === 'win32') return t.skip('POSIX env-node launcher');
  const { root, db, options } = executableFixture(t);
  const binary = path.join(root, 'custom codex');
  writeFileSync(binary, `#!/usr/bin/env node\nconsole.log('Queued message ${itemId} for thread ${thread}.');\n`);
  chmodSync(binary, 0o755);
  const channel = createCodexQueueChannel(options);
  await channel.pollOnce();
  assert.equal(db.prepare('SELECT state FROM beta_codex_seat').get().state, 'blocked');
  assert.match(db.prepare('SELECT reason FROM beta_codex_seat').get().reason, /codex_executable_unavailable/);
  db.prepare('UPDATE meta SET codex_path=?, node_path=?').run(binary, process.execPath);
  await channel.pollOnce();
  const row = db.prepare('SELECT state, queue_item_id FROM beta_codex_queue').get();
  assert.equal(row.queue_item_id, itemId);
  assert.equal(row.state, 'pending', 'a receipt alone is not delivery confirmation');
  await channel.stop();
});

test('a pre-spawn failure expires its reservation and allows the next poll to retry', async (t) => {
  const { db, options } = executableFixture(t);
  db.prepare('UPDATE meta SET codex_path=?, node_path=?').run(process.execPath, process.execPath);
  let attempts = 0;
  let witnesses = 0;
  const channel = createCodexQueueChannel({ ...options, captureGroup: () => {
    witnesses += 1;
    return { state: 'unreadable' };
  }, queue: (request) => {
    attempts += 1;
    // Model a recorded executable disappearing between validation and spawn.
    return runCodexQueue({ ...request, executable: path.join(options.installRoot, 'missing-codex') });
  } });
  await channel.pollOnce();
  let rows = db.prepare('SELECT state, queue_item_id, children FROM beta_codex_queue').all();
  assert.equal(rows[0].state, 'expired');
  assert.equal(rows[0].queue_item_id, null);
  const children = JSON.parse(rows[0].children);
  assert.equal(children.state, 'absent');
  assert.match(children.reason, /spawn_failed:ENOENT/);
  await channel.pollOnce();
  rows = db.prepare('SELECT state FROM beta_codex_queue').all();
  assert.equal(attempts, 2);
  assert.equal(witnesses, 0, 'a failed spawn must never request a process witness');
  assert.deepEqual(rows.map(row => row.state), ['expired', 'expired']);
  await channel.stop();
});

test('queue invocation is shell-free, pins CODEX_HOME, and parses only a successful matching receipt', async () => {
  const calls = [];
  const nonce = newNonce();
  const message = inboxNudge(nonce);
  assert.match(message, new RegExp(`^\\[agmsg:${nonce}\\]`));

  const result = await runCodexQueue({
    executable: '/opt/codex',
    codexHome: '/tmp/profile with spaces',
    thread,
    message,
    timeoutMs: 5000,
    spawnProcess: (file, args, options) => {
      calls.push({ file, args, options });
      return fakeChild({ stdout: `Queued message ${itemId} for thread ${thread}.\n` });
    },
  });

  assert.deepEqual(result, { kind: 'queued', queueItemId: itemId });
  assert.equal(calls[0].file, '/opt/codex');
  assert.deepEqual(calls[0].args, ['queue', '--thread', thread, '--message', message]);
  assert.equal(calls[0].options.env.CODEX_HOME, '/tmp/profile with spaces');
  assert.equal(calls[0].options.detached, process.platform !== 'win32');

  const archived = await runCodexQueue({
    executable: '/opt/codex', codexHome: '/tmp/profile', thread, message, timeoutMs: 5000,
    spawnProcess: () => fakeChild({ stdout: 'failed (code -32600)', code: 1 }),
  });
  assert.deepEqual(archived, { kind: 'archived', reason: 'thread_archived' });

  let timeoutSignal;
  const timedOut = await runCodexQueue({
    executable: '/opt/codex', codexHome: '/tmp/profile', thread, message, timeoutMs: 10,
    spawnProcess: () => {
      const child = fakeChild({ stdout: '', autoClose: false });
      child.pid = 1;
      child.kill = (signal) => {
        timeoutSignal = signal;
        setImmediate(() => child.emit('close', null, signal));
        return true;
      };
      return child;
    },
  });
  assert.equal(timedOut.kind, 'timeout');
  assert.equal(timeoutSignal, 'SIGTERM');
});

test('queue DB and rollout observations distinguish positive, absent, and unreadable evidence', async (t) => {
  const home = temporaryDirectory(t);
  const db = new DatabaseSync(path.join(home, 'queue_1.sqlite'));
  db.exec('CREATE TABLE queued_items (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL)');
  db.prepare('INSERT INTO queued_items VALUES (?, ?, ?)').run(itemId, thread, '{}');
  db.close();

  assert.deepEqual(readQueuedItem(home, itemId, thread), { state: 'present' });
  assert.deepEqual(readQueuedItem(home, '01a0ea98-2235-7f02-b477-7c130e602fce', thread), { state: 'absent' });
  assert.equal(readQueuedItem(path.join(home, 'missing'), itemId, thread).state, 'unreadable');
  assert.equal(readQueuedItem(home, itemId, '01a0ea97-c011-73f3-8470-fd59db15adbb').state, 'unreadable');

  const rolloutDir = path.join(home, 'sessions', '2026', '09', '29');
  mkdirSync(rolloutDir, { recursive: true });
  const rollout = path.join(rolloutDir, `rollout-2026-09-29T00-00-00-${thread}.jsonl`);
  const nonce = 'pending-nonce-123';
  writeFileSync(rollout, [
    JSON.stringify({ type: 'session_meta', payload: { id: thread } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', message: inboxNudge(nonce) } }),
    JSON.stringify({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text: inboxNudge('second-nonce') }] } }),
    '',
  ].join('\n'));
  assert.deepEqual(await readRolloutNonce(home, thread, nonce), { state: 'present' });
  assert.deepEqual(await readRolloutNonce(home, thread, 'second-nonce'), { state: 'present' });
  assert.deepEqual(await readRolloutNonce(home, thread, 'not-yet-seen'), { state: 'absent' });
  assert.deepEqual(await readRolloutNonce(path.join(home, 'missing-profile'), thread, nonce), { state: 'unreadable', reason: 'sessions_dir_missing' });

  writeFileSync(rollout, [
    JSON.stringify({ type: 'session_meta', payload: { id: thread } }),
    JSON.stringify({ type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'future_text_shape', value: inboxNudge(nonce) }] } }),
    '',
  ].join('\n'));
  assert.deepEqual(await readRolloutNonce(home, thread, nonce), { state: 'unreadable', reason: 'rollout_user_row_unrecognized' });

  writeFileSync(rollout, '{malformed json}\n');
  assert.equal((await readRolloutNonce(home, thread, nonce)).state, 'unreadable');
});

test('measured Windows 0.157.0 queued user response proves the rollout nonce is present', async (t) => {
  const home = temporaryDirectory(t);
  const sessions = path.join(home, 'sessions');
  mkdirSync(sessions);
  // Anonymized measured row; field positions and types are preserved.
  const row = readFileSync(new URL('./fixtures/codex-windows-0.157.0-queue-response.jsonl', import.meta.url), 'utf8');
  writeFileSync(path.join(sessions, `rollout-fixture-${thread}.jsonl`), JSON.stringify({ type: 'session_meta', payload: { id: thread } }) + '\n' + row);
  assert.deepEqual(await readRolloutNonce(home, thread, 'NONCE'), { state: 'present' });
});

test('measured Windows 0.160.0 queued user response proves the rollout nonce is present', async (t) => {
  const home = temporaryDirectory(t);
  const sessions = path.join(home, 'sessions');
  mkdirSync(sessions);
  // Anonymized measured row; field positions and types are preserved.
  const row = readFileSync(new URL('./fixtures/codex-windows-0.160.0-queue-response.jsonl', import.meta.url), 'utf8');
  writeFileSync(path.join(sessions, `rollout-fixture-${thread}.jsonl`), JSON.stringify({ type: 'session_meta', payload: { id: thread } }) + '\n' + row);
  assert.deepEqual(await readRolloutNonce(home, thread, 'NONCE'), { state: 'present' });
});

test('pending delivery confirms on either positive witness, expires only on two readable absences, and otherwise stays pending', () => {
  assert.deepEqual(resolvePendingQueue({
    queueObservation: { state: 'present' },
    rolloutObservation: { state: 'unreadable', reason: 'rollout_read_failed' },
    ageMs: 100,
  }), { state: 'confirmed', reason: 'queue_item_present' });
  assert.deepEqual(resolvePendingQueue({
    queueObservation: { state: 'unreadable', reason: 'queue_db_read_failed' },
    rolloutObservation: { state: 'present' },
    ageMs: 100,
  }), { state: 'confirmed', reason: 'nonce_observed' });
  assert.deepEqual(resolvePendingQueue({
    queueObservation: { state: 'absent' }, rolloutObservation: { state: 'absent' }, ageMs: 59_999,
  }), { state: 'pending', reason: 'awaiting_confirmation' });
  assert.deepEqual(resolvePendingQueue({
    queueObservation: { state: 'absent' }, rolloutObservation: { state: 'absent' }, ageMs: 60_000,
  }), { state: 'expired', reason: 'confirmation_timeout' });
  assert.deepEqual(resolvePendingQueue({
    queueObservation: { state: 'absent' },
    rolloutObservation: { state: 'unreadable', reason: 'thread_rollout_missing' },
    ageMs: 120_000,
  }), { state: 'pending', reason: 'verification_unreadable' });
  assert.deepEqual(resolvePendingQueue({
    queueObservation: { state: 'absent' }, rolloutObservation: { state: 'absent' }, ageMs: -1,
  }), { state: 'pending', reason: 'pending_age_unreadable' });
});

test('immediate post-receipt check confirms a still-queued item before rollout inspection', async () => {
  const events = ['queue_item_id_persisted'];
  const result = await verifyPendingDelivery({
    codexHome: '/tmp/profile', queueItemId: itemId, thread, nonce: 'pending-nonce', ageMs: 5,
    readQueue: () => {
      events.push('queue_read');
      return { state: 'present' };
    },
    readRollout: async () => {
      events.push('rollout_read');
      return { state: 'unreadable', reason: 'rollout_not_ready' };
    },
  });
  assert.deepEqual(result, { state: 'confirmed', reason: 'queue_item_present' });
  assert.deepEqual(events, ['queue_item_id_persisted', 'queue_read']);

  const consumedEarly = await verifyPendingDelivery({
    codexHome: '/tmp/profile', queueItemId: itemId, thread, nonce: 'pending-nonce', ageMs: 60_000,
    readQueue: () => ({ state: 'absent' }),
    readRollout: async () => ({ state: 'unreadable', reason: 'rollout_user_row_unrecognized' }),
  });
  assert.deepEqual(consumedEarly, { state: 'pending', reason: 'verification_unreadable' });
});

test('seat classification never treats an uncertain destination or bridge as addressable', () => {
  // A profile with no rollout for the thread is named as such, not as an unobservable conversation.
  assert.equal(rolloutStateOf({ state: 'unreadable', reason: 'thread_rollout_missing' }), 'no_rollout');
  assert.equal(rolloutStateOf({ state: 'unreadable', reason: 'rollout_read_failed' }), 'invalid');
  const record = { thread, codex_home: '/tmp/profile' };
  assert.deepEqual(classifyCodexSeat({ roleSession: record, bridgeState: 'stopped', rolloutState: 'valid' }), { state: 'addressable', reason: '' });
  assert.deepEqual(classifyCodexSeat({ roleSession: record, bridgeState: 'running' }), { state: 'bridged', reason: 'bridge_running' });
  assert.deepEqual(classifyCodexSeat({ roleSession: null }), { state: 'unaddressable', reason: 'role_session_missing' });
  assert.deepEqual(classifyCodexSeat({ roleSession: record, bridgeState: 'stopped', rolloutState: 'archived' }), { state: 'blocked', reason: 'thread_archived' });
  assert.deepEqual(classifyCodexSeat({ roleSession: record, bridgeState: 'stopped', rolloutState: 'no_rollout' }), { state: 'blocked', reason: 'codex_home_mismatch' });
  assert.deepEqual(classifyCodexSeat({ roleSession: record, bridgeState: 'unknown' }), { state: 'blocked', reason: 'bridge_state_unknown' });
  assert.deepEqual(classifyCodexSeat({ roleSession: record }), { state: 'blocked', reason: 'bridge_state_unknown' });
  assert.deepEqual(classifyCodexSeat({ roleSession: record, bridgeState: 'stopped' }), { state: 'blocked', reason: 'thread_observation_failed' });
});

test('Windows queue requires a native executable and a stable release at or above the measured minimum', (t) => {
  const root = temporaryDirectory(t);
  const nativeExe = path.join(root, 'codex.exe');
  writeFileSync(nativeExe, 'fixture, never executed');
  const env = { PATH: root };
  assert.equal(resolveWindowsCodexExe('codex', env), nativeExe);
  assert.equal(resolveWindowsCodexExe(nativeExe, env), nativeExe);
  assert.equal(resolveWindowsCodexExe(path.join(root, 'codex.cmd'), env), null);
  assert.equal(resolveWindowsCodexExe('codex', { PATH: path.join(root, 'missing') }), null);
  const npmRoot = path.join(root, 'npm');
  const vendor = path.join(npmRoot, 'node_modules', '@openai', 'codex', 'node_modules', '@openai', 'codex-win32-x64', 'vendor', 'x86_64-pc-windows-msvc', 'bin');
  mkdirSync(vendor, { recursive: true });
  writeFileSync(path.join(npmRoot, 'codex.cmd'), 'fixture shim, never executed');
  writeFileSync(path.join(vendor, 'codex.exe'), 'fixture native binary, never executed');
  assert.equal(resolveWindowsCodexExe('codex', { Path: npmRoot }, 'x64'), path.join(vendor, 'codex.exe'));
  const probe = (file, args, options) => {
    assert.equal(file, nativeExe);
    assert.deepEqual(args, ['--version']);
    assert.equal(options.timeout, 2000);
    return 'codex-cli 0.157.0\n';
  };
  assert.deepEqual(checkWindowsCodexQueueGate({ executable: 'codex', env, probe }), { state: 'ok', executable: nativeExe, version: '0.157.0' });
  assert.deepEqual(checkWindowsCodexQueueGate({ executable: 'codex', env: {} }), { state: 'blocked', reason: 'windows_codex_executable_unresolved' });
  for (const version of ['0.0.999', '0.156.999']) {
    assert.deepEqual(checkWindowsCodexQueueGate({ executable: 'codex', env, probe: () => `codex-cli ${version}\n` }), { state: 'blocked', reason: `windows_codex_version_below_minimum:${version}` });
  }
  for (const version of ['0.157.0', '0.158.0', '0.160.0', '0.1000.0', '1.0.0']) {
    assert.deepEqual(checkWindowsCodexQueueGate({ executable: 'codex', env, probe: () => `codex-cli ${version}\n` }), { state: 'ok', executable: nativeExe, version });
  }
  for (const probe of [() => 'codex-cli 0.157.0-beta\n', () => { throw new Error('timeout'); }]) {
    assert.deepEqual(checkWindowsCodexQueueGate({ executable: 'codex', env, probe }), { state: 'blocked', reason: 'windows_codex_version_unreadable' });
  }
});

test('store discovery is fail-closed and unread snapshots advance both event and legacy cursors', async (t) => {
  const root = temporaryDirectory(t);
  const teamsDir = path.join(root, 'teams');
  const runDir = path.join(root, 'run');
  const storageDir = path.join(root, 'store');
  mkdirSync(path.join(teamsDir, 'alpha'), { recursive: true });
  mkdirSync(runDir, { recursive: true });
  mkdirSync(storageDir, { recursive: true });
  writeFileSync(path.join(teamsDir, 'alpha', 'config.json'), JSON.stringify({
    agents: {
      alice: { registrations: [{ type: 'codex', project: root }] },
      bob: { registrations: [{ type: 'claude-code', project: root }] },
    },
  }));
  writeFileSync(path.join(runDir, 'role-session.alpha__alice'), `team=alpha\nagent=alice\ntype=codex\nsession=${thread}\ncodex_home=/tmp/codex-profile\n`);
  writeFileSync(path.join(root, 'config.json'), JSON.stringify({ storage: 'jsonl' }));

  assert.deepEqual(listCodexRegistrations(teamsDir).seats.map(({ team, agent }) => `${team}:${agent}`), ['alpha:alice']);
  assert.deepEqual(readRoleSession(runDir, 'alpha', 'alice').record, {
    team: 'alpha', agent: 'alice', type: 'codex', project: '', thread, codex_home: '/tmp/codex-profile',
  });
  assert.deepEqual(readStorageDriver(path.join(root, 'config.json')), { state: 'ok', driver: 'jsonl' });
  assert.equal(messageStorePath({ storageDir, team: 'alpha', teamConfig: {} }), path.join(storageDir, 'messages.db'));
  assert.equal(messageStorePath({ storageDir, team: 'alpha', teamConfig: { drivers: { partition: 'per-team' } } }), path.join(storageDir, 'teams', 'alpha', 'messages.db'));

  const installDb = new DatabaseSync(path.join(root, 'install.db'));
  ensureCodexChannelSchema(installDb);
  assert.equal(installDb.prepare("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name LIKE 'beta_codex_%'").get().n, 2);
  assert.match(CODEX_CHANNEL_SCHEMA, /beta_codex_queue_one_pending/);
  installDb.close();

  const msgDb = new DatabaseSync(path.join(storageDir, 'messages.db'));
  msgDb.exec(`
    CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, id TEXT, team TEXT, from_agent TEXT, to_agent TEXT, body TEXT, msg_id TEXT, agent TEXT, at TEXT, legacy_id INTEGER);
    CREATE TABLE messages (id INTEGER PRIMARY KEY, team TEXT, to_agent TEXT, read_at TEXT, created_at TEXT, body TEXT);
    CREATE TABLE read_cursors (team TEXT, agent TEXT, local_position INTEGER, PRIMARY KEY(team, agent));
  `);
  msgDb.prepare('INSERT INTO events VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
    .run('message_sent', 'event-1', 'alpha', 'sender', 'alice', 'secret body', null, null, '2026-09-29T00:00:00Z', null);
  msgDb.prepare('INSERT INTO messages VALUES (?, ?, ?, ?, ?, ?)').run(1, 'alpha', 'alice', null, '2026-09-29T00:00:00Z', 'legacy body');
  msgDb.close();

  const readDb = new DatabaseSync(path.join(storageDir, 'messages.db'), { readOnly: true });
  const first = readUnreadSnapshot(readDb, 'alpha', 'alice');
  assert.equal(first.state, 'ok');
  assert.equal(first.unread, true);
  assert.equal(first.upTo, JSON.stringify({ eventSeq: 1, legacyId: 1 }));
  assert.equal(readUnreadSnapshot(readDb, 'alpha', 'alice', first.upTo).unread, false);
  readDb.close();
});

test('Codex channel queues one unread snapshot and confirms it before advancing that seat', async (t) => {
  const root = temporaryDirectory(t);
  const teamsDir = path.join(root, 'teams');
  const runDir = path.join(root, 'run');
  const storageDir = path.join(root, 'store');
  const codexHome = path.join(root, 'codex');
  const sessionDir = path.join(codexHome, 'sessions', '2026', '09', '29');
  mkdirSync(path.join(teamsDir, 'alpha'), { recursive: true });
  mkdirSync(runDir, { recursive: true });
  mkdirSync(storageDir, { recursive: true });
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(path.join(teamsDir, 'alpha', 'config.json'), JSON.stringify({
    agents: { alice: { registrations: [{ type: 'codex', project: root }] } },
  }));
  writeFileSync(path.join(runDir, 'role-session.alpha__alice'), `team=alpha\nagent=alice\ntype=codex\nproject=${root}\nsession=${thread}\ncodex_home=${codexHome}\n`);
  writeFileSync(path.join(sessionDir, `rollout-2026-09-29T00-00-00-${thread}.jsonl`), [
    JSON.stringify({ type: 'session_meta', payload: { id: thread } }),
    JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', message: 'an earlier prompt' } }),
    '',
  ].join('\n'));

  const messageDb = new DatabaseSync(path.join(storageDir, 'messages.db'));
  messageDb.exec(`
    CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, type TEXT, id TEXT, team TEXT, from_agent TEXT, to_agent TEXT, body TEXT, msg_id TEXT, agent TEXT, at TEXT, legacy_id INTEGER);
    CREATE TABLE messages (id INTEGER PRIMARY KEY, team TEXT, to_agent TEXT, read_at TEXT, created_at TEXT, body TEXT);
    CREATE TABLE read_cursors (team TEXT, agent TEXT, local_position INTEGER, PRIMARY KEY(team, agent));
  `);
  messageDb.prepare('INSERT INTO events VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
    .run('message_sent', 'event-1', 'alpha', 'sender', 'alice', 'do not include this in the nudge', null, null, '2026-09-29T00:00:00Z', null);
  messageDb.close();

  const queueDb = new DatabaseSync(path.join(codexHome, 'queue_1.sqlite'));
  queueDb.exec('CREATE TABLE queued_items (id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL)');
  queueDb.close();

  const installDb = openInstallDb(path.join(runDir, 'install.db'));
  installDb.prepare('UPDATE meta SET codex_path=?, node_path=?').run(process.execPath, process.execPath);
  ensureCodexChannelSchema(installDb);
  installDb.exec("UPDATE daemon_intent SET desired='on', op_gen=4");
  const queued = [];
  let childGroupState = 'present';
  const channel = createCodexQueueChannel({
    db: installDb,
    installRoot: root,
    expectedOpGen: 4,
    env: { AGMSG_STORAGE_PATH: storageDir },
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    captureGroup: (pid) => ({ state: 'complete', pgid: pid, boot_id: 'test-boot', witness: 'test-start' }),
    observeGroup: () => ({ state: childGroupState }),
    queue: async (request) => {
      queued.push(request);
      request.onChildStart(4242);
      const db = new DatabaseSync(path.join(codexHome, 'queue_1.sqlite'));
      db.prepare('INSERT INTO queued_items VALUES (?, ?, ?)').run(itemId, thread, '{}');
      db.close();
      return { kind: 'queued', queueItemId: itemId };
    },
  });

  await channel.pollOnce();
  assert.equal(queued.length, 1);
  assert.equal(queued[0].thread, thread);
  assert.match(queued[0].message, /^\[agmsg:[A-Za-z0-9-]+\] New messages are waiting\./);
  assert.doesNotMatch(queued[0].message, /do not include this/);
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ?").get(JSON.stringify(['alpha', 'alice'])).state, 'pending');
  await channel.pollOnce();
  assert.equal(queued.length, 1, 'a still-running child group must not be retried on the next poll');
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ?").get(JSON.stringify(['alpha', 'alice'])).state, 'pending');
  childGroupState = 'absent';
  await channel.pollOnce();
  assert.equal(queued.length, 1, 'the queued snapshot is not retried after the child exits');
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ?").get(JSON.stringify(['alpha', 'alice'])).state, 'confirmed');
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice'])).state, 'addressable');
  const status = readOwnerAndIntentReadOnly(root);
  assert.equal(status.codexSeats.state, 'ok');
  assert.equal(status.codexSeats.seats[0].state, 'addressable');

  await channel.pollOnce();
  assert.equal(queued.length, 1, 'the confirmed cursor prevents another nudge for the same unread snapshot');
  await channel.stop();

  const windowsChannel = createCodexQueueChannel({
    db: installDb,
    installRoot: root,
    expectedOpGen: 4,
    env: { AGMSG_STORAGE_PATH: storageDir },
    hostPlatform: 'win32',
    windowsGate: () => ({ state: 'blocked', reason: 'windows_codex_version_below_minimum:0.156.0' }),
    queue: async () => { throw new Error('Windows queue must stay closed until live delivery is verified'); },
  });
  await windowsChannel.pollOnce();
  assert.equal(installDb.prepare("SELECT reason FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice'])).reason, 'windows_codex_version_below_minimum:0.156.0');
  installDb.prepare(`
    INSERT INTO beta_codex_queue (seat, codex_home, thread, up_to, nonce, queue_item_id, state, children, created_at)
    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
  `).run(JSON.stringify(['alpha', 'alice']), codexHome, thread, JSON.stringify({ eventSeq: 1, legacyId: 0 }), 'windows-pending-nonce', notYetVisibleItemId, JSON.stringify({ state: 'absent' }), new Date().toISOString());
  await windowsChannel.pollOnce();
  const windowsSeat = installDb.prepare("SELECT state, reason FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice']));
  assert.equal(windowsSeat.state, 'blocked');
  assert.equal(windowsSeat.reason, 'windows_codex_version_below_minimum:0.156.0;pending:awaiting_confirmation');
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ? ORDER BY id DESC LIMIT 1").get(JSON.stringify(['alpha', 'alice'])).state, 'pending');
  const windowsQueueDb = new DatabaseSync(path.join(codexHome, 'queue_1.sqlite'));
  windowsQueueDb.prepare('INSERT INTO queued_items VALUES (?, ?, ?)').run(notYetVisibleItemId, thread, '{}');
  windowsQueueDb.close();
  await windowsChannel.pollOnce();
  const confirmedWindowsSeat = installDb.prepare("SELECT state, reason FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice']));
  assert.equal(confirmedWindowsSeat.state, 'blocked');
  assert.equal(confirmedWindowsSeat.reason, 'windows_codex_version_below_minimum:0.156.0');
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ? ORDER BY id DESC LIMIT 1").get(JSON.stringify(['alpha', 'alice'])).state, 'confirmed');
  await windowsChannel.stop();

  const nextMessageDb = new DatabaseSync(path.join(storageDir, 'messages.db'));
  nextMessageDb.prepare('INSERT INTO events VALUES (2, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
    .run('message_sent', 'event-2', 'alpha', 'sender', 'alice', 'next unread message', null, null, '2026-10-01T00:00:00Z', null);
  nextMessageDb.close();
  const nativeExe = path.join(root, 'codex.exe');
  writeFileSync(nativeExe, 'native fixture, never executed');
  chmodSync(nativeExe, 0o755);
  installDb.prepare('UPDATE meta SET codex_path=?').run(nativeExe);
  let windowsQueues = 0;
  let windowsChildState = 'present';
  const verifiedWindowsChannel = createCodexQueueChannel({
    db: installDb, installRoot: root, expectedOpGen: 4, hostPlatform: 'win32',
    env: { AGMSG_STORAGE_PATH: storageDir, PATH: root },
    windowsGate: (options) => checkWindowsCodexQueueGate({ ...options, probe: () => 'codex-cli 0.157.0\n' }),
    captureGroup: (pid) => ({ state: 'complete', kind: 'windows-native-process', pgid: pid, boot_id: 'test-boot', witness: 'test-start' }),
    observeGroup: () => ({ state: windowsChildState }),
    queue: async (request) => {
      windowsQueues += 1;
      assert.equal(request.executable, nativeExe, 'queue bypasses the npm shim');
      request.onChildStart(4242);
      return { kind: 'queued', queueItemId: itemId };
    },
  });
  await verifiedWindowsChannel.pollOnce();
  assert.equal(windowsQueues, 1);
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice'])).state, 'addressable');
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ? ORDER BY id DESC LIMIT 1").get(JSON.stringify(['alpha', 'alice'])).state, 'pending');
  windowsChildState = 'absent';
  await verifiedWindowsChannel.pollOnce();
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ? ORDER BY id DESC LIMIT 1").get(JSON.stringify(['alpha', 'alice'])).state, 'confirmed');
  await verifiedWindowsChannel.pollOnce();
  assert.equal(windowsQueues, 1, 'a confirmed Windows snapshot is not requeued');
  await verifiedWindowsChannel.stop();

  writeFileSync(path.join(teamsDir, 'alpha', 'config.json'), JSON.stringify({ agents: {} }));
  const missingSeatChannel = createCodexQueueChannel({ db: installDb, installRoot: root, expectedOpGen: 4, env: { AGMSG_STORAGE_PATH: storageDir } });
  await missingSeatChannel.pollOnce();
  const missingSeat = installDb.prepare("SELECT state, reason FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice']));
  assert.equal(missingSeat.state, 'unaddressable');
  assert.equal(missingSeat.reason, 'seat_registration_missing');
  await missingSeatChannel.stop();

  installDb.prepare(`
    INSERT INTO beta_codex_queue (seat, codex_home, thread, up_to, nonce, queue_item_id, state, children, created_at)
    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
  `).run(JSON.stringify(['alpha', 'alice']), codexHome, thread, JSON.stringify({ eventSeq: 1, legacyId: 0 }), 'retired-seat-nonce', itemId, JSON.stringify({ state: 'absent' }), new Date().toISOString());
  const retiredChannel = createCodexQueueChannel({ db: installDb, installRoot: root, expectedOpGen: 4, env: { AGMSG_STORAGE_PATH: storageDir } });
  await retiredChannel.pollOnce();
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ? ORDER BY id DESC LIMIT 1").get(JSON.stringify(['alpha', 'alice'])).state, 'confirmed');
  const retiredSeat = installDb.prepare("SELECT state, reason FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice']));
  assert.equal(retiredSeat.state, 'unaddressable');
  assert.equal(retiredSeat.reason, 'seat_registration_missing');
  await retiredChannel.stop();

  writeFileSync(path.join(teamsDir, 'alpha', 'config.json'), JSON.stringify({
    agents: { alice: { registrations: [{ type: 'codex', project: root }] } },
  }));
  // A child whose start could not be witnessed is still observed by its group
  // id: a group that is gone no longer holds the seat, and a reservation for a
  // thread the seat no longer names is dropped and delivered to the current
  // thread only once that group is gone.
  const unwitnessed = JSON.stringify({ state: 'unreadable', reason: 'child_start_witness_unavailable', pgid: 4242, result: 'failed' });
  const insertPending = (forThread, nonce, queueItem) => installDb.prepare(`
    INSERT INTO beta_codex_queue (seat, codex_home, thread, up_to, nonce, queue_item_id, state, children, created_at)
    VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
  `).run(JSON.stringify(['alpha', 'alice']), codexHome, forThread, JSON.stringify({ eventSeq: 1, legacyId: 0 }), nonce, queueItem, unwitnessed, new Date().toISOString());
  const latestState = () => installDb.prepare("SELECT state FROM beta_codex_queue WHERE seat = ? ORDER BY id DESC LIMIT 1").get(JSON.stringify(['alpha', 'alice'])).state;
  const sentThreads = [];
  const logs = [];
  let groupState = 'absent';
  const staleChannel = createCodexQueueChannel({
    db: installDb, installRoot: root, expectedOpGen: 4, env: { AGMSG_STORAGE_PATH: storageDir },
    observeGroup: () => ({ state: groupState }),
    log: (message) => logs.push(message),
    captureGroup: (pid, onFailure) => { onFailure('ps failed: status=1'); return { state: 'unreadable', reason: 'child_start_witness_unavailable', pgid: pid }; },
    queue: async (request) => { request.onChildStart(4243); sentThreads.push(request.thread); return { kind: 'failed', started: false, reason: 'spawn_failed:test' }; },
  });
  insertPending(thread, 'unwitnessed-nonce', itemId);
  await staleChannel.pollOnce();
  assert.equal(latestState(), 'confirmed', 'a gone group with no start witness still resolves from the queue evidence');
  insertPending('01a0ea97-c011-73f3-8470-fd59db15adbb', 'old-thread-nonce', null);
  groupState = 'present';
  await staleChannel.pollOnce();
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE nonce = 'old-thread-nonce'").get().state, 'pending', 'a group that may still write keeps the old reservation');
  assert.deepEqual(sentThreads, []);
  groupState = 'absent';
  installDb.prepare("UPDATE beta_codex_queue SET children = 'incomplete' WHERE nonce = 'old-thread-nonce'").run();
  await staleChannel.pollOnce();
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE nonce = 'old-thread-nonce'").get().state, 'pending', 'a reservation that never recorded its child keeps the old one');
  assert.deepEqual(sentThreads, []);
  installDb.prepare("UPDATE beta_codex_queue SET children = ? WHERE nonce = 'old-thread-nonce'").run(unwitnessed);
  await staleChannel.pollOnce();
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_queue WHERE nonce = 'old-thread-nonce'").get().state, 'expired');
  assert.deepEqual(sentThreads, [thread], 'the nudge goes to the thread the seat names now');
  assert.ok(logs.some((line) => line.includes('ps failed: status=1')), 'a missing start witness leaves its cause in the log');
  await staleChannel.stop();

  const bridgePid = String(process.pid);
  const bridgeBase = path.join(runDir, 'codex-bridge.alpha.alice');
  const bridgeWitness = processStartWitness(process.pid);
  assert.ok(bridgeWitness, 'the test process has a readable start witness');
  const witnessSeparator = bridgeWitness.indexOf(':');
  const witnessPlatform = bridgeWitness.slice(0, witnessSeparator);
  const witnessToken = bridgeWitness.slice(witnessSeparator + 1);
  const bridgePairHash = createHash('sha1').update('alpha\talice').digest('hex');
  const bridgePairsHash = createHash('sha1').update(bridgePairHash).digest('hex');
  const bridgeProjectHash = createHash('sha1').update(root).digest('hex');
  const startsrc = { linux: 'proc', darwin: 'ps', windows: 'pwsh' }[witnessPlatform];
  writeFileSync(`${bridgeBase}.pid`, `${bridgePid}\n`);
  writeFileSync(`${bridgeBase}.meta`, `pid=${bridgePid}\nproject=${root}\nidentities=alpha/alice\ntype=codex\n`);
  writeFileSync(path.join(runDir, `codex-bridge-lease.${bridgePid}`), [
    'v=1', `project=${bridgeProjectHash}`, `pairs=${bridgePairsHash}`, `host=${os.hostname()}`,
    `pid=${bridgePid}`, `start=${witnessToken}`, `startsrc=${startsrc}`, '',
  ].join('\n'));
  const bridgedChannel = createCodexQueueChannel({
    db: installDb,
    installRoot: root,
    expectedOpGen: 4,
    env: { AGMSG_STORAGE_PATH: storageDir },
    queue: async () => { throw new Error('a verified live bridge retains delivery ownership'); },
  });
  await bridgedChannel.pollOnce();
  assert.equal(installDb.prepare("SELECT state FROM beta_codex_seat WHERE seat = ?").get(JSON.stringify(['alpha', 'alice'])).state, 'bridged');
  await bridgedChannel.stop();
  unlinkSync(`${bridgeBase}.pid`);
  unlinkSync(`${bridgeBase}.meta`);
  unlinkSync(path.join(runDir, `codex-bridge-lease.${bridgePid}`));
  installDb.close();
});
