// Codex queue I/O for the beta channel. This file knows only Codex's local
// profile format and CLI contract; the daemon loop and its install.db schema
// remain owned by the caller.

import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { isAbsolute } from "node:path";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_OUTPUT_CHARS = 64 * 1024;
export const QUEUE_KILL_GRACE_MS = 1000;

export function newNonce() {
  return randomUUID();
}

export function inboxNudge(nonce) {
  if (typeof nonce !== "string" || !/^[A-Za-z0-9-]{1,80}$/.test(nonce)) {
    throw new TypeError("nonce must be a short token");
  }
  return `[agmsg:${nonce}] New messages are waiting. Check your agmsg inbox.`;
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
  } catch {
    // The close event remains the authority for whether the child exited.
  }
}

// Runs one queue operation without a shell and waits for close (not just exit)
// so stdout/stderr are captured before interpretation, bounded by timeout
// plus the hard-kill grace even if a child never closes its inherited pipes.
export async function runCodexQueue({
  executable,
  codexHome,
  thread,
  message,
  timeoutMs,
  signal,
  onChildStart,
  env = process.env,
  spawnProcess = spawn,
}) {
  if (typeof executable !== "string" || executable.length === 0) throw new TypeError("missing Codex executable");
  if (typeof codexHome !== "string" || !isAbsolute(codexHome)) throw new TypeError("CODEX_HOME must be absolute");
  if (!UUID.test(thread ?? "")) throw new TypeError("thread must be a Codex UUID");
  if (typeof message !== "string" || !message) throw new TypeError("message must not be empty");
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1) throw new TypeError("timeoutMs must be a positive integer");
  if (signal?.aborted) return { kind: "cancelled", reason: "daemon_stopping" };

  const args = ["queue", "--thread", thread, "--message", message];
  let child;
  try {
    child = spawnProcess(executable, args, {
      env: { ...env, CODEX_HOME: codexHome },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform !== "win32",
    });
  } catch (error) {
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
    child.once("close", (code, signal) => settle({ code, signal }));
  });

  let timedOut = false;
  let aborted = false;
  const killTimers = [];
  const finishAtDeadline = () => {
    signalProcessGroup(child, "SIGKILL");
    // Even an unobservable child or inherited pipe must not hang the channel.
    child.stdout?.destroy();
    child.stderr?.destroy();
    child.unref?.();
    settleClosed({ deadline: true });
  };
  const onAbort = () => {
    aborted = true;
    signalProcessGroup(child, "SIGTERM");
    killTimers.push(setTimeout(finishAtDeadline, QUEUE_KILL_GRACE_MS));
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();
  const timer = setTimeout(() => {
    timedOut = true;
    signalProcessGroup(child, "SIGTERM");
  }, timeoutMs);
  const hardKill = setTimeout(() => {
    if (timedOut) finishAtDeadline();
  }, timeoutMs + QUEUE_KILL_GRACE_MS);
  let childRecordFailed = false;
  let started = false;
  child.once("spawn", () => {
    started = true;
    if (!onChildStart) return;
    try {
      onChildStart(child.pid);
    } catch {
      childRecordFailed = true;
      signalProcessGroup(child, "SIGTERM");
      killTimers.push(setTimeout(finishAtDeadline, QUEUE_KILL_GRACE_MS));
    }
  });
  const result = await closed;
  clearTimeout(timer);
  clearTimeout(hardKill);
  for (const killTimer of killTimers) clearTimeout(killTimer);
  signal?.removeEventListener("abort", onAbort);

  if (childRecordFailed) return { kind: "failed", reason: "child_record_failed", stdout, stderr };
  if (result.error && !started) return { kind: "failed", started: false, reason: `spawn_failed:${result.error.code ?? "unknown"}: ${result.error.message}`, stdout, stderr };
  if (aborted) return { kind: "cancelled", reason: "daemon_stopping", stdout, stderr };
  if (timedOut) return { kind: "timeout", stdout, stderr };
  if (result.error) return { kind: "failed", started, reason: `spawn_failed:${result.error.code ?? "unknown"}: ${result.error.message}`, stdout, stderr };
  const combined = `${stdout}\n${stderr}`;
  if (result.code !== 0) {
    if (combined.includes("code -32600")) return { kind: "archived", reason: "thread_archived" };
    if (combined.includes("code -32603")) return { kind: "no_rollout", reason: "thread_rollout_not_found" };
    return { kind: "failed", reason: `queue_exit_${result.code ?? result.signal ?? "unknown"}` };
  }

  const queued = stdout.match(/^Queued message ([0-9a-f-]{36}) for thread ([0-9a-f-]{36})\.?\s*$/m);
  if (!queued || queued[2].toLowerCase() !== thread.toLowerCase() || !UUID.test(queued[1])) {
    return { kind: "failed", reason: "queue_output_unrecognized" };
  }
  return { kind: "queued", queueItemId: queued[1] };
}

export function classifyCodexSeat({ roleSession, bridgeState }) {
  if (bridgeState === "running") return { state: "bridged", reason: "bridge_running" };
  if (!roleSession || !roleSession.thread || !roleSession.codex_home) {
    return { state: "unaddressable", reason: "role_session_missing" };
  }
  if (!UUID.test(roleSession.thread)) return { state: "unaddressable", reason: "thread_id_invalid" };
  if (!isAbsolute(roleSession.codex_home)) return { state: "unaddressable", reason: "codex_home_invalid" };
  if (bridgeState !== "stopped") return { state: "blocked", reason: "bridge_state_unknown" };
  return { state: "addressable", reason: "" };
}
