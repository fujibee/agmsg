import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, chmodSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';

import { runTerminalNudge, parseNudgeResult } from '../scripts/daemon/channels/terminal-poke-io.mjs';

function temporaryDirectory(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsgd-terminal-poke-io-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function writeFakeScript(dir, body) {
  const scriptPath = path.join(dir, 'fake-nudge.sh');
  writeFileSync(scriptPath, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(scriptPath, 0o755);
  return scriptPath;
}

test('parseNudgeResult reads the last matching state=/reason= line', () => {
  assert.deepEqual(parseNudgeResult('state=notified reason=\n'), { state: 'notified', reason: '' });
  assert.deepEqual(parseNudgeResult('noise\nstate=not_ready:blocked reason=why\n'), { state: 'not_ready:blocked', reason: 'why' });
  assert.deepEqual(parseNudgeResult('nothing useful here'), { state: 'unknown:no_result_line', reason: '' });
});

test('a successful nudge reports its parsed state and the body file is removed', async (t) => {
  const dir = temporaryDirectory(t);
  let sawBodyPath = '';
  const scriptPath = writeFakeScript(dir, [
    'team="$1"; agent="$2"; shift 3',
    'body_path="$1"',
    'echo "$team $agent" > "' + dir + '/argv.log"',
    'cat "$body_path" > "' + dir + '/body-seen.txt"',
    'echo "state=notified reason="',
  ].join('\n'));
  const result = await runTerminalNudge({
    scriptPath, team: 'test', agent: 'agy1', body: 'agmsg: you have new messages.', timeoutMs: 5000,
  });
  assert.equal(result.kind, 'ok');
  assert.equal(result.state, 'notified');
  const fs = await import('node:fs');
  assert.equal(fs.readFileSync(path.join(dir, 'body-seen.txt'), 'utf8'), 'agmsg: you have new messages.');
  assert.equal(fs.readFileSync(path.join(dir, 'argv.log'), 'utf8').trim(), 'test agy1');
});

test('a hanging script is killed at the timeout and reported as timeout', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeScript(dir, 'sleep 30');
  const result = await runTerminalNudge({
    scriptPath, team: 'test', agent: 'agy1', body: 'x', timeoutMs: 200,
  });
  assert.equal(result.kind, 'timeout');
});

test('a non-zero exit with no result line is a failure, not a crash', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeScript(dir, 'exit 3');
  const result = await runTerminalNudge({
    scriptPath, team: 'test', agent: 'agy1', body: 'x', timeoutMs: 5000,
  });
  assert.equal(result.kind, 'failed');
  assert.match(result.reason, /^nudge_exit_3$/);
});

test('an aborted signal cancels rather than reports a false state', async (t) => {
  const dir = temporaryDirectory(t);
  const scriptPath = writeFakeScript(dir, 'sleep 30');
  const controller = new AbortController();
  const promise = runTerminalNudge({
    scriptPath, team: 'test', agent: 'agy1', body: 'x', timeoutMs: 5000, signal: controller.signal,
  });
  controller.abort();
  const result = await promise;
  assert.equal(result.kind, 'cancelled');
});
