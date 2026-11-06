// Second source for a Claude Code seat's messaging socket (#1910).
//
// The role-session record names one socket path, written by SessionStart or
// actas, and Claude Code's socket changes with every new process (--resume, a
// self-update restart). When the recorded path is gone this looks at the files
// Claude Code itself writes, <claude_config_dir>/sessions/<pid>.json, for the
// record's own session id. It is a best-effort second source: the file is
// Claude Code's, not ours, so only the exact shape read here is trusted, the
// process is checked against it, and anything else is "not found" -- a socket
// is never guessed.
//
// Fields read: sessionId, pid, procStart (UTC, the form `ps -o lstart=` prints
// for the process start in local time), messagingSocketPath.
// tests/claude_code_sessions.test.mjs pins this shape.
//
// Process launches: one `ps -o lstart= -p <pid>` per candidate that matched the
// session id and whose pid is alive; none when no file matches.

import { execFile } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const MAX_FILES = 500;
const START_TOLERANCE_MS = 2_000;

export function pidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

function psStart(pid, run = execFile) {
  return new Promise((resolve) => {
    run("ps", ["-o", "lstart=", "-p", String(pid)], { encoding: "utf8", timeout: 3_000, env: { ...process.env, LC_ALL: "C", TZ: process.env.TZ } }, (error, stdout) => {
      if (error) return resolve("");
      resolve(String(stdout).trim().replace(/\s+/g, " "));
    });
  });
}

// "Mon Nov  2 00:34:49 2026" (UTC) -> epoch ms, or NaN when it is not that shape.
export function parseStart(text, zone) {
  const clean = String(text ?? "").trim().replace(/\s+/g, " ");
  if (!/^[A-Z][a-z]{2} [A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}:\d{2} \d{4}$/.test(clean)) return NaN;
  return Date.parse(zone === "utc" ? `${clean} UTC` : clean);
}

/**
 * Looks for the live Claude Code process of `sessionId`.
 * Returns
 *   { state: "found", socket, pid }   a live process with a socket path
 *   { state: "ended" }                the directory was read and no live process has this session
 *   { state: "unknown", reason }      could not tell: unreadable directory, files of another shape
 */
export async function findSessionSocket({ configDir, sessionId, alive = pidAlive, startOf = psStart, platform = process.platform }) {
  if (platform === "win32") return { state: "unknown", reason: "sessions_files_not_read_on_windows" };
  if (!configDir || !sessionId) return { state: "unknown", reason: "sessions_lookup_needs_session_and_config_dir" };
  const dir = join(configDir, "sessions");
  let names;
  try {
    names = readdirSync(dir).filter((name) => /^\d+\.json$/.test(name));
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "unknown", reason: "sessions_dir_missing" };
    return { state: "unknown", reason: "sessions_dir_unreadable" };
  }
  if (names.length > MAX_FILES) return { state: "unknown", reason: "sessions_dir_too_large" };
  let matched = 0;
  let unreadable = 0;
  for (const name of names) {
    let data;
    try {
      data = JSON.parse(readFileSync(join(dir, name), "utf8"));
    } catch {
      unreadable += 1;
      continue;
    }
    if (!data || typeof data !== "object" || typeof data.sessionId !== "string") { unreadable += 1; continue; }
    if (data.sessionId !== sessionId) continue;
    matched += 1;
    const pid = Number(name.slice(0, -5));
    if (data.pid !== pid || typeof data.procStart !== "string" || typeof data.messagingSocketPath !== "string") { unreadable += 1; continue; }
    if (!alive(pid)) continue;
    const want = parseStart(data.procStart, "utc");
    const have = parseStart(await startOf(pid), "local");
    if (Number.isNaN(want) || Number.isNaN(have)) { unreadable += 1; continue; }
    if (Math.abs(want - have) > START_TOLERANCE_MS) continue; // the pid now belongs to another process
    const socket = data.messagingSocketPath;
    if (!socket.startsWith("/") || /[\u0000-\u001f]/.test(socket)) { unreadable += 1; continue; }
    return { state: "found", socket, pid };
  }
  // Files of another shape could hide the session: that is not proof it ended.
  if (unreadable > 0) return { state: "unknown", reason: "sessions_files_unreadable_or_other_shape" };
  void matched;
  return { state: "ended" };
}
