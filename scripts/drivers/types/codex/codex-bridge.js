#!/usr/bin/env node
"use strict";

const { spawn, spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const path = require("path");
const readline = require("readline");

process.umask(0o077);

const SCRIPT_DIR = __dirname;                              // .../scripts/drivers/types/codex (codex siblings live here)
const SKILL_DIR = path.resolve(SCRIPT_DIR, "..", "..", "..", "..");    // skill root
const SCRIPTS_DIR = path.join(SKILL_DIR, "scripts");       // type-independent engine scripts (identities/inbox/send)
const RUN_DIR = path.resolve(process.env.AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR || path.join(SKILL_DIR, "run"));

// Git Bash on Windows cannot exec a .sh path directly — spawnSync of the script
// fails with EFTYPE. Invoke the helper scripts through bash on every platform.
// bash is always present in agmsg's runtime (the bridge is launched from a bash
// context); honour the same overrides delivery.sh's windows_wrap uses.
const BASH_BIN = process.env.GIT_BASH || process.env.AGMSG_BASH || "bash";

function usage() {
  console.log(`Usage: codex-bridge.js --project <path> [--type codex] [--team <team>] [--name <agent>]

Beta Codex app-server bridge for agmsg pseudo-monitoring.

Options:
  --project <path>        Project path to monitor.
  --type <agent_type>     Agent type for identity resolution (default: codex).
  --team <team>           Limit wakeups to one team.
  --name <agent>          Limit wakeups to one agent name.
  --state-key <key>       Private runtime suffix chosen by the launcher.
  --timeout <sec>         watch-once timeout before re-arming (default: 300).
  --interval <sec>        watch-once poll interval (default: 2).
  --max-wakes <n>         Stop after n wakeups, useful for tests.
  --connect-timeout-ms <ms>
                          Max wait for direct app-server connect/upgrade (default: 10000).
  --request-timeout-ms <ms>
                          Max wait for each app-server request (default: 30000).
  --watch-failure-limit <n>
                          Stop after n consecutive watch-once failures; 0 disables (default: 3).
  --app-server <url>      Connect through an existing app-server endpoint.
                          Supports unix://PATH or ws://host:port over WebSocket.
  --app-server-file <path>
                          Read the endpoint from a private (0600) file.
  --thread <id>           Resume this exact existing app-server thread.
  --inline-inbox          Rejected: background inbox reads are unsafe.
  --resolve-only          Print resolved team/name and exit.
  --help                  Show this help.

Set AGMSG_CODEX_APP_SERVER_CMD to override the app-server command for tests.`);
}

function die(message) {
  console.error(`codex-bridge: ${message}`);
  process.exit(1);
}

class TerminalBridgeError extends Error {
  constructor(message) {
    super(message);
    this.name = "TerminalBridgeError";
  }
}

class ExistingBridgeError extends TerminalBridgeError {
  constructor(message) {
    super(message);
    this.name = "ExistingBridgeError";
  }
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
    connectTimeoutMs: Number(process.env.AGMSG_CODEX_BRIDGE_CONNECT_TIMEOUT_MS || 10000),
    requestTimeoutMs: Number(process.env.AGMSG_CODEX_BRIDGE_REQUEST_TIMEOUT_MS || 30000),
    watchFailureLimit: Number(process.env.AGMSG_CODEX_BRIDGE_WATCH_FAILURE_LIMIT || 3),
    inlineInbox: false,
    turnTimeout: Number(process.env.AGMSG_CODEX_BRIDGE_TURN_TIMEOUT || 60),
    retryBaseMs: Number(process.env.AGMSG_CODEX_BRIDGE_RETRY_BASE_MS || 5000),
    retryMaxMs: Number(process.env.AGMSG_CODEX_BRIDGE_RETRY_MAX_MS || 300000),
    sameUnreadDelayMs: Number(process.env.AGMSG_CODEX_BRIDGE_SAME_UNREAD_DELAY_MS || 30000),
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      opts.help = true;
    } else if (arg === "--resolve-only") {
      opts.resolveOnly = true;
    } else if (arg === "--project") {
      opts.project = argv[++i];
    } else if (arg === "--type") {
      opts.type = argv[++i];
    } else if (arg === "--team") {
      opts.team = argv[++i];
    } else if (arg === "--name") {
      opts.name = argv[++i];
    } else if (arg === "--state-key") {
      opts.stateKey = argv[++i];
    } else if (arg === "--timeout") {
      opts.timeout = Number(argv[++i]);
    } else if (arg === "--interval") {
      opts.interval = Number(argv[++i]);
    } else if (arg === "--max-wakes") {
      opts.maxWakes = Number(argv[++i]);
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
    } else if (arg === "--app-server-file") {
      opts.appServerFile = path.resolve(argv[++i]);
    } else if (arg === "--thread") {
      opts.threadId = argv[++i];
    } else if (arg === "--inline-inbox") {
      opts.inlineInboxRequested = true;
    } else {
      die(`unknown option: ${arg}`);
    }
  }

  if (opts.help) return opts;
  if (!opts.project) die("--project is required");
  if (!Number.isFinite(opts.timeout) || opts.timeout <= 0) die("--timeout must be a positive number");
  if (!Number.isFinite(opts.interval) || opts.interval <= 0) die("--interval must be a positive number");
  if (!Number.isFinite(opts.maxWakes) || opts.maxWakes < 0) die("--max-wakes must be a non-negative number");
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
  for (const key of ["retryBaseMs", "retryMaxMs", "sameUnreadDelayMs"]) {
    if (!Number.isFinite(opts[key]) || opts[key] < 1) die(`${key} must be a positive number`);
  }
  if (opts.appServer && opts.appServerFile) die("pass only one of --app-server or --app-server-file");
  if (opts.appServerFile) opts.appServer = readPrivateEndpoint(opts.appServerFile);
  if (!opts.resolveOnly && (!opts.threadId || !/^[A-Za-z0-9._-]+$/.test(opts.threadId))) {
    die("one exact --thread id is required");
  }
  if (!opts.resolveOnly && ["loaded", "current", "unresolved"].includes(opts.threadId)) {
    die("one exact --thread id is required; discovery aliases are not supported");
  }
  if (opts.inlineInboxRequested) {
    die("--inline-inbox is disabled; only the visible Codex task may run the official inbox command");
  }
  if (opts.stateKey && !/^[A-Za-z0-9._%-]+$/.test(opts.stateKey)) die("--state-key contains unsafe characters");
  opts.project = path.resolve(opts.project);
  if (!fs.existsSync(opts.project) || !fs.statSync(opts.project).isDirectory()) {
    die(`project path is not a directory: ${opts.project}`);
  }
  // Preserve the registry spelling for identities.sh (macOS may register
  // /var while realpath is /private/var), and use the canonical root for all
  // relay-authorized app-server requests.
  opts.canonicalProject = fs.realpathSync(opts.project);
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

function resolveIdentity(opts) {
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
    .filter((pair) => !opts.name || pair.name === opts.name);

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
  if (deduped.length > 1) die("multiple identities match; pass --team and --name");
  return deduped[0];
}

class AppServerClient {
  constructor(command, cwd, opts = {}) {
    this.command = command;
    this.cwd = cwd;
    this.requestTimeoutMs = opts.requestTimeoutMs || 0;
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = new Map();
    this.child = null;
    this.disconnectHandler = null;
    this.intentionalStop = false;
  }

  start() {
    const [bin, ...args] = this.command;
    const childEnv = { ...process.env };
    delete childEnv.CODEX_APP_SERVER_WS_URL;
    this.child = spawn(bin, args, {
      cwd: this.cwd,
      env: childEnv,
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
      const error = new Error(`app-server exited (${code ?? signal})`);
      for (const { reject } of this.pending.values()) {
        reject(error);
      }
      this.pending.clear();
      if (!this.intentionalStop && this.disconnectHandler) this.disconnectHandler(error);
    });

    // app-server stderr can contain user-visible model content. Keep bridge
    // logs as lifecycle telemetry only.
    this.child.stderr.on("data", () => {});

    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on("line", (line) => this.handleLine(line));
  }

  on(method, handler) {
    this.handlers.set(method, handler);
  }

  onDisconnect(handler) {
    this.disconnectHandler = handler;
  }

  handleLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      console.error("codex-bridge: ignoring non-json app-server line");
      return;
    }

    if (message.method && Object.prototype.hasOwnProperty.call(message, "id")) {
      const handler = this.handlers.get(message.method);
      if (!handler) {
        this.sendJson({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32601, message: `No handler for ${message.method}` },
        });
        return;
      }
      Promise.resolve(handler(message.params || {})).then(
        (result) => this.sendJson({ jsonrpc: "2.0", id: message.id, result: result || {} }),
        (error) => this.sendJson({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32000, message: error.message || String(error) },
        }),
      );
      return;
    }
    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (message.method && this.handlers.has(message.method)) {
      this.dispatch(message.method, message.params || {});
    }
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

  sendJson(value) {
    this.child.stdin.write(`${JSON.stringify(value)}\n`);
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
    this.intentionalStop = true;
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
    this.requestPath = opts.requestPath || "/";
    this.connectTimeoutMs = opts.connectTimeoutMs || 0;
    this.requestTimeoutMs = opts.requestTimeoutMs || 0;
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = new Map();
    this.socket = null;
    this.buffer = Buffer.alloc(0);
    this.connected = false;
    this.handshakeComplete = false;
    this.handshakeBuffer = Buffer.alloc(0);
    this.startPromise = null;
    // Set when WE close the socket (shutdown); distinguishes an intentional stop
    // from the app-server going away under us.
    this.intentionalStop = false;
    this.disconnectHandler = null;
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
            `GET ${this.requestPath} HTTP/1.1`,
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
        if (!this.intentionalStop && this.disconnectHandler) this.disconnectHandler(error);
      });
    });
  }

  async ready() {
    if (this.startPromise) await this.startPromise;
  }

  on(method, handler) {
    this.handlers.set(method, handler);
  }

  onDisconnect(handler) {
    this.disconnectHandler = handler;
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
      console.error("codex-bridge: ignoring non-json app-server message");
      return;
    }
    if (message.method && Object.prototype.hasOwnProperty.call(message, "id")) {
      const handler = this.handlers.get(message.method);
      if (!handler) {
        this.sendJson({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32601, message: `No handler for ${message.method}` },
        });
        return;
      }
      Promise.resolve(handler(message.params || {})).then(
        (result) => this.sendJson({ jsonrpc: "2.0", id: message.id, result: result || {} }),
        (error) => this.sendJson({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32000, message: error.message || String(error) },
        }),
      );
      return;
    }
    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    if (message.method && this.handlers.has(message.method)) {
      this.dispatch(message.method, message.params || {});
    }
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
  constructor(opts, identity) {
    this.opts = opts;
    this.identity = identity;
    this.client = createAppServerClient(opts);
    this.threadId = opts.threadId || null;
    this.threadIdle = true;
    this.turnActive = false;
    this.turnTimer = null;
    this.pendingWakeMaxId = 0;
    this.watchHandle = null;
    this.wakeCount = 0;
    this.watchFailureCount = 0;
    this.wakeRetryCount = 0;
    this.watchRearmTimer = null;
    this.stopping = false;
    this.preserveHealthOnExit = false;
    this.signalHandler = null;
    this.lifetimeSettled = false;
    this.lifetime = new Promise((resolve, reject) => {
      this.resolveLifetime = (value) => {
        if (this.lifetimeSettled) return;
        this.lifetimeSettled = true;
        resolve(value);
      };
      this.rejectLifetime = (error) => {
        if (this.lifetimeSettled) return;
        this.lifetimeSettled = true;
        reject(error);
      };
    });
    const stateKey = opts.stateKey || `${identity.team}.${identity.name}`;
    this.stateKey = stateKey;
    this.pidfile = path.join(RUN_DIR, `codex-bridge.${stateKey}.pid`);
    this.metafile = path.join(RUN_DIR, `codex-bridge.${stateKey}.meta`);
    this.healthfile = path.join(RUN_DIR, `codex-bridge.${stateKey}.health`);
    const threadHash = crypto.createHash("sha256").update(this.threadId).digest("hex").slice(0, 24);
    this.threadHash = threadHash;
    this.wakeStateFile = path.join(RUN_DIR, `codex-bridge.${stateKey}.wake.${threadHash}.json`);
  }

  async run() {
    fs.mkdirSync(RUN_DIR, { recursive: true });
    this.ensureSingleInstance();
    this.writeMeta();
    this.writeHealth("connecting");
    this.installSignals();
    this.client.on("process/exited", this.clientHandler("process/exited", (params) => this.onProcessExited(params)));
    this.client.on("error", this.clientHandler("error", (params) => this.onServerError(params)));
    this.client.on("item/agentMessage/delta", this.clientHandler("item/agentMessage/delta", (params) => this.onAgentMessageDelta(params)));
    this.client.on("thread/status/changed", this.clientHandler("thread/status/changed", (params) => this.onThreadStatus(params)));
    this.client.on("turn/started", this.clientHandler("turn/started", (params) => {
      if (params.threadId !== this.threadId) return;
      this.turnActive = true;
      this.threadIdle = false;
    }));
    this.client.on("turn/completed", this.clientHandler("turn/completed", (params) => this.onTurnCompleted(params)));
    this.client.on("turn/failed", this.clientHandler("turn/failed", (params) => this.onTurnCompleted(params)));
    this.client.onDisconnect((error) => {
      if (!this.stopping) this.rejectLifetime(error);
    });

    this.client.start();
    await this.client.ready?.();
    this.writeHealth("connected");
    await this.initialize();
    await this.ensureThread();
    this.writeHealth("thread_attached");
    await this.armWatch();
    this.writeMeta();
    this.writeHealth("ready");
    this.readyAt = Date.now();
    await this.lifetime;
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
    this.writeHealth("retrying_transient", `${method}: ${error.message}`);
    this.rejectLifetime(error);
  }

  writeMeta() {
    atomicWritePrivate(this.pidfile, `${process.pid}\n`);
    atomicWritePrivate(
      this.metafile,
      [
        `pid=${process.pid}`,
        `project=${this.opts.project}`,
        `team=${this.identity.team}`,
        `name=${this.identity.name}`,
        `type=${this.opts.type}`,
        `thread=${this.threadId || ""}`,
        `app_server=${redactAppServer(this.opts.appServer || "stdio://")}`,
        `launch_label=${process.env.AGMSG_CODEX_BRIDGE_LAUNCH_LABEL || ""}`,
      ].join("\n") + "\n",
    );
  }

  writeHealth(status, detail = "") {
    const temporary = `${this.healthfile}.${process.pid}.tmp`;
    try {
      fs.writeFileSync(
        temporary,
        [
          `status=${status}`,
          `pid=${process.pid}`,
          `thread=${this.threadId || "unresolved"}`,
          `detail=${String(detail).replace(/[\r\n]+/g, " ")}`,
          `updated_at=${new Date().toISOString()}`,
          "",
        ].join("\n"),
      );
      fs.chmodSync(temporary, 0o600);
      fs.renameSync(temporary, this.healthfile);
    } catch (_) {
      try { fs.unlinkSync(temporary); } catch (_) {}
    }
  }

  readWakeState({ tolerateCorrupt = false } = {}) {
    if (!fs.existsSync(this.wakeStateFile)) return null;
    try {
      const stat = fs.lstatSync(this.wakeStateFile);
      if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) {
        throw new Error("wake state is not a private regular file");
      }
      const state = JSON.parse(fs.readFileSync(this.wakeStateFile, "utf8"));
      const expectedId = wakeClientMessageId(this.stateKey, this.threadId, state.maxId);
      if (
        state.version !== 1
        || state.threadHash !== this.threadHash
        || !Number.isInteger(state.maxId)
        || state.maxId <= 0
        || !["observed", "dispatching", "accepted", "ack_confirmed"].includes(state.phase)
        || state.clientUserMessageId !== expectedId
      ) {
        throw new Error("wake state failed validation");
      }
      return state;
    } catch (error) {
      if (tolerateCorrupt) return null;
      throw new Error(`cannot trust durable wake state: ${error.message}`);
    }
  }

  writeWakeState(state) {
    const value = {
      version: 1,
      threadHash: this.threadHash,
      maxId: state.maxId,
      phase: state.phase,
      clientUserMessageId: state.clientUserMessageId,
      updatedAt: new Date().toISOString(),
    };
    atomicWritePrivate(this.wakeStateFile, `${JSON.stringify(value)}\n`);
  }

  installSignals() {
    this.signalHandler = () => {
      this.shutdown().finally(() => this.resolveLifetime());
    };
    process.once("SIGINT", this.signalHandler);
    process.once("SIGTERM", this.signalHandler);
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

  async ensureThread() {
    let response;
    try {
      response = await this.client.request("thread/resume", {
        threadId: this.threadId,
        cwd: this.opts.canonicalProject,
        runtimeWorkspaceRoots: [this.opts.canonicalProject],
        excludeTurns: true,
      });
    } catch (error) {
      throw new TerminalBridgeError(`cannot resume exact thread ${this.threadId}: ${error.message}`);
    }
    if (!response.thread || response.thread.id !== this.threadId) {
      throw new TerminalBridgeError("thread/resume did not return the requested thread id");
    }
    const type = response.thread.status && response.thread.status.type;
    this.threadIdle = type !== "active";
    this.turnActive = type === "active";
    console.error(`codex-bridge: resumed thread ${this.threadId}`);
  }

  async armWatch() {
    this.clearWatchRearmTimer();
    if (this.stopping || this.watchHandle) return;
    const handle = `agmsg-watch-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    this.watchHandle = handle;
    const ownerId = `agmsg-codex-bridge-${process.pid}.${process.pid}`;
    const command = [
      fs.existsSync("/bin/bash") ? "/bin/bash" : BASH_BIN,
      path.join(SCRIPT_DIR, "watch-once.sh"),
      // watch-once.sh resolves the subscription set through the same exact
      // project-key lookup as identities.sh, so it needs the POSIX form of the
      // project path. The spawn cwd below stays native for the app-server.
      toPosixPath(this.opts.project),
      this.opts.type,
      "--team",
      this.identity.team,
      "--name",
      this.identity.name,
      "--owner",
      ownerId,
      "--claim",
      "--timeout",
      String(this.opts.timeout),
      "--interval",
      String(this.opts.interval),
    ];
    try {
      await this.client.request("process/spawn", {
        command,
        processHandle: handle,
        cwd: this.opts.canonicalProject,
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
      this.watchFailureCount = 0;
      const maxId = parseMaxId(params.stdout);
      if (!maxId) {
        this.writeHealth("paused_ambiguous_wake", "watch-once returned pending without a valid max_id");
        this.scheduleWatchRearm(this.nextRetryDelay());
        return;
      }

      let state;
      try {
        state = this.readWakeState();
      } catch (error) {
        this.writeHealth("paused_ambiguous_wake", error.message);
        this.scheduleWatchRearm(this.opts.sameUnreadDelayMs);
        return;
      }
      if (state && maxId < state.maxId) {
        this.writeHealth(
          "paused_ambiguous_wake",
          `unread max_id ${maxId} is older than durable max_id ${state.maxId}`,
        );
        this.scheduleWatchRearm(this.opts.sameUnreadDelayMs);
        return;
      }
      if (state && maxId === state.maxId && ["accepted", "ack_confirmed"].includes(state.phase)) {
        this.writeHealth("waiting_for_ack", `unread max_id ${maxId} is already ${state.phase}`);
        this.scheduleWatchRearm(this.opts.sameUnreadDelayMs);
        return;
      }

      const clientUserMessageId = wakeClientMessageId(this.stateKey, this.threadId, maxId);
      if (!state || maxId > state.maxId) {
        this.writeWakeState({ maxId, phase: "observed", clientUserMessageId });
      }
      this.pendingWakeMaxId = maxId;
      console.error(`codex-bridge: observed unread max_id ${maxId} for ${this.identity.team}/${this.identity.name}`);
      await this.tryStartTurn();
      return;
    }

    if (params.exitCode === 2) {
      this.watchFailureCount = 0;
      this.wakeRetryCount = 0;
      const state = this.readWakeState({ tolerateCorrupt: true });
      if (state && state.phase !== "ack_confirmed") {
        this.writeWakeState({ ...state, phase: "ack_confirmed" });
      }
      this.writeHealth("ready");
      await this.armWatch();
      return;
    }

    this.watchFailureCount += 1;
    const detail = sanitizeLogDetail(params.stderr || `exit ${params.exitCode}`);
    console.error(`codex-bridge: watch-once failed with exit ${params.exitCode}${detail ? `: ${detail}` : ""}`);
    if (this.opts.watchFailureLimit > 0 && this.watchFailureCount >= this.opts.watchFailureLimit) {
      this.writeHealth(
        "paused_watch_failure",
        `${this.watchFailureCount} consecutive watch-once failure(s)`,
      );
    } else {
      this.writeHealth("waiting_watch_retry", `${this.watchFailureCount} watch-once failure(s)`);
    }
    this.scheduleWatchRearm(this.nextRetryDelay());
  }

  nextRetryDelay() {
    const exponent = Math.min(this.wakeRetryCount, 12);
    this.wakeRetryCount += 1;
    return Math.min(this.opts.retryBaseMs * (2 ** exponent), this.opts.retryMaxMs);
  }

  scheduleWatchRearm(delayMs = this.opts.retryBaseMs) {
    if (this.stopping || this.watchHandle || this.watchRearmTimer) return;
    this.watchRearmTimer = setTimeout(() => {
      this.watchRearmTimer = null;
      this.armWatch().catch((error) => {
        this.watchFailureCount += 1;
        this.writeHealth("waiting_watch_retry", sanitizeLogDetail(error.message));
        this.scheduleWatchRearm(this.nextRetryDelay());
      });
    }, delayMs);
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
      console.error(`codex-bridge: turn completed with error code ${sanitizeLogDetail(params.turn.error.code || "unknown")}`);
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
      this.resolveLifetime();
      return;
    }
    // A wake can arrive while a turn is still active — the bridge resumed an
    // already-active thread (SessionStart fires on the first user turn), or a
    // message landed mid-turn. tryStartTurn() deferred it because turnActive
    // was set. Deliver that pending wake now instead of re-arming: a fresh
    // watch-once would re-observe the same unread max_id and the stale-wake
    // guard would stop the bridge with exit 1 before the message is delivered.
    if (this.pendingWakeMaxId) {
      await this.tryStartTurn();
      return;
    }
    // Re-arm detection only after the turn has ended, so a watch-once never
    // re-observes the message the in-flight turn is still handling. A single
    // watch-once is armed between turns.
    await this.armWatch();
  }

  async tryStartTurn() {
    if (!this.pendingWakeMaxId || this.turnActive || !this.threadIdle) return;
    const maxId = this.pendingWakeMaxId;
    const clientUserMessageId = wakeClientMessageId(this.stateKey, this.threadId, maxId);
    let state;
    try {
      state = this.readWakeState();
    } catch (error) {
      this.writeHealth("paused_ambiguous_wake", "durable wake state is unavailable");
      this.scheduleWakeRetry(this.nextRetryDelay());
      return;
    }
    if (!state || state.maxId !== maxId || !["observed", "dispatching"].includes(state.phase)) {
      this.writeHealth("paused_ambiguous_wake", "durable wake phase does not permit dispatch");
      this.scheduleWakeRetry(this.nextRetryDelay());
      return;
    }
    if (state.phase === "observed") {
      // Record bridge-side intent before asking the relay. The relay owns the
      // later at-most-once boundary: it fsyncs its own dispatch state before
      // turn/start. After a relay restart, only that relay state decides
      // whether this request may start or must reconcile.
      this.writeWakeState({ maxId, phase: "dispatching", clientUserMessageId });
    }
    try {
      const response = await this.client.request("agmsg/wake/dispatch", {
        threadId: this.threadId,
        maxId,
        clientUserMessageId,
        dispatchMode: "start-or-reconcile",
        cwd: this.opts.canonicalProject,
        runtimeWorkspaceRoots: [this.opts.canonicalProject],
      });
      if (!response || !["accepted", "reconciled"].includes(response.status) || response.maxId !== maxId) {
        throw new Error("wake dispatch returned an ambiguous result");
      }
      this.writeWakeState({ maxId, phase: "accepted", clientUserMessageId });
      this.pendingWakeMaxId = 0;
      this.wakeRetryCount = 0;
      if (response.status === "accepted") {
        this.wakeCount += 1;
        this.turnActive = true;
        this.threadIdle = false;
        console.error(`codex-bridge: accepted wakeup ${this.wakeCount} on thread ${this.threadId}`);
        this.startTurnWatchdog();
        return;
      }

      console.error(`codex-bridge: reconciled wake max_id ${maxId} on thread ${this.threadId}`);
      this.writeHealth("waiting_for_ack", `reconciled max_id ${maxId}`);
      if (this.turnActive) this.startTurnWatchdog();
      else this.scheduleWatchRearm(this.opts.sameUnreadDelayMs);
    } catch (error) {
      // A timeout can happen after app-server accepted turn/start. The relay
      // reconciles the deterministic client id against thread history on the
      // next attempt, so never issue an unmarked fallback turn here.
      this.writeHealth("paused_ambiguous_wake", "wake dispatch response unavailable; reconciliation pending");
      console.error(`codex-bridge: wake max_id ${maxId} is ambiguous; retrying reconciliation later`);
      this.scheduleWakeRetry(this.nextRetryDelay());
    }
  }

  scheduleWakeRetry(delayMs) {
    if (this.stopping || this.watchRearmTimer) return;
    this.watchRearmTimer = setTimeout(() => {
      this.watchRearmTimer = null;
      this.tryStartTurn().catch((error) => this.failClientHandler("agmsg/wake/dispatch", error));
    }, delayMs);
  }

  startTurnWatchdog() {
    this.clearTurnWatchdog();
    if (!this.opts.turnTimeout) return;
    this.turnTimer = setTimeout(() => {
      this.turnTimer = null;
      console.error(
        `codex-bridge: no turn completion within ${this.opts.turnTimeout}s; assuming the turn ended and resuming`,
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
    const code = params.code || (params.error && params.error.code) || "unknown";
    console.error(`codex-bridge: server error code ${sanitizeLogDetail(code)}`);
  }

  onAgentMessageDelta(params) {
    if (params.threadId !== this.threadId) return;
    // Agent content belongs only in the visible Codex task. The bridge log is
    // lifecycle telemetry and must never become a second transcript.
  }

  buildPrompt() {
    const inbox = path.join(SCRIPTS_DIR, "inbox.sh");
    const send = path.join(SCRIPTS_DIR, "send.sh");
    const autonomousHandlingContract = [
      "Autonomous handling contract:",
      `1. Your first tool call must be this official inbox command: ${inbox} ${this.identity.team} ${this.identity.name}`,
      "2. Do not read the agmsg database or team files directly. The resumed Codex task alone owns message reading and acknowledgement through inbox.sh.",
      "3. For a substantive request, new evidence, correction, or blocker, continue the in-scope work through verification and send an evidence-backed reply with the official send.sh command below. Do not stop after an ACK or status-only reply.",
      "4. Do not reply to ACK-only, thanks-only, or status-only mail that contains no new request, evidence, correction, or blocker. This prevents autonomous ping-pong.",
      "5. Preserve existing approval, production, customer-data, credential, and destructive-action boundaries. Stop and report a real blocker when new authority is required.",
    ].join("\n");
    const visibleUiRequirement = [
      "Visible UI requirement:",
      '1. Before the inbox tool call, post "agmsg受信を検知しました。内容を確認します。" in the visible Codex thread.',
      '2. Immediately after inbox.sh and before any other tool call, post a Japanese update starting with "agmsg受信:" and include sender, received body or safe summary, planned action, and whether you will reply.',
      "3. Keep substantive work in the visible thread. Before each major action, post a short Japanese progress update; never complete the task in an unreported background worker.",
      "4. After handling the message, post a final Japanese status update with: sender, received instruction, action taken, reply target, reply summary, remaining blocker, and next step.",
      "5. If you do not reply, state why in the visible status. ACK-only mail still requires a visible receipt notice.",
      "6. Do not treat inbox consumption, DB writes, monitor delivery, send.sh, or a successful process exit as complete unless the handling result is visible in the Codex thread UI.",
    ].join("\n");
    return [
      `agmsg has unread messages for ${this.identity.team}/${this.identity.name}.`,
      "The bridge did not read or acknowledge their contents.",
      "Continue the conversation in this same Codex thread. If a reply is needed, send it with:",
      `${send} ${this.identity.team} ${this.identity.name} <to> <message>`,
      "",
      autonomousHandlingContract,
      "",
      visibleUiRequirement,
    ].join("\n");
  }

  async pauseWithoutRestart(status, detail) {
    this.writeHealth(status, detail);
    this.preserveHealthOnExit = true;
    await this.shutdown({ preserveHealth: true });
  }

  async shutdown({ preserveHealth = false } = {}) {
    if (this.stopping) return;
    this.stopping = true;
    this.preserveHealthOnExit = this.preserveHealthOnExit || preserveHealth;
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
    if (this.signalHandler) {
      process.removeListener("SIGINT", this.signalHandler);
      process.removeListener("SIGTERM", this.signalHandler);
      this.signalHandler = null;
    }
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

    const files = [this.pidfile, this.metafile];
    if (!this.preserveHealthOnExit) files.push(this.healthfile);
    for (const file of files) {
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
    try {
      process.kill(existing, 0);
      const meta = readKeyValueFile(this.metafile);
      const command = readProcessCommand(existing);
      const expectedScript = fs.realpathSync(__filename);
      const ownsPid = Boolean(
        meta
        && meta.pid === String(existing)
        && meta.project === this.opts.project
        && meta.team === this.identity.team
        && meta.name === this.identity.name
        && meta.type === this.opts.type
        && meta.thread === this.threadId
        && command.includes(expectedScript)
        && command.includes(`--state-key ${this.stateKey}`)
      );
      if (ownsPid) {
        throw new ExistingBridgeError(
          `bridge already running for ${this.identity.team}/${this.identity.name} (pid ${existing})`,
        );
      }
      // The pid was recycled or the metadata is not sufficient to prove
      // ownership. Remove only this role's stale runtime files; never signal an
      // unrelated live process.
      this.removeStaleRuntimeFiles();
      return;
    } catch (error) {
      if (error instanceof ExistingBridgeError) throw error;
      if (error && error.code === "ESRCH") {
        this.removeStaleRuntimeFiles();
        return;
      }
      throw new TerminalBridgeError(`cannot verify existing bridge pid ${existing}: ${error.message}`);
    }
  }

  removeStaleRuntimeFiles() {
    for (const file of [this.pidfile, this.metafile, this.healthfile]) {
      try {
        if (fs.existsSync(file)) fs.unlinkSync(file);
      } catch (_) {
        // Best-effort removal of files owned by this exact state key.
      }
    }
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
  // wss:// would need TLS, which the plain net socket below does not do.
  let parsed;
  try {
    parsed = new URL(url);
  } catch (_) {
    die("--app-server must be a valid ws:// URL");
  }
  if (parsed.protocol !== "ws:" || parsed.username || parsed.password || !parsed.hostname || !parsed.port) {
    die("--app-server must be ws://host:port[/path]");
  }
  const port = Number(parsed.port);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    die("--app-server has an invalid port");
  }
  return {
    connectOptions: { host: parsed.hostname, port },
    requestPath: `${parsed.pathname || "/"}${parsed.search || ""}`,
  };
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
    return new WebSocketAppServerClient(
      target.connectOptions,
      redactAppServer(opts.appServer),
      { ...opts, requestPath: target.requestPath },
    );
  }
  return new AppServerClient(appServerCommand(opts), opts.project, opts);
}

function readPrivateEndpoint(file) {
  let endpoint;
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) die("--app-server-file must name a regular non-symlink file");
    if ((stat.mode & 0o077) !== 0) die("--app-server-file must not be group/world accessible");
    endpoint = fs.readFileSync(file, "utf8").trim();
  } catch (error) {
    die(`cannot read --app-server-file: ${error.message}`);
  }
  if (!endpoint) die("--app-server-file is empty");
  return endpoint;
}

function redactAppServer(endpoint) {
  if (!String(endpoint).startsWith("ws://")) return endpoint;
  try {
    const parsed = new URL(endpoint);
    return `ws://${parsed.host}/<capability>`;
  } catch (_) {
    return "ws://<invalid>";
  }
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
  const match = String(stdout || "").match(/\bmax_id=([0-9]+)/);
  return match ? Number(match[1]) : 0;
}

function wakeClientMessageId(stateKey, threadId, maxId) {
  const digest = crypto
    .createHash("sha256")
    .update(`${stateKey}\0${threadId}\0${maxId}`)
    .digest("hex");
  return `agmsg-wake-v1-${digest}`;
}

function atomicWritePrivate(file, contents) {
  const temporary = `${file}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`;
  let fd;
  try {
    fd = fs.openSync(temporary, "wx", 0o600);
    fs.writeFileSync(fd, contents, "utf8");
    fs.fsyncSync(fd);
    fs.closeSync(fd);
    fd = undefined;
    fs.renameSync(temporary, file);
    try {
      const dirFd = fs.openSync(path.dirname(file), "r");
      try { fs.fsyncSync(dirFd); } finally { fs.closeSync(dirFd); }
    } catch (_) {
      // Some filesystems do not support directory fsync. The file itself was
      // still fully synced before the atomic rename.
    }
  } catch (error) {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch (_) {}
    }
    try { fs.unlinkSync(temporary); } catch (_) {}
    throw error;
  }
}

function readKeyValueFile(file) {
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) return null;
    const result = {};
    for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
      const index = line.indexOf("=");
      if (index <= 0) continue;
      result[line.slice(0, index)] = line.slice(index + 1);
    }
    return result;
  } catch (_) {
    return null;
  }
}

function readProcessCommand(pid) {
  try {
    const proc = `/proc/${pid}/cmdline`;
    if (fs.existsSync(proc)) return fs.readFileSync(proc).toString("utf8").replace(/\0/g, " ").trim();
  } catch (_) {
    // Fall through to ps, which is available on macOS.
  }
  const result = spawnSync("ps", ["-p", String(pid), "-o", "command="], { encoding: "utf8" });
  return result.status === 0 ? String(result.stdout || "").trim() : "";
}

function sanitizeLogDetail(value) {
  return String(value == null ? "" : value)
    .replace(/[\r\n\t]+/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 240);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    usage();
    return;
  }

  const identity = resolveIdentity(opts);
  if (opts.resolveOnly) {
    console.log(`${identity.team}\t${identity.name}`);
    return;
  }

  let retryCount = 0;
  for (;;) {
    const bridge = new CodexBridge(opts, identity);
    try {
      await bridge.run();
      return;
    } catch (error) {
      if (error instanceof ExistingBridgeError) {
        console.error(`codex-bridge: ${error.message}`);
        return;
      }
      if (error instanceof TerminalBridgeError) {
        if (!opts.stateKey) throw error;
        bridge.writeHealth("terminal_thread_error", error.message);
        await bridge.shutdown({ preserveHealth: true });
        console.error(`codex-bridge: terminal configuration error: ${error.message}`);
        return;
      }
      if (!opts.stateKey) {
        await bridge.shutdown();
        throw error;
      }
      if (bridge.readyAt && Date.now() - bridge.readyAt >= 300000) retryCount = 0;
      retryCount += 1;
      const delayMs = Math.min(opts.retryBaseMs * (2 ** Math.min(retryCount - 1, 12)), opts.retryMaxMs);
      bridge.writeHealth("retrying_transient", `${sanitizeLogDetail(error.message)}; retry in ${delayMs}ms`);
      await bridge.shutdown({ preserveHealth: true });
      console.error(`codex-bridge: transient failure; retrying in ${delayMs}ms: ${sanitizeLogDetail(error.message)}`);
      await sleep(delayMs);
    }
  }
}

if (require.main === module) {
  main().catch((error) => die(error.message));
}

module.exports = { toPosixPath, WebSocketAppServerClient };
