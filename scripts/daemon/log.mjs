// run/agmsgd.log, rotated at 1 MiB, one prior generation kept
// (run/agmsgd.log.1). Records startup/stop/step-aside reasons and
// channel counts/failures ONLY -- never message bodies.

import { appendFileSync, existsSync, renameSync, statSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export const MAX_BYTES = 1024 * 1024;

export function logPath(installRoot) {
  return join(installRoot, "run", "agmsgd.log");
}

// Appends one line (a trailing newline is added), rotating first if the
// file has already reached MAX_BYTES. Best-effort: a logging failure must
// never be why the daemon itself fails an operation, so this never throws
// -- it falls back to stderr, once, rather than silently dropping the line.
export function logLine(installRoot, text) {
  const path = logPath(installRoot);
  const line = `${new Date().toISOString()} ${String(text).replace(/[\r\n]/g, ' ')}\n`;
  const bounded = Buffer.from(line).subarray(0, 4095).toString('utf8').trimEnd() + '\n';
  try {
    let size = 0;
    try {
      size = statSync(path).size;
    } catch {
      size = 0; // file does not exist yet: nothing to rotate
    }
    if (size + Buffer.byteLength(bounded) > MAX_BYTES) renameSync(path, `${path}.1`);
    appendFileSync(path, bounded);
  } catch (error) {
    process.stderr.write(`agmsgd: could not write to ${path}: ${error.message}\n`);
  }
}

export function logExists(installRoot) {
  return existsSync(logPath(installRoot));
}

// Explicit allowlist prevents accidental inclusion of message or token fields.
export function deliveryEvent(log, { event, channel, seat = null, reason = '', state, cursor }) {
  const entry = { event, channel, seat, reason };
  if (state !== undefined) entry.state = state;
  if (cursor !== undefined) entry.cursor = cursor;
  log(JSON.stringify(entry));
}

export function recordPollTimeout(installRoot, details) {
  const value = { at: new Date().toISOString(), channel: details.channel, seat: details.seat ?? null, reason: details.reason };
  try {
    const target = join(installRoot, 'run', 'poll-timeout.json');
    const temporary = `${target}.${process.pid}.tmp`;
    writeFileSync(temporary, JSON.stringify(value));
    renameSync(temporary, target);
  } catch (error) { logLine(installRoot, `poll: could not record deadline status: ${error.message}`); }
}

export function readPollTimeout(installRoot) {
  try { return JSON.parse(readFileSync(join(installRoot, 'run', 'poll-timeout.json'), 'utf8')); }
  catch (error) { return error.code === 'ENOENT' ? null : { reason: 'poll_timeout_status_unreadable' }; }
}
