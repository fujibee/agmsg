import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  observeTranscript,
  resolveTranscriptPath,
  resolvePendingDelivery,
} from '../scripts/daemon/channels/claude-code-queue-io.mjs';
import { createClaudeCodeQueueChannel } from '../scripts/daemon/channels/claude-code-queue.mjs';
import { ensureClaudeCodeChannelSchema } from '../scripts/daemon/channels/claude-code-queue-store.mjs';
import { openInstallDb } from '../scripts/daemon/db.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsg-cc-queue-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// Load-bearing property: a `queue-operation`/`enqueue` line fires on mere
// receipt, Held or not, so it must NEVER by itself cause a seat to be marked
// delivered -- never notify on evidence that could just as well be a hold.
// Only the `type:"user"` line whose `origin.body` carries the nonce, or the
// mid-turn `queued_command` attachment whose `prompt` carries it, counts.
// This reproduces both line shapes measured against a live Claude Code
// transcript in one file and asserts the queue-operation line alone is not
// enough, while the user/origin.body line is.
test('observeTranscript: a queue-operation enqueue line is not delivery evidence; the user/origin.body line and a mid-turn queued_command attachment are', (t) => {
  const dir = temporaryDirectory(t);
  const transcriptPath = path.join(dir, 'session.jsonl');
  const nonce = 'abc123-test-nonce';
  const marker = `[agmsg:${nonce}] New messages are waiting. Check your agmsg inbox.`;

  // Only the enqueue line present (held, or not yet acted on) — must read as
  // absent, not delivered.
  writeFileSync(transcriptPath, `${JSON.stringify({
    type: 'queue-operation',
    operation: 'enqueue',
    content: `<cross-session-message from="agmsgd">${marker}</cross-session-message>`,
  })}\n`);
  let observation = observeTranscript(transcriptPath, nonce);
  assert.equal(observation.state, 'absent');
  let resolved = resolvePendingDelivery({ observation });
  assert.equal(resolved.state, 'pending');

  // The real delivered record appended afterward (as the genuine sequence
  // measured: enqueue first, then the delivered user line) — now it must
  // read as delivered/confirmed.
  writeFileSync(transcriptPath, `${JSON.stringify({
    type: 'queue-operation',
    operation: 'enqueue',
    content: `<cross-session-message from="agmsgd">${marker}</cross-session-message>`,
  })}\n${JSON.stringify({
    type: 'user',
    isMeta: true,
    message: { role: 'user', content: 'Another Claude session sent a message...' },
    origin: { kind: 'peer', from: 'agmsgd', verifiedPeerPid: 12345, name: 'agmsgd', fromMode: 'bypass', body: marker },
  })}\n`);
  observation = observeTranscript(transcriptPath, nonce);
  assert.equal(observation.state, 'delivered');
  resolved = resolvePendingDelivery({ observation });
  assert.equal(resolved.state, 'confirmed');

  // Absorbed mid-turn: enqueue, remove, then a queued_command attachment and
  // no user line at all. The model read it, so it is delivered.
  writeFileSync(transcriptPath, `${JSON.stringify({
    type: 'queue-operation',
    operation: 'enqueue',
    content: `<cross-session-message from="agmsgd">${marker}</cross-session-message>`,
  })}\n${JSON.stringify({
    type: 'queue-operation',
    operation: 'remove',
    reason: 'absorbed_mid_turn',
    content: `<cross-session-message from="agmsgd">${marker}</cross-session-message>`,
  })}\n${JSON.stringify({
    type: 'attachment',
    attachment: { type: 'queued_command', prompt: `<cross-session-message from="agmsgd">${marker}</cross-session-message>` },
  })}\n`);
  assert.equal(observeTranscript(transcriptPath, nonce).state, 'delivered');

  // #1644: the delivered line scrolls out of the 512 KiB tail under later
  // output. A position recorded before the send still finds it; a transcript
  // that has become shorter than the position is read from the start.
  const before = statSync(transcriptPath).size;
  const delivered = JSON.stringify({ type: 'user', origin: { kind: 'peer', body: marker } });
  const filler = `${JSON.stringify({ type: 'assistant', text: 'x'.repeat(1000) })}\n`.repeat(800);
  writeFileSync(transcriptPath, `${'y'.repeat(before)}\n${delivered}\n${filler}`);
  // No recorded position (a pending row from before positions): searched from the start, however far back.
  assert.equal(observeTranscript(transcriptPath, nonce).state, 'delivered');
  assert.equal(observeTranscript(transcriptPath, nonce, before + 1).state, 'delivered');
  assert.equal(observeTranscript(transcriptPath, nonce, statSync(transcriptPath).size + 10).state, 'delivered');
  assert.equal(observeTranscript(transcriptPath, nonce, statSync(transcriptPath).size).state, 'absent');
});

// A position recorded while a row was half written lands mid-row: the rest of
// that row is a fragment, not a line, so evidence inside it is never read.
test('observeTranscript: a recorded position inside a half-written row discards that fragment', (t) => {
  const dir = temporaryDirectory(t);
  const transcriptPath = path.join(dir, 'session.jsonl');
  const nonce = 'mid-row-nonce';
  const row = JSON.stringify({ type: 'user', origin: { kind: 'peer', body: `[agmsg:${nonce}] x` } });
  writeFileSync(transcriptPath, `unfinished-prefix${row}\n`);
  assert.equal(observeTranscript(transcriptPath, nonce, 'unfinished-prefix'.length).state, 'absent');
  writeFileSync(transcriptPath, `unfinished-prefix${row}\n${row}\n`);
  assert.equal(observeTranscript(transcriptPath, nonce, 'unfinished-prefix'.length).state, 'delivered');
});

// The file is rewritten while a read is in flight: the first read sees a
// delivery row that no complete version of the file ever held. The row must
// read back unchanged before it counts.
test('observeTranscript: a delivery row that changes between two reads is not confirmed', (t) => {
  const dir = temporaryDirectory(t);
  const transcriptPath = path.join(dir, 'session.jsonl');
  const nonce = 'rewrite-nonce';
  const row = JSON.stringify({ type: 'user', origin: { kind: 'peer', body: `[agmsg:${nonce}]` } });
  writeFileSync(transcriptPath, `${row}\n`);
  let calls = 0;
  const io = {
    readSync(fd, buffer, offset, length, position) {
      const read = readSync(fd, buffer, offset, length, position);
      if (++calls === 1) writeFileSync(transcriptPath, `${JSON.stringify({ type: 'tool', origin: { body: `[agmsg:${nonce}]` } })}\n`);
      return read;
    },
  };
  assert.equal(observeTranscript(transcriptPath, nonce, 0, io).state, 'absent');
  assert.equal(observeTranscript(transcriptPath, nonce, 0).state, 'absent');
});

// The line boundary is part of what must read back unchanged, and a short
// read must not make a stable row look changed.
test('observeTranscript: a rewritten line boundary is not confirmed, and short reads still confirm a stable row', (t) => {
  const dir = temporaryDirectory(t);
  const transcriptPath = path.join(dir, 'session.jsonl');
  const nonce = 'boundary-nonce';
  const row = JSON.stringify({ type: 'user', origin: { kind: 'peer', body: `[agmsg:${nonce}]` } });
  writeFileSync(transcriptPath, `{}\n${row}\n`);
  let calls = 0;
  const rewrite = {
    readSync(fd, buffer, offset, length, position) {
      const read = readSync(fd, buffer, offset, length, position);
      if (++calls === 2) writeFileSync(transcriptPath, `bad${row}\n`);
      return read;
    },
  };
  assert.equal(observeTranscript(transcriptPath, nonce, 3, rewrite).state, 'absent');
  writeFileSync(transcriptPath, `{}\n${row}\n`);
  const short = { readSync: (fd, buffer, offset, length, position) => readSync(fd, buffer, offset, Math.min(length, 14), position) };
  assert.equal(observeTranscript(transcriptPath, nonce, 3, short).state, 'delivered');
});

// No clock decides a pending nudge: whatever the transcript shows (or fails to
// show), it stays pending until the channel itself sees the socket or the
// seat's record change.
test('resolvePendingDelivery: nothing but a delivered nonce ends a pending nudge', () => {
  for (const observation of [
    { state: 'absent' },
    { state: 'held' },
    { state: 'unreadable', reason: 'transcript_missing' },
    { state: 'unreadable', reason: 'transcript_read_failed' },
  ]) {
    assert.equal(resolvePendingDelivery({ observation, ageMs: 10 ** 9 }).state, 'pending');
  }
  assert.equal(resolvePendingDelivery({ observation: { state: 'delivered' } }).state, 'confirmed');
});

function channelFixture(t) {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'));
  const db = openInstallDb(path.join(root, 'run', 'install.db'));
  ensureClaudeCodeChannelSchema(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => db.close());
  const state = { session: 'sess-1', socket: '/tmp/cc-socks/1.sock', sent: 0, hours: 0, alive: { state: 'ok' } };
  const channel = createClaudeCodeQueueChannel({
    db, installRoot: root, expectedOpGen: 1, env: { AGMSG_STORAGE_PATH: root },
    now: () => Date.UTC(2026, 9, 14) + state.hours * 3_600_000,
    log: () => {},
    listSeats: () => ({ state: 'ok', seats: [{ team: 'test', agent: 'alice', teamConfig: { agents: { alice: { registrations: [{ type: 'claude-code', project: root }] } } } }] }),
    readSession: () => ({ state: 'present', record: { team: 'test', agent: 'alice', type: 'claude-code', project: root, claude_config_dir: root, messaging_socket: state.socket, session: state.session } }),
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: () => ({ state: 'ok', unread: true, upTo: '{}' }),
    send: async () => { state.sent += 1; return { state: 'sent' }; },
    observe: () => ({ state: 'absent' }),
    socketAlive: () => state.alive,
    hostPlatform: 'linux',
  });
  return { db, channel, state };
}

test('an unconfirmed nudge is not sent again, however long the same session and socket stay up', async (t) => {
  const { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  for (const hours of [1, 9, 40]) {
    state.hours = hours;
    await channel.pollOnce();
  }
  // A check that could not run is not evidence the socket is gone.
  state.alive = { state: 'unreadable', reason: 'messaging_socket_stat_failed' };
  await channel.pollOnce();
  assert.equal(state.sent, 1);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_claude_queue WHERE state='pending'").get().n, 1);
  await channel.stop();
});

test('a nudge is sent again once the seat record names another session', async (t) => {
  const { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  state.session = 'sess-2';
  await channel.pollOnce();
  assert.equal(state.sent, 2);
  assert.deepEqual(db.prepare('SELECT state FROM beta_claude_queue ORDER BY id').all().map((row) => row.state), ['expired', 'pending']);
  await channel.stop();
});

test('a seat whose recorded socket is gone gets no new nudge rows until its record names a socket that exists', async (t) => {
  const { db, channel, state } = channelFixture(t);
  state.alive = { state: 'unreadable', reason: 'messaging_socket_missing' };
  for (let i = 0; i < 5; i += 1) await channel.pollOnce();
  assert.equal(state.sent, 0);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM beta_claude_queue').get().n, 0);
  state.alive = { state: 'ok' };
  state.socket = '/tmp/cc-socks/2.sock';
  await channel.pollOnce();
  assert.equal(state.sent, 1);
  await channel.stop();
});

test('a conversation stored under another project directory is found by its session id, only when exactly one matches', (t) => {
  const config = temporaryDirectory(t);
  const session = '0d7c2a52-5d4c-4d0f-8c0a-6b6f5f3f9a11';
  const expected = `${config}/projects/-proj-recorded/${session}.jsonl`;
  const elsewhere = `${config}/projects/-proj-started-elsewhere/${session}.jsonl`;
  mkdirSync(path.dirname(elsewhere), { recursive: true });
  writeFileSync(elsewhere, '');
  assert.equal(resolveTranscriptPath(config, '/proj/recorded', session), elsewhere);
  const second = `${config}/projects/-proj-another/${session}.jsonl`;
  mkdirSync(path.dirname(second), { recursive: true });
  writeFileSync(second, '');
  assert.equal(resolveTranscriptPath(config, '/proj/recorded', session), expected, 'two matches decide nothing');
  mkdirSync(path.dirname(expected), { recursive: true });
  writeFileSync(expected, '');
  assert.equal(resolveTranscriptPath(config, '/proj/recorded', session), expected, 'the recorded project wins when it has the file');
});
