import assert from 'node:assert/strict';
import { appendFileSync, fstatSync, mkdirSync, mkdtempSync, readSync, renameSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import {
  createAsyncTranscriptObserver,
  createTranscriptObserver,
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

function channelFixture(t, overrides = {}) {
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
    ...overrides,
  });
  return { db, channel, state, root };
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

function deliveredRow(nonce) {
  return `${JSON.stringify({ type: 'user', origin: { kind: 'peer', body: `[agmsg:${nonce}]` } })}\n`;
}

function transcriptGrowth() {
  return `${JSON.stringify({ type: 'assistant', message: { content: 'context '.repeat(100_000) } })}\n`;
}

test('delivery survives more than 512 KiB of subsequent transcript growth and cold recovery', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  writeFileSync(file, deliveredRow('older-delivery') + transcriptGrowth());
  assert.equal(observeTranscript(file, 'older-delivery').state, 'delivered');
});

test('observer scans new bytes once, retains held evidence, and waits for a complete appended row', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'incremental';
  writeFileSync(file, transcriptGrowth());
  let bytes = 0;
  const observe = createTranscriptObserver({ read(...args) { const count = readSync(...args); bytes += count; return count; } });
  observe.begin(file, nonce);
  assert.equal(observe(file, nonce).state, 'absent');
  assert.equal(bytes, 2, 'begin and observe only check the byte before the EOF watermark');
  appendFileSync(file, `${JSON.stringify({ type: 'queue-operation', operation: 'enqueue', content: `[agmsg:${nonce}]` })}\n`);
  assert.equal(observe(file, nonce).state, 'absent', 'enqueue never confirms');
  appendFileSync(file, `${JSON.stringify({ type: 'system', subtype: 'informational', content: `[agmsg:${nonce}] held` })}\n`);
  assert.equal(observe(file, nonce).state, 'held');
  const scanned = bytes;
  assert.equal(observe(file, nonce).state, 'held');
  assert.equal(bytes, scanned + 1, 'unchanged polls only validate the checkpoint boundary');
  const row = deliveredRow(nonce);
  appendFileSync(file, row.slice(0, -4));
  assert.equal(observe(file, nonce).state, 'held');
  appendFileSync(file, row.slice(-4, -1));
  assert.equal(observe(file, nonce).state, 'held', 'JSON without its row terminator is incomplete');
  appendFileSync(file, '\n' + transcriptGrowth());
  assert.equal(observe(file, nonce).state, 'delivered');
});

test('cold recovery crosses giant rows and chunk boundaries, and then only scans appends', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'recover';
  writeFileSync(file, transcriptGrowth());
  let bytes = 0;
  const observe = createTranscriptObserver({ read(...args) { const count = readSync(...args); bytes += count; return count; } });
  assert.equal(observe(file, nonce).state, 'absent');
  assert.ok(bytes > 512 * 1024);
  const scanned = bytes;
  assert.equal(observe(file, nonce).state, 'absent');
  assert.equal(bytes, scanned + 1, 'unchanged polls only validate the checkpoint boundary');
  // Unicode and JSON escapes may straddle byte/chunk/append boundaries.
  const row = JSON.stringify({ type: 'attachment', attachment: { type: 'queued_command', prompt: '日本語 ' + `[agmsg:${nonce}]` } }).replace('[agmsg:', '\\u005bagmsg:') + '\n';
  const encoded = Buffer.from(row);
  const split = encoded.indexOf(Buffer.from('日本語')) + 1;
  appendFileSync(file, encoded.subarray(0, split));
  assert.equal(observe(file, nonce).state, 'absent');
  appendFileSync(file, encoded.subarray(split));
  assert.equal(observe(file, nonce).state, 'delivered');
});

test('observer resets held state after rotation or truncation and recovers evicted notices', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'replaced';
  const held = `${JSON.stringify({ type: 'system', subtype: 'informational', content: `[agmsg:${nonce}] held` })}\n`;
  const observe = createTranscriptObserver({ maxEntries: 1 });
  writeFileSync(file, held);
  assert.equal(observe(file, nonce).state, 'held');
  renameSync(file, file + '.old');
  writeFileSync(file, '{}\n');
  assert.equal(observe(file, nonce).state, 'absent');
  appendFileSync(file, held);
  assert.equal(observe(file, nonce).state, 'held');
  writeFileSync(file, '{}\n');
  assert.equal(observe(file, nonce).state, 'absent');
  appendFileSync(file, deliveredRow(nonce) + transcriptGrowth());
  assert.equal(observe(file, 'another-notice').state, 'absent');
  assert.equal(observe(file, nonce).state, 'delivered', 'eviction falls back to full recovery');
  observe.clear();
  assert.equal(observe(file, nonce).state, 'delivered', 'restart recovers historical delivery');
});

test('malformed JSON and lookalike fields never confirm delivery', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  for (const row of [
    '{"type":"user","origin":{"body":"[agmsg:strict]"},}\n',
    '{"type":"user","origin":{"body":"[agmsg:strict]"}}garbage\n',
    '{"type":"user","origin":{"body":"[agmsg:strict]"},"origin":{}}\n',
    JSON.stringify({ type: 'user', other: { origin: { body: '[agmsg:strict]' } } }) + '\n',
    JSON.stringify({ type: 'user', origin: { body: '[agmsg:strict]' }, other: [1, 2, true, null, -0.25e+3] }).slice(0, -1) + ',}\n',
  ]) {
    writeFileSync(file, row);
    assert.equal(observeTranscript(file, 'strict').state, 'absent', row);
  }
});

test('channel confirms delivery buried by growth and can send its next notice', async (t) => {
  let file;
  const { db, channel, state, root } = channelFixture(t, {
    observe: createTranscriptObserver(),
    send: async ({ nonce }) => {
      state.sent += 1;
      appendFileSync(file, deliveredRow(nonce) + transcriptGrowth());
      return { state: 'sent' };
    },
  });
  file = `${root}/projects/${root.replace(/\//g, '-')}/sess-1.jsonl`;
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, transcriptGrowth());
  await channel.pollOnce();
  assert.deepEqual(db.prepare('SELECT state FROM beta_claude_queue ORDER BY id').all().map((row) => row.state), ['confirmed']);
  await channel.pollOnce();
  assert.equal(state.sent, 2);
  assert.deepEqual(db.prepare('SELECT state FROM beta_claude_queue ORDER BY id').all().map((row) => row.state), ['confirmed', 'confirmed']);
  await channel.stop();
});

test('delivery fields retain their provenance and valid JSON scalars do not interfere', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'provenance';
  const marker = `[agmsg:${nonce}]`;
  for (const row of [
    { type: 'user', message: { content: marker } },
    { type: 'user', origin: { body: { text: marker } } },
    { type: 'attachment', attachment: { type: 'other', prompt: marker } },
    { type: 'attachment', other: { type: 'queued_command', prompt: marker } },
    { type: 'queue-operation', operation: 'enqueue', content: marker, origin: { body: marker } },
  ]) {
    writeFileSync(file, JSON.stringify(row) + '\n');
    assert.equal(observeTranscript(file, nonce).state, 'absent');
  }
  writeFileSync(file, JSON.stringify({ type: 'user', origin: { body: marker }, other: [0, -1, 0.25, 1e100, true, false, null, {}, []] }) + '\n');
  assert.equal(observeTranscript(file, nonce).state, 'delivered');
});

test('nesting guard rejects the whole over-deep row and resumes at the next row', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'depth-guard';
  const row = (depth) => `{"type":"user","origin":{"body":"[agmsg:${nonce}]"},"other":${'['.repeat(depth)}0${']'.repeat(depth)}}\n`;
  writeFileSync(file, row(127));
  assert.equal(observeTranscript(file, nonce).state, 'delivered', '128 container levels are accepted');
  writeFileSync(file, row(128));
  assert.equal(observeTranscript(file, nonce).state, 'absent', 'deeper evidence rows are deliberately rejected');
  appendFileSync(file, deliveredRow(nonce));
  assert.equal(observeTranscript(file, nonce).state, 'delivered', 'a rejected row never poisons subsequent evidence');
});

test('same-inode rewrite cannot splice cached partial JSON into delivery evidence', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const observe = createTranscriptObserver();
  writeFileSync(file, '{"type":"user","origin":{"body":"');
  assert.equal(observe(file, 'synthetic').state, 'absent');
  writeFileSync(file, '{"type":"tool","origin":{"body":"[agmsg:synthetic]"}}\n');
  assert.equal(observeTranscript(file, 'synthetic').state, 'absent');
  assert.equal(observe(file, 'synthetic').state, 'absent');
});

test('EOF watermark ignores a pre-existing partial row, then accepts the next complete row', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const observe = createTranscriptObserver();
  writeFileSync(file, 'unfinished-prefix');
  observe.begin(file, 'mid-row');
  appendFileSync(file, deliveredRow('mid-row'));
  assert.equal(observe(file, 'mid-row').state, 'absent', 'a suffix is never a standalone row');
  appendFileSync(file, deliveredRow('mid-row'));
  assert.equal(observe(file, 'mid-row').state, 'delivered');
});

test('same-inode replacement of a completed checkpoint must preserve its newline boundary', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const observe = createTranscriptObserver();
  writeFileSync(file, '{}\n');
  assert.equal(observe(file, 'boundary').state, 'absent');
  writeFileSync(file, 'bad' + deliveredRow('boundary'));
  assert.equal(observe(file, 'boundary').state, 'absent');
  assert.equal(observeTranscript(file, 'boundary').state, 'absent');
});

test('same-size rewrites between polls invalidate watermarks and absent, held or delivered checkpoints', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'between-polls';
  const rows = {
    absent: JSON.stringify({ type: 'tool', body: 'unrelated' }),
    held: JSON.stringify({ type: 'system', subtype: 'informational', content: `[agmsg:${nonce}]` }),
    delivered: deliveredRow(nonce).trimEnd(),
  };
  const padded = (state) => rows[state].padEnd(512, ' ') + '\n';
  for (const [before, after, begin] of [['absent', 'delivered'], ['held', 'delivered'], ['delivered', 'absent'], ['absent', 'delivered', true]]) {
    writeFileSync(file, padded(before));
    utimesSync(file, 10, 10);
    const original = statSync(file);
    const observe = createTranscriptObserver();
    if (begin) observe.begin(file, nonce);
    assert.equal(observe(file, nonce).state, before);
    writeFileSync(file, padded(after));
    utimesSync(file, 20, 20);
    assert.equal(statSync(file).ino, original.ino);
    assert.equal(statSync(file).size, original.size);
    assert.equal(observe(file, nonce).state, after, `${before} checkpoint must not survive a same-size rewrite`);
    assert.equal(observe(file, nonce).state, after, 'unchanged subsequent polls retain the new observation');
  }
});

test('short reads preserve row boundaries and a read failure discards cached progress', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  writeFileSync(file, '{}\n' + deliveredRow('short-reads'));
  let fail = false;
  const observe = createTranscriptObserver({ read(fd, buffer, offset, length, position) {
    if (fail) throw Object.assign(new Error('synthetic read error'), { code: 'EIO' });
    return readSync(fd, buffer, offset, Math.min(length, 3), position);
  } });
  assert.equal(observe(file, 'short-reads').state, 'delivered');
  fail = true;
  assert.deepEqual(observe(file, 'short-reads'), { state: 'unreadable', reason: 'transcript_read_failed' });
  fail = false;
  writeFileSync(file, '{"type":"tool","origin":{"body":"[agmsg:short-reads]"}}\n');
  assert.equal(observe(file, 'short-reads').state, 'absent');
  appendFileSync(file, deliveredRow('short-reads'));
  assert.equal(observe(file, 'short-reads').state, 'delivered');
});

test('an incomplete UTF-8 suffix after a JSON object cannot be ignored at the newline', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  writeFileSync(file, Buffer.concat([Buffer.from(deliveredRow('utf8-tail').trimEnd()), Buffer.from([0xe3, 10])]));
  assert.equal(observeTranscript(file, 'utf8-tail').state, 'absent');
});

test('a same-size rewrite during short reads cannot synthesize delivery evidence', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'scan-rewrite';
  const user = deliveredRow(nonce);
  const tool = user.replace('"user"', '"tool"');
  assert.equal(Buffer.byteLength(user), Buffer.byteLength(tool));
  writeFileSync(file, user);
  let rewrite = true;
  const observe = createTranscriptObserver({ read(fd, buffer, offset, length, position) {
    const count = readSync(fd, buffer, offset, Math.min(length, 14), position);
    if (rewrite) { rewrite = false; writeFileSync(file, tool); }
    return count;
  } });
  assert.equal(observe(file, nonce).state, 'unreadable');
  assert.equal(observeTranscript(file, nonce).state, 'absent');
  assert.equal(observe(file, nonce).state, 'absent', 'unstable scan progress is discarded');
});

test('unrelated append during a scan permits verified row confirmation', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'scan-append';
  writeFileSync(file, deliveredRow(nonce));
  let append = true;
  const observe = createTranscriptObserver({ read(fd, buffer, offset, length, position) {
    const count = readSync(fd, buffer, offset, length, position);
    if (append) { append = false; appendFileSync(file, '{}\n'); }
    return count;
  } });
  assert.equal(observe(file, nonce).state, 'delivered', 'unchanged candidate bytes prove delivery despite unrelated growth');
});

test('repeated unrelated appends preserve the watermark and complete checkpoints', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  writeFileSync(file, transcriptGrowth());
  let bytes = 0;
  const observe = createTranscriptObserver({ read(...args) {
    const count = readSync(...args);
    bytes += count;
    appendFileSync(file, '{}\n');
    return count;
  } });
  observe.begin(file, 'active-seat');
  for (let poll = 0; poll < 5; poll += 1) {
    assert.equal(observe(file, 'active-seat').state, 'absent');
    assert.ok(bytes < 1_000, 'growth must not force a cold scan of the existing 800 KB');
  }
  appendFileSync(file, deliveredRow('active-seat'));
  assert.equal(observe(file, 'active-seat').state, 'delivered');
});

test('an actively appending transcript confirms a notice and permits the next notice', async (t) => {
  let file;
  const observe = createTranscriptObserver({ read(...args) {
    const count = readSync(...args);
    appendFileSync(file, '{}\n');
    return count;
  } });
  const { db, channel, state, root } = channelFixture(t, {
    observe,
    send: async ({ nonce }) => {
      state.sent += 1;
      appendFileSync(file, deliveredRow(nonce));
      return { state: 'sent' };
    },
  });
  file = `${root}/projects/${root.replace(/\//g, '-')}/sess-1.jsonl`;
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, transcriptGrowth());
  await channel.pollOnce();
  await channel.pollOnce();
  assert.equal(state.sent, 2);
  assert.deepEqual(db.prepare('SELECT state FROM beta_claude_queue ORDER BY id').all().map((row) => row.state), ['confirmed', 'confirmed']);
  await channel.stop();
});

test('a rewrite followed by growth cannot pass candidate-row hash verification', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  // Neither actual row contains delivery evidence for this nonce: the old
  // user row has another nonce; the replacement has the nonce but type tool.
  const oldRow = deliveredRow('ignored');
  const replacement = deliveredRow('rewrite').replace('"user"', '"tool"');
  assert.equal(Buffer.byteLength(oldRow), Buffer.byteLength(replacement));
  writeFileSync(file, oldRow);
  let rewrite = true;
  const observe = createTranscriptObserver({ read(fd, buffer, offset, length, position) {
    const count = readSync(fd, buffer, offset, Math.min(length, 14), position);
    if (rewrite) { rewrite = false; writeFileSync(file, replacement + '{}\n'); }
    return count;
  } });
  assert.equal(observe(file, 'rewrite').state, 'unreadable', 'growth cannot disguise spliced candidate bytes');
  assert.equal(observe(file, 'rewrite').state, 'absent');
});

test('a candidate larger than one chunk is verified with bounded reread buffers', (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const row = JSON.stringify({ type: 'user', origin: { body: 'x'.repeat(800_000) + '[agmsg:large-row]' } }) + '\n';
  writeFileSync(file, row);
  let largest = 0;
  let bytes = 0;
  const observe = createTranscriptObserver({ read(fd, buffer, offset, length, position) {
    largest = Math.max(largest, buffer.length);
    const count = readSync(fd, buffer, offset, length, position);
    bytes += count;
    return count;
  } });
  assert.equal(observe(file, 'large-row').state, 'delivered');
  assert.equal(largest, 64 * 1024);
  assert.equal(bytes, 2 * Buffer.byteLength(row), 'only the candidate row is reread for verification');
});

test('cooperative cold recovery yields after at most 64 KiB so the event loop can run', async (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  writeFileSync(file, transcriptGrowth());
  let bytes = 0;
  let budget = 0;
  let yields = 0;
  const observe = createTranscriptObserver({ cooperative: true,
    read(...args) { const count = readSync(...args); bytes += count; budget += count; return count; },
    async schedule() {
      assert.ok(budget <= 64 * 1024, 'a scheduling unit reads at most one chunk');
      budget = 0;
      yields += 1;
      await new Promise((resolve) => setImmediate(resolve));
    },
  });
  const pending = observe(file, 'cooperative');
  assert.equal(typeof pending?.then, 'function');
  assert.equal(bytes, 64 * 1024, 'only one chunk runs before the first yield');
  assert.equal((await pending).state, 'absent');
  assert.ok(yields > 1);
  assert.equal(bytes, statSync(file).size);
});

test('default cooperative scheduler lets an already scheduled heartbeat run before cold recovery completes', async (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  writeFileSync(file, transcriptGrowth());
  let settled = false;
  const heartbeat = new Promise((resolve) => setImmediate(resolve));
  const observe = createAsyncTranscriptObserver();
  const pending = Promise.resolve(observe(file, 'heartbeat')).then((result) => { settled = true; return result; });
  await heartbeat;
  assert.equal(settled, false, 'cold recovery yields to the event loop before finishing');
  assert.equal((await pending).state, 'absent');
});

test('cancellation during cooperative candidate verification closes its descriptor and discards progress', async (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  const nonce = 'cancel-proof';
  const row = JSON.stringify({ type: 'user', origin: { body: 'x'.repeat(160_000) + `[agmsg:${nonce}]` } }) + '\n';
  writeFileSync(file, row);
  const controller = new AbortController();
  let bytes = 0;
  let fd;
  let budget = 0;
  const observe = createTranscriptObserver({ cooperative: true,
    read(...args) { fd = args[0]; const count = readSync(...args); bytes += count; budget += count; return count; },
    async schedule() {
      assert.ok(budget <= 64 * 1024, 'candidate reread also yields after one chunk');
      budget = 0;
      if (bytes > Buffer.byteLength(row)) controller.abort();
    },
  });
  assert.deepEqual(await observe(file, nonce, { signal: controller.signal }), { state: 'unreadable', reason: 'transcript_observation_cancelled' });
  assert.ok(bytes > Buffer.byteLength(row), 'cancellation occurs during the proof reread');
  assert.ok(bytes < 2 * Buffer.byteLength(row), 'the proof reread stops early');
  assert.throws(() => fstatSync(fd), { code: 'EBADF' });
  writeFileSync(file, deliveredRow(nonce).replace('"user"', '"tool"'));
  assert.equal((await observe(file, nonce)).state, 'absent', 'cancelled candidate progress never confirms');
});

test('channel stop cancels cold observation before confirmation or another send', async (t) => {
  let entered;
  const suspended = new Promise((resolve) => { entered = resolve; });
  let fd;
  const observe = createTranscriptObserver({ cooperative: true,
    read(...args) { fd = args[0]; return readSync(...args); },
    schedule(signal) {
      entered();
      return new Promise((resolve) => {
        if (signal.aborted) resolve();
        else signal.addEventListener('abort', resolve, { once: true });
      });
    },
  });
  const { db, channel, state, root } = channelFixture(t, { observe });
  const file = path.join(root, 'cold.jsonl');
  writeFileSync(file, transcriptGrowth() + deliveredRow('stop-cold'));
  db.prepare(`INSERT INTO beta_claude_queue (seat, messaging_socket, transcript_path, up_to, nonce, state, created_at)
    VALUES (?, ?, ?, '{}', 'stop-cold', 'pending', '2026-10-17T00:00:00Z')`).run(JSON.stringify(['test', 'alice']), state.socket, file);
  const polling = channel.pollOnce();
  const phase = await Promise.race([suspended.then(() => 'yielded'), polling.then(() => 'finished')]);
  assert.equal(phase, 'yielded', 'cold observation must suspend before finishing');
  await channel.stop();
  await polling;
  assert.throws(() => fstatSync(fd), { code: 'EBADF' });
  assert.equal(state.sent, 0);
  assert.equal(db.prepare('SELECT state FROM beta_claude_queue').get().state, 'pending');
  await channel.pollOnce();
  assert.equal(state.sent, 0);
});

test('abort while awaiting the default scheduler closes the cold-scan descriptor', async (t) => {
  const file = path.join(temporaryDirectory(t), 'session.jsonl');
  writeFileSync(file, transcriptGrowth());
  const controller = new AbortController();
  let fd;
  const observe = createAsyncTranscriptObserver({ read(...args) { fd = args[0]; return readSync(...args); } });
  const pending = observe(file, 'default-abort', { signal: controller.signal });
  controller.abort();
  assert.deepEqual(await pending, { state: 'unreadable', reason: 'transcript_observation_cancelled' });
  assert.throws(() => fstatSync(fd), { code: 'EBADF' });
  assert.equal((await observe(file, 'default-abort')).state, 'absent');
});

test('the daemon default observer yields while recovering an existing pending notice', async (t) => {
  const { db, channel, state, root } = channelFixture(t, { observe: undefined });
  const file = path.join(root, 'default-cold.jsonl');
  writeFileSync(file, transcriptGrowth() + deliveredRow('default-cold'));
  db.prepare(`INSERT INTO beta_claude_queue (seat, messaging_socket, transcript_path, up_to, nonce, state, created_at)
    VALUES (?, ?, ?, '{}', 'default-cold', 'pending', '2026-10-17T00:00:00Z')`).run(JSON.stringify(['test', 'alice']), state.socket, file);
  const heartbeat = new Promise((resolve) => setImmediate(resolve));
  const polling = channel.pollOnce();
  await heartbeat;
  assert.equal(db.prepare('SELECT state FROM beta_claude_queue').get().state, 'pending');
  await polling;
  assert.equal(db.prepare('SELECT state FROM beta_claude_queue').get().state, 'confirmed');
  assert.equal(state.sent, 0, 'recovery never resends an existing notice');
  await channel.stop();
});
