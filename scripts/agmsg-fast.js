"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { resolveIdentities } = require("./lib/identity-resolver" );

function loadSqlite() {
  try {
    return require("node:sqlite");
  } catch (error) {
    error.exitCode = 78;
    throw error;
  }
}

function storageDb(skillDir) {
  const storage = process.env.AGMSG_STORAGE_PATH || path.join(skillDir, "db");
  return path.join(storage, "messages.db");
}

function openDb(dbPath, { create = false } = {}) {
  const { DatabaseSync } = loadSqlite();
  if (!create && !fs.existsSync(dbPath)) return null;
  if (create) fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec(`PRAGMA busy_timeout=${Number(process.env.AGMSG_BUSY_TIMEOUT || 5000)}`);
  if (create) {
    try {
      db.exec("PRAGMA journal_mode=WAL");
    } catch (_) {
      // WAL is a best-effort optimization, matching init-db.sh.
    }
    db.exec(`
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        team TEXT NOT NULL,
        from_agent TEXT NOT NULL,
        to_agent TEXT NOT NULL,
        body TEXT NOT NULL,
        created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        read_at TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_unread
        ON messages(team, to_agent, read_at) WHERE read_at IS NULL;
      CREATE INDEX IF NOT EXISTS idx_history
        ON messages(team, created_at DESC);
    `);
  }
  return db;
}

function escapeBody(body) {
  return body.replace(/\n/g, "\\n").replace(/\t/g, "\\t");
}

function assertTeamName(team) {
  if (!team || team === "." || team === ".." || /[\\/\0]/.test(team)) {
    throw Object.assign(new Error(`invalid team name: ${team}`), { exitCode: 1 });
  }
}

function teamCommand({ skillDir, team }) {
  assertTeamName(team);
  const file = path.join(skillDir, "teams", team, "config.json");
  if (!fs.existsSync(file)) {
    return { exitCode: 1, stdout: `Team not found: ${team}\n` };
  }
  const config = JSON.parse(fs.readFileSync(file, "utf8"));
  const lines = [`Team: ${team}`, ""];
  let count = 0;
  const agents = Object.entries(config.agents || {});
  for (const [name, agent] of agents) {
    const registrations = Array.isArray(agent.registrations)
      ? agent.registrations
      : [{ type: agent.type, project: agent.project }];
    const types = [...new Set(registrations.map((item) => item.type).filter(Boolean))].join(",");
    const latest = registrations.length ? registrations[registrations.length - 1] : null;
    const project = (latest && latest.project) || "?";
    const more = registrations.length > 1 ? ` (+${registrations.length - 1} more)` : "";
    lines.push(`  ${name} (${types}) — ${project}${more}`);
    count += 1;
  }
  lines.push("", `${count} member(s)`);
  return { exitCode: 0, stdout: `${lines.join("\n")}\n` };
}

function registeredAgentNames(skillDir, team) {
  const file = path.join(skillDir, "teams", team, "config.json");
  if (!fs.existsSync(file)) return [];
  const config = JSON.parse(fs.readFileSync(file, "utf8"));
  return Object.keys(config.agents || {});
}

function sendCommand({ skillDir, dbPath, team, from, to, body, force = false }) {
  assertTeamName(team);
  if (!force) {
    const roster = registeredAgentNames(skillDir, team);
    for (const [role, name] of [["from", from], ["to", to]]) {
      if (!roster.includes(name)) {
        if (roster.length === 0) {
          return {
            exitCode: 1,
            stdout: "",
            stderr: `Error: team '${team}' has no registered agents — cannot send as ${role} '${name}' (use --force to bypass).\n`,
          };
        }
        return {
          exitCode: 1,
          stdout: "",
          stderr: `Error: ${role} agent '${name}' is not registered in team '${team}' (registered: ${roster.join(", ")}). Use --force to bypass.\n`,
        };
      }
    }
  }
  const db = openDb(dbPath, { create: true });
  try {
    db.prepare(
      "INSERT INTO messages (team, from_agent, to_agent, body) VALUES (?, ?, ?, ?)",
    ).run(team, from, to, body);
  } finally {
    db.close();
  }
  return { exitCode: 0, stdout: `Sent to ${to} in team ${team}\n` };
}

function inboxCommand({ dbPath, team, agent, quiet = false, afterSelect }) {
  assertTeamName(team);
  const db = openDb(dbPath);
  if (!db) {
    return {
      exitCode: 0,
      stdout: quiet ? "" : "No messages (DB not initialized)\n",
    };
  }
  try {
    const rows = db
      .prepare(
        `SELECT id, from_agent AS "from", body, created_at
           FROM messages
          WHERE team=? AND to_agent=? AND read_at IS NULL
          ORDER BY created_at ASC`,
      )
      .all(team, agent);
    if (rows.length === 0) {
      return { exitCode: 0, stdout: quiet ? "" : "No new messages.\n" };
    }
    if (afterSelect) afterSelect({ db, rows });
    const lines = [`${rows.length} new message(s):`, ""];
    for (const row of rows) {
      lines.push(`  [${row.created_at}] ${row.from}: ${escapeBody(row.body)}`);
    }
    lines.push("");
    let marking = false;
    try {
      db.exec("BEGIN IMMEDIATE");
      marking = true;
      const statement = db.prepare(
        "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=? AND read_at IS NULL",
      );
      for (const row of rows) statement.run(row.id);
      db.exec("COMMIT");
      marking = false;
    } catch (_) {
      // Match inbox.sh: displaying the selected rows succeeds even when the
      // best-effort mark cannot be persisted in a sandbox or lock race.
      if (marking) {
        try { db.exec("ROLLBACK"); } catch (_) {}
      }
    }
    return { exitCode: 0, stdout: `${lines.join("\n")}\n` };
  } finally {
    db.close();
  }
}

function historyCommand({ dbPath, team, agent = "", limit = 20 }) {
  assertTeamName(team);
  const db = openDb(dbPath);
  if (!db) return { exitCode: 0, stdout: "No messages (DB not initialized)\n" };
  const safeLimit = /^\d+$/.test(String(limit)) ? Number(limit) : 20;
  try {
    const where = agent
      ? "team=? AND (from_agent=? OR to_agent=?)"
      : "team=?";
    const values = agent ? [team, agent, agent, safeLimit] : [team, safeLimit];
    const rows = db
      .prepare(
        `SELECT from_agent AS "from", to_agent AS "to", body, created_at, read_at
           FROM messages WHERE ${where}
          ORDER BY created_at DESC LIMIT ?`,
      )
      .all(...values)
      .reverse();
    if (rows.length === 0) return { exitCode: 0, stdout: "No message history.\n" };
    const stdout = rows
      .map((row) => {
        const status = row.read_at === null ? "●" : "○";
        return `  ${status} [${row.created_at}] ${row.from} → ${row.to}: ${escapeBody(row.body)}`;
      })
      .join("\n");
    return { exitCode: 0, stdout: `${stdout}\n` };
  } finally {
    db.close();
  }
}

function whoamiCommand({ skillDir, project, type }) {
  if (!project || !type) {
    return { exitCode: 64, stdout: "", stderr: "usage: agmsg-fast.js whoami <project> <type>\n" };
  }
  const result = resolveIdentities({ skillDir, project, type });
  const available = result.availableTeams.length ? result.availableTeams.join(",") : "none";
  if (result.status === "not_joined") {
    return { exitCode: 0, stdout: `not_joined=true available_teams=${available}\n` };
  }
  const names = [...new Set(result.identities.map((identity) => identity.name))];
  const teams = [...new Set(result.identities.map((identity) => identity.team))];
  if (result.status === "suggest") {
    return {
      exitCode: 0,
      stdout: `suggest=true agents=${names.join(",")} teams=${teams.join(",")} type=${type} project=${project} available_teams=${available}\n`,
    };
  }
  const prefix = names.length === 1 ? `agent=${names[0]}` : `multiple=true agents=${names.join(",")}`;
  return {
    exitCode: 0,
    stdout: `${prefix} teams=${teams.join(",")} type=${type} project=${project}\n`,
  };
}

function run(argv, options = {}) {
  const skillDir = options.skillDir || process.env.AGMSG_SKILL_DIR || path.resolve(__dirname, "..");
  const dbPath = options.dbPath || storageDb(skillDir);
  const [command, ...args] = argv;
  switch (command) {
    case "whoami":
      return whoamiCommand({ skillDir, project: args[0], type: args[1] });
    case "team":
      return teamCommand({ skillDir, team: args[0] });
    case "send":
      if (args.length < 4 || args.slice(0, 4).some((value) => !value)) {
        return {
          exitCode: 64,
          stdout: "",
          stderr: "usage: agmsg-fast.js send <team> <from> <to> <message>\n",
        };
      }
      return sendCommand({
        skillDir,
        dbPath,
        team: args[0],
        from: args[1],
        to: args[2],
        body: args[3],
        force: args[4] === "--force",
      });
    case "inbox":
      return inboxCommand({
        dbPath,
        team: args[0],
        agent: args[1],
        quiet: args[2] === "--quiet",
      });
    case "history":
      return historyCommand({
        dbPath,
        team: args[0],
        agent: args[1] || "",
        limit: args[2] || 20,
      });
    default:
      return { exitCode: 64, stdout: "", stderr: `unsupported fast command: ${command}\n` };
  }
}

if (require.main === module) {
  try {
    const result = run(process.argv.slice(2));
    process.stdout.write(result.stdout || "");
    process.stderr.write(result.stderr || "");
    process.exitCode = result.exitCode;
  } catch (error) {
    process.stderr.write(`agmsg-fast: ${error.message}\n`);
    process.exitCode = error.exitCode || 1;
  }
}

module.exports = {
  historyCommand,
  inboxCommand,
  run,
  sendCommand,
  teamCommand,
  whoamiCommand,
};
