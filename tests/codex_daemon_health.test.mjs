import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
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

test("an unchecked reading keeps the noticed entry: the same daemon is not noticed twice", async () => {
  const h = harness([line(), line(), line({ state: "unchecked", over: 0, mb: "", clients: "" }), line(), line()]);
  const ch = h.make();
  for (let i = 0; i < 5; i++) { await ch.pollOnce(); await ch.settled(); h.advance(10 * 60 * 1000); }
  assert.equal(noticeCount(h.root), 1);
  rmSync(h.root, { recursive: true });
});

test("a profile missing from a cut-short read keeps its entry; a stale one clears it", async () => {
  const h = harness([line(), line(), "", line(), line({ state: "stale", over: 0 }), line(), line()]);
  const ch = h.make();
  for (let i = 0; i < 7; i++) { await ch.pollOnce(); await ch.settled(); h.advance(10 * 60 * 1000); }
  // notice 1 after reads 1-2; reads 3-4 keep it; read 5 proves the daemon gone; reads 6-7 notice it again
  assert.equal(noticeCount(h.root), 2);
  rmSync(h.root, { recursive: true });
});

test("the real reader cut short by its timeout still yields the profiles it finished", async () => {
  const root = makeInstall();
  mkdirSync(join(root, "scripts"), { recursive: true });
  const script = join(root, "scripts", "codex-daemon-health.sh");
  writeFileSync(script, `#!/bin/bash\nprintf '${PROFILE}\\trunning\\t100\\tS\\t50000\\t7000\\t1\\t\\t\\t\\n'\nexec sleep 30\n`);
  chmodSync(script, 0o755);
  const ch = createCodexDaemonHealthChannel({ installRoot: root, timeoutMs: 600 });
  await ch.pollOnce(); await ch.settled();
  assert.match(logText(root), /reader cut short/);
  const record = readHealthRecord(root);
  assert.equal(record.daemons.size, 1, "the finished profile was recorded");
  rmSync(root, { recursive: true });
});

test("each check resumes after the profiles the previous read finished", async () => {
  const root = makeInstall();
  const starts = [];
  const rows = [line(), line({ pid: "200" })];
  let t = 1_000_000;
  const ch = createCodexDaemonHealthChannel({
    installRoot: root, now: () => t,
    read: async (_root, _signal, _timeout, startAt) => { starts.push(startAt); return starts.length === 2 ? rows[0] : rows.join(""); },
  });
  for (let i = 0; i < 3; i++) { await ch.pollOnce(); await ch.settled(); t += 10 * 60 * 1000; }
  // first read finished 2 profiles, the second only 1 (cut short), the third resumes after it
  assert.deepEqual(starts, [0, 2, 3]);
  rmSync(root, { recursive: true });
});

test("fairness: with leading profiles hanging and a read that reaches only two profiles, the over one is read and noticed within a bounded number of checks", async () => {
  const root = makeInstall();
  const profiles = ["/p/a", "/p/b", "/p/c", "/p/d", "/p/over"];
  const row = (p, i) => (p === "/p/over"
    ? `${p}\trunning\t900\tS\t50000\t7000\t1\t2\t\t8000\n`
    : `${p}\tunchecked\t${100 + i}\tS\t\t\t0\t\tfootprint hung\t\n`);
  let t = 1_000_000;
  const ch = createCodexDaemonHealthChannel({
    installRoot: root, now: () => t,
    // The whole-read budget lets the reader finish only two profiles, starting where it is told to.
    read: async (_root, _signal, _timeout, startAt) => [0, 1]
      .map(k => (startAt + k) % profiles.length)
      .map(i => row(profiles[i], i)).join(""),
  });
  let checks = 0;
  while (noticeCount(root) === 0 && checks < 10) { await ch.pollOnce(); await ch.settled(); t += 10 * 60 * 1000; checks++; }
  assert.equal(noticeCount(root), 1, "the over daemon was noticed");
  assert.ok(checks <= 6, `noticed within a bounded number of checks (took ${checks})`);
  rmSync(root, { recursive: true });
});

test("a CPU-only daemon is noticed on the second check, and the notice says CPU, not memory", async () => {
  const cpuLine = `${PROFILE}\trunning\t100\tTue Nov 3 12:50:37 2026\t99000\t1228\t1\t\t\t2048\t240\tcpu\n`;
  const h = harness([cpuLine, cpuLine]);
  const ch = h.make();
  await ch.pollOnce(); await ch.settled();
  assert.equal(noticeCount(h.root), 0);
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  assert.equal(noticeCount(h.root), 1);
  const text = logText(h.root);
  assert.match(text, /uses 240% CPU, over the 200% limit/);
  assert.doesNotMatch(text, /holds/);
  assert.match(text, /It keeps running/);
});

test("memory and CPU together name both", async () => {
  const both = `${PROFILE}\trunning\t100\tTue Nov 3 12:50:37 2026\t99000\t7000\t1\t\t\t8000\t300\tmemory+cpu\n`;
  const h = harness([both, both]);
  const ch = h.make();
  await ch.pollOnce(); await ch.settled();
  h.advance(10 * 60 * 1000);
  await ch.pollOnce(); await ch.settled();
  assert.match(logText(h.root), /holds 6\.8 GB, over the 6 GB limit and uses 300% CPU, over the 200% limit/);
});
