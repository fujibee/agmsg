"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const test = require("node:test");

const bridgeModule = path.resolve(__dirname, "../scripts/drivers/types/codex/codex-bridge.js");
const { CodexBridge, existingBridgeMatches, resolveBashBin } = require(bridgeModule);

function deliveryBridge(requestImpl, monitorState = "") {
  const bridge = new CodexBridge({
    project: process.cwd(),
    type: "codex",
    inlineInbox: true,
    turnTimeout: 60,
    monitorState,
  }, { team: "team", name: "alice" });
  bridge.threadId = "exact-thread";
  bridge.threadIdle = true;
  bridge.turnActive = false;
  bridge.pendingWake = true;
  bridge.fetchUnreadForPrompt = () => ({ ids: [11, 12], text: "  message payload" });
  bridge.checkTuiLease = () => true;
  bridge.writeBridgeLease = () => {};
  bridge.startTurnWatchdog = () => {};
  bridge.client = { request: requestImpl };
  return bridge;
}

test("turn/start ACK marks the exact fetched batch once", async () => {
  const methods = [];
  const bridge = deliveryBridge(async (method) => {
    methods.push(method);
    return {};
  });
  let marked = 0;
  bridge.markFetchedRead = () => {
    marked += 1;
    assert.deepEqual(bridge.fetchedMessageIds, [11, 12]);
    return true;
  };

  await bridge.tryStartTurn();

  assert.deepEqual(methods, ["turn/start"]);
  assert.equal(marked, 1);
  assert.deepEqual(bridge.fetchedMessageIds, []);
  assert.equal(bridge.pendingWake, false);
});

test("explicit turn/start failure never marks and leaves a retryable wake", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-bridge-unit-"));
  const state = path.join(dir, "monitor.state");
  const bridge = deliveryBridge(async () => {
    throw new Error("thread route rejected");
  }, state);
  let marked = 0;
  bridge.markFetchedRead = () => { marked += 1; return true; };

  await assert.rejects(bridge.tryStartTurn(), /thread route rejected/);

  assert.equal(marked, 0);
  assert.equal(bridge.pendingWake, true);
  assert.equal(bridge.turnActive, false);
  assert.match(fs.readFileSync(state, "utf8"), /^phase=delivery_failed$/m);
  assert.match(fs.readFileSync(state, "utf8"), /^detail=bridge_restart_retry$/m);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("ambiguous turn/start ACK timeout keeps rows unread for at-least-once delivery", async () => {
  const bridge = deliveryBridge(async () => {
    throw new Error("app-server request 'turn/start' timed out after 10ms");
  });
  let marked = 0;
  bridge.markFetchedRead = () => { marked += 1; return true; };

  await bridge.tryStartTurn();

  assert.equal(marked, 0);
  assert.deepEqual(bridge.fetchedMessageIds, []);
  assert.equal(bridge.lastWakeMaxId, 0);
  assert.equal(bridge.deliveryInFlight, false);
});

test("diagnostic server errors expose only a sanitized code, not payload text", () => {
  const bridge = deliveryBridge(async () => ({}));
  const logged = [];
  const original = console.error;
  console.error = (line) => logged.push(String(line));
  try {
    bridge.onServerError({
      threadId: "exact-thread",
      error: { code: "route rejected!", message: "secret inbox body" },
    });
  } finally {
    console.error = original;
  }
  assert.match(logged.join("\n"), /server error \(route_rejected_\)/);
  assert.doesNotMatch(logged.join("\n"), /secret inbox body/);
});

test("Windows bash resolution honors an explicit Git Bash and never needs PATH bash", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-bash-unit-"));
  const fake = path.join(dir, "git-bash.exe");
  fs.writeFileSync(fake, "");
  assert.equal(resolveBashBin("win32", { GIT_BASH: fake, PATH: "C:\\Windows\\System32" }), fake);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("peer WebSocket close terminates the bridge client for launcher reconnect", () => {
  const code = String.raw`
    const crypto = require("crypto");
    const net = require("net");
    const { WebSocketAppServerClient } = require(process.argv[1]);
    const server = net.createServer((socket) => {
      let header = Buffer.alloc(0);
      socket.on("data", (chunk) => {
        header = Buffer.concat([header, chunk]);
        const end = header.indexOf("\r\n\r\n");
        if (end < 0) return;
        const text = header.slice(0, end).toString("utf8");
        const match = text.match(/Sec-WebSocket-Key: (.*)\r\n/i);
        const accept = crypto.createHash("sha1")
          .update(match[1].trim() + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
          .digest("base64");
        const response = ["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket",
          "Connection: Upgrade", "Sec-WebSocket-Accept: " + accept, "", ""].join("\r\n");
        socket.write(Buffer.concat([Buffer.from(response), Buffer.from([0x88, 0x00])]));
      });
    });
    server.listen(0, "127.0.0.1", async () => {
      const client = new WebSocketAppServerClient(
        { host: "127.0.0.1", port: server.address().port },
        "unit-peer-close",
        { connectTimeoutMs: 1000, requestTimeoutMs: 1000 },
      );
      await client.start();
    });
    setTimeout(() => process.exit(124), 3000).unref();
  `;
  const result = spawnSync(process.execPath, ["-e", code, bridgeModule], {
    encoding: "utf8",
    timeout: 5000,
  });
  assert.equal(result.status, 1, result.stderr || result.stdout);
  assert.match(result.stderr, /connection closed \(unit-peer-close\)/);
  assert.match(result.stderr, /fresh bridge can attach/);
});

test("single-instance validation rejects a recycled live PID with stale ownership", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-bridge-owner-"));
  const meta = path.join(dir, "bridge.meta");
  const lease = path.join(dir, "bridge.lease");
  fs.writeFileSync(meta, [
    "pid=1234", "pid_domain=native", "project=C:/work", "team=team", "name=alice", "type=codex", "",
  ].join("\n"));
  fs.writeFileSync(lease, [
    "format_version=1", "owner_kind=bridge", "pid_domain=native", "owner_winpid=1234",
    "owner_creation=old-process", "project=C:/work", "bound_generation=tui-1", "",
  ].join("\n"));

  assert.equal(existingBridgeMatches({
    pid: 1234,
    metafile: meta,
    bridgeLease: lease,
    opts: { project: "C:/work", type: "codex", boundGeneration: "tui-1" },
    identity: { team: "team", name: "alice" },
    creationDate: () => "reused-process",
  }), false);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("single-instance validation accepts only the exact live bridge owner", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "agmsg-bridge-owner-"));
  const meta = path.join(dir, "bridge.meta");
  const lease = path.join(dir, "bridge.lease");
  fs.writeFileSync(meta, [
    "pid=1234", "pid_domain=native", "project=C:/work", "team=team", "name=alice", "type=codex", "",
  ].join("\n"));
  fs.writeFileSync(lease, [
    "format_version=1", "owner_kind=bridge", "pid_domain=native", "owner_winpid=1234",
    "owner_creation=created-1234", "project=C:/work", "bound_generation=tui-1", "",
  ].join("\n"));

  assert.equal(existingBridgeMatches({
    pid: 1234,
    metafile: meta,
    bridgeLease: lease,
    opts: { project: "C:/work", type: "codex", boundGeneration: "tui-1" },
    identity: { team: "team", name: "alice" },
    creationDate: () => "created-1234",
  }), true);
  fs.rmSync(dir, { recursive: true, force: true });
});

test("bridge watch reuses its already-resolved identity without project rescans", async () => {
  const bridge = new CodexBridge({
    project: process.cwd(),
    type: "codex",
    timeout: 300,
    interval: 2,
  }, { team: "team", name: "alice" });
  bridge.checkTuiLease = () => true;
  bridge.writeBridgeLease = () => {};
  let request;
  bridge.client = { request: async (method, params) => { request = { method, params }; } };

  await bridge.armWatch();

  assert.equal(request.method, "process/spawn");
  assert.ok(request.params.command.includes("--resolved-pair"));
  assert.deepEqual(
    request.params.command.slice(request.params.command.indexOf("--team"), request.params.command.indexOf("--timeout")),
    ["--team", "team", "--name", "alice", "--resolved-pair"],
  );
});
