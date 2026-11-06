// Node side of scripts/lib/down-notice.sh: the same record, the same key.
//
//   <install>/run/down/<component>.json
//   {"component":..,"state":"down|degraded","reason":..,"recovery":..,"since":..,"updated":..}
//
// The shell helper is the reference; tests/down_notice_node.test.mjs checks that
// the key and the record this writes are the ones it reads and writes. Quotes and
// backslashes in free text become ' and /, control characters become spaces, so
// every field is a plain string the shell reads back with parameter expansion.
// No process is started.

import { mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";

const KEY_RE = /^[a-z0-9][a-z0-9._-]{0,99}$/;

export function downNoticeKey(prefix, text) {
  const bytes = Buffer.from(String(text ?? ""), "utf8");
  let h = 2166136261;
  for (const b of bytes) h = Math.imul(h ^ b, 16777619) >>> 0;
  // The shell folds byte by byte, so a multi-byte character is one `-` per byte.
  let slug = "";
  for (const b of bytes) {
    const ch = String.fromCharCode(b >= 65 && b <= 90 ? b + 32 : b);
    slug += b < 128 && /^[a-z0-9._-]$/.test(ch) ? ch : "-";
  }
  const room = Math.max(0, 100 - prefix.length - 10);
  return `${prefix}.${slug.slice(0, room)}-${h.toString(16).padStart(8, "0")}`;
}

function clean(text) {
  return String(text ?? "").replace(/"/g, "'").replace(/\\/g, "/").replace(/[\u0000-\u001f\u007f]/g, " ");
}

export function downNoticePath(installRoot, key) {
  return join(installRoot, "run", "down", `${key}.json`);
}

function field(json, name) {
  const rest = json.split(`"${name}":"`)[1];
  return rest === undefined ? "" : rest.split('"')[0];
}

// Returns true when the record is there with the new content.
export function downNoticeSet(installRoot, key, state, reason, recovery, now = Date.now) {
  if (!KEY_RE.test(key) || (state !== "down" && state !== "degraded")) return false;
  const file = downNoticePath(installRoot, key);
  try {
    mkdirSync(join(installRoot, "run", "down"), { recursive: true });
    let since = "";
    try {
      const old = readFileSync(file, "utf8");
      if (field(old, "state") === state) since = field(old, "since");
    } catch { /* no earlier record */ }
    const stamp = new Date(now()).toISOString().replace(/\.\d{3}Z$/, "Z");
    if (!since) since = stamp;
    const line = `{"component":"${key}","state":"${state}","reason":"${clean(reason)}","recovery":"${clean(recovery)}","since":"${since}","updated":"${stamp}"}\n`;
    const tmp = join(dirname(file), `.${key}.json.${process.pid}`);
    writeFileSync(tmp, line);
    renameSync(tmp, file);
    return readFileSync(file, "utf8") === line;
  } catch {
    return false;
  }
}

export function downNoticeClear(installRoot, key) {
  if (!KEY_RE.test(key)) return false;
  try {
    rmSync(`${downNoticePath(installRoot, key)}.shown`, { force: true });
    rmSync(downNoticePath(installRoot, key), { force: true });
    return true;
  } catch {
    return false;
  }
}
