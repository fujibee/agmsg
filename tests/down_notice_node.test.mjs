// scripts/daemon/down-notice.mjs: the Node side of scripts/lib/down-notice.sh's
// shared "down or degraded" record. The shell helper is the reference; this
// file checks the Node writer matches it (same key, same escaping) and that a
// record either side writes is read back correctly by the other.

import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { downNoticeClear, downNoticeKey, downNoticeSet } from '../scripts/daemon/down-notice.mjs';

const LIB = path.resolve('scripts/lib/down-notice.sh');

function tmpRoot(t) {
  const root = mkdtempSync(path.join(os.tmpdir(), 'agmsg-down-node-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}

function shellList(root) {
  return execFileSync('bash', ['-c', 'AGMSG_DOWN_NOTICE_ROOT="$1"; . "$2"; down_notice_list', 'x', root, LIB], { encoding: 'utf8' })
    .trim().split('\t');
}

function shellSet(root, key, state, reason, recovery) {
  execFileSync('bash', ['-c', 'AGMSG_DOWN_NOTICE_ROOT="$1"; . "$2"; down_notice_set "$3" "$4" "$5" "$6"', 'x', root, LIB, key, state, reason, recovery]);
}

test('downNoticeKey matches the shell for plain text, punctuation and a long/non-ASCII value', () => {
  for (const text of ['agmsg/lead', 'My Team/Ünï "x"', 'a'.repeat(200)]) {
    const shell = execFileSync('bash', ['-c', '. "$1"; down_notice_key agmsgd.seat "$2"', 'x', LIB, text], { encoding: 'utf8' }).trim();
    assert.equal(downNoticeKey('agmsgd.seat', text), shell);
  }
});

test('downNoticeSet -> shell down_notice_list round-trips space, apostrophe, double quote and backslash exactly', (t) => {
  const root = tmpRoot(t);
  const key = downNoticeKey('agmsgd.seat', 'agmsg/lead');
  const reason = `a line with a space, an apostrophe (it's), a "quote" and a \\backslash`;
  assert.equal(downNoticeSet(root, key, 'down', reason, 'run it', () => Date.UTC(2026, 10, 4, 12)), true);
  const listed = shellList(root);
  assert.deepEqual(listed, [key, 'down', '2026-11-04T12:00:00Z', reason, 'run it']);
  assert.equal(downNoticeSet(root, 'BAD KEY', 'down', 'x', 'y'), false);
  assert.equal(downNoticeClear(root, key), true);
  assert.throws(() => readFileSync(path.join(root, 'run', 'down', `${key}.json`)));
});

test('downNoticeSet persists an apostrophe-containing shell-quoted recovery command that the shell reads back executable', (t) => {
  const root = tmpRoot(t);
  const side = path.join(root, "side's install");
  const shq = `'${side.replace(/'/g, "'\\''")}'/scripts/agmsg`;
  const recovery = `${shq} daemon start`;
  assert.equal(downNoticeSet(root, 'agmsgd', 'down', 'stopped', recovery, () => Date.UTC(2026, 10, 4, 12)), true);
  const [, , , , decoded] = shellList(root);
  assert.equal(decoded, recovery);
});

test('a Node-written record with a control character is valid JSON and shell down_notice_list shows the literal escape text, not a raw control byte (not a supported executable-recovery case)', (t) => {
  const root = tmpRoot(t);
  const key = 'agmsgd';
  assert.equal(downNoticeSet(root, key, 'down', 'tab\tand\nnewline', 'x', () => Date.UTC(2026, 10, 4, 12)), true);
  const raw = readFileSync(path.join(root, 'run', 'down', `${key}.json`), 'utf8');
  assert.equal(JSON.parse(raw).reason, 'tab\tand\nnewline');
  const [, , , reason] = shellList(root);
  assert.equal(reason, 'tab\\tand\\nnewline');
});

test('a shell-written record with the same characters reads back identically through Node JSON.parse', (t) => {
  const root = tmpRoot(t);
  const key = 'agmsgd';
  shellSet(root, key, 'down', `a "quote", a \\backslash and it's`, 'recover');
  const raw = readFileSync(path.join(root, 'run', 'down', `${key}.json`), 'utf8');
  assert.equal(JSON.parse(raw).reason, `a "quote", a \\backslash and it's`);
});

test('a record written by a version before this escaping existed (no backslash/quote sequences to begin with) is read correctly by both sides', (t) => {
  const root = tmpRoot(t);
  const key = 'agmsgd';
  const dir = path.join(root, 'run', 'down');
  execFileSync('mkdir', ['-p', dir]);
  // Exactly what the pre-escaping writer (shell or Node) could ever produce:
  // `"` already rewritten to `'`, `\` already rewritten to `/`, no backslash
  // anywhere -- the new decoder must pass this through unchanged.
  const line = `{"component":"${key}","state":"down","reason":"a line with a 'quote' and a / slash","recovery":"agmsg daemon start","since":"2026-01-01T00:00:00Z","updated":"2026-01-01T00:00:00Z"}\n`;
  execFileSync('bash', ['-c', 'printf "%s" "$1" > "$2"', 'x', line, path.join(dir, `${key}.json`)]);
  assert.equal(JSON.parse(readFileSync(path.join(dir, `${key}.json`), 'utf8')).reason, "a line with a 'quote' and a / slash");
  const [, , , reason, recovery] = shellList(root);
  assert.equal(reason, "a line with a 'quote' and a / slash");
  assert.equal(recovery, 'agmsg daemon start');
});
