import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
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
  runCodexQueue,
} from '../scripts/daemon/channels/codex-queue-io.mjs';

const thread = '01a0ea97-c011-73f3-8470-fd59db15adba';
const itemId = '01a0ea98-2235-7f02-b477-7c130e602fcd';

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
      child.stdout.end(stdout);
      child.stderr.end(stderr);
      child.emit('close', code, null);
    });
  }
  return child;
}

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

test('seat classification never treats an uncertain destination or bridge as addressable', () => {
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
