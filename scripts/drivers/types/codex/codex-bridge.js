#!/usr/bin/env node
"use strict";

const { spawn, spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const path = require("path");
const readline = require("readline");

const SCRIPT_DIR = __dirname;                              // .../scripts/drivers/types/codex (codex siblings live here)
const SKILL_DIR = path.resolve(SCRIPT_DIR, "..", "..", "..", "..");    // skill root
const SCRIPTS_DIR = path.join(SKILL_DIR, "scripts");       // type-independent engine scripts (identities/inbox/send)
const RUN_DIR = path.join(SKILL_DIR, "run");

// Native Node must never resolve a bare `bash` to Windows' WSL launcher. The
// monitor wrapper exports the exact Git Bash it is running under; known Git for
// Windows install locations cover direct and test launches.
function nativeWindowsPath(value) {
  const match = /^\/([A-Za-z])\/(.*)$/.exec(value || "");
  return match ? `${match[1].toUpperCase()}:\\${match[2].replace(/\//g, "\\")}` : value;
}

function resolveBashBin(platform = process.platform, env = process.env) {
  const overrides = [env.GIT_BASH, env.AGMSG_BASH].filter(Boolean).map(nativeWindowsPath);
  if (platform !== "win32") return overrides[0] || "bash";
  const candidates = [
    ...overrides,
    env.ProgramFiles && path.join(env.ProgramFiles, "Git", "bin", "bash.exe"),
    env["ProgramFiles(x86)"] && path.join(env["ProgramFiles(x86)"], "Git", "bin", "bash.exe"),
    env.LOCALAPPDATA && path.join(env.LOCALAPPDATA, "Programs", "Git", "bin", "bash.exe"),
    "C:\\Program Files\\Git\\bin\\bash.exe",
  ].filter(Boolean);
  const found = candidates.find((candidate) => fs.existsSync(candidate));
  if (!found) die("Git Bash was not found; set GIT_BASH or AGMSG_BASH to Git\\bin\\bash.exe");
  return found;
}

const BASH_BIN = resolveBashBin();

function usage() {
  console.log(`Usage: codex-bridge.js --project <path> [--type codex] [--team <team>] [--name <agent>]

Beta Codex app-server bridge for agmsg pseudo-monitoring.

Options:
  --project <path>        Project path to monitor.
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
                          legacy CODEX_THREAD_ID; "loaded" requires exactly one
                          live thread from thread/loaded/list (see #170).
  --loaded-timeout <ms>   Max wait for a loaded thread to appear (default: 30000).
  --inline-inbox          Read inbox in the bridge and include message text in the turn input.
  --tui-lease <path>      Generation-specific TUI lease to validate before consumption.
  --bridge-lease <path>   Bridge lease file maintained by this process.
  --bound-generation <g>  TUI generation this bridge is allowed to deliver for.
  --monitor-state <path>  Generation-specific lifecycle state for diagnostics/re-resolution.
  --lease-timeout <sec>   Stop when the TUI lease is older than this (default: 15).
  --resolve-only          Print resolved team/name and exit.
  --help                  Show this help.

Set AGMSG_CODEX_APP_SERVER_CMD to override the app-server command for tests.`);
}

function die(message) {
  console.error(`codex-bridge: ${message}`);
  process.exit(1);
}

function appServerRequestError(payload) {
  const rawCode = payload && (payload.code || payload.type) || "request_error";
  const code = String(rawCode).replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 80) || "request_error";
  const error = new Error(`app-server request failed (${code})`);
  // Routing policy may need to classify a narrow "thread not found" response,
  // but the raw server message must never be emitted to background diagnostics.
  error.serverMessage = String(payload && payload.message || "");
  error.serverCode = code;
  return error;
}

function nativeCreationDate(pid) {
  if (process.platform !== "win32") return "";
  const result = spawnSync(
    "powershell.exe",
    ["-NoProfile", "-Command", `(Get-CimInstance Win32_Process -Filter \"ProcessId=${pid}\").CreationDate`],
    { encoding: "utf8", windowsHide: true },
  );
  return result.status === 0 ? (result.stdout || "").trim() : "";
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
    turnTimeout: Number(process.env.AGMSG_CODEX_BRIDGE_TURN_TIMEOUT || 60),
    leaseTimeout: Number(process.env.AGMSG_CODEX_LEASE_TIMEOUT || 15),
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
    } else if (arg === "--tui-lease") {
      opts.tuiLease = argv[++i];
    } else if (arg === "--bridge-lease") {
      opts.bridgeLease = argv[++i];
    } else if (arg === "--bound-generation") {
      opts.boundGeneration = argv[++i];
    } else if (arg === "--monitor-state") {
      opts.monitorState = argv[++i];
    } else if (arg === "--lease-timeout") {
      opts.leaseTimeout = Number(argv[++i]);
    } else {
      die(`unknown option: ${arg}`);
    }
  }

  if (opts.help) return opts;
  if (!opts.project) die("--project is required");
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
  if (!Number.isFinite(opts.leaseTimeout) || opts.leaseTimeout <= 0) {
    die("--lease-timeout must be a positive number");
  }
  if ((opts.tuiLease || opts.bridgeLease || opts.boundGeneration)
      && !(opts.tuiLease && opts.bridgeLease && opts.boundGeneration)) {
    die("--tui-lease, --bridge-lease, and --bound-generation must be provided together");
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

function resolveIdentity(opts) {
  const result = runScript("identities.sh", [toPosixPath(opts.project), opts.type]);
  if (result.status !== 0) {
    die(`identity resolution failed: ${(result.stderr || result.stdout).trim()}`);
  }

  const pairs = result.stdout
    .split(/\r?\n/)
    .filter((line) => line.length > 0)
    .map((line) => {
      const tab = line.indexOf("\t");
      return tab < 0 ? { team: "", name: "" } : { team: line.slice(0, tab), name: line.slice(tab + 1) };
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
    this.stderrNoted = false;
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

    this.child.stderr.on("data", () => {
      if (this.stderrNoted) return;
      this.stderrNoted = true;
      console.error("codex-bridge: app-server emitted stderr (payload suppressed)");
    });

    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on("line", (line) => this.handleLine(line));
  }

  on(method, handler) {
    this.handlers.set(method, handler);
  }

  handleLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch (error) {
      console.error("codex-bridge: ignoring a non-json app-server message");
      return;
    }

    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(appServerRequestError(message.error));
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
        // Peer-initiated close: leave intentionalStop false so the socket close
        // handler terminates this now-unusable bridge and the launcher reconnects.
        this.connected = false;
        if (this.socket && !this.socket.destroyed) this.socket.destroy();
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
      // App-server output is diagnostic transport data and may contain user or
      // model text. Keep background logs useful without copying that payload.
      console.error("codex-bridge: ignoring a non-json app-server message");
      return;
    }
    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(appServerRequestError(message.error));
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
    this.pendingWake = false;
    this.watchHandle = null;
    this.wakeCount = 0;
    this.lastWakeMaxId = 0;
    this.staleWakeCount = 0;
    this.watchFailureCount = 0;
    this.watchRearmTimer = null;
    this.inlineInboxText = "";
    this.fetchedMessageIds = [];
    this.deliveryInFlight = false;
    this.turnEndedWhileStarting = false;
    this.stopping = false;
    this.pidfile = path.join(RUN_DIR, `codex-bridge.${identity.team}.${identity.name}.pid`);
    this.metafile = path.join(RUN_DIR, `codex-bridge.${identity.team}.${identity.name}.meta`);
    this.bridgeGeneration = `${Date.now()}-${crypto.randomUUID()}`;
    this.ownerCreation = nativeCreationDate(process.pid);
    this.leaseCheckTimer = null;
    this.bridgeLeaseTimer = null;
    this.phase = "starting";
    this.lastErrorCode = "";
  }

  async run() {
    fs.mkdirSync(RUN_DIR, { recursive: true });
    this.ensureSingleInstance();
    this.writeMeta();
    // Publish the generation handshake before thread discovery/connect work;
    // the launcher polls once per second and must not mistake a slow-starting
    // but correctly bound bridge for an old generation.
    this.writeBridgeLease();
    this.installSignals();
    if (this.opts.tuiLease && !this.checkTuiLease()) {
      throw new Error("bound TUI lease is missing, stale, or incompatible");
    }
    this.startLeaseTimers();
    this.client.on("process/exited", this.clientHandler("process/exited", (params) => this.onProcessExited(params)));
    this.client.on("error", this.clientHandler("error", (params) => this.onServerError(params)));
    this.client.on("item/agentMessage/delta", this.clientHandler("item/agentMessage/delta", (params) => this.onAgentMessageDelta(params)));
    this.client.on("thread/status/changed", this.clientHandler("thread/status/changed", (params) => this.onThreadStatus(params)));
    this.client.on("turn/started", this.clientHandler("turn/started", () => {
      this.turnActive = true;
      this.threadIdle = false;
    }));
    this.client.on("turn/completed", this.clientHandler("turn/completed", (params) => this.onTurnCompleted(params)));
    this.client.on("turn/failed", this.clientHandler("turn/failed", () => this.onTurnCompleted()));

    this.client.start();
    await this.client.ready?.();
    this.phase = "connected";
    await this.initialize();
    await this.ensureThread();
    this.phase = "thread_bound";
    this.writeBridgeLease();
    await this.armWatch();
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
        "pid_domain=native",
        `project=${this.opts.project}`,
        `team=${this.identity.team}`,
        `name=${this.identity.name}`,
        `type=${this.opts.type}`,
      ].join("\n") + "\n",
    );
  }

  readLease(file) {
    try {
      const result = {};
      for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
        const index = line.indexOf("=");
        if (index > 0) result[line.slice(0, index)] = line.slice(index + 1);
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  checkTuiLease() {
    if (!this.opts.tuiLease) return true;
    const lease = this.readLease(this.opts.tuiLease);
    if (!lease || lease.format_version !== "1" || lease.owner_kind !== "tui"
        || lease.generation !== this.opts.boundGeneration) return false;
    if (!/^\d+$/.test(lease.updated_at || "")) return false;
    const age = Math.floor(Date.now() / 1000) - Number(lease.updated_at);
    return age >= 0 && age <= this.opts.leaseTimeout;
  }

  atomicWrite(file, content) {
    const tmp = `${file}.tmp.${process.pid}.${crypto.randomBytes(6).toString("hex")}`;
    fs.writeFileSync(tmp, content);
    fs.renameSync(tmp, file);
  }

  writeMonitorState(phase, detail = "") {
    if (!this.opts.monitorState) return;
    const safePhase = String(phase).replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 80);
    const safeDetail = String(detail).replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 120);
    this.atomicWrite(this.opts.monitorState, [
      "format_version=1",
      `phase=${safePhase}`,
      `detail=${safeDetail}`,
      `updated_at=${Math.floor(Date.now() / 1000)}`,
      "",
    ].join("\n"));
  }

  writeBridgeLease() {
    if (!this.opts.bridgeLease) return;
    this.atomicWrite(this.opts.bridgeLease, [
      "format_version=1",
      "owner_kind=bridge",
      "pid_domain=native",
      `owner_winpid=${process.pid}`,
      `owner_creation=${this.ownerCreation}`,
      `generation=${this.bridgeGeneration}`,
      `bound_thread_id=${this.threadId || this.opts.threadId || ""}`,
      `bound_generation=${this.opts.boundGeneration}`,
      `project=${this.opts.project}`,
      `app_server=${this.opts.appServer || ""}`,
      `phase=${this.phase}`,
      `last_error_code=${this.lastErrorCode}`,
      `updated_at=${Math.floor(Date.now() / 1000)}`,
      "",
    ].join("\n"));
  }

  startLeaseTimers() {
    if (!this.opts.tuiLease) return;
    this.leaseCheckTimer = setInterval(() => {
      if (this.stopping || this.checkTuiLease()) return;
      console.error("codex-bridge: bound TUI lease expired; stopping before consuming more messages");
      this.shutdown().finally(() => process.exit(0));
    }, 1000);
    this.bridgeLeaseTimer = setInterval(() => {
      if (!this.stopping) this.writeBridgeLease();
    }, 1000);
    this.leaseCheckTimer.unref?.();
    this.bridgeLeaseTimer.unref?.();
  }

  clearLeaseTimers() {
    if (this.leaseCheckTimer) clearInterval(this.leaseCheckTimer);
    if (this.bridgeLeaseTimer) clearInterval(this.bridgeLeaseTimer);
    this.leaseCheckTimer = null;
    this.bridgeLeaseTimer = null;
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
    // Before SessionStart publishes its stdin session_id, ask the app-server
    // which thread the live TUI has loaded. This fallback is safe only when
    // exactly one thread is present. See #170.
    const deadline = Date.now() + (this.opts.loadedTimeout || 30000);
    for (;;) {
      const response = await this.client.request("thread/loaded/list", {});
      const ids = response && Array.isArray(response.data) ? response.data : [];
      if (ids.length === 1) return ids[0];
      if (ids.length > 1) {
        this.writeMonitorState("thread_ambiguous", `loaded_count_${ids.length}`);
        die(`thread route is ambiguous: ${ids.length} threads are loaded; refusing to choose one`);
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
      try {
        const response = await this.client.request("thread/resume", {
          threadId: this.threadId,
          cwd: this.opts.project,
          runtimeWorkspaceRoots: [this.opts.project],
          excludeTurns: true,
        });
        if (!response.thread || response.thread.id !== this.threadId) {
          die("thread/resume did not return the requested thread id");
        }
        const type = response.thread.status && response.thread.status.type;
        this.threadIdle = type !== "active";
        this.turnActive = type === "active";
        console.error(`codex-bridge: resumed thread ${this.threadId}`);
      } catch (err) {
        // Codex 0.142+ writes no rollout for --remote sessions, so thread/resume
        // can fail for a thread that is nonetheless live in the app-server;
        // turn/start works with just the threadId, so continue as idle. Swallow
        // only the narrow "thread/rollout is absent" error class.
        const resumable =
          /(thread|rollout)[\s\S]{0,80}\b(not found|no such|does not exist|unknown|missing)\b|\b(not found|no such|does not exist|unknown|missing)\b[\s\S]{0,80}(thread|rollout)|\bno[\s\S]{0,30}rollout\b/i
            .test(err.serverMessage || err.message || "");
        if (!resumable) throw err;
        const loaded = await this.client.request("thread/loaded/list", {});
        const loadedIds = loaded && Array.isArray(loaded.data) ? loaded.data : [];
        if (!loadedIds.includes(this.threadId)) {
          this.writeMonitorState("route_invalid", "requested_thread_not_loaded");
          throw new Error(`requested thread ${this.threadId} is not loaded; refusing stale routing`);
        }
        console.error(
          `codex-bridge: thread/resume failed (${err.message}), but the exact thread is loaded; proceeding`,
        );
        this.threadIdle = true;
        this.turnActive = false;
      }
      return;
    }
    const response = await this.client.request("thread/start", {
      cwd: this.opts.project,
      runtimeWorkspaceRoots: [this.opts.project],
      ephemeral: false,
    });
    this.threadId = response.thread && response.thread.id;
    if (!this.threadId) die("thread/start did not return a thread id");
    console.error(`codex-bridge: started thread ${this.threadId}`);
  }

  async armWatch() {
    this.clearWatchRearmTimer();
    if (this.stopping || this.watchHandle) return;
    if (!this.checkTuiLease()) {
      await this.shutdown();
      return;
    }
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
      "--team",
      this.identity.team,
      "--name",
      this.identity.name,
      "--timeout",
      String(this.opts.timeout),
      "--interval",
      String(this.opts.interval),
    ];
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
    this.phase = "watch_armed";
    this.writeBridgeLease();
  }

  async onProcessExited(params) {
    if (this.stopping) return;
    if (params.processHandle !== this.watchHandle) return;
    this.watchHandle = null;

    if (params.exitCode === 0) {
      this.watchFailureCount = 0;
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
      const rawCode = params.turn.error.code || params.turn.error.type || "turn_error";
      const code = String(rawCode).replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 80) || "turn_error";
      this.lastErrorCode = code;
      this.writeBridgeLease();
      console.error(`codex-bridge: turn completed with error (${code})`);
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
    if (this.deliveryInFlight) {
      this.turnEndedWhileStarting = true;
      return;
    }
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
    if (this.stopping || !this.pendingWake || this.turnActive || !this.threadIdle) return;
    if (!this.checkTuiLease()) {
      await this.shutdown();
      return;
    }
    if (this.opts.inlineInbox) {
      const fetched = this.fetchUnreadForPrompt();
      this.inlineInboxText = fetched.text;
      this.fetchedMessageIds = fetched.ids;
      if (!this.inlineInboxText.trim()) {
        console.error("codex-bridge: pending wake had no inbox output; re-arming");
        this.pendingWake = false;
        await this.armWatch();
        return;
      }
    }
    if (!this.checkTuiLease()) {
      await this.shutdown();
      return;
    }
    const prompt = this.buildPrompt();
    // Consume the wake before submitting the turn. The app-server can emit an
    // idle/completed notification before it returns the turn/start JSON-RPC
    // response. Leaving pendingWake set during that window makes onTurnEnded()
    // submit the same wake a second time and can strand the bridge awaiting an
    // acknowledgement that never arrives.
    this.pendingWake = false;
    this.turnActive = true;
    this.threadIdle = false;
    this.deliveryInFlight = true;
    this.phase = "delivering";
    this.writeBridgeLease();
    this.turnEndedWhileStarting = false;
    // Start the watchdog when the request is submitted, not after its ACK. A
    // real app-server may accept and execute turn/start but lose the response;
    // that ambiguous timeout must not leave a live bridge permanently deaf.
    this.startTurnWatchdog();
    try {
      await this.client.request("turn/start", {
        threadId: this.threadId,
        input: [{ type: "text", text: prompt, text_elements: [] }],
        cwd: this.opts.project,
        runtimeWorkspaceRoots: [this.opts.project],
      });
      console.error(`codex-bridge: started turn on thread ${this.threadId}`);
      const marked = this.markFetchedRead();
      if (!marked) this.lastWakeMaxId = 0;
      this.deliveryInFlight = false;
      this.fetchedMessageIds = [];
      if (this.turnEndedWhileStarting) {
        this.turnEndedWhileStarting = false;
        await this.onTurnEnded();
      }
    } catch (error) {
      if (/app-server request 'turn\/start' timed out/.test(error.message || "")) {
        console.error(
          `codex-bridge: turn/start acknowledgement timed out; assuming the turn was accepted on thread ${this.threadId}`,
        );
        this.deliveryInFlight = false;
        this.fetchedMessageIds = [];
        this.lastWakeMaxId = 0;
        if (this.turnEndedWhileStarting) {
          this.turnEndedWhileStarting = false;
          await this.onTurnEnded();
          return;
        }
        // A completion/idle notification may already have re-armed the watch.
        // Otherwise the watchdog started above will do so. With an explicitly
        // disabled watchdog, recover immediately rather than staying deaf.
        if (!this.opts.turnTimeout && this.turnActive) await this.onTurnEnded();
        return;
      }
      this.deliveryInFlight = false;
      this.fetchedMessageIds = [];
      this.pendingWake = true;
      this.turnActive = false;
      this.threadIdle = true;
      this.clearTurnWatchdog();
      // A rejected turn/start is not proof that the hook-supplied thread id is
      // stale. Preserve the exact route so the launcher can restart this bridge
      // and retry the unread rows. ensureThread() performs the narrower loaded-
      // thread validation and publishes route_invalid only when it has evidence.
      this.phase = "delivery_failed";
      this.lastErrorCode = "turn_start_failed";
      this.writeBridgeLease();
      this.writeMonitorState("delivery_failed", "bridge_restart_retry");
      throw error;
    }
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
    const rawCode = params.code || (params.error && params.error.code) || "server_error";
    this.lastErrorCode = String(rawCode).replace(/[^A-Za-z0-9_.-]/g, "_").slice(0, 80) || "server_error";
    this.writeBridgeLease();
    console.error(`codex-bridge: server error (${this.lastErrorCode})`);
  }

  onAgentMessageDelta(params) {
    if (params.threadId !== this.threadId) return;
    // The bridge is background infrastructure. Do not copy model output (which
    // may quote an inbox message) into diagnostic logs; the TUI already renders
    // the turn. Health logs contain only fixed phases/error codes.
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

  fetchUnreadForPrompt() {
    const result = spawnSync(BASH_BIN, [path.join(SCRIPTS_DIR, "peek-inbox.sh"), this.identity.team, this.identity.name], {
      cwd: this.opts.project,
      encoding: "utf8",
    });
    if (result.error) {
      console.error(`codex-bridge: peek-inbox.sh failed: ${result.error.message}`);
      return { text: "", ids: [] };
    }
    if (result.status !== 0) {
      console.error(`codex-bridge: peek-inbox.sh exited ${result.status}: ${(result.stderr || "").trim()}`);
      return { text: "", ids: [] };
    }
    try {
      const payload = JSON.parse(result.stdout || "{}");
      if (!Array.isArray(payload.rows)) throw new Error("rows is not an array");
      const rows = payload.rows.map((row) => {
        if (!Number.isSafeInteger(row.id) || row.id < 0) throw new Error("invalid message id");
        return row;
      });
      return {
        ids: rows.map((row) => row.id),
        text: rows.map((row) => `  [${row.ts}] ${row.from}: ${row.body}`).join("\n"),
      };
    } catch (error) {
      console.error(`codex-bridge: invalid peek-inbox JSON: ${error.message}`);
      return { text: "", ids: [] };
    }
  }

  markFetchedRead() {
    if (!this.opts.inlineInbox || this.fetchedMessageIds.length === 0) return true;
    const result = spawnSync(
      BASH_BIN,
      [path.join(SCRIPTS_DIR, "mark-read.sh"), this.identity.team, this.identity.name],
      { cwd: this.opts.project, encoding: "utf8", input: `${this.fetchedMessageIds.join("\n")}\n` },
    );
    if (result.error || result.status !== 0) {
      const detail = result.error ? result.error.message : (result.stderr || "").trim();
      console.error(`codex-bridge: mark-read.sh failed; leaving messages unread: ${detail}`);
      return false;
    }
    return true;
  }

  async shutdown() {
    if (this.stopping) return;
    this.stopping = true;
    this.clearLeaseTimers();
    this.clearWatchRearmTimer();
    this.clearTurnWatchdog();
    if (this.watchHandle) {
      try {
        await Promise.race([
          this.client.request("process/kill", { processHandle: this.watchHandle }),
          new Promise((resolve) => setTimeout(resolve, 1000)),
        ]);
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
    if (this.opts.bridgeLease) {
      const lease = this.readLease(this.opts.bridgeLease);
      if (lease && lease.generation === this.bridgeGeneration) {
        try {
          if (fs.existsSync(this.opts.bridgeLease)) fs.unlinkSync(this.opts.bridgeLease);
        } catch (_) {
          // Best-effort compare-and-delete cleanup.
        }
      }
    }
  }

  ensureSingleInstance() {
    const existing = readPid(this.pidfile);
    if (!existing) return;
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
    if (maxId <= 0 || this.lastWakeMaxId !== maxId) {
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
  const match = String(stdout || "").match(/\bmax_id=([0-9]+)/);
  return match ? Number(match[1]) : 0;
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

  const bridge = new CodexBridge(opts, identity);
  await bridge.run();
}

if (require.main === module) {
  main().catch((error) => die(error.message));
}

module.exports = { CodexBridge, WebSocketAppServerClient, resolveBashBin, toPosixPath };
