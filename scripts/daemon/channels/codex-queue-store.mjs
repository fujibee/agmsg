// Read-only view of agmsg's existing message stores plus the daemon's small
// Codex-channel tables. The daemon never initializes or repairs a team store.

import { DatabaseSync } from "node:sqlite";
import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { isAbsolute, join } from "node:path";

export const CODEX_CHANNEL_SCHEMA = `
CREATE TABLE IF NOT EXISTS beta_codex_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seat TEXT NOT NULL,
  codex_home TEXT NOT NULL,
  thread TEXT NOT NULL,
  up_to TEXT NOT NULL,
  nonce TEXT NOT NULL,
  queue_item_id TEXT,
  state TEXT NOT NULL CHECK (state IN ('pending', 'confirmed', 'expired')),
  children TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS beta_codex_queue_one_pending
  ON beta_codex_queue(seat) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS beta_codex_queue_latest
  ON beta_codex_queue(seat, id DESC);
CREATE TABLE IF NOT EXISTS beta_codex_seat (
  seat TEXT PRIMARY KEY,
  thread TEXT,
  codex_home TEXT,
  state TEXT NOT NULL CHECK (state IN ('addressable', 'unaddressable', 'blocked', 'bridged')),
  reason TEXT NOT NULL,
  checked_at TEXT NOT NULL
);
`;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function ensureCodexChannelSchema(db) {
  db.exec("BEGIN IMMEDIATE;");
  try {
    db.exec(CODEX_CHANNEL_SCHEMA);
    db.exec("COMMIT;");
  } catch (error) {
    try { db.exec("ROLLBACK;"); } catch { /* preserve the schema error */ }
    throw error;
  }
}
function readJson(path) {
  try {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("not_regular_file");
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return { missing: true };
    throw error;
  }
}

function encodeName(value) {
  return [...Buffer.from(value, "utf8")].map((byte) => {
    const char = String.fromCharCode(byte);
    return /^[A-Za-z0-9._-]$/.test(char) ? char : `%${byte.toString(16).padStart(2, "0").toUpperCase()}`;
  }).join("");
}

export function roleSessionPath(runDir, team, agent) {
  return join(runDir, `role-session.${encodeName(team)}__${encodeName(agent)}`);
}

export function readRoleSession(runDir, team, agent) {
  const path = roleSessionPath(runDir, team, agent);
  let stat;
  try {
    stat = lstatSync(path);
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "absent" };
    return { state: "unreadable", reason: "role_session_read_failed" };
  }
  if (!stat.isFile() || stat.isSymbolicLink()) return { state: "unreadable", reason: "role_session_not_regular_file" };
  try {
    const fields = Object.create(null);
    for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
      const at = line.indexOf("=");
      if (at < 1) continue;
      const key = line.slice(0, at);
      if (!(key in fields)) fields[key] = line.slice(at + 1);
    }
    return {
      state: "present",
      record: {
        team: fields.team ?? "",
        agent: fields.agent ?? "",
        type: fields.type ?? "",
        project: fields.project ?? "",
        thread: fields.session ?? "",
        codex_home: fields.codex_home ?? "",
      },
    };
  } catch {
    return { state: "unreadable", reason: "role_session_read_failed" };
  }
}

// Enumerates only roles whose current registration explicitly names Codex.
// A malformed team record is reported, not interpreted as an empty roster.
export function listCodexRegistrations(teamsDir) {
  let entries;
  try {
    entries = readdirSync(teamsDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return { state: "ok", seats: [] };
    return { state: "unreadable", reason: "team_roster_unreadable" };
  }
  const seats = [];
  for (const entry of entries) {
    if (entry.isSymbolicLink()) return { state: "unreadable", reason: "team_roster_symlink" };
    if (!entry.isDirectory()) continue;
    const result = readJson(join(teamsDir, entry.name, "config.json"));
    if (result.missing) continue;
    const config = result;
    if (!config || typeof config !== "object" || !config.agents || typeof config.agents !== "object" || Array.isArray(config.agents)) {
      return { state: "unreadable", reason: "team_roster_malformed" };
    }
    for (const [agent, value] of Object.entries(config.agents)) {
      const regs = value && Array.isArray(value.registrations) ? value.registrations : [];
      if (regs.some((registration) => registration?.type === "codex")) {
        seats.push({ team: entry.name, agent, teamConfig: config });
      }
    }
  }
  return { state: "ok", seats };
}

export function readStorageDriver(configPath) {
  const result = readJson(configPath);
  if (result.missing) return { state: "ok", driver: "sqlite" };
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return { state: "unreadable", reason: "storage_config_malformed" };
  }
  const driver = result.storage || "sqlite";
  return typeof driver === "string" && driver.length > 0
    ? { state: "ok", driver }
    : { state: "unreadable", reason: "storage_driver_unreadable" };
}

export function messageStorePath({ storageDir, team, teamConfig }) {
  if (typeof team !== "string" || !team || team.includes("/") || team.includes("\\") || team === "." || team === "..") {
    throw new TypeError("invalid_team_name");
  }
  const partition = teamConfig?.drivers?.partition || "shared";
  if (partition === "shared") return join(storageDir, "messages.db");
  if (partition === "per-team") return join(storageDir, "teams", team, "messages.db");
  throw new Error("storage_partition_unsupported");
}

export function openMessageStore(path) {
  if (!isAbsolute(path)) throw new TypeError("message_store_path_not_absolute");
  const stat = lstatSync(path);
  if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("message_store_not_regular_file");
  const db = new DatabaseSync(path, { readOnly: true, allowExtension: false });
  try {
    db.exec("PRAGMA busy_timeout = 1000; PRAGMA query_only = ON;");
    // Validate the expected read schema now. An absent table is not an empty inbox.
    db.prepare("SELECT seq FROM events LIMIT 0").all();
    db.prepare("SELECT id FROM messages LIMIT 0").all();
    db.prepare("SELECT local_position FROM read_cursors LIMIT 0").all();
    return db;
  } catch (error) {
    db.close();
    throw error;
  }
}

function cursorValue(raw) {
  if (!raw) return { eventSeq: 0, legacyId: 0 };
  try {
    const cursor = JSON.parse(raw);
    if (Number.isSafeInteger(cursor.eventSeq) && cursor.eventSeq >= 0 && Number.isSafeInteger(cursor.legacyId) && cursor.legacyId >= 0) {
      return cursor;
    }
  } catch { /* malformed cursor must not become a guessed zero */ }
  throw new Error("notification_cursor_unreadable");
}

// Uses one read transaction so the cursor never advances past a concurrently
// inserted message. Bodies are not selected or returned.
export function readUnreadSnapshot(db, team, agent, encodedCursor = "") {
  const cursor = cursorValue(encodedCursor);
  db.exec("BEGIN;");
  try {
    const tip = db.prepare("SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='events'), 0) AS n").get().n;
    const legacyTip = db.prepare("SELECT COALESCE(MAX(id), 0) AS n FROM messages WHERE team = ?").get(team).n;
    const eventUnread = db.prepare(`
      SELECT 1 AS yes FROM events e
      WHERE e.type='message_sent' AND e.team=? AND e.to_agent=?
        AND e.seq>? AND e.seq<=?
        AND e.seq>COALESCE((SELECT local_position FROM read_cursors WHERE team=? AND agent=?), 0)
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read' AND r.team=e.team AND r.agent=? AND r.msg_id=e.id)
      LIMIT 1
    `).get(team, agent, cursor.eventSeq, tip, team, agent, agent);
    const legacyUnread = db.prepare(`
      SELECT 1 AS yes FROM messages m
      WHERE m.team=? AND m.to_agent=? AND m.id>? AND m.id<=? AND m.read_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM events r WHERE r.type='message_read' AND r.team=m.team AND r.agent=? AND r.msg_id=CAST(m.id AS TEXT))
        AND NOT EXISTS (SELECT 1 FROM events e2 WHERE e2.legacy_id=m.id AND e2.seq>0)
      LIMIT 1
    `).get(team, agent, cursor.legacyId, legacyTip, agent);
    db.exec("COMMIT;");
    return {
      state: "ok",
      unread: Boolean(eventUnread || legacyUnread),
      upTo: JSON.stringify({ eventSeq: tip, legacyId: legacyTip }),
    };
  } catch (error) {
    try { db.exec("ROLLBACK;"); } catch { /* keep the observation error */ }
    throw error;
  }
}
