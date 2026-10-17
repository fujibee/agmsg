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
import { closeSync, lstatSync, openSync, readFileSync, readSync, readdirSync, statSync } from "node:fs";
import process from "node:process";
import { isAbsolute } from "node:path";

export { newNonce, inboxNudge } from "./codex-queue-io.mjs";

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
  const expected = `${claudeConfigDir}/projects/${encoded}/${sessionId}.jsonl`;
  if (isFile(expected)) return expected;
  // The seat's conversation can live under another project directory than the
  // one its record names (it was started elsewhere). A session id is unique, so
  // exactly one match under the config dir is that conversation; none or
  // several keeps the expected path and the caller's own "missing" answer.
  if (!/^[A-Za-z0-9._-]+$/.test(sessionId) || sessionId.startsWith(".")) return expected;
  let dirs;
  try {
    dirs = readdirSync(`${claudeConfigDir}/projects`, { withFileTypes: true });
  } catch {
    return expected;
  }
  const found = [];
  for (const entry of dirs) {
    if (!entry.isDirectory()) continue;
    const candidate = `${claudeConfigDir}/projects/${entry.name}/${sessionId}.jsonl`;
    if (isFile(candidate)) found.push(candidate);
  }
  return found.length === 1 ? found[0] : expected;
}

function isFile(path) {
  try {
    return lstatSync(path).isFile();
  } catch {
    return false;
  }
}

// Refuses to write unless the path is a Unix domain socket owned by this
// process's own OS user: a socket path read from an untrusted or stale
// record must never be written to on trust alone. A symlinked path is
// refused the same way every other agmsg state-file reader on this codebase
// refuses one.
export function checkSocketOwnership(socketPath) {
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
//     nonce verbatim — proof of delivery (with the mid-turn shape below).
//   - held/declined: a `type:"system"`, `subtype:"informational"` line whose
//     `content` (a possibly-truncated preview) contains the nonce.
//   - absorbed mid-turn (measured 2026-10-15): a `type:"attachment"` line
//     whose `attachment.type` is `queued_command` and whose
//     `attachment.prompt` contains the nonce; the model read it in that turn.
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
    // A nudge that arrives while the seat is mid-turn is absorbed into that
    // turn: the model reads it as a queued_command attachment and no user line
    // is ever written for it. Without this the nudge stays pending forever and
    // the seat gets no further notices.
    if (row?.type === "attachment" && row?.attachment?.type === "queued_command"
      && typeof row.attachment.prompt === "string" && row.attachment.prompt.includes(marker)) {
      return { state: "delivered" };
    }
    if (row?.type === "system" && row?.subtype === "informational" && typeof row?.content === "string" && row.content.includes(marker)) {
      heldSeen = true;
    }
  }
  if (heldSeen) return { state: "held" };
  return { state: "absent" };
}

// Reads one transcript observation as a delivery state. There is deliberately
// no clock here: a nudge the seat has not shown yet is "pending" for as long as
// the same session and socket stay alive, however long that is. Claude Code
// holds a message received mid-work until the work pauses, so elapsed time says
// nothing about whether it was lost, and a wall clock jumps across a sleep.
// Only the caller's own evidence (socket gone, record changed) ends a pending
// nudge, and that is not decided here.
export function resolvePendingDelivery({ observation }) {
  if (observation?.state === "delivered") return { state: "confirmed", reason: "nonce_observed" };
  if (observation?.state === "unreadable") return { state: "pending", reason: observation.reason ?? "transcript_unreadable" };
  return { state: "pending", reason: observation?.state === "held" ? "peer_held" : "awaiting_confirmation" };
}
