import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { createServer } from 'node:net';
import {
  observeTranscript,
  sendClaudeCodeMessage,
  resolveTranscriptPath,
  resolvePendingDelivery,
  latestPermissionMode,
  encodeClaudeProjectDir,
  nativePath,
  isNamedPipePath,
  checkSocketOwnership,
} from '../scripts/daemon/channels/claude-code-queue-io.mjs';
import { createClaudeCodeQueueChannel } from '../scripts/daemon/channels/claude-code-queue.mjs';
import { ensureClaudeCodeChannelSchema, readClaudeRoleSession } from '../scripts/daemon/channels/claude-code-queue-store.mjs';
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

function channelFixture(t, hostPlatform = 'linux') {
  const root = temporaryDirectory(t);
  mkdirSync(path.join(root, 'run'));
  const db = openInstallDb(path.join(root, 'run', 'install.db'));
  ensureClaudeCodeChannelSchema(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => db.close());
  const state = { session: 'sess-1', socket: '/tmp/cc-socks/1.sock', sent: 0, hours: 0, alive: { state: 'ok' } };
  const options = {
    db, installRoot: root, expectedOpGen: 1, env: { AGMSG_STORAGE_PATH: root },
    now: () => Date.UTC(2026, 9, 14) + state.hours * 3_600_000,
    log: () => {},
    listSeats: () => ({ state: 'ok', seats: [{ team: 'test', agent: 'alice', teamConfig: { agents: { alice: { registrations: [{ type: 'claude-code', project: root }] } } } }] }),
    readSession: () => ({ state: 'present', record: { team: 'test', agent: 'alice', type: 'claude-code', project: root, claude_config_dir: root, messaging_socket: state.socket, session: state.session } }),
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: () => ({ state: 'ok', unread: true, upTo: '{}' }),
    send: async (args) => { state.sent += 1; (state.modes ??= []).push(args.fromMode); return { state: 'sent' }; },
    readMode: () => state.mode ?? '',
    observe: () => (state.hold ? { state: 'held' } : { state: 'absent' }),
    socketAlive: () => state.alive,
    hostPlatform,
    transcriptPathOf: hostPlatform === 'win32' ? () => path.join(root, 'session.jsonl') : undefined,
  };
  state.options = options;
  const channel = createClaudeCodeQueueChannel(options);
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

test('a nudge opens with the session token as an auth line and claims no permission mode unless asked to', async (t) => {
  const dir = temporaryDirectory(t);
  const socketPath = path.join(dir, 's.sock');
  const received = new Promise((resolve) => {
    const server = createServer((connection) => {
      let data = '';
      connection.on('data', (chunk) => { data += chunk; });
      connection.on('end', () => { server.close(); resolve(data); });
    });
    server.listen(socketPath);
    t.after(() => server.close());
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  const result = await sendClaudeCodeMessage({ socketPath, nonce: 'n1', body: '[agmsg:n1] hello', token: 'tok-1', checkOwnership: () => ({ state: 'ok' }) });
  assert.equal(result.state, 'sent');
  const lines = (await received).trim().split('\n');
  assert.deepEqual(JSON.parse(lines[0]), { type: 'auth', token: 'tok-1' });
  assert.ok(!lines[1].includes('from-mode'));
});

test('a bypass seat is told from-mode=bypass; any other mode, or none readable, claims nothing', async (t) => {
  const dir = temporaryDirectory(t);
  const transcript = path.join(dir, 's.jsonl');
  const row = (mode) => `${JSON.stringify({ type: 'user', permissionMode: mode, message: { role: 'user', content: 'hi' } })}\n`;
  assert.equal(latestPermissionMode(path.join(dir, 'none.jsonl')), '');
  writeFileSync(transcript, `${JSON.stringify({ type: 'assistant' })}\n`);
  assert.equal(latestPermissionMode(transcript), '');
  writeFileSync(transcript, row('bypassPermissions') + row('auto') + `${JSON.stringify({ type: 'assistant' })}\n`);
  assert.equal(latestPermissionMode(transcript), 'auto', 'the latest row decides');
  writeFileSync(transcript, row('auto') + row('bypassPermissions'));
  assert.equal(latestPermissionMode(transcript), 'bypassPermissions');
  // shift+tab writes a row of its own, between user rows.
  writeFileSync(transcript, row('bypassPermissions') + `${JSON.stringify({ type: 'permission-mode', permissionMode: 'auto', sessionId: 's' })}\n` + `${JSON.stringify({ type: 'assistant' })}\n`);
  assert.equal(latestPermissionMode(transcript), 'auto', 'a permission-mode row counts');
  writeFileSync(transcript, row('auto') + `${JSON.stringify({ type: 'permission-mode', permissionMode: 'bypassPermissions' })}\n`);
  assert.equal(latestPermissionMode(transcript), 'bypassPermissions');

  for (const [mode, expected] of [['bypassPermissions', 'bypass'], ['auto', ''], ['default', ''], ['acceptEdits', ''], ['dontAsk', ''], ['plan', ''], ['', '']]) {
    const { channel, state } = channelFixture(t);
    state.mode = mode;
    await channel.pollOnce();
    assert.deepEqual(state.modes, [expected], mode || 'unreadable');
    await channel.stop();
  }

  const socketPath = path.join(dir, 'b.sock');
  const received = new Promise((resolve) => {
    const server = createServer((connection) => {
      let data = '';
      connection.on('data', (chunk) => { data += chunk; });
      connection.on('end', () => { server.close(); resolve(data); });
    });
    server.listen(socketPath);
    t.after(() => server.close());
  });
  await new Promise((resolve) => setTimeout(resolve, 50));
  await sendClaudeCodeMessage({ socketPath, nonce: 'n2', body: '[agmsg:n2] hi', fromMode: 'bypass', checkOwnership: () => ({ state: 'ok' }) });
  assert.match(JSON.parse((await received).trim()).message.content, /^<cross-session-message from="agmsgd" from-name="agmsgd" from-mode="bypass">/);
});

test('a held nudge is sent once the other way (claim, or no claim) and then left alone', async (t) => {
  // Not in bypass by its transcript, held anyway (it was switched): claim bypass.
  let { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  state.hold = true;
  for (let i = 0; i < 4; i += 1) await channel.pollOnce();
  assert.deepEqual(state.modes, ['', 'bypass'], 'each way once, then no more');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_claude_queue WHERE state='pending'").get().n, 1);
  assert.match(db.prepare('SELECT reason FROM beta_claude_seat').get().reason, /^peer_held/);
  await channel.stop();
  // A restarted daemon (a new channel on the same database) does not give the held nudge a new budget.
  const again = createClaudeCodeQueueChannel({ ...state.options });
  for (let i = 0; i < 3; i += 1) await again.pollOnce();
  assert.deepEqual(state.modes, ['', 'bypass'], 'a restart adds no send');
  await again.stop();

  // A bypass seat that holds it anyway (switched to a prompting mode): no claim next.
  ({ db, channel, state } = channelFixture(t));
  state.mode = 'bypassPermissions';
  await channel.pollOnce();
  state.hold = true;
  for (let i = 0; i < 4; i += 1) await channel.pollOnce();
  assert.deepEqual(state.modes, ['bypass', '']);

  await channel.stop();
});

test('a nudge the seat holds is seen from the preview that drops the brackets, and the seat is not called addressable', async (t) => {
  const dir = temporaryDirectory(t);
  const transcriptPath = path.join(dir, 'session.jsonl');
  writeFileSync(transcriptPath, `${JSON.stringify({
    type: 'system',
    subtype: 'informational',
    content: 'Held peer message \u2014 from an unidentified session; preview: \u00abagmsg:held-nonce New messages are waiting.\u00bb',
  })}\n`);
  assert.equal(observeTranscript(transcriptPath, 'held-nonce').state, 'held');

  const { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  state.hold = true;
  await channel.pollOnce();
  const seat = db.prepare('SELECT state, reason FROM beta_claude_seat').get();
  assert.equal(seat.state, 'blocked');
  assert.match(seat.reason, /^peer_held/);
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

// Native Windows (measured on a real machine 2026-10-21): the inbox is the named
// pipe \\.\pipe\LOCAL\cc-msg-<hex>, the profile has no CLAUDE_CONFIG_DIR, and
// the transcript directory is the project path with every character that is not
// a letter, digit or "-" turned into "-".
test('Windows: the transcript directory name, shell-style paths and pipe paths are read the way Claude Code writes them', () => {
  assert.equal(encodeClaudeProjectDir('C:\\Users\\koich\\agmsg-agents\\win-test', 'win32'), 'C--Users-koich-agmsg-agents-win-test');
  assert.equal(encodeClaudeProjectDir('C:/Users/koich/agmsg-agents/win-test', 'win32'), 'C--Users-koich-agmsg-agents-win-test');
  assert.equal(encodeClaudeProjectDir('/home/u/a_b.c', 'linux'), '-home-u-a_b.c');
  assert.equal(nativePath('/c/Users/koich/.claude', 'win32'), 'C:/Users/koich/.claude');
  assert.equal(nativePath('/c', 'win32'), 'C:/');
  assert.equal(nativePath('C:\\Users\\x', 'win32'), 'C:\\Users\\x');
  assert.equal(nativePath('/c/Users/x', 'linux'), '/c/Users/x');
  assert.equal(isNamedPipePath('\\\\.\\pipe\\LOCAL\\cc-msg-ab12'), true);
  assert.equal(isNamedPipePath('/tmp/cc-socks/1.sock'), false);
  assert.equal(isNamedPipePath('\\\\.\\pipe\\'), false);
  // A pipe is never probed: no filesystem call can be made on this name, so the
  // answer is "unknown, go on" for a name that is not there.
  assert.deepEqual(checkSocketOwnership('\\\\.\\pipe\\LOCAL\\cc-msg-not-here', 'win32'), { state: 'ok' });
});

test('Windows: a seat is no longer blocked as unsupported', async (t) => {
  const { db, channel, state } = channelFixture(t, 'win32');
  await channel.pollOnce();
  assert.equal(state.sent, 1);
  assert.equal(db.prepare('SELECT COUNT(*) AS n FROM beta_claude_seat WHERE reason = ?').get('windows_not_supported_yet').n, 0);
  await channel.stop();
});

test('a nudge that finds its socket gone (ENOENT on connect) ends the row and is not retried for that socket', async (t) => {
  const { db, channel, state } = channelFixture(t, 'win32');
  const options = state.options;
  let calls = 0;
  const gone = createClaudeCodeQueueChannel({ ...options, send: async () => { calls += 1; return { state: 'failed', reason: 'socket_error:ENOENT' }; } });
  for (let i = 0; i < 4; i += 1) await gone.pollOnce();
  assert.equal(calls, 1, 'one attempt, then the seat waits for a new socket');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_claude_queue").get().n, 1);
  assert.equal(db.prepare("SELECT reason FROM beta_claude_seat").get().reason, 'messaging_socket_missing');
  state.socket = '/tmp/cc-socks/9.sock';
  await gone.pollOnce();
  assert.equal(calls, 2);
  await gone.stop();
  await channel.stop();
});

// Only on a Windows machine: a real pipe, probed by the preflight, then nudged.
test('Windows pipe: the preflight makes no connection, and an authenticated nudge is delivered', { skip: process.platform !== 'win32' }, async (t) => {
  const name = `\\\\.\\pipe\\LOCAL\\agmsg-test-${process.pid}`;
  let connections = 0;
  const lines = [];
  const server = createServer((connection) => {
    connections += 1;
    let data = '';
    connection.on('data', (chunk) => { data += chunk; });
    connection.on('end', () => lines.push(...data.trim().split('\n')));
  });
  await new Promise((resolve) => server.listen(name, resolve));
  t.after(() => server.close());
  assert.deepEqual(checkSocketOwnership(name, 'win32'), { state: 'ok' });
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(connections, 0, 'the preflight connected to the pipe');
  const result = await sendClaudeCodeMessage({ socketPath: name, nonce: 'w1', body: '[agmsg:w1] hi', token: 'tok-w' });
  assert.equal(result.state, 'sent');
  await new Promise((resolve) => setTimeout(resolve, 200));
  assert.equal(connections, 1);
  assert.deepEqual(JSON.parse(lines[0]), { type: 'auth', token: 'tok-w' });
});

test('a seat whose hook could not publish a destination is reported with that reason, and the record is read from disk', async (t) => {
  const { root, db, state } = (() => { const f = channelFixture(t); return { root: f.state.options.installRoot, db: f.db, state: f.state }; })();
  const record = (extra) => `team=test\nagent=alice\ntype=claude-code\nproject=${root}\nsession=sess-1\n${extra}`;
  writeFileSync(path.join(root, 'run', 'role-session.test__alice'), record('messaging_blocked=seat_pid_unresolved\n'));
  const read = readClaudeRoleSession(path.join(root, 'run'), 'test', 'alice');
  assert.equal(read.record.messaging_blocked, 'seat_pid_unresolved');
  const channel = createClaudeCodeQueueChannel({ ...state.options, readSession: () => read });
  await channel.pollOnce();
  assert.equal(db.prepare("SELECT state || '/' || reason AS r FROM beta_claude_seat").get().r, 'unaddressable/seat_pid_unresolved');
  assert.equal(state.sent, 0);
  // A value that is not a plain word is ignored, not shown.
  writeFileSync(path.join(root, 'run', 'role-session.test__alice'), record('messaging_blocked=bad value;\n'));
  assert.equal(readClaudeRoleSession(path.join(root, 'run'), 'test', 'alice').record.messaging_blocked, '');
});

test('a project that chose something other than agmsgd gets no nudge, a waiting one is dropped, and a project that never chose is unchanged', async (t) => {
  const { db, channel, state } = channelFixture(t);
  const root = state.options.installRoot;
  await channel.pollOnce();
  assert.equal(state.sent, 1, 'no choice recorded: agmsgd delivers as before');
  writeFileSync(path.join(root, 'run', 'delivery-choice'), `claude-code\t${root}\tmonitor\n`);
  for (let i = 0; i < 3; i += 1) await channel.pollOnce();
  assert.equal(state.sent, 1, 'no further nudge for an opted-out project');
  assert.equal(db.prepare("SELECT state || '/' || reason AS r FROM beta_claude_seat").get().r, 'unaddressable/delivery_chosen_monitor');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_claude_queue WHERE state = 'pending'").get().n, 0);
  writeFileSync(path.join(root, 'run', 'delivery-choice'), `claude-code\t${root}\tagmsgd\n`);
  state.hold = false;
  await channel.pollOnce();
  assert.equal(db.prepare("SELECT state FROM beta_claude_seat").get().state === 'unaddressable', false, 'choosing agmsgd again puts the seat back');
});
