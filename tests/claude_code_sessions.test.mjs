import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { findSessionSocket, parseStart } from '../scripts/daemon/channels/claude-code-sessions.mjs';
import { downNoticeClear, downNoticeKey, downNoticeSet } from '../scripts/daemon/down-notice.mjs';

function configDir(t) {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'agmsg-sessions-'));
  mkdirSync(path.join(dir, 'sessions'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// The file shape Claude Code writes (read from a live session, values replaced).
function sessionFile(dir, pid, over = {}) {
  writeFileSync(path.join(dir, 'sessions', `${pid}.json`), JSON.stringify({
    pid, sessionId: 'sess-1', procStart: 'Sat Oct 31 01:17:15 2026', pidDomain: 'darwin',
    messagingSocketPath: `/tmp/cc-socks/${pid}.sock`, kind: 'interactive', status: 'idle', ...over,
  }));
}
// ps prints the same moment in local time; the test passes it through startOf.
const localStart = () => {
  const d = new Date(Date.UTC(2026, 9, 31, 1, 17, 15));
  const p = (n) => String(n).padStart(2, '0');
  const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return `${days[d.getDay()]} ${months[d.getMonth()]} ${String(d.getDate()).padStart(2, ' ')} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())} ${d.getFullYear()}`;
};
const base = (dir, over = {}) => ({ configDir: dir, sessionId: 'sess-1', alive: () => true, startOf: async () => localStart(), platform: 'linux', ...over });

test('a live process of the session gives its socket', async (t) => {
  const dir = configDir(t);
  sessionFile(dir, 44846);
  assert.deepEqual(await findSessionSocket(base(dir)), { state: 'found', socket: '/tmp/cc-socks/44846.sock', pid: 44846 });
});

test('another session, a dead pid or a reused pid is not found; the session counts as ended', async (t) => {
  const dir = configDir(t);
  sessionFile(dir, 1, { sessionId: 'other' });
  assert.equal((await findSessionSocket(base(dir))).state, 'ended');
  sessionFile(dir, 2);
  assert.equal((await findSessionSocket(base(dir, { alive: () => false }))).state, 'ended');
  assert.equal((await findSessionSocket(base(dir, { startOf: async () => 'Sat Oct 31 05:00:00 2026' }))).state, 'ended');
});

test('an unreadable directory or a file of another shape is unknown, never ended and never guessed', async (t) => {
  const dir = configDir(t);
  assert.equal((await findSessionSocket(base(path.join(dir, 'nowhere')))).state, 'unknown');
  writeFileSync(path.join(dir, 'sessions', '7.json'), '{not json');
  assert.equal((await findSessionSocket(base(dir))).state, 'unknown');
  rmSync(path.join(dir, 'sessions', '7.json'));
  sessionFile(dir, 8, { messagingSocketPath: 12 });
  assert.equal((await findSessionSocket(base(dir))).state, 'unknown');
  sessionFile(dir, 9, { messagingSocketPath: 'relative.sock' });
  rmSync(path.join(dir, 'sessions', '8.json'));
  assert.equal((await findSessionSocket(base(dir))).state, 'unknown');
  assert.equal((await findSessionSocket(base(dir, { platform: 'win32' }))).state, 'unknown');
  assert.ok(Number.isNaN(parseStart('yesterday')));
});

test('the down record key and file are the ones scripts/lib/down-notice.sh uses', (t) => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'agmsg-down-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const lib = path.resolve('scripts/lib/down-notice.sh');
  for (const text of ['agmsg/lead', 'My Team/Ünï "x"', 'a'.repeat(200)]) {
    const shell = execFileSync('bash', ['-c', '. "$1"; down_notice_key agmsgd.seat "$2"', 'x', lib, text], { encoding: 'utf8' }).trim();
    assert.equal(downNoticeKey('agmsgd.seat', text), shell);
  }
  const key = downNoticeKey('agmsgd.seat', 'agmsg/lead');
  assert.equal(downNoticeSet(root, key, 'down', 'why "q"', 'run it', () => Date.UTC(2026, 10, 4, 12)), true);
  const listed = execFileSync('bash', ['-c', `AGMSG_DOWN_NOTICE_ROOT="$1"; . "$2"; down_notice_list`, 'x', root, lib], { encoding: 'utf8' }).trim().split('\t');
  assert.deepEqual(listed, [key, 'down', '2026-11-04T12:00:00Z', "why 'q'", 'run it']);
  assert.equal(downNoticeSet(root, 'BAD KEY', 'down', 'x', 'y'), false);
  assert.equal(downNoticeClear(root, key), true);
  assert.throws(() => readFileSync(path.join(root, 'run', 'down', `${key}.json`)));
});

test('the temp file of a record sits beside the record, also with Windows separators', () => {
  const src = readFileSync(new URL('../scripts/daemon/down-notice.mjs', import.meta.url), 'utf8');
  assert.match(src, /join\(dirname\(file\)/);
  const win = path.win32;
  const file = 'C:\\Users\\x\\run\\down\\k.json';
  const tmp = win.join(win.dirname(file), '.k.json.42');
  assert.equal(tmp, 'C:\\Users\\x\\run\\down\\.k.json.42');
  assert.equal(win.isAbsolute(tmp), true);
});
