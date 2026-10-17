// Read-only view of agmsg's existing message stores plus the daemon's small
// Claude Code native-channel tables. The daemon never initializes or repairs
// a team store. Mirrors codex-queue-store.mjs's shape; the generic store
// helpers (message store path/open/snapshot, storage driver) are reused
// directly from there rather than duplicated.

import { lstatSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { roleSessionPath } from "./codex-queue-store.mjs";

export const CLAUDE_CODE_CHANNEL_SCHEMA = `
CREATE TABLE IF NOT EXISTS beta_claude_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  seat TEXT NOT NULL,
  messaging_socket TEXT NOT NULL,
  transcript_path TEXT NOT NULL,
  up_to TEXT NOT NULL,
  nonce TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'confirmed', 'expired')),
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS beta_claude_queue_one_pending
  ON beta_claude_queue(seat) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS beta_claude_queue_latest
  ON beta_claude_queue(seat, id DESC);
CREATE TABLE IF NOT EXISTS beta_claude_seat (
  seat TEXT PRIMARY KEY,
  messaging_socket TEXT,
  state TEXT NOT NULL CHECK (state IN ('addressable', 'unaddressable', 'blocked')),
  reason TEXT NOT NULL,
  checked_at TEXT NOT NULL
);
`;

export function ensureClaudeCodeChannelSchema(db) {
  db.exec("BEGIN IMMEDIATE;");
  try {
    db.exec(CLAUDE_CODE_CHANNEL_SCHEMA);
    db.exec("COMMIT;");
  } catch (error) {
    try { db.exec("ROLLBACK;"); } catch { /* preserve the schema error */ }
    throw error;
  }
}

// Same record file role-session.sh's agmsg_role_session_set_messaging writes
// messaging_socket/claude_config_dir into (#339 record, shared with Codex's
// codex_home field in the same file). A record missing either new field is
// reported present with an empty value — the caller treats that exactly like
// Codex's role_session_missing: no destination, not an error.
export function readClaudeRoleSession(runDir, team, agent) {
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
        session: fields.session ?? "",
        messaging_socket: fields.messaging_socket ?? "",
        claude_config_dir: fields.claude_config_dir ?? "",
      },
    };
  } catch {
    return { state: "unreadable", reason: "role_session_read_failed" };
  }
}

// Enumerates only roles whose current registration explicitly names
// claude-code. Mirrors listCodexRegistrations in codex-queue-store.mjs
// exactly, filtered on a different registration type — small enough that
// sharing it would cost more indirection than it saves.
export function listClaudeCodeRegistrations(teamsDir) {
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
    let config;
    try {
      const stat = lstatSync(join(teamsDir, entry.name, "config.json"));
      if (!stat.isFile() || stat.isSymbolicLink()) return { state: "unreadable", reason: "team_roster_symlink" };
      config = JSON.parse(readFileSync(join(teamsDir, entry.name, "config.json"), "utf8"));
    } catch (error) {
      if (error?.code === "ENOENT") continue;
      return { state: "unreadable", reason: "team_roster_malformed" };
    }
    if (!config || typeof config !== "object" || !config.agents || typeof config.agents !== "object" || Array.isArray(config.agents)) {
      return { state: "unreadable", reason: "team_roster_malformed" };
    }
    for (const [agent, value] of Object.entries(config.agents)) {
      const regs = value && Array.isArray(value.registrations) ? value.registrations : [];
      if (regs.some((registration) => registration?.type === "claude-code")) {
        seats.push({ team: entry.name, agent, teamConfig: config });
      }
    }
  }
  return { state: "ok", seats };
}
