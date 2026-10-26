// Claude Code native-channel socket I/O. A completed write is delivery;
// no transcript confirmation is required. Transcript access is limited to a
// best-effort permission-mode hint for the existing wire format.

import { randomUUID } from "node:crypto";
import { createConnection } from "node:net";
import { closeSync, lstatSync, openSync, readSync, readdirSync, statSync } from "node:fs";
import process from "node:process";
import { isAbsolute } from "node:path";

export { newNonce, inboxNudge } from "./codex-queue-io.mjs";

const SEND_TIMEOUT_MS = 5_000;
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
      try {
        socket.end(line, (error) => finish(error
          ? { state: "failed", reason: `socket_write_error:${error.code ?? error.message}` }
          : { state: "sent", nonce, msgId: payload.msg_id }));
      } catch (error) {
        finish({ state: "failed", reason: `socket_write_error:${error.code ?? error.message}` });
      }
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
