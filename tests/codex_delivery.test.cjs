"use strict";
const assert = require("node:assert/strict");
const test = require("node:test");
const path = require("node:path");
const fs = require("node:fs");
const { spawn, spawnSync } = require("node:child_process");
const { once } = require("node:events");
const root = process.env.TEST_SKILL_DIR;
assert(root && process.env.TYPES, "requires disposable Bats fixture");
const { AppServerClient, WebSocketAppServerClient, CodexBridge } = require(path.join(process.env.TYPES, "codex/codex-bridge.js"));
const { DeliveryClient, DeliveryBatch, CLAIM_MAX_BYTES, PROMPT_MAX_BYTES } = require(path.join(process.env.TYPES, "codex/codex-delivery.js"));
const pair = { team: "team", name: "alice" };
const record = { type: "message_sent", id: "opaque\n\t'\\id", team: "team", to: "alice", from: "bob", body: "hello", at: "2026-10-02", claim_token: "a".repeat(64), claim_expires_at: 9999999999 };
const accepted = { turn: { id: "turn-one", status: "inProgress", items: [] } };
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function frame(value) {
  const data = Buffer.from(JSON.stringify(value));
  const header = Buffer.alloc(data.length < 126 ? 2 : 4);
  header[0] = 0x81;
  if (header.length === 2) header[1] = data.length;
  else { header[1] = 126; header.writeUInt16BE(data.length, 2); }
  return Buffer.concat([header, data]);
}

function fakeClient(transport, handler, timeout = 10000) {
  const client = transport === "stdio" ? new AppServerClient([], root, { requestTimeoutMs: timeout }) :
    new WebSocketAppServerClient({}, "fixture", { requestTimeoutMs: timeout });
  const receive = (value) => transport === "stdio" ? client.handleLine(JSON.stringify(value)) : client.handleWebSocketBytes(frame(value));
  const send = (value) => {
    if (!value.method) return;
    setImmediate(() => handler(value, (result) => receive({ id: value.id, result }),
      (code, extra = {}) => receive({ id: value.id, error: { code, message: "fixture rejection" }, ...extra }),
      (method, params) => receive({ method, params }), receive));
  };
  if (transport === "stdio") client.child = { stdin: { write: (line, cb) => { send(JSON.parse(line)); cb?.(); } } };
  else client.sendJson = (value, cb) => { send(value); cb?.(); };
  client.start = () => {};
  client.stop = () => {
    for (const pending of client.pending.values()) pending.reject(new Error("fixture transport closed"));
    client.pending.clear();
  };
  return client;
}

function memoryDelivery(records = [record]) {
  const delivery = new DeliveryClient(root, "bash", root);
  const calls = [];
  delivery.supported = true;
  delivery.bytesSupported = true;
  delivery.operation = (operation, request) => {
    calls.push({ operation, request });
    return operation === "claim" ? records.map((row) => JSON.stringify(row) + "\n").join("") : "ok\n";
  };
  return { delivery, calls };
}

async function harness(transport, handler, delivery, timeout, concreteClient) {
  const opts = { project: root, type: "codex", inlineInbox: true, threadId: "thread-one", turnTimeout: 0,
    appServer: "stdio", pairs: [], maxWakes: 0, workspaceRoots: [] };
  const bridge = new CodexBridge(opts, [pair]);
  bridge.client = concreteClient || fakeClient(transport, handler, timeout);
  if (delivery) bridge.delivery = delivery;
  bridge.eligibleIdentities = () => new Set(["team\talice"]);
  for (const method of ["ensureSingleInstance", "writeMeta", "installSignals", "initialize", "ensureThread", "armWatch", "recordSeat", "cleanupMeta"]) bridge[method] = () => {};
  await bridge.run();
  bridge.pendingWake = true;
  return bridge;
}

for (const transport of ["stdio", "ws"]) {
  test(`${transport}: only matched valid acceptance ACKs exact IDs`, async () => {
    const { delivery, calls } = memoryDelivery();
    const bridge = await harness(transport, (message, resolve, _, notify, receive) => {
      assert.equal(calls.filter((call) => call.operation === "ack").length, 0);
      // The server's independent request namespace can collide with ours.
      receive({ id: message.id, method: "unknown/server/request", params: {} });
      notify("thread/status/changed", { threadId: "thread-one", status: { type: "idle" } });
      notify("turn/completed", { threadId: "other-thread" });
      assert.equal(calls.filter((call) => call.operation === "ack").length, 0);
      resolve(accepted);
    }, delivery);
    await bridge.tryStartTurn();
    assert.deepEqual(calls.map((call) => call.operation), ["claim", "renew", "renew", "ack"]);
    assert.deepEqual(calls.at(-1).request.ids, [record.id]);
    assert.equal(bridge.pendingWake, false);
    await bridge.shutdown();
  });

  for (const mode of ["rejected", "internal", "error+result", "started-rejected", "malformed", "mismatched", "timeout", "disconnect"]) {
    test(`${transport}: ${mode} preserves the appropriate lease`, async () => {
      const { delivery, calls } = memoryDelivery();
      let bridge;
      bridge = await harness(transport, (_, resolve, reject, notify) => {
        if (mode === "rejected") reject(-32602);
        if (mode === "internal") reject(-32603);
        if (mode === "error+result") reject(-32600, { result: accepted });
        if (mode === "started-rejected" || mode === "mismatched") {
          notify("turn/started", { threadId: "thread-one", turn: { id: "other-turn" } });
          if (mode === "started-rejected") reject(-32601); else resolve(accepted);
        }
        if (mode === "malformed") resolve({ turn: { id: "turn-one" } });
        if (mode === "disconnect") bridge.client.stop();
      }, delivery, mode === "timeout" ? 30 : 10000);
      const keepalive = setTimeout(() => {}, 1000);
      await assert.rejects(bridge.tryStartTurn());
      clearTimeout(keepalive);
      assert.equal(calls.some((call) => call.operation === "ack"), false);
      assert.equal(calls.some((call) => call.operation === "release"), mode === "rejected");
      assert.equal(bridge.pendingWake, false);
      await bridge.shutdown();
    });
  }
}

test("a terminal accepted turn is a receipt even when task execution failed", async () => {
  const { delivery, calls } = memoryDelivery();
  const bridge = await harness("stdio", (_, resolve) => resolve({ turn: { id: "t", items: [], status: "failed" } }), delivery);
  await bridge.tryStartTurn();
  assert.equal(calls.at(-1).operation, "ack");
  await bridge.shutdown();
});

test("ownership change before transport releases; after attempt retains", async () => {
  const first = memoryDelivery();
  const before = await harness("stdio", () => assert.fail("must not hand off"), first.delivery);
  let resolutions = 0;
  before.eligibleIdentities = () => new Set(++resolutions === 1 ? ["team\talice"] : []);
  await before.tryStartTurn();
  assert.equal(first.calls.at(-1).operation, "release");
  const second = memoryDelivery();
  const after = await harness("stdio", () => { after.eligibleIdentities = () => new Set(); after.client.stop(); }, second.delivery);
  await assert.rejects(after.tryStartTurn());
  assert.equal(second.calls.some((call) => call.operation === "release"), false);
  await before.shutdown(); await after.shutdown();
});

test("renewal failure wins over a late acceptance and zero request timeout", async () => {
  const { delivery, calls } = memoryDelivery();
  const operation = delivery.operation.bind(delivery);
  let renewals = 0;
  delivery.operation = (op, req) => {
    if (op === "renew" && ++renewals > 1) throw new Error("fixture renewal failed");
    return operation(op, req);
  };
  const claim = delivery.claim.bind(delivery);
  delivery.claim = (pair) => {
    const batch = claim(pair);
    batch.waitFor = (promise) => DeliveryBatch.prototype.waitFor.call(batch, promise, 5);
    return batch;
  };
  const bridge = await harness("stdio", (_, resolve) => setTimeout(() => resolve(accepted), 30), delivery, 0);
  await assert.rejects(bridge.tryStartTurn(), /renewal failed/);
  await delay(50);
  assert.equal(calls.some((call) => ["ack", "release"].includes(call.operation)), false);
  assert.equal(bridge.pendingWake, false);
  await bridge.shutdown();
});

test("shutdown while response is outstanding retains claims and cancels renewal", async () => {
  const { delivery, calls } = memoryDelivery();
  const bridge = await harness("ws", () => setImmediate(() => bridge.shutdown()), delivery, 0);
  await assert.rejects(bridge.tryStartTurn());
  assert.equal(calls.some((call) => ["ack", "release"].includes(call.operation)), false);
  assert.equal(bridge.deliveryBatch, null);
});

test("successful periodic renewal stops before ACK and cannot mutate the terminal batch", async () => {
  const { delivery, calls } = memoryDelivery();
  const claim = delivery.claim.bind(delivery);
  delivery.claim = (pair) => {
    const batch = claim(pair);
    batch.waitFor = (promise) => DeliveryBatch.prototype.waitFor.call(batch, promise, 5);
    return batch;
  };
  const bridge = await harness("ws", (_, resolve) => setTimeout(() => resolve(accepted), 25), delivery, 0);
  await bridge.tryStartTurn();
  assert(calls.filter((call) => call.operation === "renew").length >= 3);
  assert.deepEqual(calls.slice(-2).map((call) => call.operation), ["renew", "ack"]);
  const completedCount = calls.length;
  await delay(20);
  assert.equal(calls.length, completedCount);
  await bridge.shutdown();
});

test("capability failure is not unsupported and never selects the consuming fallback", async () => {
  const delivery = new DeliveryClient(root, "bash", root);
  let checks = 0;
  delivery.run = () => { checks++; return { status: 13, stdout: "", stderr: "fixture" }; };
  const bridge = await harness("stdio", () => assert.fail("must not send"), delivery);
  bridge.readInboxForPrompt = () => assert.fail("must not consume on capability failure");
  await assert.rejects(bridge.tryStartTurn(), /capability check failed/);
  assert.equal(delivery.supported, null);
  assert.equal(checks, 1);
  delivery.run = () => { checks++; return { status: 1, stdout: "" }; };
  assert.equal(delivery.capability(), false);
  assert.equal(delivery.capability(), false);
  assert.equal(checks, 2, "a successfully detected unsupported driver is cached");
  await bridge.shutdown();
});

test("malformed claims never release a guessed token or disclose partial bodies", () => {
  for (const records of [[{ ...record, claim_token: "bad" }], [record, record], [{ ...record, to: "bob" }], [{ ...record, id: "nul\0id" }]]) {
    const { delivery, calls } = memoryDelivery(records);
    assert.throws(() => delivery.claim(pair), /malformed delivery claim/);
    assert.deepEqual(calls.map((call) => call.operation), ["claim"]);
  }
});

test("bounded claims reject malformed markers and enforce encoded bytes and complete groups", () => {
  const marker = { type: "delivery_oversized" };
  for (const records of [[marker, record], [marker, marker], [{ ...marker, count: 1 }],
    [{ ...record, body: "界".repeat(CLAIM_MAX_BYTES / 2) }],
    Array.from({ length: 33 }, (_, i) => ({ ...record, id: `id-${i}` }))]) {
    const { delivery, calls } = memoryDelivery(records);
    assert.throws(() => delivery.claim(pair), /malformed delivery claim/);
    assert.deepEqual(calls.map(c => c.operation), ["claim"]);
    assert.equal(delivery.oversized, false);
  }
  for (const records of [[marker], [record, marker]]) {
    const { delivery, calls } = memoryDelivery(records), batch = delivery.claim(pair);
    assert.equal(delivery.oversized, true);
    assert.equal(!!batch, records.length === 2);
    assert.equal(calls[0].request.limit, 32); assert.equal(calls[0].request.max_bytes, CLAIM_MAX_BYTES);
    if (batch) assert.deepEqual(batch.request.ids, [record.id]);
  }
});

test("control responses require exact ok-LF without adopting a terminal batch state", () => {
  for (const operation of ["renew", "ack", "release"]) {
    for (const output of ["", "nope\n", "ok", "ok\n\n", "ok\0\n"]) {
      const { delivery } = memoryDelivery();const batch = delivery.claim(pair);
      delivery.operation = () => output;
      assert.throws(() => batch.control(operation), /malformed delivery/);
      assert.equal(batch.state, "NOT_SENT");
    }
  }
});

test("v1-only inline claims fail without a consuming fallback and bytes capability errors remain errors", async () => {
  const { delivery, calls } = memoryDelivery(); delivery.bytesSupported = null;
  let checks = 0;
  delivery.run = () => { checks++; return { status: 1, stdout: "" }; };
  const bridge = await harness("stdio", () => assert.fail("must not send"), delivery);
  bridge.readInboxForPrompt = () => assert.fail("must not consume");
  await assert.rejects(bridge.tryStartTurn(), /delivery-claims-bytes-v1/);
  await assert.rejects(bridge.tryStartTurn(), /delivery-claims-bytes-v1/);
  assert.equal(checks, 1); assert.deepEqual(calls, []);
  delivery.bytesSupported = null; delivery.run = () => ({ status: 13 });
  assert.throws(() => delivery.requireBytesCapability(), /capability check failed/);
  assert.equal(delivery.bytesSupported, null);
  await bridge.shutdown();
});

test("an oversized final UTF-8 prompt releases NOT_SENT without attempting a turn", async () => {
  const { delivery, calls } = memoryDelivery();
  const bridge = await harness("stdio", () => assert.fail("must not send"), delivery);
  bridge.buildPrompt = () => "界".repeat(Math.floor(PROMPT_MAX_BYTES / 3) + 1);
  await assert.rejects(bridge.tryStartTurn(), /2 MiB limit/);
  assert.deepEqual(calls.map(c => c.operation), ["claim", "release"]);
  assert.equal(bridge.deliveryBatch, null); assert.equal(bridge.startInFlight, false);
  await bridge.shutdown();
});

test("bounded watch reports oversized once, rearms with suppression, and never counts a diagnostic wake", async () => {
  const commands = [], { delivery, calls } = memoryDelivery([{ type: "delivery_oversized" }]);
  const bridge = await harness("stdio", (message, resolve) => {
    assert.equal(message.method, "process/spawn");commands.push(message.params.command);resolve({});
  }, delivery);
  bridge.armWatch = CodexBridge.prototype.armWatch.bind(bridge);
  await bridge.armWatch();
  assert(commands[0].includes("--max-bytes"));assert(!commands[0].includes("--oversized-reported"));
  bridge.lastArmAt = 0;
  await bridge.onProcessExited({ processHandle: bridge.watchHandle, exitCode: 3, stdout: "status=oversized\n" });
  assert.equal(bridge.wakeCount, 0);assert.equal(bridge.watchFailureCount, 0);
  assert(commands[1].includes("--oversized-reported"));assert.equal(bridge.oversizedDeliveryWarned, true);
  bridge.lastArmAt = 0;
  await assert.rejects(bridge.onProcessExited({ processHandle: bridge.watchHandle, exitCode: 3, stdout: "status=oversized count=1\n" }), /malformed/);
  assert.deepEqual(calls, []);
  await bridge.shutdown();
});

test("metadata readiness and unsupported legacy delivery do not request a byte bound", async () => {
  for (const inlineInbox of [false, true]) {
    const { delivery } = memoryDelivery(); delivery.supported = false;
    const bridge = await harness("stdio", (_, resolve) => resolve({}), delivery);bridge.opts.inlineInbox = inlineInbox;
    let command;bridge.client.request = async (method, params) => { if (method === "process/spawn") command = params.command; return {}; };
    bridge.armWatch = CodexBridge.prototype.armWatch.bind(bridge);await bridge.armWatch();
    assert(!command.includes("--max-bytes"));await bridge.shutdown();
  }
});

function sql(statement) {
  const result = spawnSync("sqlite3", [path.join(root, "db/messages.db")], { input: statement, encoding: "utf8", timeout: 10000 });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim();
}

function unreadRecords() {
  const result = spawnSync("bash", ["-c", 'source "$1/lib/storage.sh"; agmsg_storage_load || exit; storage_list_unread team alice', "_", path.join(root, "scripts")],
    { encoding: "utf8", timeout: 10000, maxBuffer: 4 * 1024 * 1024 });
  assert.equal(result.status, 0, result.stderr);
  return result.stdout.trim() ? result.stdout.trim().split("\n").map(JSON.parse) : [];
}

function freshStore(body = "real payload") {
  sql("DELETE FROM messages; DELETE FROM events; DELETE FROM delivery_claims; DELETE FROM delivery_ack_receipts; DELETE FROM read_cursors;");
  const escaped = body.replaceAll("'", "''");
  sql(`INSERT INTO messages(team,from_agent,to_agent,body) VALUES('team','bob','alice','${escaped}');
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id)
      VALUES('message_sent','opaque\r\n\t''\\id','team','bob','alice','${escaped}','2026-10-02',last_insert_rowid());`);
  return new DeliveryClient(path.join(root, "scripts"), "bash", root);
}

for (const transport of ["stdio", "ws"]) {
  test(`${transport}: real bounded batches bypass an oversized head and retain every receipt`, async () => {
    const delivery = freshStore("x".repeat(CLAIM_MAX_BYTES + 1));
    sql("INSERT INTO messages(team,from_agent,to_agent,body) VALUES('team','bob','alice',replace(printf('%600000s',''),' ','a')),('team','bob','alice',replace(printf('%600000s',''),' ','b'));");
    const received = [];
    for (let i = 0; i < 2; i++) {
      const bridge = await harness(transport, (message, resolve) => {
        assert.equal(sql("SELECT count(*) FROM delivery_claims;"), "1");
        assert.equal(sql("SELECT count(*) FROM events WHERE type='message_read';"), String(i));
        received.push(message.params.input[0].text);resolve(accepted);
      }, delivery);
      await bridge.tryStartTurn();assert.equal(delivery.oversized, true);
      assert.equal(sql("SELECT count(*) FROM delivery_claims;"), "0");
      await bridge.shutdown();
    }
    assert(received[0].includes("a".repeat(600000)));assert(received[1].includes("b".repeat(600000)));
    // Legacy rows can be read through an imported event/cursor while the
    // compatibility read_at column remains NULL. Observe the canonical API.
    const unread = unreadRecords();assert.equal(unread.length, 1);
    assert.equal(unread[0].body, "x".repeat(CLAIM_MAX_BYTES + 1));
    assert.equal(sql("SELECT count(*) FROM events WHERE type='message_read';"), "2");
    assert.equal(sql("SELECT count(*) FROM delivery_ack_receipts;"), "2");
    assert.equal(delivery.claim(pair), null);assert.equal(delivery.oversized, true);
    sql("INSERT INTO messages(team,from_agent,to_agent,body) VALUES('team','bob','alice','later fitting arrival');");
    const next = delivery.claim(pair);assert.equal(next.records[0].body, "later fitting arrival");next.release();
  });
}

test("real bounded selection accounts for opaque IDs, UTF-8 bytes and JSON escaping", () => {
  for (const mode of ["opaque-id", "utf8-body", "escaped-body"]) {
    const body = mode === "utf8-body" ? "界".repeat(400000) : mode === "escaped-body" ? "\t".repeat(600000) : "small";
    const delivery = freshStore(body);
    if (mode === "opaque-id") sql("UPDATE events SET id=replace(printf('%600000s',''),' ',char(9)) WHERE type='message_sent';");
    assert.equal(delivery.claim(pair), null, mode);assert.equal(delivery.oversized, true, mode);
    assert.equal(sql("SELECT count(*) FROM delivery_claims;"), "0");
    assert.equal(sql("SELECT count(*) FROM events WHERE type='message_read';"), "0");
    assert.equal(sql("SELECT count(*) FROM delivery_ack_receipts;"), "0");
    sql("INSERT INTO messages(team,from_agent,to_agent,body) VALUES('team','bob','alice','normal after oversized');");
    const batch = delivery.claim(pair);assert.equal(batch.records.length, 1);
    assert.equal(batch.records[0].body, "normal after oversized");batch.release();
  }
});

test("real storage: unread until acceptance; new arrival excluded; lost ACK reply retries once", async () => {
  const delivery = freshStore("long\t\r\n'\\" + "x".repeat(150000));
  const operation = delivery.operation.bind(delivery);
  let acks = 0;
  delivery.operation = (op, req) => {
    const result = operation(op, req);
    if (op === "ack" && ++acks === 1) throw new Error("committed response lost");
    return result;
  };
  const bridge = await harness("stdio", (message, resolve) => {
    assert.equal(sql("SELECT count(*) FROM messages WHERE read_at IS NULL;"), "1");
    assert(message.params.input[0].text.includes("x".repeat(150000)));
    sql("INSERT INTO messages(team,from_agent,to_agent,body) VALUES('team','bob','alice','new arrival');");
    resolve(accepted);
  }, delivery);
  await bridge.tryStartTurn();
  assert.equal(acks, 2);
  assert.equal(sql("SELECT count(*) FROM messages WHERE read_at IS NULL AND body != 'new arrival';"), "0");
  assert.equal(sql("SELECT count(*) FROM messages WHERE read_at IS NULL AND body = 'new arrival';"), "1");
  assert.equal(sql("SELECT count(*) FROM delivery_claims;"), "0");
  await bridge.shutdown();
});

test("real storage: expired fence cannot ACK accepted payload", async () => {
  const delivery = freshStore();
  const bridge = await harness("ws", (_, resolve) => { sql("UPDATE delivery_claims SET expires_at=0;"); resolve(accepted); }, delivery);
  await assert.rejects(bridge.tryStartTurn(), /read-state confirmation is uncertain/);
  assert.equal(sql("SELECT count(*) FROM messages WHERE read_at IS NULL;"), "1");
  assert.equal(sql("SELECT count(*) FROM delivery_ack_receipts;"), "0");
  await bridge.shutdown();
});

test("real storage: abandoned pre/post-attempt batches recover only after expiry", () => {
  for (const attempted of [false, true]) {
    const delivery = freshStore();
    const abandoned = delivery.claim(pair);
    if (attempted) abandoned.attempted();
    const other = new DeliveryClient(path.join(root, "scripts"), "bash", root);
    assert.equal(other.claim(pair), null);
    sql("UPDATE delivery_claims SET expires_at=0;");
    const recovered = other.claim(pair);
    assert.notEqual(recovered.request.token, abandoned.request.token);
    assert.throws(() => abandoned.control("ack"));
    assert.equal(sql("SELECT count(*) FROM messages WHERE read_at IS NULL;"), "1");
    recovered.release();
  }
});

// This fixture runs in a separate Node process. It receives actual stdin or
// masked WebSocket bytes, reads the disposable DB before replying, and never
// invokes a provider or changes delivery state itself.
function wireFixture() {
  const fs = require("node:fs");
  const { spawnSync } = require("node:child_process");
  const [transport, endpoint, mode, db, observation] = process.argv.slice(2);
  function handle(message, send) {
    if (message.method !== "turn/start") return;
    const result = spawnSync("sqlite3", [db], {
      input: "SELECT count(*) FROM messages WHERE read_at IS NULL; SELECT count(*) FROM delivery_claims;",
      encoding: "utf8",
    });
    if (result.status !== 0) throw new Error("fixture DB check failed");
    fs.writeFileSync(observation, JSON.stringify({ counts: result.stdout.trim(), input: message.params.input }));
    if (mode === "accepted") send({ id: message.id, result: { turn: { id: "wire-turn", status: "inProgress", items: [] } } });
    else send({ id: message.id, error: { code: mode === "rejected" ? -32602 : -32603, message: "fixture rejection" } });
  }
  if (transport === "stdio") {
    require("node:readline").createInterface({ input: process.stdin }).on("line", (line) => {
      handle(JSON.parse(line), (value) => process.stdout.write(JSON.stringify(value) + "\n"));
    });
    return;
  }
  const net = require("node:net");
  const crypto = require("node:crypto");
  const server = net.createServer((socket) => {
    let bytes = Buffer.alloc(0), upgraded = false;
    function send(value) {
      const data = Buffer.from(JSON.stringify(value));
      const header = Buffer.alloc(data.length < 126 ? 2 : 4);
      header[0] = 0x81;
      header[1] = header.length === 2 ? data.length : 126;
      if (header.length === 4) header.writeUInt16BE(data.length, 2);
      socket.write(Buffer.concat([header, data]));
    }
    socket.on("data", (chunk) => {
      bytes = Buffer.concat([bytes, chunk]);
      if (!upgraded) {
        const end = bytes.indexOf("\r\n\r\n");
        if (end < 0) return;
        const key = bytes.subarray(0, end).toString().match(/Sec-WebSocket-Key: (.*)/i)[1].trim();
        const accept = crypto.createHash("sha1").update(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
        socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n");
        bytes = bytes.subarray(end + 4);
        upgraded = true;
      }
      while (bytes.length >= 2) {
        const opcode = bytes[0] & 15, masked = (bytes[1] & 128) !== 0;
        let length = bytes[1] & 127, offset = 2;
        if (length === 126) { if (bytes.length < 4) return; length = bytes.readUInt16BE(2); offset = 4; }
        else if (length === 127) { if (bytes.length < 10) return; length = Number(bytes.readBigUInt64BE(2)); offset = 10; }
        const maskAt = offset;
        if (masked) offset += 4;
        if (bytes.length < offset + length) return;
        const payload = Buffer.from(bytes.subarray(offset, offset + length));
        if (masked) for (let i = 0; i < payload.length; i++) payload[i] ^= bytes[maskAt + i % 4];
        bytes = bytes.subarray(offset + length);
        if (opcode === 1) handle(JSON.parse(payload.toString()), send);
        else if (opcode === 8) socket.end();
      }
    });
    socket.on("close", () => server.close());
  });
  server.listen(endpoint, () => process.send({ ready: true }));
}

for (const transport of ["stdio", "ws"]) {
  for (const mode of ["accepted", "rejected", "unknown"]) {
    test(`real ${transport} wire and store: ${mode} preserves the receipt boundary`, async (t) => {
      const body = "wire payload\n\t'\\" + "x".repeat(150000);
      const delivery = freshStore(body);
      const script = path.join(root, "wire-fixture.cjs");
      const socket = path.join(root, "wire.sock");
      const observation = path.join(root, "wire-observation.json");
      fs.writeFileSync(script, "(" + wireFixture.toString() + ")();\n");
      const args = [script, transport, socket, mode, path.join(root, "db/messages.db"), observation];
      let client, peer, bridge;
      t.after(async () => {
        const exit = peer && peer.exitCode === null && peer.signalCode === null ? once(peer, "exit") : null;
        if (bridge) await bridge.shutdown();
        if (peer && peer.exitCode === null) peer.kill("SIGTERM");
        if (exit) await exit;
        fs.rmSync(socket, { force: true });
      });
      if (transport === "stdio") {
        client = new AppServerClient([process.execPath, ...args], root, { requestTimeoutMs: 10000 });
      } else {
        peer = spawn(process.execPath, args, { stdio: ["ignore", "ignore", "pipe", "ipc"] });
        let diagnostic = "";
        peer.stderr.on("data", (chunk) => { diagnostic += chunk; });
        await Promise.race([
          once(peer, "message"),
          once(peer, "exit").then(() => { throw new Error("wire fixture exited before ready: " + diagnostic); }),
        ]);
        client = new WebSocketAppServerClient({ path: socket }, "fixture", { connectTimeoutMs: 10000, requestTimeoutMs: 10000 });
      }
      bridge = await harness(transport, null, delivery, undefined, client);
      if (transport === "stdio") peer = client.child;
      if (mode === "accepted") await bridge.tryStartTurn();
      else await assert.rejects(bridge.tryStartTurn(), /fixture rejection/);
      const received = JSON.parse(fs.readFileSync(observation, "utf8"));
      assert.equal(received.counts, "1\n1", "body stays unread and leased at the actual transport peer");
      assert(received.input[0].text.includes("x".repeat(150000)));
      assert.equal(sql("SELECT count(*) FROM messages WHERE read_at IS NULL;"), mode === "accepted" ? "0" : "1");
      assert.equal(sql("SELECT count(*) FROM delivery_claims;"), mode === "unknown" ? "1" : "0");
      assert.equal(sql("SELECT count(*) FROM delivery_ack_receipts;"), mode === "accepted" ? "1" : "0");
      assert.equal(bridge.pendingWake, false);
      const next = new DeliveryClient(path.join(root, "scripts"), "bash", root).claim(pair);
      if (mode === "rejected") { assert(next, "definitely rejected payload is immediately available"); next.release(); }
      else assert.equal(next, null, "accepted or uncertain payload is not immediately replayed");
    });
  }
}
