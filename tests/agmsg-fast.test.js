"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { DatabaseSync } = require("node:sqlite");
const { run } = require("../scripts/agmsg-fast");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-fast-"));
const skillDir = path.join(root, "skill");
const dbPath = path.join(root, "store", "messages.db");
fs.mkdirSync(path.join(skillDir, "teams", "mes"), { recursive: true });
fs.writeFileSync(
  path.join(skillDir, "teams", "mes", "config.json"),
  JSON.stringify({
    name: "mes",
    agents: {
      Codex: {
        registrations: [{ type: "codex", project: "E:/repo" }],
      },
      Claude: {
        registrations: [
          { type: "claude-code", project: "E:/one" },
          { type: "claude-code", project: "E:/two" },
        ],
      },
    },
  }),
);

try {
  const whoami = run(["whoami", "e:\\repo", "codex"], { skillDir, dbPath });
  assert.equal(whoami.exitCode, 0);
  assert.equal(whoami.stdout, "agent=Codex teams=mes type=codex project=e:\\repo\n");
  const suggested = run(["whoami", "E:/other", "codex"], { skillDir, dbPath });
  assert.match(suggested.stdout, /^suggest=true agents=Codex teams=mes /);
  const missing = run(["whoami", "E:/other", "unknown"], { skillDir, dbPath });
  assert.equal(missing.stdout, "not_joined=true available_teams=mes\n");

  const team = run(["team", "mes"], { skillDir, dbPath });
  assert.equal(team.exitCode, 0);
  assert.equal(
    team.stdout,
    "Team: mes\n\n" +
      "  Codex (codex) — E:/repo\n" +
      "  Claude (claude-code) — E:/two (+1 more)\n\n" +
      "2 member(s)\n",
  );

  const missingSend = run(["send", "mes", "Claude"], { skillDir, dbPath });
  assert.equal(missingSend.exitCode, 64);
  assert.match(missingSend.stderr, /^usage:/);

  const badFrom = run(["send", "mes", "Typo", "Codex", "lost"], { skillDir, dbPath });
  assert.equal(badFrom.exitCode, 1);
  assert.match(badFrom.stderr, /from agent 'Typo' is not registered/);
  const forced = run(["send", "new-team", "ghost", "nobody", "forced", "--force"], {
    skillDir,
    dbPath,
  });
  assert.equal(forced.exitCode, 0);
  assert.equal(forced.stdout, "Sent to nobody in team new-team\n");

  const first = run(["send", "mes", "Claude", "Codex", "line 1\nline\t2"], {
    skillDir,
    dbPath,
  });
  assert.equal(first.stdout, "Sent to Codex in team mes\n");
  run(["send", "mes", "Codex", "Claude", "reply"], { skillDir, dbPath });

  const before = run(["history", "mes", "Codex", "20"], { skillDir, dbPath });
  assert.match(before.stdout, /^  ● .*Claude → Codex: line 1\\nline\\t2/m);
  assert.match(before.stdout, /^  ● .*Codex → Claude: reply/m);

  const inbox = run(["inbox", "mes", "Codex"], { skillDir, dbPath });
  assert.match(inbox.stdout, /^1 new message\(s\):/);
  assert.match(inbox.stdout, /Claude: line 1\\nline\\t2/);

  const after = run(["history", "mes", "Codex", "20"], { skillDir, dbPath });
  assert.match(after.stdout, /^  ○ .*Claude → Codex:/m);
  assert.match(after.stdout, /^  ● .*Codex → Claude:/m);

  const db = new DatabaseSync(dbPath);
  const unread = db
    .prepare("SELECT COUNT(*) AS count FROM messages WHERE to_agent='Codex' AND read_at IS NULL")
    .get().count;
  db.close();
  assert.equal(unread, 0);

  assert.equal(run(["history", "mes", "", "bad"], { skillDir, dbPath }).exitCode, 0);
  assert.throws(() => run(["team", "../escape"], { skillDir, dbPath }), /invalid team name/);


  process.stdout.write("agmsg-fast tests: PASS\n");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
