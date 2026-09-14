"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");
const { checkInbox } = require("../scripts/check-inbox");

const fixtureDir = path.join(__dirname, "fixtures", "check-inbox");
const fixtureFiles = fs.readdirSync(fixtureDir).filter((name) => name.endsWith(".json")).sort();
const liveSkillDir = process.env.AGMSG_LIVE_SKILL_DIR || "C:\\Users\\Matsu\\.agents\\skills\\agmsg";

function encodeToken(value) {
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

function createDb(dbPath, messages) {
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec(`
    CREATE TABLE messages (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      team TEXT NOT NULL,
      from_agent TEXT NOT NULL,
      to_agent TEXT NOT NULL,
      body TEXT NOT NULL,
      created_at TEXT NOT NULL,
      read_at TEXT
    );
  `);
  const insert = db.prepare(
    "INSERT INTO messages(id, team, from_agent, to_agent, body, created_at, read_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
  );
  for (const row of messages) {
    insert.run(row.id, row.team, row.from, row.to, row.body, row.created_at, row.read_at);
  }
  db.close();
}

function writeTeams(skillDir, teams) {
  for (const team of teams) {
    const dir = path.join(skillDir, "teams", team.name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "config.json"), JSON.stringify(team));
  }
}

function writeType(skillDir, type) {
  const dir = path.join(skillDir, "scripts", "drivers", "types", type);
  fs.mkdirSync(dir, { recursive: true });
  const stopOutput = type === "codex" || type === "copilot" ? "json" : "";
  fs.writeFileSync(path.join(dir, "type.conf"), `name=${type}\nstop_output=${stopOutput}\n`);
}

function materializeRun(skillDir, fixture, nowMs) {
  const runDir = path.join(skillDir, "run");
  fs.mkdirSync(runDir, { recursive: true });
  const alivePids = new Set();
  let nextPid = 41000;
  const allocate = (alive) => {
    nextPid += 1;
    if (alive) alivePids.add(nextPid);
    return nextPid;
  };

  if (fixture.run.marker) {
    const file = path.join(runDir, `.lastcheck-${fixture.run.marker.agent}`);
    fs.writeFileSync(file, "");
    const time = (nowMs - fixture.run.marker.ageSeconds * 1000) / 1000;
    fs.utimesSync(file, time, time);
  }

  let normalizedSessionId = fixture.input.sessionId || "";
  for (const lock of fixture.run.locks || []) {
    let owner = lock.owner;
    if (owner.includes("SELFPID")) {
      const pid = allocate(true);
      owner = owner.replace("SELFPID", String(pid));
      normalizedSessionId = owner;
      fs.writeFileSync(path.join(runDir, `cc-instance.${pid}`), owner);
    } else if (lock.alive) {
      const pid = allocate(true);
      fs.writeFileSync(path.join(runDir, `cc-instance.${pid}`), owner);
    }
    const file = path.join(
      runDir,
      `actas.${encodeToken(lock.team)}__${encodeToken(lock.agent)}.session`,
    );
    fs.writeFileSync(file, owner);
  }

  if (fixture.run.watch) {
    const pid = allocate(fixture.run.watch.alive);
    fs.writeFileSync(path.join(runDir, `watch.${fixture.run.watch.instanceId}.pid`), String(pid));
  }
  return {
    normalizedSessionId,
    pidIsAlive: (pid) => alivePids.has(pid),
  };
}

function writeConfig(skillDir, config) {
  if (!config) return;
  const value = config["delivery.turn.check_interval"];
  fs.mkdirSync(path.join(skillDir, "db"), { recursive: true });
  fs.writeFileSync(
    path.join(skillDir, "db", "config.yaml"),
    `# fixture mirrors the installed nested config shape\ndelivery:\n  monitor:\n    poll_interval: 5\n  turn:\n    # cooldown\n    check_interval: ${value}\n`,
  );
}

function semantic(stdout) {
  if (!stdout) return { kind: "silent" };
  const parsed = JSON.parse(stdout);
  if (parsed.systemMessage) return { kind: "status", systemMessage: parsed.systemMessage };
  assert.equal(parsed.decision, "block");
  const teams = [];
  let current = null;
  for (const line of parsed.reason.split("\n")) {
    const header = /^(\d+) new message\(s\) in (.+):$/.exec(line);
    if (header) {
      current = { team: header[2], messages: [] };
      teams.push(current);
      continue;
    }
    const message = /^  \[([^\]]+)\] ([^:]+): (.*)$/.exec(line);
    if (message && current) {
      current.messages.push({
        from: message[2],
        body: message[3].replace(/\\n/g, "\n").replace(/\\t/g, "\t"),
        created_at: message[1],
      });
    }
  }
  return { kind: "block", teams };
}

function readState(dbPath) {
  const db = new DatabaseSync(dbPath);
  const rows = db.prepare("SELECT id, read_at FROM messages ORDER BY id").all();
  db.close();
  return {
    unreadIds: rows.filter((row) => row.read_at === null).map((row) => Number(row.id)),
    readIds: rows.filter((row) => row.read_at !== null).map((row) => Number(row.id)),
  };
}

let passed = 0;
let eligible = 0;
for (const file of fixtureFiles) {
  const fixture = JSON.parse(fs.readFileSync(path.join(fixtureDir, file), "utf8"));
  if (!fixture.runners.includes("node")) continue;
  eligible += 1;
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-check-inbox-"));
  const skillDir = path.join(root, "skill");
  const dbPath = path.join(root, "store", "messages.db");
  const nowMs = Date.now();
  try {
    assert.notEqual(path.resolve(skillDir), path.resolve(liveSkillDir));
    writeTeams(skillDir, fixture.teams);
    writeType(skillDir, fixture.input.type);
    writeConfig(skillDir, fixture.config);
    createDb(dbPath, fixture.messages);
    const runtime = materializeRun(skillDir, fixture, nowMs);
    let stdin = fixture.input.stdin || "";
    if (!stdin && fixture.input.sessionId) {
      stdin = JSON.stringify({ sessionId: fixture.input.sessionId });
    }
    const interval =
      fixture.input.interval === null
        ? 60
        : fixture.input.interval === "config"
          ? undefined
          : fixture.input.interval;
    const injected = fixture.injectDuringRun?.afterSelect || [];
    let injectedOnce = false;
    const result = checkInbox({
      skillDir,
      dbPath,
      liveSkillDir,
      type: fixture.input.type,
      project: fixture.input.project,
      stdin,
      interval,
      nowMs,
      pidIsAlive: runtime.pidIsAlive,
      afterSelect: injected.length
        ? ({ db }) => {
            if (injectedOnce) return;
            injectedOnce = true;
            const insert = db.prepare(
              "INSERT INTO messages(id, team, from_agent, to_agent, body, created_at, read_at) VALUES(?, ?, ?, ?, ?, ?, ?)",
            );
            for (const row of injected) {
              insert.run(row.id, row.team, row.from, row.to, row.body, row.created_at, row.read_at);
            }
          }
        : undefined,
    });
    assert.deepEqual(semantic(result.stdout), fixture.expected.stdoutSemantic, `${file}: stdout`);
    const state = readState(dbPath);
    assert.deepEqual(state.unreadIds, fixture.expected.unreadIds, `${file}: unread ids`);
    assert.deepEqual(state.readIds, fixture.expected.readIds, `${file}: read ids`);
    assert.equal(result.markerTouched, fixture.expected.markerTouched, `${file}: marker`);
    passed += 1;
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

assert.equal(passed, eligible);
process.stdout.write(`check-inbox fixtures: ${passed}/${fixtureFiles.length} PASS\n`);
