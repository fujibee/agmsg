import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createControlServer, PROTOCOL_VERSION } from "../scripts/daemon/control.mjs";

function socketDir() {
  return mkdtempSync(join(tmpdir(), "agmsgd-control-test-"));
}

// Sends `lines` (already-terminated strings, or a raw prefix with no
// trailing newline for the overflow case) and collects every line the
// server sends back before the connection closes.
function talk(socketPath, rawBytesOrLines) {
  return new Promise((resolve, reject) => {
    const socket = createConnection(socketPath);
    const received = [];
    let buf = "";
    socket.on("connect", () => {
      const payload = Array.isArray(rawBytesOrLines) ? rawBytesOrLines.join("") : rawBytesOrLines;
      socket.write(payload);
    });
    socket.on("data", (chunk) => {
      buf += chunk.toString("utf8");
    });
    socket.on("close", () => {
      for (const line of buf.split("\n")) {
        if (line.length > 0) received.push(JSON.parse(line));
      }
      resolve(received);
    });
    socket.on("error", reject);
  });
}

test("control server: hello -> status is a clean one-shot round trip", async () => {
  const dir = socketDir();
  const socketPath = join(dir, "c.sock");
  try {
    const handle = await createControlServer(socketPath, {
      onStop: async () => ({ gen: 1 }),
      onStatus: async () => ({ state: "ready", gen: 1 }),
    });
    const lines = [
      `${JSON.stringify({ type: "hello", protocol: PROTOCOL_VERSION, role: "control" })}\n`,
      `${JSON.stringify({ type: "status" })}\n`,
    ];
    const received = await talk(socketPath, lines);
    assert.deepEqual(received, [
      { type: "hello_ok" },
      { type: "status", state: "ready", gen: 1 },
    ]);
    await handle.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("control server: hello -> stop round trip calls onStop and reports its result", async () => {
  const dir = socketDir();
  const socketPath = join(dir, "c.sock");
  try {
    let stopCalled = false;
    const handle = await createControlServer(socketPath, {
      onStop: async () => {
        stopCalled = true;
        return { gen: 3 };
      },
      onStatus: async () => ({}),
    });
    const lines = [
      `${JSON.stringify({ type: "hello", protocol: PROTOCOL_VERSION, role: "control" })}\n`,
      `${JSON.stringify({ type: "stop" })}\n`,
    ];
    const received = await talk(socketPath, lines);
    assert.equal(stopCalled, true);
    assert.deepEqual(received, [{ type: "hello_ok" }, { type: "stop_ok", gen: 3 }]);
    await handle.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("control server rejects a wrong protocol, a wrong role, a duplicate-key frame, and a second request on one connection", async () => {
  const dir = socketDir();
  const socketPath = join(dir, "c.sock");
  try {
    const handle = await createControlServer(socketPath, {
      onStop: async () => ({}),
      onStatus: async () => ({}),
    });

    let received = await talk(socketPath, [`${JSON.stringify({ type: "hello", protocol: 999, role: "control" })}\n`]);
    assert.equal(received[0].type, "error");
    assert.match(received[0].reason, /protocol/);

    received = await talk(socketPath, [`${JSON.stringify({ type: "hello", protocol: PROTOCOL_VERSION, role: "session" })}\n`]);
    assert.equal(received[0].type, "error");
    assert.match(received[0].reason, /role/);

    // A hand-built frame with a duplicate key -- parseStrictJson must
    // reject this even though JSON.parse alone would accept it silently.
    received = await talk(socketPath, ['{"type":"hello","protocol":1,"role":"control","protocol":1}\n']);
    assert.equal(received[0].type, "error");

    // A second request pipelined onto the same connection after the first
    // has already been answered: the connection is already ending by
    // then, so it gets silently dropped rather than a second response --
    // the point of the test is that this must NOT disturb or lose the
    // FIRST (real) response, which it did before this was fixed.
    const twoRequests = [
      `${JSON.stringify({ type: "hello", protocol: PROTOCOL_VERSION, role: "control" })}\n`,
      `${JSON.stringify({ type: "status" })}\n`,
      `${JSON.stringify({ type: "status" })}\n`,
    ];
    received = await talk(socketPath, twoRequests);
    assert.deepEqual(received, [{ type: "hello_ok" }, { type: "status" }]);

    await handle.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("control server cuts a connection that exceeds the 1 MiB frame ceiling before a newline arrives", async () => {
  const dir = socketDir();
  const socketPath = join(dir, "c.sock");
  try {
    const handle = await createControlServer(socketPath, {
      onStop: async () => ({}),
      onStatus: async () => ({}),
    });
    const oversized = "x".repeat(1024 * 1024 + 10); // no trailing newline
    const received = await talk(socketPath, [oversized]);
    // The connection is destroyed outright -- no response line at all,
    // just a close.
    assert.deepEqual(received, []);
    await handle.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
