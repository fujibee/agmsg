// Codex queue I/O for the beta channel. This file knows only Codex's local
// profile format and CLI contract; the daemon loop and its install.db schema
// remain owned by the caller.

import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createReadStream, lstatSync, readdirSync } from "node:fs";
import { createInterface } from "node:readline";
import { isAbsolute, join } from "node:path";
import { DatabaseSync } from "node:sqlite";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_OUTPUT_CHARS = 64 * 1024;
export const QUEUE_CONFIRMATION_TTL_MS = 60_000;

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
// so stdout/stderr are fully captured before its result is interpreted.
export async function runCodexQueue({
  executable,
  codexHome,
  thread,
  message,
  timeoutMs,
  signal,
  onChildStart,
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
      env: { ...process.env, CODEX_HOME: codexHome },
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform !== "win32",
    });
  } catch (error) {
    return { kind: "failed", reason: `spawn_failed: ${error.message}` };
  }

  let stdout = "";
  let stderr = "";
  child.stdout?.on("data", (chunk) => { stdout = appendBounded(stdout, chunk); });
  child.stderr?.on("data", (chunk) => { stderr = appendBounded(stderr, chunk); });

  const closed = new Promise((resolveClose) => {
    let settled = false;
    const settle = (value) => {
      if (settled) return;
      settled = true;
      resolveClose(value);
    };
    child.once("error", (error) => settle({ error }));
    child.once("close", (code, signal) => settle({ code, signal }));
  });

  let timedOut = false;
  let aborted = false;
  const killTimers = [];
  const onAbort = () => {
    aborted = true;
    signalProcessGroup(child, "SIGTERM");
    killTimers.push(setTimeout(() => signalProcessGroup(child, "SIGKILL"), 1000));
  };
  signal?.addEventListener("abort", onAbort, { once: true });
  if (signal?.aborted) onAbort();
  const timer = setTimeout(() => {
    timedOut = true;
    signalProcessGroup(child, "SIGTERM");
  }, timeoutMs);
  const hardKill = setTimeout(() => {
    if (timedOut) signalProcessGroup(child, "SIGKILL");
  }, timeoutMs + 1000);
  let childRecordFailed = false;
  if (onChildStart) {
    try {
      onChildStart(child.pid);
    } catch {
      childRecordFailed = true;
      signalProcessGroup(child, "SIGTERM");
      killTimers.push(setTimeout(() => signalProcessGroup(child, "SIGKILL"), 1000));
    }
  }
  const result = await closed;
  clearTimeout(timer);
  clearTimeout(hardKill);
  for (const killTimer of killTimers) clearTimeout(killTimer);
  signal?.removeEventListener("abort", onAbort);

  if (childRecordFailed) return { kind: "failed", reason: "child_record_failed", stdout, stderr };
  if (aborted) return { kind: "cancelled", reason: "daemon_stopping", stdout, stderr };
  if (timedOut) return { kind: "timeout", stdout, stderr };
  if (result.error) return { kind: "failed", reason: `spawn_failed: ${result.error.message}`, stdout, stderr };
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

// Tri-state by design: an unreadable DB is not an empty queue. A row is
// corroborating evidence only when both its id and thread match.
export function readQueuedItem(codexHome, queueItemId, thread) {
  if (!isAbsolute(codexHome ?? "") || !UUID.test(queueItemId ?? "") || !UUID.test(thread ?? "")) {
    return { state: "unreadable", reason: "invalid_queue_lookup" };
  }
  const dbPath = join(codexHome, "queue_1.sqlite");
  let db;
  try {
    if (!lstatSync(dbPath).isFile()) return { state: "unreadable", reason: "queue_db_missing" };
    db = new DatabaseSync(dbPath, { readOnly: true, allowExtension: false });
    db.exec("PRAGMA busy_timeout = 1000;");
    const row = db.prepare("SELECT thread_id FROM queued_items WHERE id = ?").get(queueItemId);
    if (!row) return { state: "absent" };
    if (row.thread_id !== thread) return { state: "unreadable", reason: "queue_thread_mismatch" };
    return { state: "present" };
  } catch {
    return { state: "unreadable", reason: "queue_db_read_failed" };
  } finally {
    try { db?.close(); } catch { /* the query result already carries the observation */ }
  }
}

function matchingRollouts(sessionsDir, thread) {
  const matches = [];
  const walk = (dir, depth) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    for (const entry of entries) {
      const path = join(dir, entry.name);
      if (entry.isSymbolicLink()) throw new Error("symlink_in_sessions");
      if (entry.isDirectory() && depth < 3) walk(path, depth + 1);
      else if (entry.isFile() && entry.name.startsWith("rollout-") && entry.name.endsWith(`-${thread}.jsonl`)) matches.push(path);
    }
  };
  walk(sessionsDir, 0);
  return matches;
}

function userText(row) {
  if (row?.type === "event_msg" && row.payload?.type === "user_message") {
    const value = row.payload.message;
    return typeof value === "string" ? { kind: "text", text: value } : { kind: "unreadable" };
  }
  if (row?.type === "response_item" && row.payload?.type === "message" && row.payload.role === "user") {
    if (!Array.isArray(row.payload.content) || row.payload.content.length === 0) return { kind: "unreadable" };
    const pieces = [];
    for (const part of row.payload.content) {
      if (typeof part?.text !== "string") return { kind: "unreadable" };
      pieces.push(part.text);
    }
    return { kind: "text", text: pieces.join("\n") };
  }
  return { kind: "other" };
}

async function rolloutHasNonce(path, thread, nonce) {
  let malformed = false;
  let first = true;
  let sawUserRow = false;
  let sawUnreadableUserRow = false;
  const input = createInterface({ input: createReadStream(path, { encoding: "utf8" }), crlfDelay: Infinity });
  try {
    for await (const line of input) {
      if (!line) continue;
      let row;
      try {
        row = JSON.parse(line);
      } catch {
        malformed = true;
        continue;
      }
      if (first) {
        first = false;
        if (row?.type !== "session_meta" || row.payload?.id !== thread) return { state: "unreadable", reason: "rollout_thread_mismatch" };
      }
      const observation = userText(row);
      if (observation.kind === "unreadable") {
        sawUnreadableUserRow = true;
      } else if (observation.kind === "text") {
        sawUserRow = true;
        if (observation.text.includes(nonce)) return { state: "present" };
      }
    }
  } catch {
    return { state: "unreadable", reason: "rollout_read_failed" };
  }
  if (first) return { state: "unreadable", reason: "rollout_empty" };
  if (malformed) return { state: "unreadable", reason: "rollout_malformed" };
  if (sawUnreadableUserRow) return { state: "unreadable", reason: "rollout_user_row_unrecognized" };
  if (!sawUserRow) return { state: "unreadable", reason: "rollout_user_rows_unrecognized" };
  return { state: "absent" };
}

// This observation may not yet be available on unauthenticated runs. Unknown
// is deliberately separate from absent so callers can leave the row pending.
export async function readRolloutNonce(codexHome, thread, nonce) {
  if (!isAbsolute(codexHome ?? "") || !UUID.test(thread ?? "") || !/^[A-Za-z0-9-]{1,80}$/.test(nonce ?? "")) {
    return { state: "unreadable", reason: "invalid_rollout_lookup" };
  }
  const sessionsDir = join(codexHome, "sessions");
  let matches;
  try {
    let sessionsStat;
    try {
      sessionsStat = lstatSync(sessionsDir);
    } catch (error) {
      if (error?.code === "ENOENT") return { state: "unreadable", reason: "sessions_dir_missing" };
      throw error;
    }
    if (sessionsStat.isSymbolicLink() || !sessionsStat.isDirectory()) {
      return { state: "unreadable", reason: "sessions_path_not_directory" };
    }
    matches = matchingRollouts(sessionsDir, thread);
  } catch {
    return { state: "unreadable", reason: "sessions_scan_failed" };
  }
  if (matches.length === 0) return { state: "unreadable", reason: "thread_rollout_missing" };
  if (matches.length !== 1) return { state: "unreadable", reason: "multiple_thread_rollouts" };
  return rolloutHasNonce(matches[0], thread, nonce);
}

// A positive observation is enough to confirm. Two readable negative
// observations wait for the retry window, then expire. Any unreadable or
// malformed observation remains pending; callers must surface that state
// instead of treating it as an empty queue or an absent nonce.
export function resolvePendingQueue({ queueObservation, rolloutObservation, ageMs }) {
  if (queueObservation?.state === "present") {
    return { state: "confirmed", reason: "queue_item_present" };
  }
  if (rolloutObservation?.state === "present") {
    return { state: "confirmed", reason: "nonce_observed" };
  }

  const knownState = (observation) =>
    observation?.state === "absent" || observation?.state === "unreadable";
  if (!knownState(queueObservation) || !knownState(rolloutObservation)) {
    return { state: "pending", reason: "verification_unreadable" };
  }
  if (queueObservation.state === "unreadable" || rolloutObservation.state === "unreadable") {
    return { state: "pending", reason: "verification_unreadable" };
  }
  if (!Number.isSafeInteger(ageMs) || ageMs < 0) {
    return { state: "pending", reason: "pending_age_unreadable" };
  }
  if (ageMs >= QUEUE_CONFIRMATION_TTL_MS) {
    return { state: "expired", reason: "confirmation_timeout" };
  }
  return { state: "pending", reason: "awaiting_confirmation" };
}

// Call immediately after the caller has durably stored queueItemId. Check the
// queue first: Codex may consume the item before the rollout can be inspected.
// A present row is already sufficient evidence, so that fast path does not
// depend on the not-yet-measured processed-message serialization.
export async function verifyPendingDelivery({
  codexHome,
  queueItemId,
  thread,
  nonce,
  ageMs,
  readQueue = readQueuedItem,
  readRollout = readRolloutNonce,
}) {
  let queueObservation;
  try {
    queueObservation = readQueue(codexHome, queueItemId, thread);
  } catch {
    queueObservation = { state: "unreadable", reason: "queue_db_read_failed" };
  }
  if (queueObservation?.state === "present") {
    return { state: "confirmed", reason: "queue_item_present" };
  }

  let rolloutObservation;
  try {
    rolloutObservation = await readRollout(codexHome, thread, nonce);
  } catch {
    rolloutObservation = { state: "unreadable", reason: "rollout_read_failed" };
  }
  return resolvePendingQueue({ queueObservation, rolloutObservation, ageMs });
}

export function classifyCodexSeat({ roleSession, bridgeState, rolloutState }) {
  if (bridgeState === "running") return { state: "bridged", reason: "bridge_running" };
  if (!roleSession || !roleSession.thread || !roleSession.codex_home) {
    return { state: "unaddressable", reason: "role_session_missing" };
  }
  if (!UUID.test(roleSession.thread)) return { state: "unaddressable", reason: "thread_id_invalid" };
  if (!isAbsolute(roleSession.codex_home)) return { state: "unaddressable", reason: "codex_home_invalid" };
  if (bridgeState !== "stopped") return { state: "blocked", reason: "bridge_state_unknown" };
  if (rolloutState === "valid") return { state: "addressable", reason: "" };
  if (rolloutState === "archived") return { state: "blocked", reason: "thread_archived" };
  if (rolloutState === "no_rollout") return { state: "blocked", reason: "codex_home_mismatch" };
  return { state: "blocked", reason: "thread_observation_failed" };
}
