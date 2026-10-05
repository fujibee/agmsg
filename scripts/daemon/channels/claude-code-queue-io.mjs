// Claude Code native-channel I/O: writes one line to a seat's own
// cross-session-messaging socket (https://code.claude.com/docs/en/cross-session-messaging)
// and verifies delivery by reading the seat's own transcript file. Measured
// 2026-10-05, memory/design/2026-10-05-cross-session-messaging-socket-measurement.md
// (and its addendum) and memory/design/2026-09-22-agmsgd-arch-8-delivery-driver.md
// §12/§12.1 — this file's shape follows directly from those measurements, not
// from the (partly inaccurate, per the same memo) public docs alone.
//
// This file knows only the Claude Code peer-socket wire format and transcript
// layout; the daemon loop and its install.db schema remain owned by the caller
// (claude-code-queue.mjs), matching codex-queue-io.mjs's split.

import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";
import { closeSync, lstatSync, openSync, readFileSync, readSync, statSync } from "node:fs";
import process from "node:process";
import { isAbsolute } from "node:path";

export { newNonce, inboxNudge, QUEUE_CONFIRMATION_TTL_MS } from "./codex-queue-io.mjs";

const SEND_TIMEOUT_MS = 5_000;
// Bound the transcript read to its tail: a long-lived seat's jsonl grows
// without limit, and the delivery record this channel looks for is always
// recent (written within the TTL window of a message this same daemon just
// sent). 512 KiB comfortably covers many turns' worth of lines.
const TRANSCRIPT_TAIL_BYTES = 512 * 1024;

// Measured 2026-10-05: Claude Code encodes a project's cwd into its
// transcript directory name by replacing every "/" with "-"
// (e.g. /home/user/projects/example/sub -> -home-user-projects-example-sub).
// Only this simple case was measured; a cwd containing a literal "-" was not
// tested separately and is not known to collide in practice, so this is not
// claimed exhaustive.
export function encodeClaudeProjectDir(cwd) {
  if (typeof cwd !== "string" || !cwd) return "";
  return cwd.replace(/\//g, "-");
}

export function resolveTranscriptPath(claudeConfigDir, project, sessionId) {
  if (typeof claudeConfigDir !== "string" || !isAbsolute(claudeConfigDir)) return "";
  if (typeof project !== "string" || !isAbsolute(project)) return "";
  if (typeof sessionId !== "string" || !sessionId) return "";
  const encoded = encodeClaudeProjectDir(project);
  if (!encoded) return "";
  return `${claudeConfigDir}/projects/${encoded}/${sessionId}.jsonl`;
}

// Refuses to write unless the path is a Unix domain socket owned by this
// process's own OS user: a socket path read from an untrusted or stale
// record must never be written to on trust alone. A symlinked path is
// refused the same way every other agmsg state-file reader on this codebase
// refuses one.
function checkSocketOwnership(socketPath) {
  let stat;
  try {
    stat = lstatSync(socketPath);
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "unreadable", reason: "messaging_socket_missing" };
    return { state: "unreadable", reason: "messaging_socket_stat_failed" };
  }
  if (stat.isSymbolicLink()) return { state: "unreadable", reason: "messaging_socket_symlink" };
  if (!stat.isSocket()) return { state: "unreadable", reason: "messaging_socket_not_a_socket" };
  if (typeof process.getuid === "function" && stat.uid !== process.getuid()) {
    return { state: "unreadable", reason: "messaging_socket_not_owned_by_self" };
  }
  return { state: "ok" };
}

// Sends the one-line JSON cross-session-message the socket accepts (measured
// shape). `from` is a fixed, non-socket string on purpose: it must not look
// like a reply address, since this is a one-way nudge, not a peer
// conversation.
export async function sendClaudeCodeMessage({
  socketPath,
  nonce,
  body,
  timeoutMs = SEND_TIMEOUT_MS,
  checkOwnership = checkSocketOwnership,
  connect = createConnection,
}) {
  const ownership = checkOwnership(socketPath);
  if (ownership.state !== "ok") return { state: "failed", reason: ownership.reason };

  const payload = {
    msgV: 1,
    msg_id: randomUUID(),
    type: "user",
    message: {
      role: "user",
      content: `<cross-session-message from="agmsgd" from-name="agmsgd" from-mode="bypass">\n${body}\n</cross-session-message>`,
    },
    priority: "next",
    from: "agmsgd",
  };
  const line = `${JSON.stringify(payload)}\n`;

  return new Promise((resolve) => {
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { socket.destroy(); } catch { /* best effort */ }
      resolve(result);
    };
    const timer = setTimeout(() => finish({ state: "failed", reason: "send_timeout" }), timeoutMs);
    let socket;
    try {
      socket = connect(socketPath);
    } catch {
      clearTimeout(timer);
      resolve({ state: "failed", reason: "connect_failed" });
      return;
    }
    socket.on("error", (error) => finish({ state: "failed", reason: `socket_error:${error.code ?? error.message}` }));
    socket.on("connect", () => {
      socket.end(line, () => finish({ state: "sent", nonce, msgId: payload.msg_id }));
    });
  });
}

function readTail(path, maxBytes) {
  const stat = statSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("not_regular_file");
  if (stat.size <= maxBytes) return readFileSync(path, "utf8");
  const buf = Buffer.alloc(maxBytes);
  const fd = openSync(path, "r");
  try {
    readSync(fd, buf, 0, maxBytes, stat.size - maxBytes);
  } finally {
    closeSync(fd);
  }
  return buf.toString("utf8");
}

// Reads the delivery outcome straight from the receiving session's own
// transcript. Measured line shapes (2026-10-05 addendum):
//   - delivered: a `type:"user"` line with `origin.body` containing the
//     nonce verbatim — the ONLY line this treats as proof of delivery.
//   - held/declined: a `type:"system"`, `subtype:"informational"` line whose
//     `content` (a possibly-truncated preview) contains the nonce.
//   - a `type:"queue-operation"`, `operation:"enqueue"` line fires on mere
//     receipt, held or not — deliberately never read as evidence here (G4:
//     never mark a seat notified on evidence that could be a hold).
export function observeTranscript(transcriptPath, nonce) {
  if (typeof nonce !== "string" || !nonce) return { state: "unreadable", reason: "nonce_missing" };
  let text;
  try {
    text = readTail(transcriptPath, TRANSCRIPT_TAIL_BYTES);
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "unreadable", reason: "transcript_missing" };
    return { state: "unreadable", reason: "transcript_read_failed" };
  }
  const marker = `[agmsg:${nonce}]`;
  let heldSeen = false;
  for (const line of text.split("\n")) {
    if (!line || !line.includes(marker)) continue;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (row?.type === "user" && typeof row?.origin?.body === "string" && row.origin.body.includes(marker)) {
      return { state: "delivered" };
    }
    if (row?.type === "system" && row?.subtype === "informational" && typeof row?.content === "string" && row.content.includes(marker)) {
      heldSeen = true;
    }
  }
  if (heldSeen) return { state: "held" };
  return { state: "absent" };
}

// Single-observation analogue of codex-queue-io.mjs's resolvePendingQueue:
// this channel has only the transcript to read, not a separate queue-item
// check, so "present" collapses to one case (delivered) instead of two.
export function resolvePendingDelivery({ observation, ageMs, ttlMs }) {
  if (observation?.state === "delivered") return { state: "confirmed", reason: "nonce_observed" };
  if (observation?.state === "unreadable") return { state: "pending", reason: observation.reason ?? "transcript_unreadable" };
  if (!Number.isSafeInteger(ageMs) || ageMs < 0) return { state: "pending", reason: "pending_age_unreadable" };
  const reason = observation?.state === "held" ? "peer_held" : "awaiting_confirmation";
  if (ageMs >= ttlMs) return { state: "expired", reason: observation?.state === "held" ? "confirmation_timeout:peer_held" : "confirmation_timeout" };
  return { state: "pending", reason };
}
