#!/usr/bin/env node
"use strict";

const { spawn, spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");
const readline = require("readline");

const SCRIPT_DIR = __dirname;                              // .../scripts/drivers/types/codex (codex siblings live here)
const SKILL_DIR = path.resolve(SCRIPT_DIR, "..", "..", "..", "..");    // skill root
const SCRIPTS_DIR = path.join(SKILL_DIR, "scripts");       // type-independent engine scripts (identities/inbox/send)
const RUN_DIR = path.join(SKILL_DIR, "run");

// Git Bash on Windows cannot exec a .sh path directly — spawnSync of the script
// fails with EFTYPE. Invoke the helper scripts through bash on every platform.
// bash is always present in agmsg's runtime (the bridge is launched from a bash
// context); honour the same overrides delivery.sh's windows_wrap uses.
const BASH_BIN = process.env.GIT_BASH || process.env.AGMSG_BASH || "bash";

// A ceiling on how often watch-once may be re-armed, across every re-arm path
// (a clean deadline, a wake and its turn, an idle transition). watch-once's own
// deadline paces the healthy case at one arm per --timeout, so this is only ever
// felt by a degenerate loop: a stream of DISTINCT wakes re-arms with no delay
// otherwise -- 2094 arms in 56 s measured against the real bridge (#936) -- and
// every arm forks watch-once's library sourcing, which is the fork pressure the
// #906 incident saturated a per-user pid limit with. A rate, not a poll cadence.
const MIN_ARM_INTERVAL_MS = 1000;

function usage() {
  console.log(`Usage: codex-bridge.js --project <path> [--type codex] [--team <team>] [--name <agent>]

Codex app-server bridge for agmsg pseudo-monitoring.

Options:
  --project <path>        Project path to monitor.
  --workspace-root <path> Additional writable root to retain on bridge turns.
                          Repeat for multiple roots.
  --type <agent_type>     Agent type for identity resolution (default: codex).
  --team <team>           Limit wakeups to one team.
  --name <agent>          Limit wakeups to one agent name.
  --timeout <sec>         watch-once timeout before re-arming (default: 300).
  --interval <sec>        watch-once poll interval (default: 2).
  --max-wakes <n>         Stop after n wakeups, useful for tests.
  --stale-wake-limit <n>  Stop after n repeated unchanged wakeups (default: 1).
  --connect-timeout-ms <ms>
                          Max wait for direct app-server connect/upgrade (default: 10000).
  --request-timeout-ms <ms>
                          Max wait for each app-server request (default: 30000).
  --watch-failure-limit <n>
                          Stop after n consecutive watch-once failures; 0 disables (default: 3).
  --app-server <url>      Connect through an existing app-server endpoint.
                          Supports unix://PATH or ws://host:port over WebSocket.
  --thread <id|current|loaded>
                          Resume an existing app-server thread. "current" uses
                          CODEX_THREAD_ID; "loaded" discovers the live TUI thread
                          via thread/loaded/list (codex 0.141+, see #170).
  --loaded-timeout <ms>   Max wait for a loaded thread to appear (default: 30000).
  --turn-timeout <sec>    Idle watchdog: assume a turn ended after this many
                          seconds with no app-server activity for it at all
                          (default: 60; 0 disables). Re-armed on any
                          reasoning/tool-call/message notification, so an
                          actively-working turn is never cut off regardless
                          of total duration — only true silence trips it.
  --inline-inbox          Read inbox in the bridge and include message text in the turn input.
  --resolve-only          Print resolved team/name and exit.
  --print-loaded-threads  Print the app-server's loaded thread ids (one per
                          line) and exit. Needs --app-server. Used by
                          codex-record-session.sh to seat a role without
                          guessing from rollout files (#579).
  --help                  Show this help.

Set AGMSG_CODEX_APP_SERVER_CMD to override the app-server command for tests.`);
}

// EVERY DIAGNOSTIC LINE NAMES THE PROCESS THAT WROTE IT, AND REACHES THE FILE
// IN ONE WRITE.
//
// The launcher appends this process's stderr to a per-identity log
// (`codex-bridge-launcher.sh`: `>>"$log" 2>&1`), and that file has more than
// one writer by construction: the bridge that is running, plus every launch
// attempt that finds it already there, says so, and exits. Two such lines were
// reported spliced mid-word, and other logs were reported losing their line
// beginnings (#784).
//
// This does not claim to prevent that, and it is deliberately not written as
// if it did. What it does:
//
//   ONE WRITE PER LINE. The newline is part of the same `write` as the text,
//   so a line is never split into two writes by this side. Whether two
//   processes' writes can still interleave is a property of the platform's
//   append, not of this code — and the report is from Windows/Git Bash, where
//   that is exactly the open question.
//
//   THE WRITER IS NAMED. A spliced line now carries two pids, and a line that
//   lost its beginning no longer starts with `[<pid>] `. Corruption that
//   cannot be prevented from here can at least stop being invisible: the log
//   is the only evidence for the other reports on that platform, and one that
//   is quietly wrong is worse than one that is obviously wrong.
//
// stdout is deliberately NOT prefixed. `usage()`, the thread-id list and
// `--resolve-only` are read by people and asserted by tests; a prefix there
// would change an interface, not a diagnostic.
//
// THREE THINGS REACH STDERR FROM THIS FILE, and only one of them is a log
// record. Derived by grepping every write rather than by listing the ones that
// came to mind — the first version of this change named only the first and was
// wrong about the other two (raised in review):
//
//   1. DIAGNOSTICS — `console.error`, forty-odd sites. Whole lines, ours.
//      These are the log records: prefixed, one write each.
//   2. CHILD DIAGNOSTICS — the app-server's own stderr, forwarded in whatever
//      chunks it arrives in. Not ours to frame: a chunk is not a line, and
//      buffering it would delay someone's only view of a child that is hanging.
//   3. STREAMED AGENT OUTPUT — `agent/message/delta`, partial BY NAME. There is
//      no newline to wait for; that is what makes it a delta.
//
// 2 and 3 are passed through unchanged and are NOT log records. What they must
// not do is make a log record unreadable, and before this they could: a delta
// that ends mid-word, followed immediately by a diagnostic, produces one
// physical line containing both — the exact shape reported in #784, reachable
// INSIDE ONE PROCESS with no concurrent writer and no platform question.
//
// So everything goes through one funnel that remembers whether the last byte
// was a newline, and a diagnostic starts a fresh line when it was not.
const LOG_PREFIX = `[${process.pid}] `;

let atLineStart = true;

// The funnel. Streamed content passes through byte-for-byte; all it does is
// keep the flag honest.
//
// A BUFFER IS WRITTEN AS A BUFFER. The first version of this decoded every
// chunk with `toString()`, which is wrong at exactly the boundary this code
// exists for: a multi-byte character split across two `data` events decodes to
// a replacement character in each half, and the child's diagnostic arrives
// corrupted — a regression the direct `process.stderr.write(chunk)` it replaced
// did not have (raised in review). "byte-for-byte" has to be true of the code,
// not only of the comment.
//
// The newline flag comes from the last BYTE for a Buffer and the last CHARACTER
// for a string. Those agree: `\n` is 0x0a and is never part of a multi-byte
// UTF-8 sequence.
function writeErr(text) {
  if (text === undefined || text === null || text.length === 0) return;
  // One call, string or Buffer alike: `process.stderr.write` takes both, and
  // keeping it to one is what lets a test assert that nothing writes to stderr
  // outside this function.
  process.stderr.write(text);
  atLineStart = typeof text === "string" ? text.endsWith("\n") : text[text.length - 1] === 0x0a;
}

function logLine(...args) {
  const line = `${LOG_PREFIX}${require("util").format(...args)}\n`;
  // The leading newline is the whole point: without it this diagnostic would
  // continue whatever half-line a delta or a child chunk left open.
  writeErr(atLineStart ? line : `\n${line}`);
}

// Rebound rather than applied at the forty-odd call sites: a helper that has
// to be remembered is one a later line will forget, and the point of this
// change is that EVERY diagnostic carries the pid.
console.error = logLine;

function die(message) {
  console.error(`codex-bridge: ${message}`);
  process.exit(1);
}

// Convert a native Windows path into the MSYS/Git-Bash POSIX form that agmsg
// registration data is keyed by (Git Bash stores e.g. `/c/Users/me/proj`).
// A drive-letter path `C:\...`/`C:/...` becomes `/c/...` and its backslashes
// become forward slashes; a UNC path `\\host\share` becomes `//host/share`.
// Only inputs carrying a Windows drive-letter or UNC prefix are rewritten, so
// an already-POSIX path is returned byte-for-byte unchanged - including a POSIX
// path that legitimately contains a backslash in a filename, which must not be
// mangled on macOS/Linux.
function toPosixPath(p) {
  if (typeof p !== "string" || p.length === 0) return p;
  if (/^\\\\/.test(p)) return p.replace(/\\/g, "/"); // UNC: \\host\share -> //host/share
  const match = /^([A-Za-z]):[\\/]/.exec(p);
  if (!match) return p; // already POSIX (no drive letter): leave exactly as-is
  return `/${match[1].toLowerCase()}${p.slice(2).replace(/\\/g, "/")}`;
}

function parseArgs(argv) {
  const opts = {
    type: "codex",
    timeout: Number(process.env.AGMSG_WATCH_ONCE_TIMEOUT || 300),
    interval: Number(process.env.AGMSG_WATCH_ONCE_INTERVAL || 2),
    maxWakes: 0,
    staleWakeLimit: Number(process.env.AGMSG_CODEX_BRIDGE_STALE_WAKE_LIMIT || 1),
    connectTimeoutMs: Number(process.env.AGMSG_CODEX_BRIDGE_CONNECT_TIMEOUT_MS || 10000),
    requestTimeoutMs: Number(process.env.AGMSG_CODEX_BRIDGE_REQUEST_TIMEOUT_MS || 30000),
    watchFailureLimit: Number(process.env.AGMSG_CODEX_BRIDGE_WATCH_FAILURE_LIMIT || 3),
    inlineInbox: false,
    pairs: [],
    workspaceRoots: [],
    turnTimeout: Number(process.env.AGMSG_CODEX_BRIDGE_TURN_TIMEOUT || 60),
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      opts.help = true;
    } else if (arg === "--resolve-only") {
      opts.resolveOnly = true;
    } else if (arg === "--print-loaded-threads") {
      opts.printLoadedThreads = true;
    } else if (arg === "--project") {
      opts.project = argv[++i];
    } else if (arg === "--workspace-root") {
      opts.workspaceRoots.push(argv[++i]);
    } else if (arg === "--type") {
      opts.type = argv[++i];
    } else if (arg === "--team") {
      opts.team = argv[++i];
    } else if (arg === "--name") {
      opts.name = argv[++i];
    } else if (arg === "--pair") {
      const [team, name] = (argv[++i] || "").split("\t");
      if (!team || !name) die("--pair must be team<TAB>agent");
      opts.pairs.push({ team, name });
    } else if (arg === "--timeout") {
      opts.timeout = Number(argv[++i]);
    } else if (arg === "--interval") {
      opts.interval = Number(argv[++i]);
    } else if (arg === "--max-wakes") {
      opts.maxWakes = Number(argv[++i]);
    } else if (arg === "--stale-wake-limit") {
      opts.staleWakeLimit = Number(argv[++i]);
    } else if (arg === "--connect-timeout-ms") {
      opts.connectTimeoutMs = Number(argv[++i]);
    } else if (arg === "--request-timeout-ms") {
      opts.requestTimeoutMs = Number(argv[++i]);
    } else if (arg === "--watch-failure-limit") {
      opts.watchFailureLimit = Number(argv[++i]);
    } else if (arg === "--turn-timeout") {
      opts.turnTimeout = Number(argv[++i]);
    } else if (arg === "--app-server") {
      opts.appServer = argv[++i];
    } else if (arg === "--thread") {
      opts.threadId = argv[++i];
    } else if (arg === "--loaded-timeout") {
      opts.loadedTimeout = Number(argv[++i]);
    } else if (arg === "--inline-inbox") {
      opts.inlineInbox = true;
    } else {
      die(`unknown option: ${arg}`);
    }
  }

  if (opts.help) return opts;
  // The loaded-thread probe neither watches an inbox nor resolves an identity,
  // so every option below is meaningless to it. --project in particular is the
  // one thing its caller cannot supply usefully: a project is how you find a
  // ROLE, and the probe exists precisely because no role is seated yet.
  if (opts.printLoadedThreads) {
    if (!opts.appServer) die("--print-loaded-threads requires --app-server");
    return opts;
  }
  if (!opts.project) die("--project is required");
  if (opts.workspaceRoots.some((root) => !root)) die("--workspace-root requires a path");
  opts.workspaceRoots = [...new Set([opts.project, ...opts.workspaceRoots])];
  if (!Number.isFinite(opts.timeout) || opts.timeout <= 0) die("--timeout must be a positive number");
  if (!Number.isFinite(opts.interval) || opts.interval <= 0) die("--interval must be a positive number");
  if (!Number.isFinite(opts.maxWakes) || opts.maxWakes < 0) die("--max-wakes must be a non-negative number");
  if (!Number.isFinite(opts.staleWakeLimit) || opts.staleWakeLimit < 0) {
    die("--stale-wake-limit must be a non-negative number");
  }
  if (!Number.isFinite(opts.connectTimeoutMs) || opts.connectTimeoutMs < 0) {
    die("--connect-timeout-ms must be a non-negative number");
  }
  if (!Number.isFinite(opts.requestTimeoutMs) || opts.requestTimeoutMs < 0) {
    die("--request-timeout-ms must be a non-negative number");
  }
  if (!Number.isFinite(opts.watchFailureLimit) || opts.watchFailureLimit < 0) {
    die("--watch-failure-limit must be a non-negative number");
  }
  if (!Number.isFinite(opts.turnTimeout) || opts.turnTimeout < 0) {
    die("--turn-timeout must be a non-negative number");
  }
  if (opts.threadId === "current") {
    opts.threadId = process.env.CODEX_THREAD_ID || "";
    if (!opts.threadId) die("--thread current requires CODEX_THREAD_ID");
  }
  opts.project = path.resolve(opts.project);
  if (!fs.existsSync(opts.project) || !fs.statSync(opts.project).isDirectory()) {
    die(`project path is not a directory: ${opts.project}`);
  }
  return opts;
}

function runScript(script, args) {
  const result = spawnSync(BASH_BIN, [path.join(SCRIPTS_DIR, script), ...args], {
    cwd: SKILL_DIR,
    encoding: "utf8",
  });
  if (result.error) die(`${script} failed: ${result.error.message}`);
  return result;
}

function resolveIdentities(opts) {
  const result = runScript("identities.sh", [toPosixPath(opts.project), opts.type]);
  if (result.status !== 0) {
    die(`identity resolution failed: ${(result.stderr || result.stdout).trim()}`);
  }

  const pairs = result.stdout
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const parts = line.split(/\s+/);
      return { team: parts[0], name: parts[1] };
    })
    .filter((pair) => pair.team && pair.name)
    .filter((pair) => !opts.team || pair.team === opts.team)
    .filter((pair) => !opts.name || pair.name === opts.name)
    .filter((pair) => opts.pairs.length === 0 || opts.pairs.some((wanted) => wanted.team === pair.team && wanted.name === pair.name));

  const deduped = [];
  const seen = new Set();
  for (const pair of pairs) {
    const key = `${pair.team}\t${pair.name}`;
    if (!seen.has(key)) {
      seen.add(key);
      deduped.push(pair);
    }
  }

  if (deduped.length === 0) die("no matching codex identity; run actas or pass --team/--name");
  if (deduped.length > 1) die("multiple identities match; launch one bridge per --pair");
  return deduped;
}

class AppServerClient {
  constructor(command, cwd, opts = {}) {
    this.command = command;
    this.cwd = cwd;
    this.requestTimeoutMs = opts.requestTimeoutMs || 0;
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = new Map();
    this.requestHandlers = new Map();
    this.child = null;
    // Set by CodexBridge to learn about ANY thread-scoped activity, even for
    // methods with no registered handler below -- e.g. reasoning/tool-call
    // progress notifications the bridge doesn't otherwise care about, but
    // which still prove a turn is alive. See onThreadActivity() call site.
    this.onThreadActivity = null;
  }

  start() {
    const [bin, ...args] = this.command;
    this.child = spawn(bin, args, {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.child.on("error", (error) => {
      for (const { reject } of this.pending.values()) {
        reject(error);
      }
      this.pending.clear();
      console.error(`codex-bridge: failed to start app-server: ${error.message}`);
    });

    this.child.on("exit", (code, signal) => {
      for (const { reject } of this.pending.values()) {
        reject(new Error(`app-server exited (${code || signal})`));
      }
      this.pending.clear();
    });

    this.child.stderr.on("data", (chunk) => {
      // Through the funnel so a chunk that does not end in a newline cannot
      // leave the next diagnostic continuing the child's half-line. The Buffer
      // is passed on undecoded: see `writeErr`.
      writeErr(chunk);
    });

    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on("line", (line) => this.handleLine(line));
  }

  on(method, handler) {
    this.handlers.set(method, handler);
  }

  // Register a handler for a REQUEST the app-server sends us (a message with
  // both `method` and `id`, expecting a reply) -- as opposed to `on()`, which
  // only ever sees notifications (no `id`). Approval/elicitation prompts are
  // requests: see dispatchRequest() and #299.
  onRequest(method, handler) {
    this.requestHandlers.set(method, handler);
  }

  handleLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      console.error(`codex-bridge: ignoring non-json app-server line: ${line}`);
      return;
    }

    // A message carrying `method` is always a request or notification FROM
    // the app-server -- check this BEFORE looking at `pending`. Client and
    // server number their own outbound requests independently on this
    // bidirectional connection, so a server-initiated request's `id` can
    // collide with the id of one of OUR still-outstanding requests (e.g. our
    // pending "turn/start" and an incoming approval request both landing on
    // id 4). Checking `pending` first would then wrongly resolve our own
    // request with the approval's params and swallow the approval -- the
    // exact #299 deadlock this fix exists to close. `method` presence is
    // what a JSON-RPC response never has, so it is the correct discriminator.
    if (message.method) {
      // Fires for every thread-scoped notification/request, including the
      // many the bridge has no specific handler for (reasoning deltas, tool
      // -call/command-output progress, etc.) -- unlike the handlers Map
      // below, which silently drops anything it has no registered method
      // for. This is the ONLY generic signal that a turn is still doing
      // something; without it, a turn that spends most of its time in
      // exactly those unhandled notification types looks idle to the turn
      // watchdog even while it is actively working. See onThreadActivity().
      if (this.onThreadActivity && message.params && message.params.threadId) {
        this.onThreadActivity(message.params.threadId);
      }
      if (Object.prototype.hasOwnProperty.call(message, "id")) {
        this.dispatchRequest(message.id, message.method, message.params || {});
      } else if (this.handlers.has(message.method)) {
        this.dispatch(message.method, message.params || {});
      }
      return;
    }

    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        const rpcError = new Error(message.error.message || JSON.stringify(message.error));
        // Carry the JSON-RPC error code through, not just its text. ensureThread
        // decides on the message ("already has an active writer"), so the code is
        // not what gates that today; it is kept for diagnostics and any future
        // caller that wants the numeric reason without parsing the text (#906).
        if (typeof message.error.code === "number") rpcError.code = message.error.code;
        pending.reject(rpcError);
      } else {
        pending.resolve(message.result);
      }
    }
  }

  dispatchRequest(id, method, params) {
    const handler = this.requestHandlers.get(method);
    if (!handler) {
      console.error(`codex-bridge: no handler for app-server request '${method}'; replying with method-not-found`);
      this.respondError(id, -32601, `Method not found: ${method}`);
      return;
    }
    Promise.resolve()
      .then(() => handler(params))
      .then((result) => this.respond(id, result === undefined ? null : result))
      .catch((error) => {
        console.error(`codex-bridge: ${method} request handler failed: ${error.message}`);
        this.respondError(id, -32000, error.message || String(error));
      });
  }

  respond(id, result) {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
  }

  respondError(id, code, message) {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
  }

  request(method, params) {
    const id = this.nextId++;
    const payload = { jsonrpc: "2.0", id, method, params };
    return new Promise((resolve, reject) => {
      let timer = null;
      const clear = () => {
        if (timer) {
          clearTimeout(timer);
          timer = null;
        }
      };
      const pending = {
        resolve: (value) => {
          clear();
          resolve(value);
        },
        reject: (error) => {
          clear();
          reject(error);
        },
      };
      if (this.requestTimeoutMs > 0) {
        timer = setTimeout(() => {
          if (!this.pending.delete(id)) return;
          reject(new Error(`app-server request '${method}' timed out after ${this.requestTimeoutMs}ms`));
        }, this.requestTimeoutMs);
        if (timer.unref) timer.unref();
      }
      this.pending.set(id, pending);
      this.child.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
        if (error) {
          this.pending.delete(id);
          pending.reject(error);
        }
      });
    });
  }

  notify(method, params = {}) {
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
  }

  dispatch(method, params) {
    try {
      Promise.resolve(this.handlers.get(method)(params)).catch((error) => {
        console.error(`codex-bridge: ${method} handler failed: ${error.message}`);
      });
    } catch (error) {
      console.error(`codex-bridge: ${method} handler failed: ${error.message}`);
    }
  }

  stop() {
    if (this.child && !this.child.killed) {
      this.child.kill("SIGTERM");
    }
  }
}

// WebSocket app-server client. The handshake and framing are transport-agnostic;
// only the connection target differs: a unix socket path ({ path }) for
// `--app-server unix://…`, or a TCP host/port ({ host, port }) for
// `--app-server ws://host:port` (codex 0.141+ accepts only ws:// for `--remote`,
// see #170).
class WebSocketAppServerClient {
  constructor(connectOptions, label, opts = {}) {
    this.connectOptions = connectOptions;
    this.label = label || "app-server";
    this.connectTimeoutMs = opts.connectTimeoutMs || 0;
    this.requestTimeoutMs = opts.requestTimeoutMs || 0;
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = new Map();
    this.requestHandlers = new Map();
    // Set by CodexBridge to learn about ANY thread-scoped activity, even for
    // methods with no registered handler below. See the identical property
    // and its call site in AppServerClient.handleLine().
    this.onThreadActivity = null;
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.connected = false;
    this.handshakeComplete = false;
    this.handshakeBuffer = Buffer.alloc(0);
    this.startPromise = null;
    // Set when WE close the socket (shutdown); distinguishes an intentional stop
    // from the app-server going away under us.
    this.intentionalStop = false;
  }

  start() {
    this.startPromise = new Promise((resolve, reject) => {
      let settled = false;
      let timer = null;
      const finish = (error) => {
        if (settled) return;
        settled = true;
        if (timer) {
          clearTimeout(timer);
          timer = null;
        }
        if (error) {
          reject(error);
        } else {
          resolve();
        }
      };
      const key = crypto.randomBytes(16).toString("base64");
      this.expectedAccept = crypto
        .createHash("sha1")
        .update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
        .digest("base64");

      if (this.connectTimeoutMs > 0) {
        timer = setTimeout(() => {
          const error = new Error(
            `app-server websocket handshake timed out after ${this.connectTimeoutMs}ms (${this.label})`,
          );
          this.rejectAll(error);
          finish(error);
          this.stop();
        }, this.connectTimeoutMs);
        if (timer.unref) timer.unref();
      }

      this.socket = net.createConnection(this.connectOptions);
      this.socket.on("connect", () => {
        this.socket.write(
          [
            "GET / HTTP/1.1",
            "Host: localhost",
            "Upgrade: websocket",
            "Connection: Upgrade",
            `Sec-WebSocket-Key: ${key}`,
            "Sec-WebSocket-Version: 13",
            "",
            "",
          ].join("\r\n"),
        );
      });
      this.socket.on("data", (chunk) => this.handleData(chunk, () => finish(), finish));
      this.socket.on("error", (error) => {
        this.rejectAll(error);
        finish(error);
      });
      this.socket.on("close", () => {
        const error = new Error(`app-server connection closed (${this.label})`);
        this.rejectAll(error);
        if (!this.handshakeComplete) {
          finish(error);
          return;
        }
        // The app-server went away after we were connected (e.g. it was killed
        // and recreated on a codex upgrade). A bridge that lingers here keeps a
        // live pidfile, so the launcher reuses this now-dead bridge and never
        // starts a fresh one against the new app-server — delivery silently
        // stops. Exit instead; the launcher then relaunches a fresh bridge bound
        // to the current app-server. Skipped when WE closed the socket.
        if (!this.intentionalStop) {
          console.error(`codex-bridge: ${error.message}; exiting so a fresh bridge can attach`);
          process.exit(1);
        }
      });
    });
  }

  async ready() {
    if (this.startPromise) await this.startPromise;
  }

  on(method, handler) {
    this.handlers.set(method, handler);
  }

  // Register a handler for a REQUEST the app-server sends us (a message with
  // both `method` and `id`, expecting a reply) -- as opposed to `on()`, which
  // only ever sees notifications (no `id`). Approval/elicitation prompts are
  // requests: see dispatchRequest() and #299.
  onRequest(method, handler) {
    this.requestHandlers.set(method, handler);
  }

  handleData(chunk, resolveStart, rejectStart) {
    if (!this.handshakeComplete) {
      this.handshakeBuffer = Buffer.concat([this.handshakeBuffer, chunk]);
      const headerEnd = this.handshakeBuffer.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;
      const header = this.handshakeBuffer.slice(0, headerEnd).toString("utf8");
      const rest = this.handshakeBuffer.slice(headerEnd + 4);
      this.handshakeBuffer = Buffer.alloc(0);
      try {
        this.validateHandshake(header);
      } catch (error) {
        rejectStart(error);
        this.stop();
        return;
      }
      this.handshakeComplete = true;
      this.connected = true;
      resolveStart();
      if (rest.length > 0) this.handleWebSocketBytes(rest);
      return;
    }
    this.handleWebSocketBytes(chunk);
  }

  validateHandshake(header) {
    const lines = header.split(/\r\n/);
    if (!/^HTTP\/1\.1 101\b/.test(lines[0] || "")) {
      throw new Error(`app-server websocket upgrade failed: ${lines[0] || "no status"}`);
    }
    const headers = new Map();
    for (const line of lines.slice(1)) {
      const index = line.indexOf(":");
      if (index === -1) continue;
      headers.set(line.slice(0, index).toLowerCase(), line.slice(index + 1).trim());
    }
    if (headers.get("sec-websocket-accept") !== this.expectedAccept) {
      throw new Error("app-server websocket upgrade returned an invalid accept key");
    }
  }

  handleWebSocketBytes(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < offset + 2) return;
        length = this.buffer.readUInt16BE(offset);
        offset += 2;
      } else if (length === 127) {
        if (this.buffer.length < offset + 8) return;
        const high = this.buffer.readUInt32BE(offset);
        const low = this.buffer.readUInt32BE(offset + 4);
        if (high !== 0) {
          this.stop();
          this.rejectAll(new Error("app-server websocket frame is too large"));
          return;
        }
        length = low;
        offset += 8;
      }
      const maskOffset = offset;
      if (masked) offset += 4;
      if (this.buffer.length < offset + length) return;

      let payload = this.buffer.slice(offset, offset + length);
      if (masked) {
        const mask = this.buffer.slice(maskOffset, maskOffset + 4);
        payload = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
      }
      this.buffer = this.buffer.slice(offset + length);

      if (opcode === 0x1) {
        this.handleLine(payload.toString("utf8"));
      } else if (opcode === 0x8) {
        this.stop();
        return;
      } else if (opcode === 0x9) {
        this.sendFrame(0x0a, payload);
      }
    }
  }

  handleLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch (_) {
      console.error(`codex-bridge: ignoring non-json app-server message: ${line}`);
      return;
    }
    // A message carrying `method` is always a request or notification FROM
    // the app-server -- check this BEFORE looking at `pending`. Client and
    // server number their own outbound requests independently on this
    // bidirectional connection, so a server-initiated request's `id` can
    // collide with the id of one of OUR still-outstanding requests. Checking
    // `pending` first would then wrongly resolve our own request with the
    // approval's params and swallow the approval -- the exact #299 deadlock
    // this fix exists to close. `method` presence is what a JSON-RPC response
    // never has, so it is the correct discriminator.
    if (message.method) {
      // Fires for every thread-scoped notification/request, including the
      // many the bridge has no specific handler for (reasoning deltas, tool
      // -call/command-output progress, etc.) -- unlike the handlers Map
      // below, which silently drops anything it has no registered method
      // for. This is the ONLY generic signal that a turn is still doing
      // something; without it, a turn that spends most of its time in
      // exactly those unhandled notification types looks idle to the turn
      // watchdog even while it is actively working. See onThreadActivity().
      if (this.onThreadActivity && message.params && message.params.threadId) {
        this.onThreadActivity(message.params.threadId);
      }
      if (Object.prototype.hasOwnProperty.call(message, "id")) {
        this.dispatchRequest(message.id, message.method, message.params || {});
      } else if (this.handlers.has(message.method)) {
        this.dispatch(message.method, message.params || {});
      }
      return;
    }

    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        const rpcError = new Error(message.error.message || JSON.stringify(message.error));
        // Carry the JSON-RPC error code through, not just its text. ensureThread
        // decides on the message ("already has an active writer"), so the code is
        // not what gates that today; it is kept for diagnostics and any future
        // caller that wants the numeric reason without parsing the text (#906).
        if (typeof message.error.code === "number") rpcError.code = message.error.code;
        pending.reject(rpcError);
      } else {
        pending.resolve(message.result);
      }
    }
  }

  dispatchRequest(id, method, params) {
    const handler = this.requestHandlers.get(method);
    if (!handler) {
      console.error(`codex-bridge: no handler for app-server request '${method}'; replying with method-not-found`);
      this.respondError(id, -32601, `Method not found: ${method}`);
      return;
    }
    Promise.resolve()
      .then(() => handler(params))
      .then((result) => this.respond(id, result === undefined ? null : result))
      .catch((error) => {
        console.error(`codex-bridge: ${method} request handler failed: ${error.message}`);
        this.respondError(id, -32000, error.message || String(error));
      });
  }

  respond(id, result) {
    this.sendJson({ jsonrpc: "2.0", id, result });
  }

  respondError(id, code, message) {
    this.sendJson({ jsonrpc: "2.0", id, error: { code, message } });
  }

  request(method, params) {
    const id = this.nextId++;
    const payload = { jsonrpc: "2.0", id, method, params };
    return new Promise((resolve, reject) => {
      let timer = null;
      const clear = () => {
        if (timer) {
          clearTimeout(timer);
          timer = null;
        }
      };
      const pending = {
        resolve: (value) => {
          clear();
          resolve(value);
        },
        reject: (error) => {
          clear();
          reject(error);
        },
      };
      if (this.requestTimeoutMs > 0) {
        timer = setTimeout(() => {
          if (!this.pending.delete(id)) return;
          reject(new Error(`app-server request '${method}' timed out after ${this.requestTimeoutMs}ms`));
        }, this.requestTimeoutMs);
        if (timer.unref) timer.unref();
      }
      this.pending.set(id, pending);
      this.sendJson(payload, (error) => {
        if (error) {
          this.pending.delete(id);
          pending.reject(error);
        }
      });
    });
  }

  notify(method, params = {}) {
    this.sendJson({ jsonrpc: "2.0", method, params });
  }

  dispatch(method, params) {
    try {
      Promise.resolve(this.handlers.get(method)(params)).catch((error) => {
        console.error(`codex-bridge: ${method} handler failed: ${error.message}`);
      });
    } catch (error) {
      console.error(`codex-bridge: ${method} handler failed: ${error.message}`);
    }
  }

  sendJson(value, callback = () => {}) {
    if (!this.connected) {
      callback(new Error("app-server websocket is not connected"));
      return;
    }
    this.sendFrame(0x1, Buffer.from(JSON.stringify(value), "utf8"), callback);
  }

  sendFrame(opcode, payload, callback = () => {}) {
    const length = payload.length;
    let headerLength = 2;
    if (length >= 126 && length <= 0xffff) headerLength += 2;
    if (length > 0xffff) headerLength += 8;
    const mask = crypto.randomBytes(4);
    const frame = Buffer.alloc(headerLength + 4 + length);
    frame[0] = 0x80 | opcode;
    if (length < 126) {
      frame[1] = 0x80 | length;
    } else if (length <= 0xffff) {
      frame[1] = 0x80 | 126;
      frame.writeUInt16BE(length, 2);
    } else {
      frame[1] = 0x80 | 127;
      frame.writeUInt32BE(0, 2);
      frame.writeUInt32BE(length, 6);
    }
    mask.copy(frame, headerLength);
    for (let i = 0; i < length; i += 1) {
      frame[headerLength + 4 + i] = payload[i] ^ mask[i % 4];
    }
    this.socket.write(frame, callback);
  }

  rejectAll(error) {
    for (const { reject } of this.pending.values()) {
      reject(error);
    }
    this.pending.clear();
  }

  stop() {
    this.intentionalStop = true;
    this.connected = false;
    if (this.socket && !this.socket.destroyed) {
      this.socket.destroy();
    }
  }
}

class CodexBridge {
  constructor(opts, identities) {
    this.opts = opts;
    this.identities = identities;
    this.identity = identities[0];
    this.client = createAppServerClient(opts);
    this.threadId = opts.threadId || null;
    this.threadIdle = true;
    this.turnActive = false;
    this.turnTimer = null;
    this.pendingWake = false;
    this.watchHandle = null;
    this.wakeCount = 0;
    this.lastWakeMaxId = "";
    this.staleWakeCount = 0;
    this.watchFailureCount = 0;
    this.watchRearmTimer = null;
    this.lastArmAt = 0;
    this.inlineInboxText = "";
    this.stopping = false;
    const key = identities.length === 1
      ? `${identities[0].team}.${identities[0].name}`
      : crypto.createHash("sha1").update(identities.map((p) => `${p.team}\t${p.name}`).join("\n")).digest("hex");
    this.pidfile = path.join(RUN_DIR, `codex-bridge.${key}.pid`);
    this.metafile = path.join(RUN_DIR, `codex-bridge.${key}.meta`);
    // A per-PID identity lease the launcher reaper reads to tell an orphan of THIS
    // (project, role) from any other bridge, without reconstructing argv from ps
    // (#943). Keyed by pid so duplicates are each enumerable; content is hashes,
    // so no raw project/role value with a separator can be misread.
    this.leasefile = path.join(RUN_DIR, `codex-bridge-lease.${process.pid}`);
    this.leaseStart = "";
    this.leaseStartSrc = "";
  }

  async run() {
    fs.mkdirSync(RUN_DIR, { recursive: true });
    this.ensureSingleInstance();
    this.writeMeta();
    this.installSignals();
    // Any thread-scoped app-server activity for OUR active turn re-arms the
    // idle watchdog -- reasoning, tool-call/command progress, agent-message
    // deltas, all of it, not just one specific notification type. See
    // startTurnWatchdog()'s comment for why a fixed-from-start ceiling was
    // wrong here.
    this.client.onThreadActivity = (threadId) => {
      if (threadId === this.threadId && this.turnActive) this.startTurnWatchdog();
    };
    this.client.on("process/exited", this.clientHandler("process/exited", (params) => this.onProcessExited(params)));
    this.client.on("error", this.clientHandler("error", (params) => this.onServerError(params)));
    this.client.on("item/agentMessage/delta", this.clientHandler("item/agentMessage/delta", (params) => this.onAgentMessageDelta(params)));
    this.client.on("thread/status/changed", this.clientHandler("thread/status/changed", (params) => this.onThreadStatus(params)));
    this.client.on("turn/started", this.clientHandler("turn/started", () => {
      this.turnActive = true;
      this.threadIdle = false;
      // This turn was not started by tryStartTurn() -- e.g. a TUI-driven turn
      // on a thread the bridge shares -- so nothing else will arm a watchdog
      // for it. Without one, a turn that never reports completion (the app
      // -server does not reliably send turn/completed, see #41) leaves
      // turnActive stuck true and every later wake deferred forever. See #299.
      this.startTurnWatchdog();
    }));
    this.client.on("turn/completed", this.clientHandler("turn/completed", (params) => this.onTurnCompleted(params)));
    this.client.on("turn/failed", this.clientHandler("turn/failed", () => this.onTurnCompleted()));

    // A headless bridge must never leave a prompt only a human can answer
    // unanswered -- an unanswered approval/elicitation request wedges the
    // thread in "waitingOnApproval" forever, with no watchdog able to save it
    // (see #299). Auto-decline everything: a denied command/patch/permission
    // still lets the turn finish normally instead of hanging.
    this.client.onRequest("item/commandExecution/requestApproval", () => this.denyApproval());
    this.client.onRequest("item/fileChange/requestApproval", () => this.denyApproval());
    this.client.onRequest("item/permissions/requestApproval", () => this.denyPermissions());
    this.client.onRequest("mcpServer/elicitation/request", () => this.denyElicitation());
    // Legacy (pre-v2) app-server protocol names, kept as a safety net.
    this.client.onRequest("execCommandApproval", () => this.denyLegacyApproval());
    this.client.onRequest("applyPatchApproval", () => this.denyLegacyApproval());

    this.client.start();
    await this.client.ready?.();
    await this.initialize();
    await this.ensureThread();
    await this.armWatch();
    // After armWatch, not before: the seat is a claim that this role is being
    // delivered to, and until the watch is armed that is not yet true.
    this.recordSeat();
  }

  // Write the seat from the thread the bridge actually armed on (#579). Seating
  // before this point can only ever be inference -- the app-server is the one
  // that knows which thread this session got, and it does not know it until the
  // resume above succeeded. So whatever seeded the seat earlier, the value it
  // guessed is replaced here by one the app-server confirmed.
  //
  // Best-effort by design: a failure to record costs the NEXT session a resume,
  // not this one, which is already armed and delivering. Never let it take the
  // bridge down.
  recordSeat() {
    if (!this.threadId || this.threadId === "loaded") return;
    for (const pair of this.identities) {
      try {
        spawnSync(BASH_BIN, [
          path.join(SCRIPT_DIR, "codex-record-session.sh"),
          pair.team, pair.name, toPosixPath(this.opts.project),
        ], { cwd: SKILL_DIR, encoding: "utf8", env: { ...process.env, CODEX_THREAD_ID: this.threadId } });
      } catch (error) {
        console.error(`codex-bridge: could not record seat for ${pair.team}/${pair.name}: ${error.message}`);
      }
    }
  }

  clientHandler(method, handler) {
    return (params) => {
      try {
        Promise.resolve(handler(params)).catch((error) => this.failClientHandler(method, error));
      } catch (error) {
        this.failClientHandler(method, error);
      }
    };
  }

  failClientHandler(method, error) {
    console.error(`codex-bridge: ${method} handler failed: ${error.message}`);
    this.shutdown().finally(() => process.exit(1));
  }

  writeMeta() {
    fs.writeFileSync(this.pidfile, `${process.pid}\n`);
    fs.writeFileSync(
      this.metafile,
      [
        `pid=${process.pid}`,
        `project=${this.opts.project}`,
        `identities=${this.identities.map((p) => `${p.team}/${p.name}`).join(",")}`,
        `type=${this.opts.type}`,
      ].join("\n") + "\n",
    );
    this.writeLease();
  }

  // The reaper's authority. It is published atomically (temp + rename) so a
  // reader never sees a half-written file, and BEFORE any thread/network work,
  // so a bridge is reapable the instant it exists. project and pairs are stored
  // as SHA-1 hashes -- the launcher hashes its own PROJECT and sorted pair set
  // the same way and compares hex, so no separator inside a project path or role
  // can make one identity read as another (the whole class of bugs argv parsing
  // hit). host and the process start time are what let the reaper reject a
  // recycled pid or another machine before it kills anything.
  // This process's start token, at the best precision the platform offers and by
  // the SAME method _reap_orphan_bridges (codex-bridge-launcher.sh) recomputes it
  // for a live pid, so the two agree:
  //   Linux -> /proc/<pid>/stat field 22 (starttime in clock ticks): lossless, so
  //            a recycled pid is always distinguishable from the one we leased.
  //   else  -> `ps -o lstart=` (second precision): a pid reused within the SAME
  //            second is the documented residual on such platforms; no external
  //            observer can do better there (etime/mtime are second-grained too),
  //            and the only victim would be a same-(project,pair) bridge in the
  //            sub-ms window before it overwrites this pid's lease, self-corrected
  //            by the launcher respawning it.
  //   win32 -> Process.StartTime.Ticks, read through PowerShell. Windows has NO
  //            /proc, and the only `ps` likely to be on PATH there is MSYS's,
  //            which rejects -o outright ("ps: unknown option -- o") rather than
  //            degrading -- so BOTH POSIX sources above yield an empty token and
  //            writeLease() throws, which is why the bridge could never start on
  //            Windows at all.
  //            ★ONE source, deliberately, not a preference list. WMIC's
  //            CreationDate is ~2x cheaper and was the obvious first pick, but it
  //            is deprecated and already absent from Windows 11 installs that
  //            have dropped the Feature-on-Demand. A per-side "WMIC, else
  //            PowerShell" order would then let THIS writer and _start_token
  //            (codex-bridge-launcher.sh) resolve DIFFERENT sources for the SAME
  //            process whenever only one of the two can reach wmic.exe -- their
  //            tokens differ by FORMAT, so the reaper would read a live bridge's
  //            lease as some other process's and never collect the orphan it
  //            exists to collect. Ticks is the one value both sides can always
  //            agree on, so the speed is not worth the divergence.
  //            Falling back from powershell.exe to pwsh is safe for the same
  //            reason it is safe here and nowhere else: both return the SAME
  //            Ticks for a given pid (measured), so the src label names the
  //            format, not the executable that produced it.
  startToken() {
    if (process.platform === "win32") {
      for (const bin of ["powershell.exe", "pwsh"]) {
        const r = spawnSync(
          bin,
          [
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            `(Get-Process -Id ${process.pid}).StartTime.Ticks`,
          ],
          { encoding: "utf8" },
        );
        const ticks = (r.status === 0 ? (r.stdout || "") : "").trim();
        if (/^\d+$/.test(ticks)) return { src: "pwsh", token: ticks };
      }
      return { src: "pwsh", token: "" };
    }
    try {
      const stat = fs.readFileSync(`/proc/${process.pid}/stat`, "utf8");
      const after = stat.slice(stat.lastIndexOf(")") + 1).trim().split(/\s+/);
      const ticks = after[19];
      if (/^\d+$/.test(ticks || "")) return { src: "proc", token: ticks };
    } catch (_) { /* no /proc (macOS/BSD) or unreadable */ }
    const ps = spawnSync("ps", ["-o", "lstart=", "-p", String(process.pid)], { encoding: "utf8" });
    const token = (ps.status === 0 ? (ps.stdout || "") : "").trim();
    return { src: "ps", token };
  }

  writeLease() {
    const { src, token } = this.startToken();
    // Fail CLOSED at the source. A bridge that cannot publish a well-formed,
    // enumerable lease must not go on to arm its network/thread -- that is exactly
    // the authority-less orphan #906 is about. Each failure below throws, and run()
    // publishes the lease before client.start(), so the throw aborts startup rather
    // than leaving a live-but-unreapable bridge.
    if (!token) throw new Error("cannot determine process start token for identity lease");
    const host = os.hostname();
    if (!host) throw new Error("cannot determine hostname for identity lease");
    const projectHash = crypto.createHash("sha1").update(this.opts.project).digest("hex");
    // Canonicalize the pair SET before hashing: hash each "team\tname" pair, then
    // sort the hex hashes (pure ASCII, so a byte sort in the launcher and a JS
    // code-unit sort here agree even for non-ASCII names) and hash the joined
    // list. codex-bridge-launcher.sh computes BRIDGE_PAIRS_HASH identically.
    const pairsHash = crypto.createHash("sha1")
      .update(
        this.identities
          .map((pair) => crypto.createHash("sha1").update(`${pair.team}\t${pair.name}`).digest("hex"))
          .sort()
          .join("\n"),
      )
      .digest("hex");
    this.leaseStart = token;
    this.leaseStartSrc = src;
    const body = [
      "v=1",
      `project=${projectHash}`,
      `pairs=${pairsHash}`,
      `host=${host}`,
      `pid=${process.pid}`,
      `start=${token}`,
      `startsrc=${src}`,
    ].join("\n") + "\n";
    const tmp = `${this.leasefile}.tmp`;
    // writeFileSync / renameSync throw on failure -> fatal, by design (see above).
    // rename is atomic, so a reader never sees a half-written lease.
    fs.writeFileSync(tmp, body, { mode: 0o600 });
    fs.renameSync(tmp, this.leasefile);
  }

  // Remove only OUR lease: read it back and unlink only when both the pid and the
  // start token still name this process, so a lease a recycled pid's new owner
  // may have written to the same path is never deleted from under it.
  cleanupLease() {
    try {
      if (!fs.existsSync(this.leasefile)) return;
      const text = fs.readFileSync(this.leasefile, "utf8");
      const pid = (text.match(/^pid=(.*)$/mu) || [])[1];
      const start = (text.match(/^start=(.*)$/mu) || [])[1];
      if (pid === String(process.pid) && start === this.leaseStart) {
        fs.unlinkSync(this.leasefile);
      }
    } catch (_) { /* best effort */ }
  }

  installSignals() {
    const stop = () => {
      this.shutdown().finally(() => process.exit(0));
    };
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    process.on("exit", () => {
      this.client.stop();
      this.cleanupMeta();
      this.cleanupLease();
    });
  }

  async initialize() {
    await this.client.request("initialize", {
      clientInfo: {
        name: "agmsg-codex-bridge",
        title: "agmsg Codex bridge",
        version: readVersion(),
      },
      capabilities: {
        experimentalApi: true,
        requestAttestation: false,
        optOutNotificationMethods: [],
      },
    });
    this.client.notify("initialized");
  }

  async resolveLoadedThread() {
    // codex 0.141+ does not export CODEX_THREAD_ID to hooks and writes no rollout
    // for --remote sessions, so the thread id cannot be resolved out-of-band.
    // Ask the app-server which thread the live TUI has loaded instead. See #170.
    const deadline = Date.now() + (this.opts.loadedTimeout || 30000);
    for (;;) {
      const response = await this.client.request("thread/loaded/list", {});
      const ids = response && Array.isArray(response.data) ? response.data : [];
      if (ids.length > 0) {
        if (ids.length > 1) {
          console.error(
            `codex-bridge: ${ids.length} threads loaded; attaching to the first (${ids[0]})`,
          );
        }
        return ids[0];
      }
      if (Date.now() >= deadline) {
        die("no loaded codex thread found via thread/loaded/list");
      }
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }

  async ensureThread() {
    if (this.threadId === "loaded") {
      this.threadId = await this.resolveLoadedThread();
      console.error(`codex-bridge: discovered loaded thread ${this.threadId}`);
    }
    if (this.threadId) {
      let response;
      try {
        response = await this.client.request("thread/resume", {
          threadId: this.threadId,
          cwd: this.opts.project,
          runtimeWorkspaceRoots: this.opts.workspaceRoots,
          excludeTurns: true,
        });
      } catch (err) {
        // Codex 0.142+'s --remote sessions may not create a rollout, which
        // makes the thread/resume request itself fail outright. turn/start
        // only needs threadId, so keep the bridge alive by falling back to
        // the idle state instead of dying. This catch covers only the
        // request -- the "did not return the requested thread id" check
        // below is a distinct failure (a resume that succeeded but returned
        // the wrong thread) and should still die() as before, not be
        // silently swallowed by this fallback.
        // Two failures reach this catch and they need opposite handling. The
        // benign one below -- a Codex 0.142+ --remote session that never created
        // a rollout -- is what it was written for: turn/start needs only the
        // threadId, so the bridge stays alive idle.
        //
        // "already has an active writer" is the other, and it is deterministic:
        // another writer -- a co-resident Codex Desktop, or a second bridge --
        // owns this thread, and resume cannot succeed while that holds. A bridge
        // that proceeds anyway still arms watchers and holds ~10 threads, so
        // duplicates accumulate until a per-user pid limit is saturated (#906).
        // Match the message, not the JSON-RPC code alone (-32600 is the generic
        // "invalid request", carried here now for diagnostics): the message is
        // the condition, and a rewording that kept the code would not be this.
        // Exit non-zero so a bridge that cannot own its thread does not linger.
        if (/already has an active writer/iu.test(err && err.message ? err.message : "")) {
          die(`thread/resume failed: ${err.message}`);
        }
        console.error(`codex-bridge: thread/resume failed (${err.message}); proceeding without resume`);
        this.threadIdle = true;
        this.turnActive = false;
        return;
      }
      if (!response.thread || response.thread.id !== this.threadId) {
        die("thread/resume did not return the requested thread id");
      }
      const type = response.thread.status && response.thread.status.type;
      this.threadIdle = type !== "active";
      this.turnActive = type === "active";
      // The thread can already be active on resume (e.g. a stuck approval
      // predating this bridge, or a co-resident TUI turn) with no bridge-owned
      // turn/start to hang a watchdog off of. Arm one here too so a pending
      // wake never waits on it forever. See #299.
      if (this.turnActive) this.startTurnWatchdog();
      console.error(`codex-bridge: resumed thread ${this.threadId}`);
      return;
    }
    const response = await this.client.request("thread/start", {
      cwd: this.opts.project,
      runtimeWorkspaceRoots: this.opts.workspaceRoots,
      ephemeral: false,
    });
    this.threadId = response.thread && response.thread.id;
    if (!this.threadId) die("thread/start did not return a thread id");
    console.error(`codex-bridge: started thread ${this.threadId}`);
  }

  async armWatch() {
    this.clearWatchRearmTimer();
    if (this.stopping || this.watchHandle) return;
    // The rate ceiling, on the one path every re-arm goes through. If the last
    // arm was too recent, defer this one to fill the interval rather than spawn
    // now; the watchHandle guard above and clearWatchRearmTimer keep a single
    // pending arm. Nothing is dropped -- a deferred arm still runs.
    const wait = MIN_ARM_INTERVAL_MS - (Date.now() - this.lastArmAt);
    if (wait > 0) {
      this.watchRearmTimer = setTimeout(() => {
        this.watchRearmTimer = null;
        this.armWatch().catch((error) => this.failClientHandler("process/exited", error));
      }, wait);
      return;
    }
    this.lastArmAt = Date.now();
    const handle = `agmsg-watch-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    this.watchHandle = handle;
    const command = [
      BASH_BIN,
      path.join(SCRIPT_DIR, "watch-once.sh"),
      // watch-once.sh resolves the subscription set through the same exact
      // project-key lookup as identities.sh, so it needs the POSIX form of the
      // project path. The spawn cwd below stays native for the app-server.
      toPosixPath(this.opts.project),
      this.opts.type,
      "--timeout",
      String(this.opts.timeout),
      "--interval",
      String(this.opts.interval),
    ];
    for (const pair of this.identities) command.push("--pair", `${pair.team}\t${pair.name}`);
    try {
      await this.client.request("process/spawn", {
        command,
        processHandle: handle,
        cwd: this.opts.project,
        outputBytesCap: 8192,
        timeoutMs: (this.opts.timeout + this.opts.interval + 10) * 1000,
      });
    } catch (error) {
      if (this.watchHandle === handle) this.watchHandle = null;
      throw error;
    }
    console.error(`codex-bridge: armed ${this.identity.team}/${this.identity.name}`);
  }

  async onProcessExited(params) {
    if (params.processHandle !== this.watchHandle) return;
    this.watchHandle = null;

    if (params.exitCode === 0) {
      // Decay, not reset. A wake is progress, but a wake arriving amid failures
      // does not prove the host recovered -- it proves one message moved. The
      // old reset-to-0 let a fail/fail/wake churn hold the counter below the
      // limit forever, so a bridge that never stopped delivering also never
      // stopped failing (#936 (b)). Forgiving ONE failure per delivery lets a
      // genuinely-recovered bridge (mostly wakes) fall to 0 while a churn still
      // climbs to the cap. A clean deadline (exit 2 below) is the stronger
      // signal -- a full timeout ran end to end -- and still resets outright.
      this.watchFailureCount = Math.max(0, this.watchFailureCount - 1);
      const maxId = parseMaxId(params.stdout);
      if (this.isStaleWake(maxId)) {
        await this.shutdown();
        process.exit(1);
      }
      this.pendingWake = true;
      this.wakeCount += 1;
      console.error(`codex-bridge: wakeup ${this.wakeCount} for ${this.identity.team}/${this.identity.name}`);
      await this.tryStartTurn();
      return;
    }

    if (params.exitCode === 2) {
      this.watchFailureCount = 0;
      await this.armWatch();
      return;
    }

    this.watchFailureCount += 1;
    const detail = [params.stderr, params.stdout].filter(Boolean).join("\n").trim();
    console.error(`codex-bridge: watch-once failed with exit ${params.exitCode}${detail ? `: ${detail}` : ""}`);
    if (this.opts.watchFailureLimit > 0 && this.watchFailureCount >= this.opts.watchFailureLimit) {
      console.error(
        `codex-bridge: stopping after ${this.watchFailureCount} consecutive watch-once failure(s)`,
      );
      await this.shutdown();
      process.exit(1);
    }
    this.scheduleWatchRearm();
  }

  scheduleWatchRearm() {
    if (this.stopping || this.watchHandle || this.watchRearmTimer) return;
    this.watchRearmTimer = setTimeout(() => {
      this.watchRearmTimer = null;
      this.armWatch().catch((error) => this.failClientHandler("process/exited", error));
    }, 5000);
  }

  clearWatchRearmTimer() {
    if (!this.watchRearmTimer) return;
    clearTimeout(this.watchRearmTimer);
    this.watchRearmTimer = null;
  }

  onThreadStatus(params) {
    if (params.threadId !== this.threadId) return;
    const type = params.status && params.status.type;
    if (type === "active") {
      this.turnActive = true;
      this.threadIdle = false;
      // See the identical comment on the "turn/started" handler in run() --
      // this transition can also happen without tryStartTurn() ever calling
      // startTurnWatchdog() itself. See #299.
      this.startTurnWatchdog();
      return;
    }
    if (type === "idle") {
      this.threadIdle = true;
      // The real app-server signals idle but may never send turn/completed;
      // treat idle as the end of the turn so detection resumes. See #41.
      this.onTurnEnded().catch((error) =>
        console.error(`codex-bridge: resume on idle failed: ${error.message}`),
      );
    }
  }

  async onTurnCompleted(params = {}) {
    if (params.threadId && params.threadId !== this.threadId) return;
    if (params.turn && params.turn.error) {
      console.error(`codex-bridge: turn completed with error: ${JSON.stringify(params.turn.error)}`);
    } else {
      console.error(`codex-bridge: turn completed on thread ${this.threadId}`);
    }
    await this.onTurnEnded();
  }

  // Single exit point for "the turn is no longer running", reachable from
  // turn/completed, turn/failed, thread/status idle, OR the turn watchdog. The
  // real app-server does not reliably deliver turn/completed, so a bridge that
  // gates re-arm on it never re-arms and sleeps after one message. See #41.
  async onTurnEnded() {
    this.clearTurnWatchdog();
    this.turnActive = false;
    this.threadIdle = true;
    if (this.opts.maxWakes && this.wakeCount >= this.opts.maxWakes) {
      await this.shutdown();
      process.exit(0);
    }
    // A wake can arrive while a turn is still active — the bridge resumed an
    // already-active thread (SessionStart fires on the first user turn), or a
    // message landed mid-turn. tryStartTurn() deferred it because turnActive
    // was set. Deliver that pending wake now instead of re-arming: a fresh
    // watch-once would re-observe the same unread max_id and the stale-wake
    // guard would stop the bridge with exit 1 before the message is delivered.
    if (this.pendingWake) {
      await this.tryStartTurn();
      return;
    }
    // Re-arm detection only after the turn has ended, so a watch-once never
    // re-observes the message the in-flight turn is still handling. A single
    // watch-once is armed between turns.
    await this.armWatch();
  }

  async tryStartTurn() {
    if (!this.pendingWake || this.turnActive || !this.threadIdle) return;
    if (this.opts.inlineInbox) {
      this.inlineInboxText = this.readInboxForPrompt();
      if (!this.inlineInboxText.trim()) {
        console.error("codex-bridge: pending wake had no inbox output; re-arming");
        this.pendingWake = false;
        await this.armWatch();
        return;
      }
    }
    const prompt = this.buildPrompt();
    this.turnActive = true;
    this.threadIdle = false;
    try {
      await this.client.request("turn/start", {
        threadId: this.threadId,
        input: [{ type: "text", text: prompt, text_elements: [] }],
        cwd: this.opts.project,
        runtimeWorkspaceRoots: this.opts.workspaceRoots,
      });
      console.error(`codex-bridge: started turn on thread ${this.threadId}`);
      this.pendingWake = false;
      // Bound how long we treat the turn as active. The real app-server may
      // never send turn/completed; the watchdog (and thread/status idle) drive
      // onTurnEnded so detection re-arms instead of sleeping forever. See #41.
      this.startTurnWatchdog();
    } catch (error) {
      this.turnActive = false;
      this.threadIdle = true;
      this.clearTurnWatchdog();
      throw error;
    }
  }

  // Idle watchdog, not a fixed ceiling on the turn's total duration: ANY
  // thread-scoped app-server activity re-arms it (client.onThreadActivity,
  // set in run() -- reasoning deltas, tool-call/command progress, agent
  // -message deltas, all of it), so a turn that is actively doing something
  // never trips it no matter how long it runs — only turnTimeout seconds of
  // true silence does. This matters because the app-server does not reliably
  // send turn/completed (#41), so something has to detect a turn that will
  // never report completion; a turn that is visibly still working is not
  // that case, and cutting it off before it reaches its own send.sh call
  // silently drops whatever it was about to report.
  startTurnWatchdog() {
    this.clearTurnWatchdog();
    if (!this.opts.turnTimeout) return;
    this.turnTimer = setTimeout(() => {
      this.turnTimer = null;
      console.error(
        `codex-bridge: no turn activity within ${this.opts.turnTimeout}s; assuming the turn ended and resuming`,
      );
      this.onTurnEnded().catch((error) =>
        console.error(`codex-bridge: resume after turn timeout failed: ${error.message}`),
      );
    }, this.opts.turnTimeout * 1000);
    if (this.turnTimer.unref) this.turnTimer.unref();
  }

  clearTurnWatchdog() {
    if (this.turnTimer) {
      clearTimeout(this.turnTimer);
      this.turnTimer = null;
    }
  }

  onServerError(params) {
    if (params.threadId && params.threadId !== this.threadId) return;
    console.error(`codex-bridge: server error: ${JSON.stringify(params)}`);
  }

  // Response shapes below are the app-server's actual v2/legacy approval
  // protocol (codex-rs app-server-protocol ServerRequest), not guesses.
  denyApproval() {
    console.error("codex-bridge: auto-declining an approval request (headless bridge, see #299)");
    return { decision: "decline" };
  }

  denyLegacyApproval() {
    console.error("codex-bridge: auto-denying a legacy approval request (headless bridge, see #299)");
    return { decision: "denied" };
  }

  denyPermissions() {
    // No optional grant fields set = no additional permissions granted.
    console.error("codex-bridge: auto-declining a permissions request (headless bridge, see #299)");
    return { permissions: {}, scope: "turn" };
  }

  denyElicitation() {
    console.error("codex-bridge: auto-declining an MCP elicitation request (headless bridge, see #299)");
    return { action: "decline", content: null, _meta: null };
  }

  onAgentMessageDelta(params) {
    if (params.threadId !== this.threadId) return;
    // Same funnel: a delta is partial by name, so the flag it leaves behind is
    // what stops the next diagnostic from joining it into one line (#784).
    writeErr(params.delta);
    // Watchdog re-arm on this activity is handled generically by
    // client.onThreadActivity (see run()), covering every notification type,
    // not just this one.
  }

  buildPrompt() {
    const inbox = path.join(SCRIPTS_DIR, "inbox.sh");
    const send = path.join(SCRIPTS_DIR, "send.sh");
    if (this.opts.inlineInbox) {
      return [
        `agmsg delivered the following unread messages for ${this.identity.team}/${this.identity.name}:`,
        "",
        this.inlineInboxText.trim(),
        "",
        "Continue the conversation in this Codex thread. If a reply to an agmsg sender is needed, send it with:",
        `${send} ${this.identity.team} ${this.identity.name} <to> <message>`,
      ].join("\n");
    }
    return [
      `agmsg has unread messages for ${this.identity.team}/${this.identity.name}.`,
      `Run: ${inbox} ${this.identity.team} ${this.identity.name}`,
      "Read the messages and continue the conversation. If a reply is needed, send it with:",
      `${send} ${this.identity.team} ${this.identity.name} <to> <message>`,
    ].join("\n");
  }

  readInboxForPrompt() {
    // Re-resolve locks immediately before reading. watch-once only tells us
    // that *some* eligible identity woke; ownership can change before this
    // turn starts, so never let a stale bridge membership mark another
    // session's messages read.
    const eligible = spawnSync(BASH_BIN, [path.join(SCRIPT_DIR, "eligible-pairs.sh"), toPosixPath(this.opts.project), this.opts.type,
      ...this.identities.flatMap((pair) => ["--pair", `${pair.team}\t${pair.name}`])], { cwd: this.opts.project, encoding: "utf8" });
    if (eligible.error || eligible.status !== 0) {
      console.error("codex-bridge: could not resolve eligible identities before reading inbox");
      return "";
    }
    const allowed = new Set((eligible.stdout || "").split(/\r?\n/).filter(Boolean));
    const sections = [];
    for (const pair of this.identities) {
      if (!allowed.has(`${pair.team}\t${pair.name}`)) continue;
      const result = spawnSync(BASH_BIN, [path.join(SCRIPTS_DIR, "inbox.sh"), pair.team, pair.name], { cwd: this.opts.project, encoding: "utf8" });
      if (result.error || result.status !== 0) { console.error(`codex-bridge: inbox.sh failed for ${pair.team}/${pair.name}`); continue; }
      if ((result.stdout || "").trim()) sections.push(result.stdout.trim());
    }
    return sections.join("\n\n");
  }

  async shutdown() {
    if (this.stopping) return;
    this.stopping = true;
    this.clearWatchRearmTimer();
    this.clearTurnWatchdog();
    if (this.watchHandle) {
      try {
        await this.client.request("process/kill", { processHandle: this.watchHandle });
      } catch (_) {
        // The app-server may already be gone.
      }
      this.watchHandle = null;
    }
    this.client.stop();
    this.cleanupMeta();
  }

  cleanupMeta() {
    let ownerPid = "";
    try {
      ownerPid = fs.existsSync(this.metafile)
        ? (fs.readFileSync(this.metafile, "utf8").match(/^pid=(.*)$/m) || [])[1]
        : "";
    } catch (_) {
      ownerPid = "";
    }
    if (ownerPid && ownerPid !== String(process.pid)) return;

    try {
      if (fs.existsSync(this.pidfile) && fs.readFileSync(this.pidfile, "utf8").trim() !== String(process.pid)) {
        return;
      }
    } catch (_) {
      return;
    }

    for (const file of [this.pidfile, this.metafile]) {
      try {
        if (fs.existsSync(file)) fs.unlinkSync(file);
      } catch (_) {
        // Best-effort cleanup.
      }
    }
  }

  ensureSingleInstance() {
    const existing = readPid(this.pidfile);
    if (!existing) return;
    // The launcher records the spawned PID immediately so status never points
    // at a stale predecessor. When that write wins the startup race, this
    // process sees its own PID here; it owns the reservation, not a peer bridge.
    if (existing === process.pid) return;
    try {
      process.kill(existing, 0);
      die(`bridge already running for ${this.identity.team}/${this.identity.name} (pid ${existing})`);
    } catch (error) {
      if (error && error.code === "ESRCH") {
        for (const file of [this.pidfile, this.metafile]) {
          try {
            if (fs.existsSync(file)) fs.unlinkSync(file);
          } catch (_) {
            // Best-effort stale cleanup.
          }
        }
        return;
      }
      die(`cannot verify existing bridge pid ${existing}: ${error.message}`);
    }
  }

  isStaleWake(maxId) {
    // maxId is an OPAQUE token (the unread frontier id from watch-once), compared
    // only for equality — never ordered. An empty token means "no unread".
    if (!maxId || this.lastWakeMaxId !== maxId) {
      this.lastWakeMaxId = maxId;
      this.staleWakeCount = 0;
      return false;
    }

    this.staleWakeCount += 1;
    console.error(
      `codex-bridge: unread max_id is still ${maxId}; inbox was not marked read after the prior wakeup`,
    );
    if (this.opts.staleWakeLimit > 0 && this.staleWakeCount >= this.opts.staleWakeLimit) {
      console.error("codex-bridge: stopping to avoid a repeated wakeup loop");
      return true;
    }
    return false;
  }
}

function appServerCommand(opts = {}) {
  if (opts.appServer) {
    if (opts.appServer === "stdio://" || opts.appServer === "stdio") {
      return ["codex", "app-server", "--listen", "stdio://"];
    }
    if (opts.appServer.startsWith("unix://") || opts.appServer.startsWith("ws://")) {
      die("--app-server unix://PATH or ws://host:port is handled by the direct WebSocket client");
    }
    die("--app-server supports only unix://PATH or ws://host:port");
  }
  if (process.env.AGMSG_CODEX_APP_SERVER_CMD) {
    return ["/bin/sh", "-lc", process.env.AGMSG_CODEX_APP_SERVER_CMD];
  }
  return ["codex", "app-server", "--listen", "stdio://"];
}

function parseWsTarget(url) {
  // ws://host:port → { host, port }. wss:// would need TLS, which the plain
  // net socket below does not do; the agmsg app-server is loopback ws only.
  const match = /^ws:\/\/([^/:]+):(\d+)\/?$/.exec(url);
  if (!match) die(`--app-server ${url} must be ws://host:port`);
  const port = Number(match[2]);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    die(`--app-server ${url} has an invalid port`);
  }
  return { host: match[1], port };
}

function createAppServerClient(opts) {
  if (opts.appServer && opts.appServer.startsWith("unix://")) {
    const rawSocketPath = opts.appServer.slice("unix://".length);
    if (!rawSocketPath) die("--app-server unix:// requires a socket path");
    const socketPath = path.isAbsolute(rawSocketPath) ? rawSocketPath : path.resolve(process.cwd(), rawSocketPath);
    return new WebSocketAppServerClient({ path: socketPath }, `unix://${socketPath}`, opts);
  }
  if (opts.appServer && opts.appServer.startsWith("ws://")) {
    const target = parseWsTarget(opts.appServer);
    return new WebSocketAppServerClient(target, opts.appServer, opts);
  }
  return new AppServerClient(appServerCommand(opts), opts.project, opts);
}

function readVersion() {
  try {
    return fs.readFileSync(path.join(SKILL_DIR, "VERSION"), "utf8").trim();
  } catch (_) {
    return "unknown";
  }
}

function readPid(file) {
  try {
    if (!fs.existsSync(file)) return 0;
    const value = Number(fs.readFileSync(file, "utf8").trim());
    return Number.isInteger(value) && value > 0 ? value : 0;
  } catch (_) {
    return 0;
  }
}

function parseMaxId(stdout) {
  // max_id is now an opaque token (UUIDv7 / legacy decimal / any whitespace-free
  // string), not an integer — return it verbatim for equality-only comparison.
  const match = String(stdout || "").match(/\bmax_id=(\S+)/);
  return match ? match[1] : "";
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    usage();
    return;
  }

  // Read-only probe: no identities, no pidfile, no thread resumed. Runs before
  // resolveIdentities because seating a role is exactly what has not happened
  // yet when this is called -- requiring an identity here would be circular.
  if (opts.printLoadedThreads) {
    const client = createAppServerClient(opts);
    try {
      // start() arms the connection; ready() is what resolves once the WebSocket
      // handshake has completed. Awaiting start() alone sends the first request
      // into a socket that is not connected yet.
      client.start();
      await client.ready?.();
      await client.request("initialize", {
        clientInfo: { name: "agmsg-codex-bridge", title: "agmsg Codex bridge", version: readVersion() },
        capabilities: { experimentalApi: true, requestAttestation: false, optOutNotificationMethods: [] },
      });
      client.notify("initialized");
      const response = await client.request("thread/loaded/list", {});
      const ids = response && Array.isArray(response.data) ? response.data : [];
      if (ids.length > 0) console.log(ids.join("\n"));
    } finally {
      client.stop();
    }
    return;
  }

  const identities = resolveIdentities(opts);
  if (opts.resolveOnly) {
    console.log(identities.map((pair) => `${pair.team}\t${pair.name}`).join("\n"));
    return;
  }

  const bridge = new CodexBridge(opts, identities);
  await bridge.run();
}

if (require.main === module) {
  main().catch((error) => die(error.message));
}

// `writeErr` and `logLine` are exported for the same reason `toPosixPath` is:
// the property that matters — a diagnostic never continues someone else's
// half-line — is a property of these two together, and driving them directly
// is the only way to state it without standing up an app-server.
module.exports = { toPosixPath, writeErr, logLine };
