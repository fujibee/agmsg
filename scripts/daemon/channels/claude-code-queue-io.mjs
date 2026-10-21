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
// A pending nudge is checked from the transcript position recorded before it
// was sent (the start when none was), in chunks of this size.
const TRANSCRIPT_CHUNK_BYTES = 256 * 1024;

// Measured 2026-10-05: Claude Code encodes a project's cwd into its
// transcript directory name by replacing every "/" with "-"
// (e.g. /home/user/projects/example/sub -> -home-user-projects-example-sub).
// Only this simple case was measured; a cwd containing a literal "-" was not
// tested separately and is not known to collide in practice, so this is not
// claimed exhaustive.
// Native Windows (measured 2026-10-21): C:\Users\koich\agmsg-agents\win-test
// -> C--Users-koich-agmsg-agents-win-test, i.e. every character that is not a
// letter, digit or "-" becomes "-".
export function encodeClaudeProjectDir(cwd, platform = process.platform) {
  if (typeof cwd !== "string" || !cwd) return "";
  return platform === "win32" ? cwd.replace(/[^A-Za-z0-9-]/g, "-") : cwd.replace(/\//g, "-");
}

// A path the shell recorded, as a path this process can open. Git Bash writes
// /c/Users/me; node on Windows needs C:/Users/me. Anything else is unchanged,
// and so is every path off Windows.
export function nativePath(value, platform = process.platform) {
  if (platform !== "win32" || typeof value !== "string") return value;
  const gitBash = value.match(/^\/([A-Za-z])(?:\/(.*))?$/);
  return gitBash ? `${gitBash[1].toUpperCase()}:/${gitBash[2] ?? ""}` : value;
}

export function isNamedPipePath(value) {
  return typeof value === "string" && /^\\\\[.?]\\pipe\\[^\\/\0]/i.test(value);
}

export function resolveTranscriptPath(claudeConfigDirRaw, projectRaw, sessionId, platform = process.platform) {
  const claudeConfigDir = nativePath(claudeConfigDirRaw, platform);
  const project = nativePath(projectRaw, platform);
  const absolute = platform === "win32" ? winAbsolute : isAbsolute;
  if (typeof claudeConfigDir !== "string" || !absolute(claudeConfigDir)) return "";
  if (typeof project !== "string" || !absolute(project)) return "";
  if (typeof sessionId !== "string" || !sessionId) return "";
  const encoded = encodeClaudeProjectDir(project, platform);
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

// A drive path (C:\x or C:/x) or a UNC one; the POSIX test does not apply.
function winAbsolute(value) {
  return /^[A-Za-z]:[\\/]/.test(value) || /^\\\\[^\\]/.test(value);
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
export function checkSocketOwnership(socketPath, platform = process.platform) {
  // A named pipe (native Windows) is not a file: every filesystem probe of it
  // (stat, access, exists) can open it, which connects to the seat's inbox.
  // Nothing is asked of it here; a pipe that is gone shows as ENOENT when the
  // nudge connects, and the caller treats that as the socket being gone.
  if (platform === "win32" && isNamedPipePath(socketPath)) return { state: "ok" };
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
  token = "",
  fromMode = "",
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
      content: `<cross-session-message from="agmsgd"${fromMode === "bypass" ? ' from-name="agmsgd" from-mode="bypass"' : ""}>\n${body}\n</cross-session-message>`,
    },
    priority: "next",
    from: "agmsgd",
  };
  // The session's own inbox token goes first, as its documentation describes
  // ({"type":"auth","token":...} as the first line of the connection), so the
  // message is judged as one posted to its own session. A permission mode is
  // claimed only when the caller read the receiving seat to be in bypass mode
  // (a bypass receiver holds anything that names no mode, and a prompting one
  // holds a mode that is not its own).
  const auth = token ? `${JSON.stringify({ type: "auth", token })}\n` : "";
  const line = `${auth}${JSON.stringify(payload)}\n`;

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

// The permission mode the seat's conversation last recorded: Claude Code
// writes "permissionMode" on every user row. Only the tail is read; "" when the
// transcript is unreadable or carries none.
export function latestPermissionMode(transcriptPath, tailBytes = 1024 * 1024, io = { readSync }) {
  let fd;
  try {
    const stat = statSync(transcriptPath);
    if (!stat.isFile()) return "";
    fd = openSync(transcriptPath, "r");
    const start = Math.max(0, stat.size - tailBytes);
    const buf = Buffer.alloc(stat.size - start);
    let got = 0;
    while (got < buf.length) {
      const read = io.readSync(fd, buf, got, buf.length - got, start + got);
      if (read <= 0) break;
      got += read;
    }
    const lines = buf.subarray(0, got).toString("utf8").split("\n");
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      if (!lines[i].includes('"permissionMode"')) continue;
      try {
        const mode = JSON.parse(lines[i])?.permissionMode;
        if (typeof mode === "string" && mode) return mode;
      } catch { /* a cut first line or a half-written last one */ }
    }
    return "";
  } catch {
    return "";
  } finally {
    if (fd !== undefined) { try { closeSync(fd); } catch { /* read only */ } }
  }
}

// The byte length of the transcript right now, recorded just before a nudge is
// sent so the later check reads only what was written after it. null when the
// file cannot be measured: that nudge is checked from the start.
export function transcriptEndPosition(transcriptPath) {
  try {
    const stat = statSync(transcriptPath);
    return stat.isFile() ? stat.size : null;
  } catch {
    return null;
  }
}

// Judges one transcript line: "delivered", "held", or "" when it says nothing
// about this nonce. Measured line shapes (2026-10-05 addendum):
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
function judgeLine(line, marker) {
  // A held message is shown as a preview in which Claude Code drops the
  // brackets: «agmsg:<nonce> …». Only delivery needs the bracketed form.
  const heldMarker = marker.slice(1, -1);
  if (!line || !line.includes(heldMarker)) return "";
  let row;
  try {
    row = JSON.parse(line);
  } catch {
    return "";
  }
  if (row?.type === "user" && typeof row?.origin?.body === "string" && row.origin.body.includes(marker)) {
    return "delivered";
  }
  // A nudge that arrives while the seat is mid-turn is absorbed into that
  // turn: the model reads it as a queued_command attachment and no user line
  // is ever written for it. Without this the nudge stays pending forever and
  // the seat gets no further notices.
  if (row?.type === "attachment" && row?.attachment?.type === "queued_command"
    && typeof row.attachment.prompt === "string" && row.attachment.prompt.includes(marker)) {
    return "delivered";
  }
  if (row?.type === "system" && row?.subtype === "informational" && typeof row?.content === "string" && row.content.includes(heldMarker)) {
    return "held";
  }
  return "";
}

// Reads from `start` to EOF in fixed-size chunks, handing each complete line
// its byte offset and whether a newline ended it to `onLine` (stop early by returning true). A line is
// decoded only whole, so a multi-byte character is never split across chunks.
// A `start` that is not at the beginning of a line (the byte before it is not a
// newline: a row was half written when it was recorded) discards the fragment
// up to the first newline instead of reading it as a line of its own.
function scanFrom(path, start, onLine, io) {
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(TRANSCRIPT_CHUNK_BYTES);
    let skipping = false;
    if (start > 0) {
      const prior = Buffer.alloc(1);
      skipping = io.readSync(fd, prior, 0, 1, start - 1) === 1 && prior[0] !== 10;
    }
    let position = start;
    let carry = Buffer.alloc(0);
    for (;;) {
      const read = io.readSync(fd, buf, 0, buf.length, position);
      if (read <= 0) break;
      position += read;
      const data = Buffer.concat([carry, buf.subarray(0, read)]);
      const base = position - data.length;
      let from = 0;
      for (let at = data.indexOf(10, from); at !== -1; at = data.indexOf(10, from)) {
        if (skipping) skipping = false;
        else if (onLine(data.subarray(from, at), base + from, fd, true)) return;
        from = at + 1;
      }
      carry = data.subarray(from);
    }
    if (!skipping && carry.length) onLine(carry, position - carry.length, fd, false);
  } finally {
    closeSync(fd);
  }
}

// Reads the delivery outcome straight from the receiving session's own
// transcript. Only what was written after `fromPosition` (the transcript
// length recorded before the nudge was sent) is read, however much the
// conversation has grown since; a transcript shorter than that position was
// rewritten or truncated and is read from the start, as is a nudge with no
// recorded position. A line is accepted as delivery only after it reads back
// byte for byte from the same place: a file rewritten during a read must not
// be confirmed from bytes that no version of it ever held.
export function observeTranscript(transcriptPath, nonce, fromPosition = null, io = { readSync }) {
  if (typeof nonce !== "string" || !nonce) return { state: "unreadable", reason: "nonce_missing" };
  const marker = `[agmsg:${nonce}]`;
  let heldSeen = false;
  let delivered = false;
  // Reads exactly `length` bytes at `position` (short reads are legal), or
  // fewer only at EOF.
  const readFully = (fd, buffer, length, position) => {
    let got = 0;
    while (got < length) {
      const read = io.readSync(fd, buffer, got, length - got, position + got);
      if (read <= 0) break;
      got += read;
    }
    return got;
  };
  // The line reads back unchanged with its own boundaries: the newline before
  // it (every line but the first of the file follows one), its bytes in
  // bounded chunks, and the newline after it when it had one.
  const stable = (fd, bytes, offset, terminated) => {
    const edge = Buffer.alloc(1);
    if (offset > 0 && (readFully(fd, edge, 1, offset - 1) !== 1 || edge[0] !== 10)) return false;
    const chunk = Buffer.alloc(Math.min(TRANSCRIPT_CHUNK_BYTES, bytes.length));
    for (let done = 0; done < bytes.length; done += chunk.length) {
      const size = Math.min(chunk.length, bytes.length - done);
      if (readFully(fd, chunk, size, offset + done) !== size || !chunk.subarray(0, size).equals(bytes.subarray(done, done + size))) return false;
    }
    return !terminated || (readFully(fd, edge, 1, offset + bytes.length) === 1 && edge[0] === 10);
  };
  const onLine = (bytes, offset, fd, terminated) => {
    const verdict = judgeLine(bytes.toString("utf8"), marker);
    if (verdict === "delivered" && stable(fd, bytes, offset, terminated)) delivered = true;
    else if (verdict === "held") heldSeen = true;
    return delivered;
  };
  try {
    const stat = statSync(transcriptPath);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("not_regular_file");
    const start = Number.isSafeInteger(fromPosition) && fromPosition >= 0 && fromPosition <= stat.size ? fromPosition : 0;
    scanFrom(transcriptPath, start, onLine, io);
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "unreadable", reason: "transcript_missing" };
    return { state: "unreadable", reason: "transcript_read_failed" };
  }
  if (delivered) return { state: "delivered" };
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
