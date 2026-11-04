import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createCodexDaemonHealthChannel, foldReadings, parseHealthLines, readHealthRecord } from "../scripts/daemon/channels/codex-daemon-health.mjs";

function makeInstall() {
  const root = mkdtempSync(join(tmpdir(), "codex-health-test-"));
  mkdirSync(join(root, "run"), { recursive: true });
  return root;
}

const PROFILE = "/p/one";
function line({ pid = "100", start = "Tue Nov 3 12:50:37 2026", age = 50000, mb = 7000, over = 1, clients = "3", state = "running" } = {}) {
  return `${PROFILE}\t${state}\t${pid}\t${start}\t${age}\t${mb}\t${over}\t${clients}\t\n`;
}

// A channel whose reader returns scripted output, one entry per check, and a
// clock the test advances by hand.
function harness(outputs) {
  const root = makeInstall();
  let t = 1_000_000;
  let calls = 0;
  const make = () => createCodexDaemonHealthChannel({
    installRoot: root,
    now: () => t,
    read: async () => outputs[Math.min(calls++, outputs.length - 1)],
  });
  return { root, make, advance: ms => { t += ms; }, calls: () => calls };
}
const logText = root => { try { return readFileSync(join(root, "run", "agmsgd.log"), "utf8"); } catch { return ""; } };
const noticeCount = root => (logText(root).match(/codex daemon health:/g) ?? []).length;

test("parseHealthLines reads the reader's tab lines", () => {
  const [row] = parseHealthLines(line());
  assert.deepEqual([row.profile, row.state, row.pid, row.over, row.footprintMb], [PROFILE, "running", "100", true, 7000]);
});

test("first over-threshold check sends nothing; the second sends exactly one notice", async () => {
  const h = harness([line(), line(), line()]);
  const ch = h.make();
  await ch.pollOnce(); await ch.settled();
  assert.equal(noticeCount(h.root), 0);
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  assert.equal(noticeCount(h.root), 1);
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  assert.equal(noticeCount(h.root), 1, "the same pid is not noticed again");
  assert.match(readHealthRecord(h.root).notice, /codex app-server daemon restart/);
  rmSync(h.root, { recursive: true });
});

test("checks run at most once per 10 minutes, not every tick", async () => {
  const h = harness([line()]);
  const ch = h.make();
  await ch.pollOnce(); await ch.settled();
  for (let i = 0; i < 5; i++) { h.advance(5000); await ch.pollOnce(); await ch.settled(); }
  assert.equal(h.calls(), 1);
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  assert.equal(h.calls(), 2);
  rmSync(h.root, { recursive: true });
});

test("an agmsgd restart does not notice the same daemon again", async () => {
  const h = harness([line(), line(), line(), line()]);
  let ch = h.make();
  await ch.pollOnce(); await ch.settled();
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  assert.equal(noticeCount(h.root), 1);
  ch = h.make(); // the process restarted: only the run/ record remains
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  assert.equal(noticeCount(h.root), 1);
  rmSync(h.root, { recursive: true });
});

test("a new daemon pid is a new daemon: two over readings notice it once more", async () => {
  const h = harness([line(), line(), line({ pid: "200" }), line({ pid: "200" })]);
  const ch = h.make();
  for (let i = 0; i < 4; i++) { await ch.pollOnce(); await ch.settled(); h.advance(10 * 60 * 1000); }
  assert.equal(noticeCount(h.root), 2);
  rmSync(h.root, { recursive: true });
});

test("a reading back under the limit restarts the consecutive count", async () => {
  const h = harness([line(), line({ over: 0, mb: 2000 }), line()]);
  const ch = h.make();
  for (let i = 0; i < 3; i++) { await ch.pollOnce(); await ch.settled(); h.advance(10 * 60 * 1000); }
  assert.equal(noticeCount(h.root), 0);
  rmSync(h.root, { recursive: true });
});

test("a stale or absent daemon is never noticed, and a failed reader only logs", async () => {
  const stale = harness([line({ state: "stale", over: 0 }), line({ state: "stale", over: 0 })]);
  const ch = stale.make();
  for (let i = 0; i < 2; i++) { await ch.pollOnce(); await ch.settled(); stale.advance(10 * 60 * 1000); }
  assert.equal(noticeCount(stale.root), 0);
  const root = makeInstall();
  const failing = createCodexDaemonHealthChannel({ installRoot: root, read: async () => { throw new Error("boom"); } });
  await failing.pollOnce(); await failing.settled();
  assert.match(logText(root), /check failed: boom/);
  rmSync(root, { recursive: true }); rmSync(stale.root, { recursive: true });
});

test("foldReadings drops daemons that are gone and sends no notice for a non-running state", () => {
  const prev = { daemons: new Map([[`${PROFILE}\t1\tx`, { over: 5, noticed: true }]]), notice: "" };
  const { daemons, notices } = foldReadings(prev, parseHealthLines(line({ state: "absent", over: 0 })));
  assert.equal(daemons.size, 0);
  assert.deepEqual(notices, []);
});
