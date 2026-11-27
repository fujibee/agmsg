// Records a Codex seat's pane after the seat asked (#2050).
//
// A Codex seat's tool shell runs inside Codex's sandbox, which refuses ps, so
// the seat cannot prove its own pane (scripts/lib/codex-own-pane.sh). It leaves
// run/codex-pane-request.<thread> instead, and this hook, outside the sandbox,
// hands each request to scripts/internal/codex-pane-fill.sh. That script checks
// the request against the seat's role-session record, proves the pane the way
// the seat would have, writes it through the seat's own path, and removes the
// request.
//
// Cost: one readdir of run/ per poll. A child process runs only for a request,
// one per request, at most one per poll; the script removes the request
// whatever the outcome, so a request that cannot be served is not retried.

import { spawn } from "node:child_process";
import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { logLine } from "../log.mjs";

const REQUEST = /^codex-pane-request\.[A-Za-z0-9-]+$/;
const FILL_TIMEOUT_MS = 10_000;
const KILL_GRACE_MS = 1000;
const MAX_OUTPUT_CHARS = 4 * 1024;
const RESULT_LINE = /^state=([a-z_]+) reason=(.*)$/;

export function pendingRequests(runDir, readdir = readdirSync) {
  let names;
  try {
    names = readdir(runDir);
  } catch {
    return [];
  }
  return names.filter((name) => REQUEST.test(name)).sort();
}

export function parseFillResult(output) {
  for (const line of String(output).split(/\r?\n/)) {
    const match = RESULT_LINE.exec(line.trim());
    if (match) return { state: match[1], reason: match[2] };
  }
  return { state: "unknown", reason: "no_result_line" };
}

function killGroup(child, signal) {
  if (process.platform !== "win32" && Number.isInteger(child.pid) && child.pid > 1) {
    try { process.kill(-child.pid, signal); return; } catch { /* fall through */ }
  }
  try { child.kill(signal); } catch { /* close decides */ }
}

export function runFill({ scriptPath, requestPath, env = process.env, timeoutMs = FILL_TIMEOUT_MS, signal, spawnProcess = spawn }) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawnProcess("bash", [scriptPath, requestPath], {
        env,
        stdio: ["ignore", "pipe", "pipe"],
        windowsHide: true,
        detached: process.platform !== "win32",
      });
    } catch (error) {
      resolve({ state: "failed", reason: `spawn_failed:${error.code ?? error.message}` });
      return;
    }
    let stdout = "";
    let done = false;
    const finish = (value) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      clearTimeout(hard);
      signal?.removeEventListener?.("abort", onAbort);
      resolve(value);
    };
    child.stdout?.on("data", (chunk) => {
      if (stdout.length < MAX_OUTPUT_CHARS) stdout += chunk.toString("utf8").slice(0, MAX_OUTPUT_CHARS - stdout.length);
    });
    child.stderr?.resume?.();
    const onAbort = () => killGroup(child, "SIGTERM");
    signal?.addEventListener?.("abort", onAbort, { once: true });
    const timer = setTimeout(() => killGroup(child, "SIGTERM"), timeoutMs);
    const hard = setTimeout(() => {
      killGroup(child, "SIGKILL");
      child.stdout?.destroy();
      child.stderr?.destroy();
      child.unref?.();
      finish({ state: "timeout", reason: `no answer in ${timeoutMs} ms` });
    }, timeoutMs + KILL_GRACE_MS);
    child.once("error", (error) => finish({ state: "failed", reason: `spawn_failed:${error.code ?? error.message}` }));
    child.once("close", (code) => {
      if (code !== 0) finish({ state: "failed", reason: `exit_${code}` });
      else finish(parseFillResult(stdout));
    });
  });
}

export function createCodexPaneFillChannel({ installRoot, env = process.env, run = runFill, readdir = readdirSync, log = (message) => logLine(installRoot, message) }) {
  const runDir = join(installRoot, "run");
  const scriptPath = join(installRoot, "scripts", "internal", "codex-pane-fill.sh");
  let stopped = false;
  return {
    name: "codex_pane_fill",
    async pollOnce({ signal } = {}) {
      if (stopped) return;
      const [name] = pendingRequests(runDir, readdir);
      if (!name) return;
      const requestPath = join(runDir, name);
      const result = await run({ scriptPath, requestPath, env, signal });
      log(`codex pane: ${name.slice("codex-pane-request.".length)}: ${result.state}${result.reason ? ` (${result.reason})` : ""}`);
      // The script removes the request itself; a run that never got that far
      // (spawn failure, timeout) must not leave it to be retried every poll.
      try { rmSync(requestPath, { force: true }); } catch { /* next poll sees it again */ }
    },
    async stop() { stopped = true; },
  };
}
