// Schema and roster for the terminal-poke channel. Mirrors
// claude-code-queue-store.mjs's shape (schema + listClaudeCodeRegistrations),
// inverted: this lists every (team, agent) whose type has NO native channel
// of its own, instead of one specific type.

import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

// Types with their own native delivery channel elsewhere in this daemon
// (claude-code-queue.mjs, codex-queue.mjs). grok-build's own channel does
// not exist in this codebase yet (design note names it as a future native
// channel, not a present one) -- listed here anyway because the exclusion is
// the 2026-11-13 decision, not a reflection of what has shipped; the day a
// grok channel lands, this list does not need to change.
export const NATIVE_CHANNEL_TYPES = ["claude-code", "codex", "grok-build"];

export const TERMINAL_POKE_CHANNEL_SCHEMA = `
CREATE TABLE IF NOT EXISTS beta_terminal_poke_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seat TEXT NOT NULL,
  up_to TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'confirmed', 'expired')),
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS beta_terminal_poke_queue_one_pending
  ON beta_terminal_poke_queue(seat) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS beta_terminal_poke_queue_latest
  ON beta_terminal_poke_queue(seat, id DESC);
CREATE TABLE IF NOT EXISTS beta_terminal_poke_seat (
  seat TEXT PRIMARY KEY,
  state TEXT NOT NULL,
  reason TEXT NOT NULL,
  checked_at TEXT NOT NULL
);
`;

export function ensureTerminalPokeChannelSchema(db) {
  db.exec("BEGIN IMMEDIATE;");
  try {
    db.exec(TERMINAL_POKE_CHANNEL_SCHEMA);
    db.exec("COMMIT;");
  } catch (error) {
    try { db.exec("ROLLBACK;"); } catch { /* preserve the schema error */ }
    throw error;
  }
}

function latestNonNativeRegistration(registrations, isNative) {
  if (!Array.isArray(registrations)) return null;
  for (let index = registrations.length - 1; index >= 0; index -= 1) {
    const registration = registrations[index];
    const type = registration?.type;
    if (typeof type === "string" && type && !isNative(type)) return registration;
  }
  return null;
}

// Enumerates (team, agent) pairs whose registrations include NO native-
// channel type (a seat that has one is already covered by that channel) and
// whose most recent non-native registration's type has not opted out via
// type.conf's poke_delivery=no. A team that cannot be read is listed under
// `skipped` and does not hide the others -- same contract as
// listClaudeCodeRegistrations.
export function listTerminalPokeRegistrations(teamsDir, {
  isNativeChannelType = (type) => NATIVE_CHANNEL_TYPES.includes(type),
  pokeDeliveryEnabled = () => true,
} = {}) {
  let entries;
  try {
    entries = readdirSync(teamsDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "ok", seats: [] };
    return { state: "unreadable", reason: "team_roster_unreadable" };
  }
  const seats = [];
  const skipped = [];
  for (const entry of entries) {
    if (entry.isSymbolicLink()) {
      skipped.push({ team: entry.name, reason: "team_roster_symlink" });
      continue;
    }
    if (!entry.isDirectory()) continue;
    let config;
    try {
      const stat = lstatSync(join(teamsDir, entry.name, "config.json"));
      if (!stat.isFile() || stat.isSymbolicLink()) {
        skipped.push({ team: entry.name, reason: "team_roster_symlink" });
        continue;
      }
      config = JSON.parse(readFileSync(join(teamsDir, entry.name, "config.json"), "utf8"));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      skipped.push({ team: entry.name, reason: "team_roster_malformed" });
      continue;
    }
    if (!config || typeof config !== "object" || !config.agents || typeof config.agents !== "object" || Array.isArray(config.agents)) {
      skipped.push({ team: entry.name, reason: "team_roster_malformed" });
      continue;
    }
    for (const [agent, value] of Object.entries(config.agents)) {
      const regs = value && Array.isArray(value.registrations) ? value.registrations : [];
      if (regs.length === 0) continue;
      if (regs.some((registration) => isNativeChannelType(registration?.type))) continue;
      const registration = latestNonNativeRegistration(regs, isNativeChannelType);
      if (!registration) continue;
      if (!pokeDeliveryEnabled(registration.type)) continue;
      seats.push({ team: entry.name, agent, type: registration.type, project: registration.project ?? "", teamConfig: config });
    }
  }
  return { state: "ok", seats, skipped };
}
