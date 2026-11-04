// Notify-only health check of the Codex app-server daemon (#1886).
//
// At most once per CHECK_INTERVAL_MS it runs scripts/codex-daemon-health.sh (a
// read-only reader: one ps and one top per profile) in the background, so a
// slow `top` never holds a poll tick. A daemon that is over the limit (6 GB
// footprint AND 12 h old) on two consecutive checks gets ONE notice: a line in
// agmsgd.log and a record in run/codex-daemon-health that doctor prints. The
// "already noticed" state is keyed on pid + process start time and lives in
// that same record, so an agmsgd restart does not notice the same daemon again.
// Nothing here stops, restarts or kills any process.

import { execFile } from "node:child_process";
import { readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { logLine } from "../log.mjs";

export const CHECK_INTERVAL_MS = 10 * 60 * 1000;
const CHECK_TIMEOUT_MS = 20_000;

export function healthRecordPath(installRoot) {
  return join(installRoot, "run", "codex-daemon-health");
}

// run/codex-daemon-health lines:
//   daemon\t<profile>\t<pid>\t<start time>\t<consecutive over>\t<noticed 0|1>
//   notice\t<text>            (the latest notice)
export function readHealthRecord(installRoot) {
  const daemons = new Map();
  let notice = "";
  let text = "";
  try {
    text = readFileSync(healthRecordPath(installRoot), "utf8");
  } catch {
    return { daemons, notice };
  }
  for (const line of text.split("\n")) {
    const f = line.split("\t");
    if (f[0] === "daemon" && f.length === 6) {
      daemons.set(`${f[1]}\t${f[2]}\t${f[3]}`, { over: Number(f[4]) || 0, noticed: f[5] === "1" });
    } else if (f[0] === "notice") notice = f.slice(1).join("\t");
  }
  return { daemons, notice };
}

function writeHealthRecord(installRoot, { daemons, notice }) {
  const lines = [];
  for (const [key, v] of daemons) lines.push(`daemon\t${key}\t${v.over}\t${v.noticed ? 1 : 0}`);
  if (notice) lines.push(`notice\t${notice}`);
  const path = healthRecordPath(installRoot);
  const tmp = `${path}.${process.pid}`;
  writeFileSync(tmp, lines.join("\n") + (lines.length ? "\n" : ""));
  renameSync(tmp, path);
}

export function parseHealthLines(output) {
  const rows = [];
  for (const line of String(output).split("\n")) {
    const f = line.split("\t");
    if (f.length < 9) continue;
    rows.push({ profile: f[0], state: f[1], pid: f[2], start: f[3], ageSeconds: Number(f[4]), footprintMb: Number(f[5]), over: f[6] === "1", clients: f[7], reason: f[8] });
  }
  return rows;
}

// Folds one check's readings into the record. Returns the notices to send.
export function foldReadings(previous, rows) {
  const daemons = new Map();
  const notices = [];
  for (const row of rows) {
    if (row.state !== "running") continue;
    const key = `${row.profile}\t${row.pid}\t${row.start}`;
    const before = previous.daemons.get(key) ?? { over: 0, noticed: false };
    const over = row.over ? before.over + 1 : 0;
    let noticed = before.noticed;
    if (over >= 2 && !noticed) {
      noticed = true;
      notices.push(row);
    }
    daemons.set(key, { over, noticed });
  }
  return { daemons, notices };
}

function noticeText(row) {
  const hours = Math.floor(row.ageSeconds / 3600);
  const gb = (row.footprintMb / 1024).toFixed(1);
  const clients = row.clients === "" ? "" : ` with ${row.clients} client(s)`;
  return `Codex app-server daemon pid ${row.pid} for ${row.profile} has run ${hours}h${clients} and holds ${gb} GB, over the 6 GB / 12 h limit on two checks in a row. It keeps running. To restart it: CODEX_HOME=${row.profile} codex app-server daemon restart`;
}

function runReader(installRoot, signal) {
  return new Promise((resolve, reject) => {
    execFile("bash", [join(installRoot, "scripts", "codex-daemon-health.sh")], { encoding: "utf8", timeout: CHECK_TIMEOUT_MS, signal, env: { ...process.env, SKILL_DIR: installRoot } },
      (error, stdout) => (error ? reject(error) : resolve(stdout)));
  });
}

export function createCodexDaemonHealthChannel({ installRoot, intervalMs = CHECK_INTERVAL_MS, now = Date.now, read = runReader } = {}) {
  let lastStart = null;
  let inFlight = null;
  const lifetime = new AbortController();

  async function check() {
    try {
      const rows = parseHealthLines(await read(installRoot, lifetime.signal));
      const previous = readHealthRecord(installRoot);
      const { daemons, notices } = foldReadings(previous, rows);
      let notice = previous.notice;
      for (const row of notices) {
        notice = `${new Date(now()).toISOString()} ${noticeText(row)}`;
        logLine(installRoot, `codex daemon health: ${noticeText(row)}`);
      }
      writeHealthRecord(installRoot, { daemons, notice });
    } catch (error) {
      if (!lifetime.signal.aborted) logLine(installRoot, `codex daemon health: check failed: ${error.message}`);
    } finally {
      inFlight = null;
    }
  }

  return {
    name: "codex_daemon_health",
    async pollOnce() {
      if (inFlight) return;
      const t = now();
      if (lastStart !== null && t - lastStart < intervalMs) return;
      lastStart = t;
      inFlight = check();
    },
    // Awaitable for tests.
    settled: () => inFlight ?? Promise.resolve(),
    async stop() {
      lifetime.abort();
    },
  };
}
