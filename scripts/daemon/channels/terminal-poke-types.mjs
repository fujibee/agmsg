// A tiny, read-only reader for scripts/drivers/types/<name>/type.conf, for
// the three keys the terminal-poke channel needs (poke_delivery, cmd_prefix,
// poke_nudge). Mirrors scripts/lib/type-registry.sh's agmsg_type_get: plain
// key=value lines, one optional pair of surrounding double quotes, first
// match wins, never sourced/executed. A separate reader (not a shell-out to
// agmsg_type_get) because this is read on every unread transition for every
// terminal-poke-eligible seat, and a process per read would scale with seat
// count the way review-criteria §4 flags; a missing or unreadable type.conf
// is not an error here -- every key this reads has a safe default (poke
// delivery stays ON, same as the shell side).
import { readFileSync } from "node:fs";
import { join } from "node:path";

const cache = new Map();

function parseTypeConf(text) {
  const fields = Object.create(null);
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const at = line.indexOf("=");
    if (at < 1) continue;
    const key = line.slice(0, at).trim();
    let value = line.slice(at + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.slice(1, -1);
    }
    if (!(key in fields)) fields[key] = value;
  }
  return fields;
}

function readTypeConf(installRoot, type) {
  const cacheKey = `${installRoot}\u0000${type}`;
  if (cache.has(cacheKey)) return cache.get(cacheKey);
  let fields = Object.create(null);
  try {
    const path = join(installRoot, "scripts", "drivers", "types", type, "type.conf");
    fields = parseTypeConf(readFileSync(path, "utf8"));
  } catch {
    // Missing/unreadable: every caller below has a safe default.
  }
  cache.set(cacheKey, fields);
  return fields;
}

export function typeConfGet(installRoot, type, key, fallback = "") {
  const fields = readTypeConf(installRoot, type);
  return key in fields ? fields[key] : fallback;
}

// Default: on for every type without a native channel (design decision,
// 2026-11-13). `poke_delivery=no` is the only way to turn it off.
export function pokeDeliveryEnabled(installRoot, type) {
  return typeConfGet(installRoot, type, "poke_delivery", "yes") !== "no";
}

export function pokeNudgeText(installRoot, type, cmdName) {
  const override = typeConfGet(installRoot, type, "poke_nudge", "");
  if (override) return override;
  const prefix = typeConfGet(installRoot, type, "cmd_prefix", "/");
  return `agmsg: you have new messages. Run ${prefix}${cmdName} to check your inbox.`;
}

// Test-only: the cache is keyed on (installRoot, type) and never expires
// otherwise, since a running daemon's own type.conf files do not change
// under it -- a test using a throwaway installRoot per case never collides
// with another, so this is for a test that reuses one path across cases.
export function clearTypeConfCacheForTests() {
  cache.clear();
}
