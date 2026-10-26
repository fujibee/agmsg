import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { EventEmitter } from 'node:events';
import { DatabaseSync } from 'node:sqlite';
import { readUnreadSnapshot } from '../scripts/daemon/channels/codex-queue-store.mjs';

import { createServer } from 'node:net';
import {
  sendClaudeCodeMessage,
  resolveTranscriptPath,
  latestPermissionMode,
  encodeClaudeProjectDir,
  nativePath,
  isNamedPipePath,
  checkSocketOwnership,
} from '../scripts/daemon/channels/claude-code-queue-io.mjs';
import { createClaudeCodeQueueChannel } from '../scripts/daemon/channels/claude-code-queue.mjs';
import { ensureClaudeCodeChannelSchema, readClaudeRoleSession } from '../scripts/daemon/channels/claude-code-queue-store.mjs';
import { readOwnerAndIntentReadOnly } from '../scripts/daemon/status.mjs';
import { openInstallDb } from '../scripts/daemon/db.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsg-cc-queue-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function channelFixture(t, hostPlatform = 'linux') {
  const root = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-claude-queue-'));
  mkdirSync(path.join(root, 'run'));
  const db = openInstallDb(path.join(root, 'run', 'install.db'));
  ensureClaudeCodeChannelSchema(db);
  db.exec("UPDATE daemon_intent SET desired='on', op_gen=1");
  t.after(() => { db.close(); rmSync(root, { recursive: true, force: true }); });
  const state = { session: 'sess-1', socket: '/tmp/cc-socks/1.sock', sent: 0, sequence: 1, hours: 0, alive: { state: 'ok' } };
  const options = {
    db, installRoot: root, expectedOpGen: 1, env: { AGMSG_STORAGE_PATH: root },
    now: () => Date.UTC(2026, 9, 14) + state.hours * 3_600_000,
    log: () => {},
    listSeats: () => ({ state: 'ok', seats: [{ team: 'test', agent: 'alice', teamConfig: { agents: { alice: { registrations: [{ type: 'claude-code', project: root }] } } } }] }),
    readSession: () => ({ state: 'present', record: { team: 'test', agent: 'alice', type: 'claude-code', project: root, claude_config_dir: root, messaging_socket: state.socket, session: state.session, ...state.record } }),
    readDriver: () => ({ state: 'ok', driver: 'sqlite' }),
    openStore: () => ({ close() {} }),
    readSnapshot: (_store, _team, _agent, cursor = '') => ({
      state: 'ok', unread: state.unread !== false && state.sequence > (cursor ? JSON.parse(cursor).eventSeq : 0),
      upTo: JSON.stringify({ eventSeq: state.sequence, legacyId: 0 }),
    }),
    send: async (args) => { state.sent += 1; (state.modes ??= []).push(args.fromMode); return { state: 'sent' }; },
    readMode: () => state.mode ?? '',
    socketAlive: () => state.alive,
    hostPlatform,
    transcriptPathOf: hostPlatform === 'win32' ? () => path.join(root, 'session.jsonl') : undefined,
  };
  state.options = options;
  const channel = createClaudeCodeQueueChannel(options);
  return { db, channel, state };
}

test('socket send success immediately advances the notified cursor and suppresses the same unread', async (t) => {
  const { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  const row = db.prepare('SELECT state, up_to FROM beta_claude_queue').get();
  assert.equal(row.state, 'confirmed');
  assert.deepEqual(JSON.parse(row.up_to), { eventSeq: 1, legacyId: 0 });
  assert.equal(db.prepare("SELECT count(*) AS n FROM beta_claude_queue WHERE state='pending'").get().n, 0);
  for (const hours of [1, 9, 40]) { state.hours = hours; await channel.pollOnce(); }
  assert.equal(state.sent, 1);
  state.sequence = 2;
  await channel.pollOnce();
  assert.equal(state.sent, 2, 'new unread past the notified cursor gets another nudge');
  assert.equal(JSON.parse(db.prepare('SELECT up_to FROM beta_claude_queue ORDER BY id DESC LIMIT 1').get().up_to).eventSeq, 2);
  await channel.stop();
});

test('changing a session or socket does not resend old unread, and new unread still gets nudged', async (t) => {
  const { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  state.session = 'sess-2';
  state.socket = '/tmp/cc-socks/2.sock';
  await channel.pollOnce();
  assert.equal(state.sent, 1);
  state.sequence += 1;
  await channel.pollOnce();
  assert.equal(state.sent, 2);
  assert.deepEqual(db.prepare('SELECT state FROM beta_claude_queue ORDER BY id').all().map((row) => row.state), ['confirmed', 'confirmed']);
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

for (const unread of [false, true]) {
  test(`a closed seat is unaddressable when unread is ${unread}`, async (t) => {
    const { db, state } = channelFixture(t);
    state.alive = { state: 'unreadable', reason: 'messaging_socket_missing' };
    const channel = createClaudeCodeQueueChannel({
      ...state.options, readSnapshot: () => ({ state: 'ok', unread, upTo: '{}' }),
    });
    await channel.pollOnce();
    assert.deepEqual({ ...db.prepare('SELECT state, reason FROM beta_claude_seat').get() },
      { state: 'unaddressable', reason: 'messaging_socket_missing' });
    assert.equal(state.sent, 0);
    assert.equal(db.prepare('SELECT count(*) AS n FROM beta_claude_queue').get().n, 0);
    await channel.stop();
  });
}

test('an idle seat is addressable only after its socket check succeeds', async (t) => {
  const { db, state } = channelFixture(t);
  let checks = 0;
  const channel = createClaudeCodeQueueChannel({
    ...state.options, readSnapshot: () => ({ state: 'ok', unread: false, upTo: '{}' }),
    socketAlive: () => { checks += 1; return { state: 'ok' }; },
  });
  await channel.pollOnce();
  assert.equal(checks, 1);
  assert.equal(db.prepare('SELECT state FROM beta_claude_seat').get().state, 'addressable');
  await channel.stop();
});

test('an idle seat whose socket cannot be checked reports the uncertainty', async (t) => {
  const { db, state } = channelFixture(t);
  state.alive = { state: 'unreadable', reason: 'messaging_socket_stat_failed' };
  const channel = createClaudeCodeQueueChannel({
    ...state.options, readSnapshot: () => ({ state: 'ok', unread: false, upTo: '{}' }),
  });
  await channel.pollOnce();
  assert.deepEqual({ ...db.prepare('SELECT state, reason FROM beta_claude_seat').get() },
    { state: 'blocked', reason: 'messaging_socket_stat_failed' });
  assert.equal(state.sent, 0);
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

test('transcript evidence is not read and cannot block subsequent nudges', async (t) => {
  const { db, state } = channelFixture(t);
  const channel = createClaudeCodeQueueChannel({ ...state.options, observe: () => { throw new Error('must not observe'); } });
  await channel.pollOnce();
  state.sequence += 1;
  await channel.pollOnce();
  assert.equal(state.sent, 2);
  assert.deepEqual({ ...db.prepare('SELECT state, reason FROM beta_claude_seat').get() }, { state: 'addressable', reason: '' });
  await channel.stop();
});

for (const [name, override] of [
  ['unreadable mode', { readMode() { throw new Error('unreadable transcript'); } }],
  ['missing path', { transcriptPathOf() { return ''; } }],
  ['unreadable path', { transcriptPathOf() { throw new Error('no transcript path'); } }],
]) {
  test(`permission metadata is best effort: ${name}`, async (t) => {
    const { state } = channelFixture(t);
    const channel = createClaudeCodeQueueChannel({ ...state.options, ...override });
    await channel.pollOnce();
    assert.equal(state.sent, 1);
    assert.deepEqual(state.modes, ['']);
    await channel.stop();
  });
}

test('missing transcript metadata does not prevent a socket send', async (t) => {
  const { channel, state } = channelFixture(t);
  state.record = { claude_config_dir: '', session: '' };
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

for (const reason of ['socket_error:ENOENT', 'messaging_socket_missing', 'connect_failed', 'socket_write_error:EPIPE', 'send_timeout', 'socket_error:ECONNREFUSED']) {
  test(`send failure records its reason and retries the same socket on the next poll: ${reason}`, async (t) => {
    const { db, state } = channelFixture(t, 'win32');
    let calls = 0;
    const channel = createClaudeCodeQueueChannel({ ...state.options, send: async () => ++calls === 1 ? { state: 'failed', reason } : { state: 'sent' } });
    await channel.pollOnce();
    const missing = ['socket_error:ENOENT', 'messaging_socket_missing'].includes(reason);
    assert.equal(db.prepare('SELECT reason FROM beta_claude_seat').get().reason, missing ? 'messaging_socket_missing' : `send_failed:${reason}`);
    assert.equal(readOwnerAndIntentReadOnly(state.options.installRoot).claudeCodeSeats.seats[0].reason, missing ? 'messaging_socket_missing' : `send_failed:${reason}`, 'daemon status exposes the failure reason');
    assert.equal(db.prepare('SELECT state FROM beta_claude_queue').get().state, 'expired');
    await channel.pollOnce();
    assert.equal(calls, 2, 'the same path is retried without a new destination record');
    assert.deepEqual(db.prepare('SELECT state FROM beta_claude_queue ORDER BY id').all().map((row) => row.state), ['expired', 'confirmed']);
    await channel.pollOnce();
    assert.equal(calls, 2, 'success suppresses the already-notified unread');
    await channel.stop();
  });
}

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
  for (const reason of ['seat_pid_unresolved', 'agmsgd_not_ready_stopped', 'native_storage_not_ready']) {
    writeFileSync(path.join(root, 'run', 'role-session.test__alice'), record(`messaging_blocked=${reason}\n`));
    const read = readClaudeRoleSession(path.join(root, 'run'), 'test', 'alice');
    assert.equal(read.record.messaging_blocked, reason);
    const channel = createClaudeCodeQueueChannel({ ...state.options, readSession: () => read });
    await channel.pollOnce();
    assert.equal(db.prepare("SELECT state || '/' || reason AS r FROM beta_claude_seat").get().r, `unaddressable/${reason}`);
    assert.equal(state.sent, 0);
    await channel.stop();
  }
  // A value that is not a plain word is ignored, not shown.
  writeFileSync(path.join(root, 'run', 'role-session.test__alice'), record('messaging_blocked=bad value;\n'));
  assert.equal(readClaudeRoleSession(path.join(root, 'run'), 'test', 'alice').record.messaging_blocked, '');
});

test('a project that opts out gets no new nudges, and choosing agmsgd again resumes new unread', async (t) => {
  const { db, channel, state } = channelFixture(t);
  const root = state.options.installRoot;
  await channel.pollOnce();
  assert.equal(state.sent, 1, 'no choice recorded: agmsgd delivers as before');
  state.sequence += 1;
  writeFileSync(path.join(root, 'run', 'delivery-choice'), `claude-code\t${root}\tmonitor\n`);
  for (let i = 0; i < 3; i += 1) await channel.pollOnce();
  assert.equal(state.sent, 1, 'no further nudge for an opted-out project');
  assert.equal(db.prepare("SELECT state || '/' || reason AS r FROM beta_claude_seat").get().r, 'unaddressable/delivery_chosen_monitor');
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_claude_queue WHERE state = 'pending'").get().n, 0);
  writeFileSync(path.join(root, 'run', 'delivery-choice'), `claude-code\t${root}\tagmsgd\n`);
  await channel.pollOnce();
  assert.equal(db.prepare("SELECT state FROM beta_claude_seat").get().state, 'addressable');
  assert.equal(state.sent, 2, 'the previously opted-out new unread gets a nudge');
});

for (const prepareSchema of [false, true]) {
  test(`a 1.6.0 pending row never blocks delivery after upgrade (schema preparation: ${prepareSchema})`, async (t) => {
    const { db, channel, state } = channelFixture(t);
    db.prepare(`INSERT INTO beta_claude_queue
      (seat, messaging_socket, transcript_path, up_to, nonce, state, created_at, tried_modes)
      VALUES (?, ?, ?, ?, ?, 'pending', ?, 'plain,bypass')`)
      .run('["test","alice"]', state.socket, '/old/transcript', '{"eventSeq":1,"legacyId":0}', 'old-nonce', '2026-10-23');
    if (prepareSchema) {
      ensureClaudeCodeChannelSchema(db);
      assert.equal(db.prepare('SELECT state FROM beta_claude_queue').get().state, 'expired');
    }
    await channel.pollOnce();
    assert.equal(state.sent, 1);
    assert.deepEqual(db.prepare('SELECT state FROM beta_claude_queue ORDER BY id').all().map((row) => row.state), ['expired', 'confirmed']);
    assert.equal(db.prepare('SELECT transcript_path FROM beta_claude_queue ORDER BY id LIMIT 1').get().transcript_path, '/old/transcript', 'historical columns and data are retained');
    await channel.stop();
  });
}

test('a daemon restart keeps the notified cursor, and a new snapshot gets a new nudge', async (t) => {
  const { db, channel, state } = channelFixture(t);
  await channel.pollOnce();
  await channel.stop();
  ensureClaudeCodeChannelSchema(db);
  const restarted = createClaudeCodeQueueChannel(state.options);
  await restarted.pollOnce();
  assert.equal(state.sent, 1);
  state.sequence += 1;
  await restarted.pollOnce();
  assert.equal(state.sent, 2);
  await restarted.stop();
});

test('the notified cursor advances only to the snapshot sent, preserving arrivals during the write', async (t) => {
  const { db, state } = channelFixture(t);
  const channel = createClaudeCodeQueueChannel({ ...state.options, send: async () => {
    state.sent += 1;
    if (state.sent === 1) state.sequence += 1;
    return { state: 'sent' };
  } });
  await channel.pollOnce();
  assert.equal(JSON.parse(db.prepare('SELECT up_to FROM beta_claude_queue').get().up_to).eventSeq, 1);
  await channel.pollOnce();
  assert.equal(state.sent, 2);
  assert.equal(JSON.parse(db.prepare('SELECT up_to FROM beta_claude_queue ORDER BY id DESC LIMIT 1').get().up_to).eventSeq, 2);
  await channel.stop();
});

test('real unread snapshots suppress already-notified messages without marking the inbox read', async (t) => {
  const { db, state } = channelFixture(t);
  const store = new DatabaseSync(':memory:');
  t.after(() => store.close());
  store.exec(`
    CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT, type TEXT, team TEXT, to_agent TEXT, agent TEXT, msg_id TEXT, legacy_id INTEGER);
    CREATE TABLE messages (id INTEGER PRIMARY KEY, team TEXT, to_agent TEXT, read_at TEXT);
    CREATE TABLE read_cursors (team TEXT, agent TEXT, local_position INTEGER);
    INSERT INTO events (id,type,team,to_agent) VALUES ('first','message_sent','test','alice');
  `);
  const channel = createClaudeCodeQueueChannel({ ...state.options,
    openStore: () => ({ exec: store.exec.bind(store), prepare: store.prepare.bind(store), close() {} }),
    readSnapshot: readUnreadSnapshot,
  });
  await channel.pollOnce();
  await channel.pollOnce();
  assert.equal(state.sent, 1);
  store.exec("INSERT INTO events (id,type,team,to_agent) VALUES ('second','message_sent','test','alice');");
  await channel.pollOnce();
  assert.equal(state.sent, 2);
  assert.equal(store.prepare("SELECT count(*) AS n FROM events WHERE type='message_read'").get().n, 0);
  assert.equal(store.prepare('SELECT count(*) AS n FROM read_cursors').get().n, 0);
  assert.deepEqual(JSON.parse(db.prepare('SELECT up_to FROM beta_claude_queue ORDER BY id DESC LIMIT 1').get().up_to), { eventSeq: 2, legacyId: 0 });
  await channel.stop();
});

test('a Unix socket recreated at the same recorded path is used again', { skip: process.platform === 'win32', timeout: 5000 }, async (t) => {
  const { state } = channelFixture(t);
  state.socket = path.join(state.options.installRoot, 'seat.sock');
  const received = new EventEmitter();
  let server;
  const listen = async () => {
    server = createServer((connection) => {
      connection.resume();
      connection.on('end', () => received.emit('message'));
    });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(state.socket, resolve); });
  };
  const close = async () => {
    if (server?.listening) await new Promise((resolve) => server.close(resolve));
  };
  const channel = createClaudeCodeQueueChannel({ ...state.options,
    socketAlive: checkSocketOwnership,
    send: async (options) => { state.sent += 1; return sendClaudeCodeMessage(options); },
  });
  try {
    await channel.pollOnce();
    assert.equal(state.sent, 0);
    await listen();
    let notice = new Promise((resolve) => received.once('message', resolve));
    await channel.pollOnce();
    await notice;
    assert.equal(state.sent, 1);
    await close();
    state.sequence += 1;
    await channel.pollOnce();
    assert.equal(state.sent, 1);
    await listen();
    notice = new Promise((resolve) => received.once('message', resolve));
    await channel.pollOnce();
    await notice;
    assert.equal(state.sent, 2);
  } finally {
    await channel.stop();
    await close();
  }
});

for (const failure of ['throw', 'callback']) {
  test(`socket write ${failure} is a failure rather than delivery`, async () => {
    const result = await sendClaudeCodeMessage({ socketPath: '/fixture/socket', nonce: 'n', body: 'notice',
      checkOwnership: () => ({ state: 'ok' }),
      connect: () => {
        const socket = new EventEmitter();
        socket.destroy = () => {};
        socket.end = (_line, callback) => {
          const error = Object.assign(new Error('write failed'), { code: 'EPIPE' });
          if (failure === 'throw') throw error;
          callback(error);
        };
        queueMicrotask(() => socket.emit('connect'));
        return socket;
      },
    });
    assert.deepEqual(result, { state: 'failed', reason: 'socket_write_error:EPIPE' });
  });
}

test('a connection that never becomes writable times out', async () => {
  const result = await sendClaudeCodeMessage({ socketPath: '/fixture/socket', nonce: 'n', body: 'notice', timeoutMs: 1,
    checkOwnership: () => ({ state: 'ok' }),
    connect: () => Object.assign(new EventEmitter(), { destroy() {} }),
  });
  assert.deepEqual(result, { state: 'failed', reason: 'send_timeout' });
});

for (const reason of ['messaging_socket_stat_failed', 'messaging_socket_symlink', 'messaging_socket_not_a_socket', 'messaging_socket_not_owned_by_self']) {
  test(`a notified seat reports blocked when its next socket check fails: ${reason}`, async (t) => {
    const { db, channel, state } = channelFixture(t);
    await channel.pollOnce();
    state.alive = { state: 'unreadable', reason };
    await channel.pollOnce();
    assert.deepEqual({ ...db.prepare('SELECT state, reason FROM beta_claude_seat').get() }, { state: 'blocked', reason });
    assert.equal(state.sent, 1);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_claude_queue WHERE state='pending'").get().n, 0);
    assert.equal(db.prepare("SELECT COUNT(*) AS n FROM beta_claude_queue WHERE state='confirmed'").get().n, 1);
    await channel.stop();
  });
}

test('a stuck Claude send has a seat deadline and late success cannot publish delivery', async (t) => {
  const { db, channel: unused, state } = channelFixture(t);
  let release;
  const logs = [];
  const channel = createClaudeCodeQueueChannel({ ...state.options, seatDeadlineMs: 20, log: line => logs.push(line),
    send: () => new Promise(resolve => { release = resolve; }),
  });
  await channel.pollOnce();
  assert.equal(db.prepare('SELECT reason FROM beta_claude_seat').get().reason, 'seat_poll_deadline');
  assert.ok(logs.some(line => line.includes('poll_timeout')));
  release({ state: 'sent' });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(db.prepare('SELECT reason FROM beta_claude_seat').get().reason, 'seat_poll_deadline');
  await channel.stop();
  await unused.stop();
});
