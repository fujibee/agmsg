import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawn } from 'node:child_process';

import { runGrokNudge, queueChangedAccepts } from '../scripts/daemon/channels/grok-queue-io.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-grok-queue-io-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// A fake `grok agent --leader --leader-socket <sock> stdio` process: a tiny
// Node script (not bash) so it can speak newline-delimited JSON-RPC exactly
// the way the real client does, line-buffered, without a shell's own
// stdio-buffering quirks.
function writeFakeLeaderClient(dir, body) {
  const scriptPath = path.join(dir, 'fake-grok');
  writeFileSync(scriptPath, `#!/usr/bin/env node\n${body}\n`);
  chmodSync(scriptPath, 0o755);
  return scriptPath;
}

function callDefault(exe, args, opts, scriptPath) {
  return spawn(exe, [scriptPath], opts);
}

// Matches the real sequence measured live (2026-11-15, seat-sandbox, Mac):
// session/resume needs cwd + mcpServers, session/prompt is an id-bearing
// request whose own prompt param is an array of content blocks, and
// acceptance is announced via queue/changed with either `entries` (queued)
// or `runningText` (already running, entries empty).
const HAPPY_PATH_SCRIPT = `
const readline = require('node:readline');
const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.method === 'initialize') {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }) + '\\n');
  } else if (msg.method === 'session/resume') {
    if (typeof msg.params.cwd !== 'string' || !Array.isArray(msg.params.mcpServers)) {
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32602, message: 'missing cwd/mcpServers' } }) + '\\n');
      return;
    }
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }) + '\\n');
  } else if (msg.method === 'session/prompt') {
    if (!Array.isArray(msg.params.prompt) || msg.params.prompt[0]?.type !== 'text') {
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32602, message: 'prompt must be an array of content blocks' } }) + '\\n');
      return;
    }
    process.stdout.write(JSON.stringify({
      jsonrpc: '2.0', method: '_x.ai/queue/changed',
      params: { sessionId: msg.params.sessionId, entries: [{ id: 'p1', version: 0, kind: 'prompt', text: msg.params.prompt[0].text, position: 0 }] },
    }) + '\\n');
  }
});
`;

const RUNNING_PATH_SCRIPT = `
const readline = require('node:readline');
const rl = readline.createInterface({ input: process.stdin });
rl.on('line', (line) => {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.method === 'initialize' || msg.method === 'session/resume') {
    process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }) + '\\n');
  } else if (msg.method === 'session/prompt') {
    process.stdout.write(JSON.stringify({
      jsonrpc: '2.0', method: '_x.ai/queue/changed',
      params: { sessionId: msg.params.sessionId, entries: [], runningPromptId: 'r1', runningText: msg.params.prompt[0].text, runningKind: 'prompt' },
    }) + '\\n');
  }
});
`;

test('queueChangedAccepts matches by text in queued entries or the running prompt text', () => {
  assert.equal(queueChangedAccepts({ entries: [{ id: 'a', text: 'hello' }] }, 'hello'), true);
  assert.equal(queueChangedAccepts({ entries: [{ id: 'a', text: 'other' }] }, 'hello'), false);
  assert.equal(queueChangedAccepts({ entries: [], runningText: 'hello' }, 'hello'), true);
  assert.equal(queueChangedAccepts({ entries: [], runningText: 'other' }, 'hello'), false);
  assert.equal(queueChangedAccepts({ entries: [], runningPromptId: 'a' }, 'hello'), false);
  assert.equal(queueChangedAccepts(null, 'hello'), false);
  assert.equal(queueChangedAccepts({}, 'hello'), false);
});

test('a queued prompt accepted via queue/changed entries reports ok, and the client is torn down right after', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, HAPPY_PATH_SCRIPT);
  const result = await runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'agmsg: you have new messages.',
    timeoutMs: 5000,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  assert.equal(result.kind, 'ok');
  assert.equal(result.state, 'notified');
});

test('a prompt already running (queue/changed runningText, entries empty) also reports ok', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, RUNNING_PATH_SCRIPT);
  const result = await runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'agmsg: you have new messages.',
    timeoutMs: 5000,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  assert.equal(result.kind, 'ok');
});

test('session/resume sends cwd and mcpServers (a leader that rejects a request missing them would otherwise report an unexplained timeout)', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, HAPPY_PATH_SCRIPT);
  const result = await runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'x',
    timeoutMs: 5000,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  assert.equal(result.kind, 'ok');
});

test('an RPC error response (e.g. session/resume rejected) is reported distinctly, not as a bare timeout', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, `
    const readline = require('node:readline');
    const rl = readline.createInterface({ input: process.stdin });
    rl.on('line', (line) => {
      let msg; try { msg = JSON.parse(line); } catch { return; }
      if (msg.method === 'initialize') {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }) + '\\n');
      } else if (msg.method === 'session/resume') {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, error: { code: -32001, message: 'no such session' } }) + '\\n');
      }
    });
  `);
  const result = await runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'x',
    timeoutMs: 5000,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  assert.equal(result.kind, 'failed');
  assert.match(result.reason, /rpc_failed:rpc_error:-32001/);
});

test('no acceptance before the timeout reports timeout, not a hang', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, `
    // never responds to anything
    process.stdin.resume();
  `);
  const result = await runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'agmsg: you have new messages.',
    timeoutMs: 300,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  assert.equal(result.kind, 'timeout');
});

test('a leader client that exits early (e.g. bad socket path) is reported as its own distinct reason, not timeout', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, `process.exit(1);`);
  const result = await runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'x',
    timeoutMs: 5000,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  assert.equal(result.kind, 'failed');
  assert.match(result.reason, /^leader_client_exit_1/);
});

test('an abort signal cancels an in-flight attempt rather than hanging until timeout', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, `
    process.stdin.resume();
  `);
  const controller = new AbortController();
  const promise = runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'x',
    timeoutMs: 30000,
    signal: controller.signal,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  controller.abort();
  const result = await promise;
  assert.equal(result.kind, 'cancelled');
});

test('an already-aborted signal is cancelled before any process is spawned', async () => {
  const controller = new AbortController();
  controller.abort();
  let spawned = false;
  const result = await runGrokNudge({
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'x',
    timeoutMs: 5000,
    signal: controller.signal,
    spawnProcess: () => { spawned = true; throw new Error('must not spawn'); },
  });
  assert.equal(result.kind, 'cancelled');
  assert.equal(spawned, false);
});

test('a missing grok executable is reported as a failed spawn, not a crash', async (t) => {
  const result = await runGrokNudge({
    executable: '/no/such/grok-binary-xyz',
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'x',
    timeoutMs: 2000,
  });
  assert.equal(result.kind, 'failed');
  assert.match(result.reason, /^spawn_failed:/);
});

test('a missing cwd is a programming error, caught before anything spawns', async () => {
  await assert.rejects(
    () => runGrokNudge({ leaderSocket: '/tmp/fake.sock', sessionId: 'sess-1', text: 'x', timeoutMs: 1000 }),
    /missing cwd/,
  );
});
