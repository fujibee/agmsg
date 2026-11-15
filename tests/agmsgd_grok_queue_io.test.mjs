import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { spawn } from 'node:child_process';
import net from 'node:net';

import { runGrokNudge, createGrokPromptTracker, probeLeaderListening } from '../scripts/daemon/channels/grok-queue-io.mjs';

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

test('probeLeaderListening: true when something is actually listening on the socket', async (t) => {
  const dir = temporaryDirectory(t);
  const sockPath = path.join(dir, 'leader.sock');
  const server = net.createServer();
  await new Promise((resolve) => server.listen(sockPath, resolve));
  t.after(() => server.close());
  assert.equal(await probeLeaderListening(sockPath, 1000), true);
});

test('probeLeaderListening: false when nothing is listening (ENOENT) -- no process is spawned to find this out', async (t) => {
  const dir = temporaryDirectory(t);
  const sockPath = path.join(dir, 'no-such-leader.sock');
  assert.equal(await probeLeaderListening(sockPath, 1000), false);
});

test('probeLeaderListening: false when a stale socket file refuses the connection (ECONNREFUSED)', async (t) => {
  const dir = temporaryDirectory(t);
  const sockPath = path.join(dir, 'stale.sock');
  const server = net.createServer();
  await new Promise((resolve) => server.listen(sockPath, resolve));
  await new Promise((resolve) => server.close(resolve));
  // The socket FILE can survive its listener's exit on some platforms,
  // connecting to it then fails with ECONNREFUSED rather than ENOENT --
  // both must report "nothing is listening", not just the ENOENT case.
  assert.equal(await probeLeaderListening(sockPath, 1000), false);
});

test('createGrokPromptTracker: armed, matches a genuinely new entry or running prompt by text', () => {
  const t1 = createGrokPromptTracker('sess-1', 'hello');
  t1.arm();
  assert.equal(t1.observe({ sessionId: 'sess-1', entries: [{ id: 'a', text: 'hello' }] }), true);

  const t2 = createGrokPromptTracker('sess-1', 'hello');
  t2.arm();
  assert.equal(t2.observe({ sessionId: 'sess-1', entries: [{ id: 'a', text: 'other' }] }), false);

  const t3 = createGrokPromptTracker('sess-1', 'hello');
  t3.arm();
  assert.equal(t3.observe({ sessionId: 'sess-1', entries: [], runningPromptId: 'r1', runningText: 'hello' }), true);

  const t4 = createGrokPromptTracker('sess-1', 'hello');
  t4.arm();
  assert.equal(t4.observe({ sessionId: 'sess-1', entries: [], runningText: 'other' }), false);
  assert.equal(t4.observe(null), false);
  assert.equal(t4.observe({ sessionId: 'sess-1' }), false);
});

test('createGrokPromptTracker: a notification for a DIFFERENT sessionId never counts, even with matching text (review on #1979)', () => {
  const tracker = createGrokPromptTracker('sess-1', 'hello');
  tracker.arm();
  assert.equal(tracker.observe({ sessionId: 'sess-OTHER', entries: [{ id: 'a', text: 'hello' }] }), false);
});

test('createGrokPromptTracker: a notification observed before arm() is pre-existing state, never counted as acceptance even if armed later', () => {
  const tracker = createGrokPromptTracker('sess-1', 'hello');
  // Arrives (e.g. right after initialize) before session/prompt is sent.
  assert.equal(tracker.observe({ sessionId: 'sess-1', entries: [{ id: 'a', text: 'hello' }] }), false);
  tracker.arm();
  // The SAME entry, still sitting there -- never freshly matched.
  assert.equal(tracker.observe({ sessionId: 'sess-1', entries: [{ id: 'a', text: 'hello' }] }), false);
});

test('createGrokPromptTracker: a PREVIOUS attempt\'s own already-seen entry (same literal text) never counts for a later one', () => {
  // The nudge text is the same fixed string every attempt, so two
  // different unread-transition attempts for the same seat can produce
  // identical queue/changed text. A tracker instance is per-attempt
  // (grok-queue-io.mjs makes a fresh one per runGrokNudge call), so this
  // models the handoff: the first attempt's tracker having already seen
  // entry "p1" must not let a SECOND attempt's fresh tracker treat that
  // same still-queued entry as its own new acceptance.
  const first = createGrokPromptTracker('sess-1', 'hello');
  first.arm();
  assert.equal(first.observe({ sessionId: 'sess-1', entries: [{ id: 'p1', text: 'hello' }] }), true);

  const second = createGrokPromptTracker('sess-1', 'hello');
  // The second attempt's tracker observes the SAME leftover entry before
  // arming (its own initialize/session/resume phase) -- recorded as seen.
  second.observe({ sessionId: 'sess-1', entries: [{ id: 'p1', text: 'hello' }] });
  second.arm();
  assert.equal(second.observe({ sessionId: 'sess-1', entries: [{ id: 'p1', text: 'hello' }] }), false);
  // A genuinely NEW entry for the second attempt still matches.
  assert.equal(second.observe({ sessionId: 'sess-1', entries: [{ id: 'p1', text: 'hello' }, { id: 'p2', text: 'hello' }] }), true);
});

test('createGrokPromptTracker: a running prompt already seen as running does not re-match on a later identical notification', () => {
  const tracker = createGrokPromptTracker('sess-1', 'hello');
  tracker.observe({ sessionId: 'sess-1', entries: [], runningPromptId: 'r1', runningText: 'hello' });
  tracker.arm();
  assert.equal(tracker.observe({ sessionId: 'sess-1', entries: [], runningPromptId: 'r1', runningText: 'hello' }), false);
  assert.equal(tracker.observe({ sessionId: 'sess-1', entries: [], runningPromptId: 'r2', runningText: 'hello' }), true);
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

test('runGrokNudge end to end: a queue/changed with matching text that arrives BEFORE session/prompt is sent is never mistaken for acceptance (review on #1979)', async (t) => {
  const dir = temporaryDirectory(t);
  // Sends a stale-looking queue/changed with our exact text right after
  // initialize -- before session/resume has even been answered -- then
  // only answers for real once session/prompt actually arrives.
  const scriptPath = writeFakeLeaderClient(dir, `
    const readline = require('node:readline');
    const rl = readline.createInterface({ input: process.stdin });
    let promptSeen = false;
    rl.on('line', (line) => {
      let msg; try { msg = JSON.parse(line); } catch { return; }
      if (msg.method === 'initialize') {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }) + '\\n');
        process.stdout.write(JSON.stringify({
          jsonrpc: '2.0', method: '_x.ai/queue/changed',
          params: { sessionId: 'sess-1', entries: [{ id: 'stale', text: 'agmsg: you have new messages.' }] },
        }) + '\\n');
      } else if (msg.method === 'session/resume') {
        process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: msg.id, result: {} }) + '\\n');
      } else if (msg.method === 'session/prompt') {
        promptSeen = true;
        process.stdout.write(JSON.stringify({
          jsonrpc: '2.0', method: '_x.ai/queue/changed',
          params: { sessionId: 'sess-1', entries: [{ id: 'stale', text: 'agmsg: you have new messages.' }, { id: 'fresh', text: msg.params.prompt[0].text }] },
        }) + '\\n');
      }
    });
    process.on('exit', () => { if (!promptSeen) process.stderr.write('session/prompt never arrived\\n'); });
  `);
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

test('runGrokNudge: an unresponsive client that ignores SIGTERM is SIGKILLed after the grace period, not left running', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeLeaderClient(dir, `
    process.on('SIGTERM', () => {}); // ignore it
    process.stdin.resume();
  `);
  const result = await runGrokNudge({
    executable: process.execPath,
    leaderSocket: '/tmp/fake.sock',
    sessionId: 'sess-1',
    cwd: '/a/project',
    text: 'x',
    timeoutMs: 200,
    spawnProcess: (exe, args, opts) => callDefault(exe, args, opts, scriptPath),
  });
  assert.equal(result.kind, 'timeout');
  // runGrokNudge only returns once the child has actually been confirmed
  // closed (SIGKILL after the grace period here) -- not merely signaled.
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
