// run/agmsgd.log, rotated at 1 MiB, one prior generation kept
// (run/agmsgd.log.1). T3 "ほか": startup/stop/step-aside reasons and
// channel counts/failures ONLY -- never message bodies.

import { appendFileSync, existsSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";

const MAX_BYTES = 1024 * 1024;

export function logPath(installRoot) {
  return join(installRoot, "run", "agmsgd.log");
}

// Appends one line (a trailing newline is added), rotating first if the
// file has already reached MAX_BYTES. Best-effort: a logging failure must
// never be why the daemon itself fails an operation, so this never throws
// -- it falls back to stderr, once, rather than silently dropping the line.
export function logLine(installRoot, text) {
  const path = logPath(installRoot);
  try {
    let size = 0;
    try {
      size = statSync(path).size;
    } catch {
      size = 0; // file does not exist yet: nothing to rotate
    }
    if (size >= MAX_BYTES) {
      try {
        renameSync(path, `${path}.1`);
      } catch {
        // best-effort: if the rename fails, keep appending to the same
        // file rather than lose the line
      }
    }
    appendFileSync(path, `${new Date().toISOString()} ${text}\n`);
  } catch (error) {
    process.stderr.write(`agmsgd: could not write to ${path}: ${error.message}\n`);
  }
}

export function logExists(installRoot) {
  return existsSync(logPath(installRoot));
}
