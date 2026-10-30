// The author check (agmsg-addon-check.cjs) must refuse what the app's
// installer refuses, with the same words. The shared corpus is the contract;
// the Rust installer runs the same file (src-tauri/src/addons/install).
import { afterEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const { collect, check, LIMITS } = require("./agmsg-addon-check.cjs");
const corpus = JSON.parse(fs.readFileSync(path.join(here, "fixtures", "install-cases.json"), "utf8"));

const made = [];
afterEach(() => {
  while (made.length) fs.rmSync(made.pop(), { recursive: true, force: true });
});

function tmp() {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "addon-check-"));
  made.push(d);
  return d;
}

function materialize(entries) {
  const root = tmp();
  for (const e of entries) {
    const abs = path.join(root, e.path);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    if (e.type === "file") {
      if (e.size !== undefined) fs.writeFileSync(abs, Buffer.alloc(e.size, 0x61));
      else fs.writeFileSync(abs, e.text || "");
    } else if (e.type === "symlink") fs.symlinkSync(e.target, abs);
    else if (e.type === "hardlink") fs.linkSync(path.join(root, e.of), abs);
    else throw new Error("unsupported fixture entry type " + e.type);
  }
  return root;
}

describe("shared install fixtures", () => {
  for (const c of corpus.cases.filter((c) => !c.archiveOnly)) {
    it(c.name, () => {
      const root = materialize(c.entries);
      const r = collect(root, Object.assign({}, LIMITS, c.limits || {}));
      expect(r.errors.slice().sort()).toEqual(c.expect.errors.slice().sort());
    });
  }
});

// A committed add-on in a fresh git repository, laid out the way the sample is.
function git(root, ...args) {
  execFileSync("git", ["-C", root, ...args], { stdio: "ignore" });
}

function scaffold({ commit = true } = {}) {
  const root = tmp();
  git(root, "init", "-q");
  git(root, "config", "user.email", "t@example.com");
  git(root, "config", "user.name", "t");
  fs.writeFileSync(path.join(root, "agmsg-plugin.conf"), "name = demo\ndescription = A demo.\n");
  fs.mkdirSync(path.join(root, "app-panes/demo/web/assets"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "app-panes/demo/addon.conf"),
    "title = demo\nentry = index.html\nprotocol = 1\npermissions = messages:read\nwhy.messages:read = Shows the timeline.\n",
  );
  fs.writeFileSync(path.join(root, "app-panes/demo/web/index.html"), '<!doctype html><script type="module" src="./assets/a.js"></script>\n');
  fs.writeFileSync(path.join(root, "app-panes/demo/web/assets/a.js"), "console.log(1)\n");
  if (commit) {
    git(root, "add", "-A");
    git(root, "commit", "-qm", "scaffold");
  }
  return root;
}

function edit(root, rel, from, to) {
  const p = path.join(root, rel);
  const s = fs.readFileSync(p, "utf8");
  if (!s.includes(from)) throw new Error("fixture text not found: " + from);
  fs.writeFileSync(p, s.replace(from, to));
}

function commitAll(root, msg) {
  git(root, "add", "-A");
  git(root, "commit", "-qm", msg);
}

function run(root) {
  const lines = [];
  const log = console.log;
  const err = console.error;
  console.log = (...a) => lines.push(a.join(" "));
  console.error = (...a) => lines.push(a.join(" "));
  try {
    return { status: check(root), output: lines.join("\n") };
  } finally {
    console.log = log;
    console.error = err;
  }
}

describe("agmsg-addon-check", () => {
  it("passes a committed add-on", () => {
    const r = run(scaffold());
    expect(r.status).toBe(0);
    expect(r.output).toContain("ok: the app would accept this layout.");
  });

  it("refuses a folder with no app-panes and points at the sample", () => {
    const r = run(tmp());
    expect(r.status).toBe(1);
    expect(r.output).toContain("No app add-on here (no app-panes/ folder). See https://github.com/fujibee/agmsg-addon-sample");
  });

  it("refuses an unknown permission instead of ignoring it", () => {
    const root = scaffold();
    edit(root, "app-panes/demo/addon.conf", "permissions = messages:read\n", "permissions = messages:read, files:write\n");
    const r = run(root);
    expect(r.status).toBe(1);
    expect(r.output).toContain('unknown permission "files:write"');
  });

  it("refuses a symbolic link", () => {
    const root = scaffold();
    fs.symlinkSync("/etc/hosts", path.join(root, "app-panes/demo/web/hosts"));
    commitAll(root, "link");
    const r = run(root);
    expect(r.status).toBe(1);
    expect(r.output).toContain("symbolic link at app-panes/demo/web/hosts");
  });

  it("refuses a web/ that is not committed", () => {
    const r = run(scaffold({ commit: false }));
    expect(r.status).toBe(1);
    expect(r.output).toContain("index.html is not committed");
  });

  it("installs inline handlers but reports them as blocked", () => {
    const root = scaffold();
    fs.writeFileSync(path.join(root, "app-panes/demo/web/index.html"), '<!doctype html><button onclick="go()">x</button>\n');
    commitAll(root, "handler");
    const r = run(root);
    expect(r.status).toBe(1);
    expect(r.output).toContain("blocked: app-panes/demo/web/index.html: inline event handlers");
    expect(r.output).toContain("The app would install this, but 1 thing(s) will be blocked");
  });

  it("requires an origin list with network", () => {
    const root = scaffold();
    edit(root, "app-panes/demo/addon.conf", "permissions = messages:read\n", "permissions = messages:read, network\n");
    const r = run(root);
    expect(r.status).toBe(1);
    expect(r.output).toContain('network is declared but "network = *" or a list of origins is missing');
  });

  it("refuses extra arguments on the command line", () => {
    const { main } = require("./agmsg-addon-check.cjs");
    const err = console.error;
    console.error = () => {};
    try {
      expect(main(["a", "b"])).toBe(2);
      expect(main(["--help"])).toBe(2);
    } finally {
      console.error = err;
    }
  });
});
