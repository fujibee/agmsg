"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { resolveIdentities } = require("./lib/identity-resolver");

const PREFLIGHT_UNAVAILABLE = 78;

function loadSqlite() {
  try {
    return require("node:sqlite");
  } catch (error) {
    error.exitCode = PREFLIGHT_UNAVAILABLE;
    throw error;
  }
}

function stopOutputForType(skillDir, type) {
  const file = path.join(skillDir, "scripts", "drivers", "types", type, "type.conf");
  if (!fs.existsSync(file)) return "";
  const match = /^stop_output=(.*)$/m.exec(fs.readFileSync(file, "utf8"));
  return match ? match[1].trim() : "";
}

function parseInput(value) {
  if (!value || !value.trim()) return {};
  try {
    return JSON.parse(value);
  } catch (_) {
    return {};
  }
}

function emitStatus(stopOutput, systemMessage) {
  return stopOutput === "json"
    ? `${JSON.stringify({ continue: true, systemMessage }, null, 2)}\n`
    : "";
}

function instancePid(token) {
  const match = /\.(\d+)$/.exec(token || "");
  return match ? Number(match[1]) : null;
}

function pidAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

function instanceAlive(skillDir, token, injectedPidAlive = pidAlive) {
  const compositePid = instancePid(token);
  if (compositePid !== null) return injectedPidAlive(compositePid);
  const runDir = path.join(skillDir, "run");
  if (!fs.existsSync(runDir)) return false;
  for (const entry of fs.readdirSync(runDir)) {
    if (!entry.startsWith("cc-instance.")) continue;
    const pid = Number(entry.slice("cc-instance.".length));
    if (!injectedPidAlive(pid)) continue;
    const stored = fs.readFileSync(path.join(runDir, entry), "utf8").trim();
    if (stored === token || stored.startsWith(`${token}.`)) return true;
  }
  return false;
}

function safeToken(value) {
  return Buffer.from(String(value), "utf8").reduce((encoded, byte) => {
    const safe =
      (byte >= 48 && byte <= 57) ||
      (byte >= 65 && byte <= 90) ||
      (byte >= 97 && byte <= 122) ||
      byte === 45 ||
      byte === 46 ||
      byte === 95;
    return encoded + (safe ? String.fromCharCode(byte) : `%${byte.toString(16).toUpperCase().padStart(2, "0")}`);
  }, "");
}

function lockOwner(skillDir, team, agent) {
  const file = path.join(
    skillDir,
    "run",
    `actas.${safeToken(team)}__${safeToken(agent)}.session`,
  );
  return fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim() : "";
}

function normalizeInstanceId(skillDir, token, injectedPidAlive = pidAlive) {
  if (!token || instancePid(token) !== null) return token;
  const runDir = path.join(skillDir, "run");
  if (!fs.existsSync(runDir)) return token;
  for (const entry of fs.readdirSync(runDir)) {
    if (!entry.startsWith("cc-instance.")) continue;
    const pid = Number(entry.slice("cc-instance.".length));
    if (!injectedPidAlive(pid)) continue;
    const stored = fs.readFileSync(path.join(runDir, entry), "utf8").trim();
    if (stored === token || stored.startsWith(`${token}.`)) return stored;
  }
  return token;
}

function yamlScalar(text, keys) {
  const stack = [];
  for (const rawLine of text.split(/\r?\n/)) {
    if (!rawLine.trim() || rawLine.trimStart().startsWith("#")) continue;
    const match = /^(\s*)([^:#]+):\s*([^#]*?)\s*$/.exec(rawLine);
    if (!match) continue;
    const depth = Math.floor(match[1].length / 2);
    stack.length = depth;
    stack[depth] = match[2].trim();
    if (stack.length === keys.length && stack.every((key, index) => key === keys[index])) {
      return match[3].trim();
    }
  }
  return "";
}

function configInterval(skillDir) {
  const file = path.join(skillDir, "db", "config.yaml");
  if (!fs.existsSync(file)) return 60;
  const text = fs.readFileSync(file, "utf8");
  const raw =
    yamlScalar(text, ["delivery", "turn", "check_interval"]) ||
    yamlScalar(text, ["hook", "check_interval"]);
  return /^\d+$/.test(raw) ? Number(raw) : 60;
}
function watcherAlive(skillDir, instanceId, injectedPidAlive = pidAlive) {
  if (!instanceId) return false;
  const file = path.join(skillDir, "run", `watch.${instanceId}.pid`);
  if (!fs.existsSync(file)) return false;
  return injectedPidAlive(Number(fs.readFileSync(file, "utf8").trim()));
}

function markerFresh(file, intervalSeconds, nowMs) {
  if (!fs.existsSync(file)) return false;
  return nowMs - fs.statSync(file).mtimeMs < intervalSeconds * 1000;
}

function formatBlock(groups) {
  const reason = groups
    .map((group) => {
      let text = `${group.messages.length} new message(s) in ${group.team}:\n`;
      for (const message of group.messages) {
        const body = message.body.replace(/\n/g, "\\n").replace(/\t/g, "\\t");
        text += `  [${message.created_at}] ${message.from}: ${body}\n`;
      }
      return text;
    })
    .join("\n");
  return `${JSON.stringify({ decision: "block", reason }, null, 2)}\n`;
}
function assertIsolatedPaths(skillDir, dbPath, liveSkillDir) {
  if (!liveSkillDir) return;
  const live = path.resolve(liveSkillDir);
  if (path.resolve(skillDir) === live || path.resolve(dbPath).startsWith(`${live}${path.sep}`)) {
    throw new Error("refusing to run fixture against live agmsg paths");
  }
}

function checkInbox(options) {
  const {
    skillDir,
    type,
    project,
    stdin = "",
    interval,
    dbPath = path.join(process.env.AGMSG_STORAGE_PATH || path.join(skillDir, "db"), "messages.db"),
    nowMs = Date.now(),
    pidIsAlive = pidAlive,
    afterSelect,
    liveSkillDir,
  } = options;
  assertIsolatedPaths(skillDir, dbPath, liveSkillDir);
  const { DatabaseSync } = loadSqlite();
  const input = parseInput(stdin);
  if (input.stop_hook_active === true) return { stdout: "", markerTouched: false };

  const rawInstanceId = input.session_id || input.sessionId || process.env.GROK_SESSION_ID || "";
  const instanceId = normalizeInstanceId(skillDir, rawInstanceId, pidIsAlive);
  if (watcherAlive(skillDir, instanceId, pidIsAlive)) {
    return { stdout: "", markerTouched: false };
  }

  const resolved = resolveIdentities({ skillDir, project, type });
  if (resolved.status === "suggest" || resolved.status === "not_joined") {
    return { stdout: "", markerTouched: false };
  }
  const agent = resolved.identities[0] && resolved.identities[0].name;
  if (!agent) return { stdout: "", markerTouched: false };
  const teams = [...new Set(resolved.identities.map((identity) => identity.team))];
  const stopOutput = stopOutputForType(skillDir, type);
  const marker = path.join(skillDir, "run", `.lastcheck-${agent}`);
  const effectiveInterval = interval === undefined ? configInterval(skillDir) : interval;
  if (markerFresh(marker, effectiveInterval, nowMs)) {
    return {
      stdout: emitStatus(stopOutput, "agmsg: check skipped (cooldown)"),
      markerTouched: false,
    };
  }

  fs.mkdirSync(path.dirname(marker), { recursive: true });
  fs.closeSync(fs.openSync(marker, "a"));
  fs.utimesSync(marker, nowMs / 1000, nowMs / 1000);
  if (!fs.existsSync(dbPath)) return { stdout: "", markerTouched: true };

  const db = new DatabaseSync(dbPath);
  db.exec(`PRAGMA busy_timeout=${Number(process.env.AGMSG_BUSY_TIMEOUT || 5000)}`);
  const groups = [];
  try {
    for (const team of teams) {
      const owner = lockOwner(skillDir, team, agent);
      if (owner && owner !== instanceId && instanceAlive(skillDir, owner, pidIsAlive)) continue;
      const rows = db
        .prepare(
          `SELECT id, from_agent AS "from", body, created_at
             FROM messages
            WHERE team = ? AND to_agent = ? AND read_at IS NULL
            ORDER BY created_at ASC`,
        )
        .all(team, agent);
      if (rows.length === 0) continue;
      if (afterSelect) afterSelect({ db, team, agent, rows });
      db.exec("BEGIN IMMEDIATE");
      try {
        const statement = db.prepare(
          "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=? AND read_at IS NULL",
        );
        for (const row of rows) statement.run(row.id);
        db.exec("COMMIT");
      } catch (error) {
        db.exec("ROLLBACK");
        throw error;
      }
      groups.push({ team, messages: rows });
    }
  } finally {
    db.close();
  }

  return {
    stdout:
      groups.length === 0
        ? emitStatus(stopOutput, "agmsg: no new messages")
        : formatBlock(groups),
    markerTouched: true,
  };
}

function main() {
  const [, , type, project] = process.argv;
  if (!type || !project) {
    process.stderr.write("usage: check-inbox.js <type> <project>\n");
    return 64;
  }
  const skillDir = process.env.AGMSG_SKILL_DIR || path.resolve(__dirname, "..");
  loadSqlite(); // Capability probe must happen before stdin or any side effect.
  const stdin = fs.readFileSync(0, "utf8");
  const interval = process.env.AGMSG_CHECK_INTERVAL === undefined
    ? undefined
    : Number(process.env.AGMSG_CHECK_INTERVAL);
  const result = checkInbox({ skillDir, type, project, stdin, interval });
  process.stdout.write(result.stdout);
  process.stderr.write("agmsg: node check-inbox path\n");
  return 0;
}

if (require.main === module) {
  try {
    process.exitCode = main();
  } catch (error) {
    process.stderr.write(`agmsg: node check-inbox failed: ${error.message}\n`);
    process.exitCode = error.exitCode || 1;
  }
}

module.exports = {
  PREFLIGHT_UNAVAILABLE,
  checkInbox,
  instanceAlive,
  markerFresh,
  parseInput,
  watcherAlive,
};
