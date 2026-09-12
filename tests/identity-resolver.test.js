"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const {
  normalizeProjectPath,
  resolveIdentities,
} = require("../scripts/lib/identity-resolver");

function fixture(configs, run) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-identity-"));
  try {
    for (const config of configs) {
      const dir = path.join(root, "teams", config.name);
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, "config.json"), JSON.stringify(config));
    }
    run(root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test("normalizes Windows, MSYS, separators, drive case, and trailing slash", () => {
  const variants = [
    "E:\\Workspace\\mes-reference-impl\\",
    "e:/Workspace//mes-reference-impl",
    "/E/Workspace/mes-reference-impl/",
  ];
  assert.deepEqual(
    variants.map(normalizeProjectPath),
    Array(variants.length).fill("/e/Workspace/mes-reference-impl"),
  );
});

test("resolves single identity across mixed path forms", () => {
  fixture(
    [{
      name: "mes",
      agents: {
        Codex: { registrations: [{ type: "codex", project: "/e/Workspace/mes-reference-impl" }] },
      },
    }],
    (skillDir) => {
      const result = resolveIdentities({
        skillDir,
        project: "E:\\Workspace\\mes-reference-impl",
        type: "codex",
      });
      assert.equal(result.status, "single");
      assert.deepEqual(result.identities.map(({ team, name }) => ({ team, name })), [
        { team: "mes", name: "Codex" },
      ]);
    },
  );
});

test("reports multiple names and honors explicit team/name", () => {
  fixture(
    [{
      name: "mes",
      agents: {
        A: { type: "codex", project: "/e/project" },
        B: { registrations: [{ type: "codex", project: "E:\\project" }] },
      },
    }],
    (skillDir) => {
      const multiple = resolveIdentities({ skillDir, project: "/e/project", type: "codex" });
      assert.equal(multiple.status, "multiple");
      assert.deepEqual(multiple.identities.map((identity) => identity.name), ["A", "B"]);
      const single = resolveIdentities({
        skillDir,
        project: "/e/project",
        type: "codex",
        team: "mes",
        name: "B",
      });
      assert.equal(single.status, "single");
      assert.equal(single.identities[0].name, "B");
    },
  );
});

test("distinguishes suggest from not_joined", () => {
  fixture(
    [{
      name: "mes",
      agents: {
        Codex: { registrations: [{ type: "codex", project: "/e/other" }] },
      },
    }],
    (skillDir) => {
      assert.equal(
        resolveIdentities({ skillDir, project: "/e/current", type: "codex" }).status,
        "suggest",
      );
      assert.equal(
        resolveIdentities({ skillDir, project: "/e/current", type: "antigravity" }).status,
        "not_joined",
      );
    },
  );
});
