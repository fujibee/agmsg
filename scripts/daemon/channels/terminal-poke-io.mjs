// Runs scripts/internal/terminal-nudge.sh for one seat and parses its single
// result line. Shape mirrors codex-queue-io.mjs's runCodexQueue: no shell,
// bounded output, a hard timeout plus a kill grace even if the child never
// closes its inherited pipes.

import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const MAX_OUTPUT_CHARS = 4 * 1024;
export const NUDGE_KILL_GRACE_MS = 1000;

const RESULT_LINE = /^state=([A-Za-z0-9_:.-]+)\s+reason=(.*)$/;

export function parseNudgeResult(output) {
  for (const line of output.split(/\r?\n/)) {
    const match = RESULT_LINE.exec(line.trim());
    if (match) return { state: match[1], reason: match[2] ?? "" };
  }
  return { state: "unknown:no_result_line", reason: "" };
}

function appendBounded(current, chunk) {
  if (current.length >= MAX_OUTPUT_CHARS) return current;
  return current + chunk.toString("utf8").slice(0, MAX_OUTPUT_CHARS - current.length);
}

function signalProcessGroup(child, signal) {
  if (process.platform !== "win32" && Number.isInteger(child.pid) && child.pid > 1) {
    try {
      process.kill(-child.pid, signal);
      return;
    } catch (error) {
      if (error?.code !== "ESRCH") return;
    }
  }
  try {
    child.kill(signal);
  } catch { /* the close event remains the authority for whether the child exited */ }
}

// Writes the nudge body to a throwaway temp file rather than a shell
// argument (#507's lesson, same as poke.sh's own --body-file contract) and
// removes it once the child has closed, success or not.
export async function runTerminalNudge({
  scriptPath,
  team,
  agent,
  body,
  timeoutMs,
  signal,
  env = process.env,
  spawnProcess = spawn,
}) {
  if (typeof scriptPath !== "string" || !scriptPath) throw new TypeError("missing terminal-nudge.sh path");
  if (typeof team !== "string" || !team) throw new TypeError("missing team");
  if (typeof agent !== "string" || !agent) throw new TypeError("missing agent");
  if (typeof body !== "string" || !body) throw new TypeError("body must not be empty");
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) throw new TypeError("timeoutMs must be a positive integer");
  if (signal?.aborted) return { kind: "cancelled", reason: "daemon_stopping" };

  const tempDir = mkdtempSync(join(tmpdir(), "agmsg-terminal-poke-"));
  const bodyPath = join(tempDir, `${randomUUID()}.txt`);
  try {
    writeFileSync(bodyPath, body, { mode: 0o600 });
  } catch (error) {
    try { rmSync(tempDir, { recursive: true, force: true }); } catch { /* best effort */ }
    return { kind: "failed", started: false, reason: `body_write_failed:${error.code ?? error.message}` };
  }

  let child;
  try {
    child = spawnProcess("bash", [scriptPath, team, agent, "--body-file", bodyPath], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform !== "win32",
    });
  } catch (error) {
    try { rmSync(tempDir, { recursive: true, force: true }); } catch { /* best effort */ }
    return { kind: "failed", started: false, reason: `spawn_failed:${error.code ?? "unknown"}: ${error.message}` };
  }

  let stdout = "";
  let stderr = "";
  child.stdout?.on("data", (chunk) => { stdout = appendBounded(stdout, chunk); });
  child.stderr?.on("data", (chunk) => { stderr = appendBounded(stderr, chunk); });

  let settleClosed;
  const closed = new Promise((resolveClose) => {
    let settled = false;
    const settle = (value) => {
      if (settled) return;
      settled = true;
      resolveClose(value);
    };
    settleClosed = settle;
    child.once("error", (error) => settle({ error }));
    child.once("close", (code, closeSignal) => settle({ code, signal: closeSignal }));
  });

  let timedOut = false;
  let aborted = false;
  const killTimers = [];
  const finishAtDeadline = () => {
    signalProcessGroup(child, "SIGKILL");
    child.stdout?.destroy();
    child.stderr?.destroy();
    child.unref?.();
    settleClosed({ deadline: true });
  };
  const onAbort = () => {
    aborted = true;
    signalProcessGroup(child, "SIGTERM");
    killTimers.push(setTimeout(finishAtDeadline, NUDGE_KILL_GRACE_MS));
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();
  const timer = setTimeout(() => {
    timedOut = true;
    signalProcessGroup(child, "SIGTERM");
  }, timeoutMs);
  const hardKill = setTimeout(() => {
    if (timedOut) finishAtDeadline();
  }, timeoutMs + NUDGE_KILL_GRACE_MS);
  let started = false;
  child.once("spawn", () => { started = true; });

  const result = await closed;
  clearTimeout(timer);
  clearTimeout(hardKill);
  for (const killTimer of killTimers) clearTimeout(killTimer);
  signal?.removeEventListener("abort", onAbort);
  try { rmSync(tempDir, { recursive: true, force: true }); } catch { /* best effort */ }

  if (result.error && !started) return { kind: "failed", started: false, reason: `spawn_failed:${result.error.code ?? "unknown"}: ${result.error.message}`, stdout, stderr };
  if (aborted) return { kind: "cancelled", reason: "daemon_stopping", stdout, stderr };
  if (timedOut) return { kind: "timeout", stdout, stderr };
  if (result.error) return { kind: "failed", started, reason: `spawn_failed:${result.error.code ?? "unknown"}: ${result.error.message}`, stdout, stderr };
  if (result.code !== 0) return { kind: "failed", reason: `nudge_exit_${result.code ?? result.signal ?? "unknown"}`, stdout, stderr };
  const parsed = parseNudgeResult(stdout);
  return { kind: "ok", state: parsed.state, reason: parsed.reason, stdout, stderr };
}
