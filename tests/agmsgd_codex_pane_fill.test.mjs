import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { createCodexPaneFillChannel, parseFillResult, pendingRequests } from '../scripts/daemon/channels/codex-pane-fill.mjs';

function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), 'agmsgd-pane-fill-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, 'run'));
  return root;
}

test('only well-formed request names are picked up, in a stable order', (t) => {
  const root = fixture(t);
  for (const name of ['codex-pane-request.bbb-2', 'codex-pane-request.aaa-1', 'codex-pane-request.x.tmp', 'codex-pane-request.', 'role-session.t__a', 'codex-pane-request.aaa-1.123']) {
    writeFileSync(path.join(root, 'run', name), '');
  }
  assert.deepEqual(pendingRequests(path.join(root, 'run')), ['codex-pane-request.aaa-1', 'codex-pane-request.bbb-2']);
  assert.deepEqual(pendingRequests(path.join(root, 'missing')), []);
});

test('the result line is read; anything else is no_result_line', () => {
  assert.deepEqual(parseFillResult('noise\nstate=recorded reason=herdr:/s.sock:w1:p2\n'), { state: 'recorded', reason: 'herdr:/s.sock:w1:p2' });
  assert.deepEqual(parseFillResult('state=unrecorded reason=several_codex_tuis_may_hold_this_thread'), { state: 'unrecorded', reason: 'several_codex_tuis_may_hold_this_thread' });
  assert.deepEqual(parseFillResult(''), { state: 'unknown', reason: 'no_result_line' });
});

test('no request: no child process at all', async (t) => {
  const root = fixture(t);
  let runs = 0;
  const channel = createCodexPaneFillChannel({ installRoot: root, run: async () => { runs += 1; return { state: 'recorded', reason: '' }; }, log: () => {} });
  for (let i = 0; i < 5; i += 1) await channel.pollOnce();
  assert.equal(runs, 0);
});

test('one request per poll, one run per request, and the request is gone even when the run failed', async (t) => {
  const root = fixture(t);
  writeFileSync(path.join(root, 'run', 'codex-pane-request.aaa-1'), 'team=t\n');
  writeFileSync(path.join(root, 'run', 'codex-pane-request.bbb-2'), 'team=t\n');
  const seen = [];
  const logs = [];
  const channel = createCodexPaneFillChannel({
    installRoot: root,
    run: async ({ requestPath, scriptPath }) => {
      seen.push(path.basename(requestPath));
      assert.equal(scriptPath, path.join(root, 'scripts', 'internal', 'codex-pane-fill.sh'));
      return seen.length === 1 ? { state: 'timeout', reason: 'no answer in 10000 ms' } : { state: 'recorded', reason: 'herdr:/s:w1:p2' };
    },
    log: (line) => logs.push(line),
  });
  await channel.pollOnce();
  assert.deepEqual(seen, ['codex-pane-request.aaa-1']);
  assert.equal(existsSync(path.join(root, 'run', 'codex-pane-request.aaa-1')), false);
  await channel.pollOnce();
  await channel.pollOnce();
  assert.deepEqual(seen, ['codex-pane-request.aaa-1', 'codex-pane-request.bbb-2']);
  assert.deepEqual(logs, ['codex pane: aaa-1: timeout (no answer in 10000 ms)', 'codex pane: bbb-2: recorded (herdr:/s:w1:p2)']);
});

test('a stopped channel runs nothing', async (t) => {
  const root = fixture(t);
  writeFileSync(path.join(root, 'run', 'codex-pane-request.aaa-1'), '');
  let runs = 0;
  const channel = createCodexPaneFillChannel({ installRoot: root, run: async () => { runs += 1; return { state: 'recorded', reason: '' }; }, log: () => {} });
  await channel.stop();
  await channel.pollOnce();
  assert.equal(runs, 0);
});
