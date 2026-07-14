#!/usr/bin/env node
"use strict";

// Codex Desktop owns one app-server connection. agmsg needs a second client so
// it can inject a turn into that same visible thread, but codex app-server's
// websocket listener accepts only one active frontend. This relay keeps one
// stdio app-server upstream and multiplexes Desktop plus agmsg bridge clients.
// It never reads agmsg mail; the bridge only starts a visible Codex turn.

const { spawn } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const path = require("path");
const readline = require("readline");

const SCRIPT_DIR = __dirname;
const SKILL_DIR = path.resolve(SCRIPT_DIR, "..", "..", "..", "..");
const RUN_DIR = path.resolve(process.env.AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR || path.join(SKILL_DIR, "run"));
const DEFAULT_HOST = "127.0.0.1";
const DEFAULT_PORT = 49643;
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

function usage() {
  console.log(`Usage: codex-desktop-relay.js [options]

Options:
  --host <host>       Loopback host (default: ${DEFAULT_HOST}).
  --port <port>       Listen port; 0 selects a free port (default: ${DEFAULT_PORT}).
  --codex <path>      Codex CLI that supplies app-server.
  --desktop-token-file <path>
                      0600 capability used only by Codex Desktop.
  --bridge-token-file <path>
                      0600 capability used only by agmsg bridges.
  --health <path>     Health state file.
  --port-file <path>  File that receives the actual listen port.
  --pid-file <path>   File that receives the relay pid.
  --parent-pid <pid>  Supervising runner pid; relay stops if it disappears.
  --help              Show this help.`);
}

function die(message) {
  console.error(`codex-desktop-relay: ${message}`);
  // 64 distinguishes permanent invocation/configuration failures from an
  // app-server crash. The LaunchAgent runner retries only transient exits.
  process.exit(64);
}

function parseArgs(argv) {
  const opts = {
    host: process.env.AGMSG_CODEX_DESKTOP_RELAY_HOST || DEFAULT_HOST,
    port: Number(process.env.AGMSG_CODEX_DESKTOP_RELAY_PORT || DEFAULT_PORT),
    codex: process.env.AGMSG_CODEX_DESKTOP_RELAY_CODEX || findCodex(),
    desktopTokenFile: process.env.AGMSG_CODEX_DESKTOP_RELAY_DESKTOP_TOKEN_FILE || "",
    bridgeTokenFile: process.env.AGMSG_CODEX_DESKTOP_RELAY_BRIDGE_TOKEN_FILE || "",
    health: path.join(RUN_DIR, "codex-desktop-relay.health"),
    portFile: path.join(RUN_DIR, "codex-desktop-relay.port"),
    pidFile: path.join(RUN_DIR, "codex-desktop-relay.pid"),
    parentPid: Number(process.env.AGMSG_CODEX_DESKTOP_RELAY_PARENT_PID || 0),
    shutdownGraceMs: Number(process.env.AGMSG_CODEX_DESKTOP_RELAY_SHUTDOWN_GRACE_MS || 5000),
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") opts.help = true;
    else if (arg === "--host") opts.host = argv[++index];
    else if (arg === "--port") opts.port = Number(argv[++index]);
    else if (arg === "--codex") opts.codex = argv[++index];
    else if (arg === "--desktop-token-file") opts.desktopTokenFile = path.resolve(argv[++index]);
    else if (arg === "--bridge-token-file") opts.bridgeTokenFile = path.resolve(argv[++index]);
    else if (arg === "--health") opts.health = path.resolve(argv[++index]);
    else if (arg === "--port-file") opts.portFile = path.resolve(argv[++index]);
    else if (arg === "--pid-file") opts.pidFile = path.resolve(argv[++index]);
    else if (arg === "--parent-pid") opts.parentPid = Number(argv[++index]);
    else die(`unknown option: ${arg}`);
  }
  if (opts.help) return opts;
  if (!Number.isInteger(opts.port) || opts.port < 0 || opts.port > 65535) {
    die("--port must be an integer from 0 to 65535");
  }
  if (!Number.isFinite(opts.shutdownGraceMs) || opts.shutdownGraceMs < 0) {
    die("shutdown grace must be a non-negative number");
  }
  if (!Number.isSafeInteger(opts.parentPid) || opts.parentPid < 0 || opts.parentPid === process.pid) {
    die("--parent-pid must be a positive supervising pid");
  }
  if (opts.host !== "127.0.0.1" && opts.host !== "localhost" && opts.host !== "::1") {
    die("--host must be loopback");
  }
  if (!opts.codex) die("Codex CLI not found; pass --codex");
  if (!opts.desktopTokenFile || !opts.bridgeTokenFile) {
    die("--desktop-token-file and --bridge-token-file are required");
  }
  opts.desktopToken = readCapability(opts.desktopTokenFile, "desktop");
  opts.bridgeToken = readCapability(opts.bridgeTokenFile, "bridge");
  if (opts.desktopToken === opts.bridgeToken) die("desktop and bridge capabilities must differ");
  return opts;
}

function readCapability(file, role) {
  let value = "";
  try {
    const stat = fs.lstatSync(file);
    if (!stat.isFile() || stat.isSymbolicLink()) die(`${role} capability must be a regular non-symlink file`);
    const mode = stat.mode & 0o777;
    if ((mode & 0o077) !== 0) die(`${role} capability file must not be group/world accessible`);
    value = fs.readFileSync(file, "utf8").trim();
  } catch (error) {
    die(`cannot read ${role} capability file: ${error.message}`);
  }
  if (!/^[a-f0-9]{64}$/.test(value)) die(`${role} capability must be 32 random bytes encoded as hex`);
  return value;
}

function readBridgeBinding(token) {
  let names = [];
  try {
    names = fs.readdirSync(RUN_DIR).filter((name) => /^codex-bridge\..+\.binding$/.test(name));
  } catch (_) {
    return null;
  }
  for (const name of names) {
    try {
      const file = path.join(RUN_DIR, name);
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) continue;
      const values = new Map();
      for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
        const index = line.indexOf("=");
        if (index > 0) values.set(line.slice(0, index), line.slice(index + 1));
      }
      const storedToken = values.get("token") || "";
      if (!/^[a-f0-9]{64}$/.test(storedToken) || storedToken.length !== token.length) continue;
      if (!crypto.timingSafeEqual(Buffer.from(storedToken), Buffer.from(token))) continue;
      const binding = {
        token: storedToken,
        project: values.get("project") || "",
        type: values.get("type") || "",
        team: values.get("team") || "",
        name: values.get("name") || "",
        threadId: values.get("thread") || "",
        stateKey: values.get("state_key") || "",
      };
      if (!binding.project || binding.type !== "codex" || !binding.team || !binding.name
          || !binding.threadId || !/^[A-Za-z0-9._%-]+$/.test(binding.stateKey)) continue;
      binding.project = fs.realpathSync(binding.project);
      return binding;
    } catch (_) {
      // Ignore malformed or concurrently replaced bindings.
    }
  }
  return null;
}

function hasOnlyKeys(value, allowed) {
  return Object.keys(value).every((key) => allowed.has(key));
}

function sameRuntimeRoots(value, project) {
  return Array.isArray(value) && value.length === 1 && String(value[0]) === project;
}

function resolvesToProject(value, project) {
  try {
    return fs.realpathSync(String(value || "")) === project;
  } catch (_) {
    return false;
  }
}

function capabilityEquals(actual, expected) {
  const left = Buffer.from(String(actual || ""));
  const right = Buffer.from(String(expected || ""));
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function containsClientMessageId(value, expected) {
  if (!value || typeof value !== "object") return false;
  if (String(value.clientId || "") === expected) return true;
  if (Array.isArray(value)) return value.some((entry) => containsClientMessageId(entry, expected));
  return Object.values(value).some((entry) => containsClientMessageId(entry, expected));
}

function expectedWakeClientId(binding, maxId) {
  const digest = crypto.createHash("sha256")
    .update(`${binding.stateKey}\0${binding.threadId}\0${maxId}`)
    .digest("hex");
  return `agmsg-wake-v1-${digest}`;
}

function relayWakeStateFile(binding) {
  return path.join(RUN_DIR, `codex-bridge.${binding.stateKey}.relay-wake.json`);
}

function readRelayWakeState(binding) {
  const file = relayWakeStateFile(binding);
  if (!fs.existsSync(file)) return null;
  const stat = fs.lstatSync(file);
  if (!stat.isFile() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0) {
    throw new Error("relay wake state is not a private regular file");
  }
  const state = JSON.parse(fs.readFileSync(file, "utf8"));
  const expectedThreadHash = crypto.createHash("sha256").update(binding.threadId).digest("hex");
  if (
    state.version !== 1
    || state.stateKey !== binding.stateKey
    || state.threadHash !== expectedThreadHash
    || !Number.isSafeInteger(state.maxId)
    || state.maxId <= 0
    || !["dispatching", "accepted"].includes(state.phase)
    || state.clientUserMessageId !== expectedWakeClientId(binding, state.maxId)
  ) {
    throw new Error("relay wake state failed validation");
  }
  return state;
}

function writeRelayWakeState(binding, maxId, phase, clientUserMessageId) {
  const value = {
    version: 1,
    stateKey: binding.stateKey,
    threadHash: crypto.createHash("sha256").update(binding.threadId).digest("hex"),
    maxId,
    phase,
    clientUserMessageId,
    updatedAt: new Date().toISOString(),
  };
  atomicWriteDurable(relayWakeStateFile(binding), `${JSON.stringify(value)}\n`);
}

function buildWakePrompt(binding) {
  const inbox = path.join(SKILL_DIR, "scripts", "inbox.sh");
  const send = path.join(SKILL_DIR, "scripts", "send.sh");
  return [
    `agmsg has unread messages for ${binding.team}/${binding.name}.`,
    "The bridge did not read or acknowledge their contents.",
    "Continue the conversation in this same Codex thread. If a reply is needed, send it with:",
    `${send} ${binding.team} ${binding.name} <to> <message>`,
    "",
    "Autonomous handling contract:",
    `1. Your first tool call must be this official inbox command: ${inbox} ${binding.team} ${binding.name}`,
    "2. Do not read the agmsg database or team files directly. The resumed Codex task alone owns message reading and acknowledgement through inbox.sh.",
    "3. For a substantive request, new evidence, correction, or blocker, continue the in-scope work through verification and send an evidence-backed reply with the official send.sh command above. Do not stop after an ACK or status-only reply.",
    "4. Do not reply to ACK-only, thanks-only, or status-only mail that contains no new request, evidence, correction, or blocker.",
    "5. Preserve existing approval, production, customer-data, credential, and destructive-action boundaries.",
    "",
    "Visible UI requirement:",
    '1. Before the inbox tool call, post "agmsg受信を検知しました。内容を確認します。" in the visible Codex thread.',
    '2. Immediately after inbox.sh and before any other tool call, post a Japanese update starting with "agmsg受信:" and include sender, received body or safe summary, planned action, and whether you will reply.',
    "3. Keep substantive work in the visible thread and post short progress updates before major actions.",
    "4. Finish with sender, instruction, action, reply target and summary, remaining blocker, and next step.",
    "5. If no reply is sent, state why. ACK-only mail still requires a visible receipt notice.",
    "6. Do not treat inbox consumption, DB writes, monitor delivery, send.sh, or process exit as complete unless the handling result is visible in this task.",
  ].join("\n");
}

function findCodex() {
  const candidates = [
    "/Applications/ChatGPT.app/Contents/Resources/codex",
    "/Applications/Codex.app/Contents/Resources/codex",
    path.join(process.env.HOME || "", ".codex", "packages", "standalone", "current", "codex"),
  ];
  return candidates.find((candidate) => candidate && fs.existsSync(candidate)) || "codex";
}

function atomicWrite(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, contents, { mode: 0o600 });
  fs.renameSync(temporary, file);
}

function atomicWriteDurable(file, contents) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
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
      // The file itself is durable even where directory fsync is unsupported.
    }
  } catch (error) {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch (_) {}
    }
    try { fs.unlinkSync(temporary); } catch (_) {}
    throw error;
  }
}

function encodeFrame(opcode, payload) {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(payload || "", "utf8");
  let header;
  if (body.length < 126) {
    header = Buffer.from([0x80 | opcode, body.length]);
  } else if (body.length <= 0xffff) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(body.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeUInt32BE(0, 2);
    header.writeUInt32BE(body.length, 6);
  }
  return Buffer.concat([header, body]);
}

class RelayClient {
  constructor(relay, socket, id) {
    this.relay = relay;
    this.socket = socket;
    this.id = id;
    this.buffer = Buffer.alloc(0);
    this.handshakeComplete = false;
    this.closed = false;
    this.initialized = false;
    this.initializeResponseSent = false;
    this.isBridge = false;
    this.role = "";
    this.binding = null;
    this.threadId = "";
    this.projectRoot = "";
    this.fragments = [];
    this.fragmentOpcode = 0;
    socket.on("data", (chunk) => this.onData(chunk));
    socket.on("error", (error) => relay.log(`client ${id} socket error: ${error.message}`));
    socket.on("close", () => this.close());
  }

  onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk]);
    if (!this.handshakeComplete && !this.handleHandshake()) return;
    this.handleFrames();
  }

  handleHandshake() {
    const end = this.buffer.indexOf("\r\n\r\n");
    if (end === -1) {
      if (this.buffer.length > 64 * 1024) this.rejectHandshake(431, "Request Header Fields Too Large");
      return false;
    }
    const header = this.buffer.slice(0, end).toString("utf8");
    this.buffer = this.buffer.slice(end + 4);
    const lines = header.split(/\r\n/);
    const request = /^(GET)\s+([^\s]+)\s+HTTP\/1\.[01]$/.exec(lines.shift() || "");
    const headers = new Map();
    for (const line of lines) {
      const colon = line.indexOf(":");
      if (colon === -1) continue;
      headers.set(line.slice(0, colon).trim().toLowerCase(), line.slice(colon + 1).trim());
    }
    const key = headers.get("sec-websocket-key") || "";
    if (!request || !key || !/websocket/i.test(headers.get("upgrade") || "")) {
      this.rejectHandshake(400, "Bad Request");
      return false;
    }
    const authentication = this.relay.authenticatePath(request[2]);
    if (!authentication) {
      this.rejectHandshake(403, "Forbidden");
      return false;
    }
    this.role = authentication.role;
    this.binding = authentication.binding || null;
    const accept = crypto.createHash("sha1").update(`${key}${WS_GUID}`).digest("base64");
    this.socket.write([
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      `Sec-WebSocket-Accept: ${accept}`,
      "",
      "",
    ].join("\r\n"));
    this.handshakeComplete = true;
    this.relay.onClientOpen(this);
    return true;
  }

  rejectHandshake(status, text) {
    if (!this.socket.destroyed) this.socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\n\r\n`);
  }

  handleFrames() {
    while (this.buffer.length >= 2) {
      const first = this.buffer[0];
      const second = this.buffer[1];
      const final = (first & 0x80) !== 0;
      const opcode = first & 0x0f;
      const masked = (second & 0x80) !== 0;
      let length = second & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        const high = this.buffer.readUInt32BE(2);
        const low = this.buffer.readUInt32BE(6);
        if (high !== 0) return this.protocolError("frame too large");
        length = low;
        offset = 10;
      }
      if (!masked) return this.protocolError("client frame was not masked");
      if (this.buffer.length < offset + 4 + length) return;
      const mask = this.buffer.slice(offset, offset + 4);
      offset += 4;
      const payload = Buffer.from(this.buffer.slice(offset, offset + length));
      for (let index = 0; index < payload.length; index += 1) payload[index] ^= mask[index % 4];
      this.buffer = this.buffer.slice(offset + length);

      if (opcode === 0x8) {
        this.sendFrame(0x8, payload);
        this.socket.end();
        return;
      }
      if (opcode === 0x9) {
        this.sendFrame(0x0a, payload);
        continue;
      }
      if (opcode === 0x0a) continue;
      if (opcode === 0x1 && final) {
        this.relay.onClientText(this, payload.toString("utf8"));
        continue;
      }
      if (opcode === 0x1 && !final) {
        this.fragmentOpcode = opcode;
        this.fragments = [payload];
        continue;
      }
      if (opcode === 0x0 && this.fragmentOpcode) {
        this.fragments.push(payload);
        if (final) {
          const full = Buffer.concat(this.fragments);
          this.fragments = [];
          this.fragmentOpcode = 0;
          this.relay.onClientText(this, full.toString("utf8"));
        }
        continue;
      }
      return this.protocolError(`unsupported opcode ${opcode}`);
    }
  }

  protocolError(message) {
    this.relay.log(`client ${this.id} protocol error: ${message}`);
    this.sendFrame(0x8, Buffer.from([0x03, 0xea]));
    this.socket.destroy();
  }

  sendJson(message) {
    if (!this.closed && this.handshakeComplete && !this.socket.destroyed) {
      this.sendFrame(0x1, Buffer.from(JSON.stringify(message), "utf8"));
    }
  }

  sendFrame(opcode, payload) {
    if (!this.socket.destroyed) this.socket.write(encodeFrame(opcode, payload));
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    this.relay.onClientClose(this);
  }
}

class CodexDesktopRelay {
  constructor(opts) {
    this.opts = opts;
    this.clients = new Set();
    this.primary = null;
    this.nextClientId = 1;
    this.nextUpstreamId = 1;
    this.nextServerRequestId = 1;
    this.pending = new Map();
    this.serverRequests = new Map();
    this.initializeWaiters = [];
    this.initializeRequestId = null;
    this.initializeResult = null;
    this.initializeError = null;
    this.upstreamInitializedNotificationSent = false;
    this.processOwners = new Map();
    this.wakeInflight = new Map();
    this.server = null;
    this.child = null;
    this.upstreamPgid = 0;
    this.actualPort = 0;
    this.parentTimer = null;
    this.shuttingDown = false;
  }

  run() {
    this.server = net.createServer((socket) => {
      socket.setNoDelay(true);
      this.clients.add(new RelayClient(this, socket, this.nextClientId++));
      this.writeHealth("listening");
    });
    this.server.on("error", (error) => {
      this.log(`listen failed: ${error.message}`);
      this.shutdown(1);
    });
    this.server.listen(this.opts.port, this.opts.host, () => {
      const address = this.server.address();
      this.actualPort = typeof address === "object" && address ? address.port : this.opts.port;
      this.startUpstream();
      atomicWrite(this.opts.portFile, `${this.actualPort}\n`);
      atomicWrite(this.opts.pidFile, `${process.pid}\n`);
      this.writeHealth("listening");
      this.log(`listening on ws://${this.opts.host}:${this.actualPort}`);
    });
    const stop = () => this.shutdown(0);
    process.on("SIGINT", stop);
    process.on("SIGTERM", stop);
    process.on("SIGHUP", stop);
    this.monitorParent();
  }

  monitorParent() {
    if (!this.opts.parentPid) return;
    const check = () => {
      try {
        process.kill(this.opts.parentPid, 0);
      } catch (error) {
        if (error && error.code === "EPERM") return;
        this.log("supervising runner disappeared; stopping relay and app-server");
        this.shutdown(1);
      }
    };
    check();
    if (!this.shuttingDown) this.parentTimer = setInterval(check, 250);
  }

  authenticatePath(requestPath) {
    const desktop = /^\/desktop\/([a-f0-9]{64})$/.exec(requestPath);
    if (desktop && capabilityEquals(desktop[1], this.opts.desktopToken)) return { role: "desktop" };
    const match = /^\/bridge\/([a-f0-9]{64})\/([a-f0-9]{64})$/.exec(requestPath);
    if (!match) return null;
    if (!capabilityEquals(match[1], this.opts.bridgeToken)) return null;
    const binding = readBridgeBinding(match[2]);
    if (!binding) return null;
    const alreadyConnected = [...this.clients].some(
      (client) => client.role === "bridge" && !client.closed && client.binding
        && client.binding.stateKey === binding.stateKey,
    );
    if (alreadyConnected) return null;
    return { role: "bridge", binding };
  }

  startUpstream() {
    const args = ["-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"];
    const childEnv = { ...process.env };
    delete childEnv.CODEX_APP_SERVER_WS_URL;
    this.child = spawn(this.opts.codex, args, {
      cwd: process.env.HOME || process.cwd(),
      env: {
        ...childEnv,
        CODEX_INTERNAL_ORIGINATOR_OVERRIDE: "Codex Desktop",
        LOG_FORMAT: "json",
        RUST_LOG: process.env.RUST_LOG || "warn",
      },
      stdio: ["pipe", "pipe", "pipe"],
      detached: process.platform !== "win32",
    });
    this.upstreamPgid = this.child.pid || 0;
    this.child.once("error", (error) => {
      this.log(`app-server start failed: ${error.message}`);
      this.shutdown(1);
    });
    this.child.once("exit", (code, signal) => {
      if (this.shuttingDown) return;
      this.log(`app-server exited (${code ?? signal}); relay will restart`);
      this.shutdown(1);
    });
    // Never mirror app-server stderr into the relay lifecycle log; it may
    // include visible conversation content.
    this.child.stderr.on("data", () => {});
    readline.createInterface({ input: this.child.stdout }).on("line", (line) => this.onUpstreamLine(line));
  }

  onClientOpen(client) {
    this.log(`${client.role} client ${client.id} connected`);
    this.writeHealth(this.isReady() ? "ready" : "waiting_for_desktop");
  }

  onClientClose(client) {
    this.clients.delete(client);
    this.initializeWaiters = this.initializeWaiters.filter((waiter) => waiter.client !== client);
    for (const [id, pending] of this.pending) {
      if (pending.client !== client) continue;
      this.pending.delete(id);
      if (pending.wakeDispatch && pending.wakeDispatch.inflightKey) {
        // The durable relay state, not this in-memory map, owns ambiguity after
        // turn/start. A read-stage disconnect has not started a turn and is
        // therefore safe to retry after the bridge reconnects.
        this.wakeInflight.delete(pending.wakeDispatch.inflightKey);
      }
    }
    for (const [id, request] of this.serverRequests) {
      if (request.client !== client) continue;
      this.serverRequests.delete(id);
      this.sendUpstream({
        jsonrpc: "2.0",
        id: request.upstreamId,
        error: { code: -32000, message: "Visible Codex Desktop client disconnected" },
      });
    }
    for (const [handle, owner] of this.processOwners) {
      if (owner.client !== client) continue;
      this.processOwners.delete(handle);
      const upstreamId = this.nextUpstreamId++;
      this.pending.set(upstreamId, { internal: true, upstreamHandle: handle });
      this.sendUpstream({
        jsonrpc: "2.0",
        id: upstreamId,
        method: "process/kill",
        params: { processHandle: handle },
      });
    }
    if (this.primary === client) {
      this.primary = [...this.clients].find(
        (candidate) => candidate.role === "desktop" && !candidate.closed,
      ) || null;
      this.flushInitializeWaiters();
    }
    this.log(`${client.role || "unknown"} client ${client.id} disconnected`);
    this.writeHealth(this.isReady() ? "ready" : "waiting_for_desktop");
  }

  onClientText(client, text) {
    let message;
    try {
      message = JSON.parse(text);
    } catch (_) {
      client.sendJson({ jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: null });
      return;
    }

    if (message.method === "initialize" && Object.prototype.hasOwnProperty.call(message, "id")) {
      this.onInitialize(client, message);
      return;
    }
    if (message.method === "initialized" && !Object.prototype.hasOwnProperty.call(message, "id")) {
      if (!client.initializeResponseSent) {
        client.socket.destroy();
        return;
      }
      client.initialized = true;
      if (client === this.primary && this.initializeResult && !this.upstreamInitializedNotificationSent) {
        this.sendUpstream({ jsonrpc: "2.0", method: "initialized", params: message.params || {} });
        this.upstreamInitializedNotificationSent = true;
        this.flushInitializeWaiters();
      }
      this.writeHealth(this.isReady() ? "ready" : "waiting_for_desktop");
      return;
    }

    if (!message.method && Object.prototype.hasOwnProperty.call(message, "id")) {
      const serverRequest = this.serverRequests.get(String(message.id));
      if (client === this.primary && serverRequest && serverRequest.client === client) {
        this.serverRequests.delete(String(message.id));
        this.sendUpstream({ ...message, id: serverRequest.upstreamId });
        return;
      }
    }

    if (message.method && Object.prototype.hasOwnProperty.call(message, "id")) {
      if (!client.initialized || !this.isReady()) {
        client.sendJson({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32002, message: "Visible Codex Desktop is not ready" },
        });
        return;
      }
      const routed = this.prepareClientRequest(client, message);
      if (!routed) return;
      const upstreamId = this.nextUpstreamId++;
      this.pending.set(upstreamId, {
        client,
        clientId: message.id,
        method: message.method,
        originalHandle: routed.originalHandle || "",
        upstreamHandle: routed.upstreamHandle || "",
        requestedThreadId: routed.requestedThreadId || "",
        requestedProjectRoot: routed.requestedProjectRoot || "",
        wakeDispatch: routed.wakeDispatch || null,
      });
      this.sendUpstream({ ...routed.message, id: upstreamId });
      return;
    }

    if (client.role === "desktop") this.sendUpstream(message);
  }

  isReady() {
    return Boolean(
      this.initializeResult && this.upstreamInitializedNotificationSent
      && this.primary && this.primary.initialized && !this.primary.closed
    );
  }

  rejectClientRequest(client, id, message) {
    client.sendJson({ jsonrpc: "2.0", id, error: { code: -32601, message } });
  }

  prepareClientRequest(client, message) {
    if (client.role === "desktop") return { message };
    const allowed = new Set(["thread/resume", "agmsg/wake/dispatch", "process/spawn", "process/kill"]);
    if (!allowed.has(message.method)) {
      this.rejectClientRequest(client, message.id, `Bridge method is not allowed: ${message.method}`);
      return null;
    }
    const params = message.params && typeof message.params === "object" ? { ...message.params } : {};
    if (message.method === "thread/resume") {
      const threadId = String(params.threadId || "");
      const binding = client.binding;
      const allowedKeys = new Set(["threadId", "cwd", "runtimeWorkspaceRoots", "excludeTurns"]);
      if (!binding || threadId !== binding.threadId || client.threadId && client.threadId !== threadId
          || !hasOnlyKeys(params, allowedKeys)
          || params.cwd && params.cwd !== binding.project
          || params.runtimeWorkspaceRoots && !sameRuntimeRoots(params.runtimeWorkspaceRoots, binding.project)
          || params.excludeTurns !== undefined && params.excludeTurns !== true) {
        this.rejectClientRequest(client, message.id, "Bridge requires one exact thread id");
        return null;
      }
      return {
        message: {
          ...message,
          params: { threadId, cwd: binding.project, runtimeWorkspaceRoots: [binding.project], excludeTurns: true },
        },
        requestedThreadId: threadId,
        requestedProjectRoot: binding.project,
      };
    }
    if (message.method === "agmsg/wake/dispatch") {
      const binding = client.binding;
      const allowedKeys = new Set([
        "threadId", "maxId", "clientUserMessageId", "dispatchMode", "cwd", "runtimeWorkspaceRoots",
      ]);
      const maxId = Number(params.maxId);
      const clientUserMessageId = String(params.clientUserMessageId || "");
      const dispatchMode = String(params.dispatchMode || "");
      if (!client.threadId || params.threadId !== client.threadId || !binding
          || !hasOnlyKeys(params, allowedKeys)
          || params.cwd && params.cwd !== client.projectRoot
          || params.runtimeWorkspaceRoots && !sameRuntimeRoots(params.runtimeWorkspaceRoots, client.projectRoot)
          || !Number.isSafeInteger(maxId) || maxId <= 0
          || clientUserMessageId !== expectedWakeClientId(binding, maxId)
          || !["start-or-reconcile", "reconcile-only"].includes(dispatchMode)) {
        this.rejectClientRequest(client, message.id, "Bridge wake does not match its exact role binding");
        return null;
      }
      const inflightKey = clientUserMessageId;
      const inflight = this.wakeInflight.get(inflightKey);
      let durableState;
      try {
        durableState = readRelayWakeState(binding);
      } catch (error) {
        this.rejectClientRequest(client, message.id, `Cannot trust relay wake state: ${error.message}`);
        return null;
      }
      if (durableState && durableState.maxId > maxId) {
        this.rejectClientRequest(client, message.id, "Bridge wake is older than relay durable state");
        return null;
      }
      const durableSameWake = durableState && durableState.maxId === maxId
        && durableState.clientUserMessageId === clientUserMessageId;
      if (dispatchMode === "reconcile-only" || inflight || durableSameWake) {
        // The bridge may time out while the original thread/read or turn/start
        // is still in flight. A retry is reconciliation-only: if history does
        // not contain the marker yet, fail closed instead of starting a second
        // turn concurrently with the original request.
        return {
          message: {
            jsonrpc: "2.0",
            method: "thread/read",
            params: { threadId: client.threadId, includeTurns: true },
          },
          wakeDispatch: {
            clientUserMessageId,
            maxId,
            inflightKey,
            reconcileOnly: true,
            binding,
          },
        };
      }
      this.wakeInflight.set(inflightKey, { stage: "read" });
      return {
        message: {
          jsonrpc: "2.0",
          method: "thread/read",
          params: { threadId: client.threadId, includeTurns: true },
        },
        wakeDispatch: {
          clientUserMessageId,
          maxId,
          inflightKey,
          binding,
          turnParams: {
            threadId: client.threadId,
            input: [{ type: "text", text: buildWakePrompt(binding), text_elements: [] }],
            cwd: client.projectRoot,
            runtimeWorkspaceRoots: [client.projectRoot],
            clientUserMessageId,
          },
        },
      };
    }
    if (!client.threadId) {
      this.rejectClientRequest(client, message.id, "Bridge must resume its exact thread before spawning a watcher");
      return null;
    }
    const originalHandle = String(params.processHandle || "");
    if (!/^agmsg-watch-[A-Za-z0-9._-]+$/.test(originalHandle)) {
      this.rejectClientRequest(client, message.id, "Bridge process handle is invalid");
      return null;
    }
    if (message.method === "process/spawn") {
      const command = Array.isArray(params.command) ? params.command : [];
      const binding = client.binding;
      const allowedKeys = new Set(["command", "processHandle", "cwd", "outputBytesCap", "timeoutMs"]);
      const timeoutSeconds = Number(command[12]);
      const intervalSeconds = Number(command[14]);
      const validShape = command.length === 15
        && String(command[0] || "") === "/bin/bash"
        && String(command[1] || "") === path.join(SCRIPT_DIR, "watch-once.sh")
        && resolvesToProject(command[2], binding.project)
        && String(command[3] || "") === binding.type
        && command[4] === "--team" && command[5] === binding.team
        && command[6] === "--name" && command[7] === binding.name
        && command[8] === "--owner" && /^agmsg-codex-bridge-[0-9]+\.[0-9]+$/.test(String(command[9] || ""))
        && command[10] === "--claim"
        && command[11] === "--timeout" && /^[1-9][0-9]*$/.test(String(command[12] || ""))
        && command[13] === "--interval" && /^[1-9][0-9]*$/.test(String(command[14] || ""));
      const expectedTimeoutMs = (timeoutSeconds + intervalSeconds + 10) * 1000;
      const validParams = hasOnlyKeys(params, allowedKeys)
        && params.cwd === binding.project
        && params.outputBytesCap === 8192
        && Number.isInteger(params.timeoutMs) && params.timeoutMs === expectedTimeoutMs
        && params.timeoutMs > 0 && params.timeoutMs <= 86400000;
      if (!validShape || !validParams) {
        this.rejectClientRequest(client, message.id, "Bridge may spawn only watch-once.sh");
        return null;
      }
      const upstreamHandle = `agmsg-relay-${client.id}-${originalHandle}`;
      if (this.processOwners.has(upstreamHandle)) {
        this.rejectClientRequest(client, message.id, "Bridge process handle already exists");
        return null;
      }
      this.processOwners.set(upstreamHandle, { client, originalHandle });
      params.processHandle = upstreamHandle;
      params.cwd = binding.project;
      return { message: { ...message, params }, originalHandle, upstreamHandle };
    }
    if (!hasOnlyKeys(params, new Set(["processHandle"]))) {
      this.rejectClientRequest(client, message.id, "Bridge may kill only its owned watch process");
      return null;
    }
    const ownerEntry = [...this.processOwners.entries()].find(
      ([, owner]) => owner.client === client && owner.originalHandle === originalHandle,
    );
    if (!ownerEntry) {
      this.rejectClientRequest(client, message.id, "Bridge does not own this process handle");
      return null;
    }
    params.processHandle = ownerEntry[0];
    return {
      message: { ...message, params },
      originalHandle,
      upstreamHandle: ownerEntry[0],
    };
  }

  onInitialize(client, message) {
    client.isBridge = client.role === "bridge";
    if (client.role === "desktop" && !this.primary) this.primary = client;
    this.initializeWaiters.push({ client, clientId: message.id });
    if (this.initializeResult || this.initializeError) {
      this.flushInitializeWaiters();
      return;
    }
    if (client !== this.primary || this.initializeRequestId !== null) {
      this.writeHealth("waiting_for_desktop");
      return;
    }
    const upstreamId = this.nextUpstreamId++;
    this.initializeRequestId = upstreamId;
    this.pending.set(upstreamId, { initialize: true });
    this.sendUpstream({ ...message, id: upstreamId });
    this.writeHealth("initializing");
  }

  flushInitializeWaiters() {
    const remaining = [];
    for (const waiter of this.initializeWaiters.splice(0)) {
      if (this.initializeError) {
        waiter.client.sendJson({ jsonrpc: "2.0", id: waiter.clientId, error: this.initializeError });
      } else if (
        this.initializeResult
        && (waiter.client === this.primary || this.isReady())
      ) {
        waiter.client.initializeResponseSent = true;
        waiter.client.sendJson({ jsonrpc: "2.0", id: waiter.clientId, result: this.initializeResult });
      } else {
        remaining.push(waiter);
      }
    }
    this.initializeWaiters.push(...remaining);
    let status = "waiting_for_desktop";
    if (this.initializeError) status = "initialization_failed";
    else if (this.isReady()) status = "ready";
    else if (this.initializeRequestId !== null) status = "initializing";
    this.writeHealth(status);
  }

  onUpstreamLine(line) {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch (_) {
      this.log("ignoring non-json app-server line");
      return;
    }

    if (Object.prototype.hasOwnProperty.call(message, "id") && !message.method) {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (pending.initialize) {
        this.initializeRequestId = null;
        if (message.error) this.initializeError = message.error;
        else this.initializeResult = message.result;
        this.flushInitializeWaiters();
        return;
      }
      if (pending.internal) {
        if (pending.upstreamHandle) this.processOwners.delete(pending.upstreamHandle);
        return;
      }
      if (pending.wakeDispatch) {
        const dispatch = pending.wakeDispatch;
        if (dispatch.reconcileOnly) {
          if (!message.error && containsClientMessageId(message.result, dispatch.clientUserMessageId)) {
            writeRelayWakeState(
              dispatch.binding,
              dispatch.maxId,
              "accepted",
              dispatch.clientUserMessageId,
            );
            pending.client.sendJson({
              jsonrpc: "2.0",
              id: pending.clientId,
              result: { status: "reconciled", maxId: dispatch.maxId },
            });
          } else {
            pending.client.sendJson({
              jsonrpc: "2.0",
              id: pending.clientId,
              error: { code: -32004, message: "Wake acceptance is still ambiguous" },
            });
          }
          return;
        }
        if (dispatch.stage === "turn") {
          this.wakeInflight.delete(dispatch.inflightKey);
          if (message.error) {
            pending.client.sendJson({ ...message, id: pending.clientId });
          } else {
            writeRelayWakeState(
              dispatch.binding,
              dispatch.maxId,
              "accepted",
              dispatch.clientUserMessageId,
            );
            pending.client.sendJson({
              jsonrpc: "2.0",
              id: pending.clientId,
              result: {
                status: "accepted",
                maxId: dispatch.maxId,
                turnId: String(message.result && message.result.turn && message.result.turn.id || ""),
              },
            });
          }
          return;
        }
        if (message.error) {
          this.wakeInflight.delete(dispatch.inflightKey);
          pending.client.sendJson({ ...message, id: pending.clientId });
          return;
        }
        if (containsClientMessageId(message.result, dispatch.clientUserMessageId)) {
          this.wakeInflight.delete(dispatch.inflightKey);
          writeRelayWakeState(
            dispatch.binding,
            dispatch.maxId,
            "accepted",
            dispatch.clientUserMessageId,
          );
          pending.client.sendJson({
            jsonrpc: "2.0",
            id: pending.clientId,
            result: { status: "reconciled", maxId: dispatch.maxId },
          });
          return;
        }
        const inflight = this.wakeInflight.get(dispatch.inflightKey);
        if (inflight) inflight.stage = "turn";
        writeRelayWakeState(
          dispatch.binding,
          dispatch.maxId,
          "dispatching",
          dispatch.clientUserMessageId,
        );
        const upstreamId = this.nextUpstreamId++;
        this.pending.set(upstreamId, {
          client: pending.client,
          clientId: pending.clientId,
          method: "agmsg/wake/dispatch",
          wakeDispatch: { ...dispatch, stage: "turn" },
        });
        this.sendUpstream({
          jsonrpc: "2.0",
          id: upstreamId,
          method: "turn/start",
          params: dispatch.turnParams,
        });
        return;
      }
      if (pending.method === "process/spawn" && message.error && pending.upstreamHandle) {
        this.processOwners.delete(pending.upstreamHandle);
      }
      if (pending.method === "thread/resume" && !message.error) {
        const returnedThreadId = String(
          message.result && message.result.thread && message.result.thread.id || "",
        );
        if (!returnedThreadId || returnedThreadId !== pending.requestedThreadId) {
          pending.client.sendJson({
            jsonrpc: "2.0",
            id: pending.clientId,
            error: { code: -32003, message: "App-server resumed a different thread" },
          });
          return;
        }
        pending.client.threadId = returnedThreadId;
        pending.client.projectRoot = pending.requestedProjectRoot;
      }
      pending.client.sendJson({ ...message, id: pending.clientId });
      return;
    }

    if (message.method && Object.prototype.hasOwnProperty.call(message, "id")) {
      const primary = this.primary;
      if (!primary || primary.closed) {
        this.sendUpstream({
          jsonrpc: "2.0",
          id: message.id,
          error: { code: -32000, message: "No visible Codex Desktop client is connected" },
        });
        return;
      }
      const relayId = `agmsg-relay-server-${this.nextServerRequestId++}`;
      this.serverRequests.set(relayId, { client: primary, upstreamId: message.id });
      primary.sendJson({ ...message, id: relayId });
      return;
    }

    if (message.method && message.method.startsWith("process/")) {
      const upstreamHandle = String(message.params && message.params.processHandle || "");
      const owner = this.processOwners.get(upstreamHandle);
      if (owner) {
        if (message.method === "process/exited") this.processOwners.delete(upstreamHandle);
        owner.client.sendJson({
          ...message,
          params: { ...message.params, processHandle: owner.originalHandle },
        });
      } else {
        for (const client of this.clients) {
          if (client.role === "desktop" && client.initialized && !client.closed) client.sendJson(message);
        }
      }
      return;
    }

    for (const client of this.clients) {
      if (!client.initialized || client.closed) continue;
      if (client.role === "desktop") {
        client.sendJson(message);
        continue;
      }
      const bridgeNotifications = new Set([
        "thread/status/changed",
        "turn/started",
        "turn/completed",
        "turn/failed",
        "item/agentMessage/delta",
        "error",
      ]);
      if (
        bridgeNotifications.has(message.method)
        && client.threadId
        && message.params
        && message.params.threadId === client.threadId
      ) {
        client.sendJson(message);
      }
    }
  }

  sendUpstream(message) {
    if (!this.child || !this.child.stdin || this.child.stdin.destroyed) return;
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  writeHealth(status) {
    const primaryConnected = Boolean(this.primary && !this.primary.closed);
    const initializedClients = [...this.clients].filter((client) => client.initialized).length;
    const contents = [
      `status=${status === "ready" && !this.isReady() ? "waiting_for_desktop" : status}`,
      `pid=${process.pid}`,
      `port=${this.actualPort || this.opts.port}`,
      `upstream_pid=${this.child && this.child.pid || ""}`,
      `clients=${this.clients.size}`,
      `initialized_clients=${initializedClients}`,
      `primary_connected=${primaryConnected ? 1 : 0}`,
      `upstream_initialized=${this.initializeResult ? 1 : 0}`,
      `updated_at=${new Date().toISOString()}`,
      "",
    ].join("\n");
    try {
      atomicWrite(this.opts.health, contents);
    } catch (error) {
      this.log(`health write failed: ${error.message}`);
    }
  }

  log(message) {
    console.error(`codex-desktop-relay: ${message}`);
  }

  shutdown(code) {
    if (this.shuttingDown) return;
    this.shuttingDown = true;
    if (this.parentTimer) {
      clearInterval(this.parentTimer);
      this.parentTimer = null;
    }
    this.writeHealth(code === 0 ? "stopped" : "failed");
    for (const client of this.clients) {
      if (!client.socket.destroyed) client.socket.destroy();
    }
    if (this.server) {
      try { this.server.close(); } catch (_) {}
    }
    for (const file of [this.opts.pidFile]) {
      try { fs.unlinkSync(file); } catch (_) {}
    }
    const finish = () => process.exit(code);
    if (!this.child || !this.upstreamPgid) return finish();

    if (process.platform === "win32") {
      if (this.child.exitCode === null && this.child.signalCode === null) this.child.kill("SIGTERM");
      const timer = setTimeout(() => {
        if (this.child && this.child.exitCode === null) this.child.kill("SIGKILL");
        finish();
      }, this.opts.shutdownGraceMs);
      this.child.once("exit", () => { clearTimeout(timer); finish(); });
      return;
    }

    const pgid = this.upstreamPgid;
    const groupAlive = () => {
      try {
        process.kill(-pgid, 0);
        return true;
      } catch (error) {
        return error && error.code === "EPERM";
      }
    };
    const signalGroup = (signal) => {
      try { process.kill(-pgid, signal); } catch (_) {}
    };
    const deadline = Date.now() + this.opts.shutdownGraceMs;
    signalGroup("SIGTERM");
    const awaitGroupExit = () => {
      if (!groupAlive()) return finish();
      if (Date.now() >= deadline) {
        signalGroup("SIGKILL");
        const killDeadline = Date.now() + 1000;
        const awaitKilled = () => {
          if (!groupAlive() || Date.now() >= killDeadline) return finish();
          setTimeout(awaitKilled, 50);
        };
        setTimeout(awaitKilled, 50);
        return;
      }
      setTimeout(awaitGroupExit, 50);
    };
    setTimeout(awaitGroupExit, 50);
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) return usage();
  new CodexDesktopRelay(opts).run();
}

if (require.main === module) main();

module.exports = { CodexDesktopRelay, RelayClient, encodeFrame, parseArgs };
