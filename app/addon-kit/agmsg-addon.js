// agmsg-addon.js — the one file an agmsg app add-on needs to talk to the app.
// MIT License. No dependencies. Works as an ES module.
//
//   import { connect } from "./agmsg-addon.js";
//   const app = connect({
//     onInit({ team, members, messages }) {},
//     onMessage(message) {},
//   });
//   const args = await app.openArgs();     // { path } / { url } / { base }
//   const tree = await app.fs.list(".");   // needs files:read
//
// Inside the app, the pane hands this frame one MessagePort. Messages are
// pushed over it, and requests (files, git) go back over it; the app decides
// every request against what the user allowed. This file never posts to the
// parent window.
//
// Outside the app (a dev server in a plain browser) no port arrives, and after
// `sampleAfterMs` it serves sample data instead, so the add-on can be built and
// styled without the app. Pass `sample: false` to turn that off.

const PROTOCOL = 1;

export class AddonError extends Error {
  constructor(code, message) {
    super(message || code);
    this.name = "AddonError";
    this.code = code;
  }
}

export function connect(options = {}) {
  const {
    onInit = () => {},
    onMessage = () => {},
    sample = true,
    sampleAfterMs = 1000,
    errorOverlay = true,
  } = options;

  if (errorOverlay) installErrorOverlay();

  let port = null;
  let sampleMode = false;
  let nextId = 1;
  const pending = new Map();
  const waiters = [];

  function ready() {
    if (port || sampleMode) return Promise.resolve();
    return new Promise((resolve) => waiters.push(resolve));
  }
  function wake() {
    while (waiters.length) waiters.shift()();
  }

  function onPortMessage(event) {
    const data = event.data;
    if (!data || data.agmsg !== PROTOCOL) return;
    if (data.type === "init") {
      safe(() => onInit({ team: data.team, members: data.members || [], messages: data.messages || [] }));
    } else if (data.type === "message") {
      safe(() => onMessage(data.message));
    } else if (data.type === "response") {
      const p = pending.get(data.id);
      if (!p) return;
      pending.delete(data.id);
      if (data.ok) p.resolve(data.result);
      else p.reject(new AddonError(data.error?.code || "error", data.error?.message));
    }
  }

  function onWindowMessage(event) {
    // Accept exactly one port, from the pane that hosts this frame.
    if (port || event.source !== window.parent) return;
    const data = event.data;
    if (!data || data.agmsg !== PROTOCOL || data.type !== "port" || !event.ports || !event.ports[0]) return;
    port = event.ports[0];
    port.onmessage = onPortMessage;
    port.start();
    window.removeEventListener("message", onWindowMessage);
    wake();
  }
  window.addEventListener("message", onWindowMessage);

  if (sample) {
    setTimeout(() => {
      if (port) return;
      sampleMode = true;
      window.removeEventListener("message", onWindowMessage);
      console.info("[agmsg-addon] no app found; serving sample data");
      wake();
      safe(() => onInit(SAMPLE.init));
      let i = 0;
      const timer = setInterval(() => {
        if (i >= SAMPLE.live.length) return clearInterval(timer);
        safe(() => onMessage(SAMPLE.live[i++]));
      }, 2500);
    }, sampleAfterMs);
  }

  async function request(op, args = {}) {
    await ready();
    if (sampleMode) return sampleRequest(op, args);
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      port.postMessage({ agmsg: PROTOCOL, type: "request", id, op, args });
    });
  }

  return {
    get inApp() { return port !== null; },
    get sample() { return sampleMode; },
    openArgs: () => request("open.args"),
    fs: {
      stat: (path) => request("fs.stat", { path }),
      list: (path = ".") => request("fs.list", { path }),
      read: (path, range) => request("fs.read", range ? { path, range } : { path }),
    },
    git: {
      status: () => request("git.status"),
      log: (opts = {}) => request("git.log", opts),
      diff: (opts = {}) => request("git.diff", opts),
      show: (rev, path) => request("git.show", { rev, path }),
    },
  };
}

function safe(fn) {
  try {
    const r = fn();
    if (r && typeof r.catch === "function") r.catch(showError);
  } catch (e) {
    showError(e);
  }
}

// ---- error overlay: an add-on never fails as a blank pane ----

let overlay = null;
function installErrorOverlay() {
  window.addEventListener("error", (e) => showError(e.error || e.message));
  window.addEventListener("unhandledrejection", (e) => showError(e.reason));
}
function showError(err) {
  const text = err && err.code ? `${err.code}: ${err.message}` : String((err && err.message) || err);
  console.error("[agmsg-addon]", err);
  if (!document.body) return;
  if (!overlay) {
    overlay = document.createElement("div");
    overlay.setAttribute("role", "alert");
    overlay.style.cssText =
      "position:fixed;left:8px;right:8px;bottom:8px;z-index:2147483647;padding:8px 12px;" +
      "border-radius:6px;background:#2b1520;border:1px solid #5a2a35;color:#f0b6c2;" +
      "font:12px/1.5 system-ui,sans-serif;white-space:pre-wrap;overflow-wrap:anywhere";
    document.body.appendChild(overlay);
  }
  overlay.textContent = `This add-on hit an error: ${text}\nUse ⟳ Reload in the pane header.`;
}

// ---- sample data (outside the app only) ----

const t0 = Date.parse("2026-10-22T09:00:00Z");
const at = (min) => new Date(t0 + min * 60000).toISOString();
const msg = (id, from, to, body, min) => ({ id: String(id), team: "sample-team", from, to, body, created_at: at(min) });

const SAMPLE = {
  init: {
    team: "sample-team",
    members: [
      { name: "you", type: "agmsg-app" },
      { name: "alice", type: "claude-code" },
      { name: "bob", type: "codex" },
    ],
    messages: [
      msg(1, "you", "alice", "Can you look at the failing login test?", 0),
      msg(2, "alice", "you", "On it. It fails only when the session cookie is missing.", 2),
      msg(3, "alice", "bob", "Please review the fix on branch fix-login.", 9),
      msg(4, "bob", "alice", "Looks good. One nit: rename the helper.", 15),
    ],
  },
  live: [
    msg(5, "alice", "bob", "Renamed. Pushed.", 18),
    msg(6, "bob", "you", "CLEARED: fix-login is ready.", 21),
  ],
};

const SAMPLE_FILES = {
  "README.md": "# sample-project\n\nA tiny project for trying add-ons outside the app.\n",
  "src/main.ts": 'import { greet } from "./greet";\n\nconsole.log(greet("agmsg"));\n',
  "src/greet.ts": "export function greet(name: string): string {\n  return `Hello, ${name}!`;\n}\n",
};

function sampleRequest(op, args) {
  const files = Object.keys(SAMPLE_FILES);
  switch (op) {
    case "open.args":
      return { path: "sample-project", base: "main" };
    case "fs.list": {
      const dir = norm(args.path);
      const seen = new Map();
      for (const f of files) {
        if (dir && !f.startsWith(dir + "/")) continue;
        const rest = dir ? f.slice(dir.length + 1) : f;
        const [head, ...tail] = rest.split("/");
        if (!seen.has(head)) {
          seen.set(head, tail.length
            ? { name: head, kind: "dir", size: 0, mtime: at(0) }
            : { name: head, kind: "file", size: SAMPLE_FILES[f].length, mtime: at(0) });
        }
      }
      if (!seen.size && dir) throw new AddonError("not_found", `${args.path} not found`);
      return { entries: [...seen.values()], truncated: false };
    }
    case "fs.stat": {
      const p = norm(args.path);
      if (p === "" || files.some((f) => f.startsWith(p + "/"))) return { name: p || ".", kind: "dir", size: 0, mtime: at(0) };
      if (p in SAMPLE_FILES) return { name: p, kind: "file", size: SAMPLE_FILES[p].length, mtime: at(0) };
      throw new AddonError("not_found", `${args.path} not found`);
    }
    case "fs.read": {
      const p = norm(args.path);
      if (!(p in SAMPLE_FILES)) throw new AddonError("not_found", `${args.path} not found`);
      const full = SAMPLE_FILES[p];
      const r = args.range;
      const text = r ? full.slice(r.offset, r.offset + r.length) : full; // sample files are ASCII
      return { text, size: full.length, eof: !r || r.offset + r.length >= full.length };
    }
    case "git.diff":
      return sampleDiff(args);
    default:
      throw new AddonError("not_available", `${op} has no sample data`);
  }
}

function norm(p = ".") {
  return String(p).replace(/^\.\/?/, "").replace(/\/+$/, "");
}

// git.diff sample, in the DiffResult shape of protocol.d.ts.
function sampleDiff(args) {
  const L = (type, text, oldNo, newNo) => ({ type, text, oldNo, newNo });
  const greet = {
    path: "src/greet.ts", status: "modified", binary: false, additions: 4, deletions: 2,
    hunks: [
      {
        oldStart: 1, oldLines: 5, newStart: 1, newLines: 7, section: "greet",
        lines: [
          L("context", "export function greet(name: string): string {", 1, 1),
          L("del", "  return `Hello, ${name}!`;", 2, null),
          L("add", "  const hello = `Hello, ${name}!`;", null, 2),
          L("add", "  return hello.trim();", null, 3),
          L("context", "}", 3, 4),
          L("context", "", 4, 5),
          L("del", "export const VERSION = 1;", 5, null),
          L("add", "export const VERSION = 2;", null, 6),
          L("add", "export const NAME = \"greet\";", null, 7),
        ],
      },
      {
        oldStart: 20, oldLines: 3, newStart: 22, newLines: 3,
        lines: [
          L("context", "function helper() {", 20, 22),
          L("del", "  return computeTotal(items.length);", 21, null),
          L("add", "  return computeTotal(items.size);", null, 23),
          L("context", "}", 22, 24),
        ],
      },
    ],
  };
  const farewell = {
    path: "src/farewell.ts", status: "added", binary: false, additions: 3, deletions: 0,
    hunks: [{
      oldStart: 0, oldLines: 0, newStart: 1, newLines: 3,
      lines: [
        L("add", "export function farewell(name: string): string {", null, 1),
        L("add", "  return `Goodbye, ${name}.`;", null, 2),
        L("add", "}", null, 3),
      ],
    }],
  };
  const logo = { path: "assets/logo.png", status: "modified", binary: true, additions: 0, deletions: 0, hunks: [] };
  const old = { path: "docs/old.md", status: "deleted", binary: false, additions: 0, deletions: 2,
    hunks: [{ oldStart: 1, oldLines: 2, newStart: 0, newLines: 0,
      lines: [L("del", "# Old notes", 1, null), L("del", "Superseded.", 2, null)] }] };
  let files = [greet, farewell, logo, old];
  if (args && args.path) files = files.filter((f) => f.path === args.path);
  const base = (args && args.base) || "HEAD";
  return {
    base: { rev: base, sha: "9f3e1b0c2a7d4e8f6b5a1c3d2e4f5a6b7c8d9e0f" },
    head: { worktree: true },
    files,
    additions: files.reduce((n, f) => n + f.additions, 0),
    deletions: files.reduce((n, f) => n + f.deletions, 0),
  };
}
