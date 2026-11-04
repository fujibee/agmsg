"use strict";
// A disposable protocol fixture. It never launches Codex or any app-server.
const fs = require("fs");
const net = require("net");
const crypto = require("crypto");
const readline = require("readline");
const [mode, log, portfile] = process.argv.slice(2);
const record = (text) => fs.appendFileSync(log, `${text}\n`);
record(`pid=${process.pid}`);
let initializations = 0, discoveries = 0, arms = 0, connections = 0;
function handler(send, disconnect = () => {}) {
  return (message) => {
    record(message.method);
    const answer = (result) => send({ jsonrpc: "2.0", id: message.id, result });
    if (message.method === "initialize") {
      initializations += 1;
      if (mode === "stdio-init" && initializations === 1) return;
      answer({});
    } else if (message.method === "thread/loaded/list") {
      discoveries += 1;
      answer({ data: discoveries < 3 ? [] : ["thread-existing"] });
    } else if (message.method === "thread/resume") {
      answer({ thread: { id: message.params.threadId, status: { type: "idle" } } });
    } else if (message.method === "process/spawn") {
      arms += 1;
      answer({});
      if (mode === "ws-reconnect" && arms === 1) { setTimeout(disconnect, 20); return; }
      setTimeout(() => send({ jsonrpc: "2.0", method: "process/exited", params: {
        processHandle: message.params.processHandle, exitCode: 0,
        stdout: `pending max_id=frontier-${arms}`, stderr: "",
      } }), 20);
    } else if (message.method === "turn/start") {
      const threadId = message.params.threadId;
      if (mode === "stdio-uncertain" || mode === "stdio-late-completion") {
        send({ jsonrpc: "2.0", method: "turn/started", params: { threadId, turn: { id: "unacknowledged-turn" } } });
        setTimeout(() => {
          send({ jsonrpc: "2.0", method: "thread/status/changed", params: { threadId, status: { type: "idle" } } });
          send({ jsonrpc: "2.0", method: "turn/completed", params: { threadId, turn: { id: mode === "stdio-late-completion" ? "unacknowledged-turn" : "previous-turn" } } });
        }, 800);
        return;
      }
      answer({ turn: { id: "confirmed-turn" } });
      setTimeout(() => send({ jsonrpc: "2.0", method: "turn/completed", params: { threadId, turn: { id: "confirmed-turn" } } }), 20);
    } else if (message.method === "process/kill") answer({});
  };
}
if (mode !== "ws-reconnect") {
  const rl = readline.createInterface({ input: process.stdin });
  rl.on("line", (line) => handler((value) => process.stdout.write(`${JSON.stringify(value)}\n`))(JSON.parse(line)));
  rl.on("close", () => process.exit(0));
} else {
  function send(socket, value) {
    const payload = Buffer.from(JSON.stringify(value));
    const header = payload.length < 126 ? Buffer.from([0x81, payload.length]) : Buffer.alloc(4);
    if (payload.length >= 126) { header[0] = 0x81; header[1] = 126; header.writeUInt16BE(payload.length, 2); }
    if (!socket.destroyed) socket.write(Buffer.concat([header, payload]));
  }
  const server = net.createServer((socket) => {
    connections += 1;
    record(`connection=${connections}`);
    let input = Buffer.alloc(0), upgraded = false;
    const stalled = connections === 1;
    const onMessage = handler((value) => send(socket, value), () => socket.destroy());
    socket.on("error", () => {});
    socket.on("data", (chunk) => {
      if (stalled) return;
      input = Buffer.concat([input, chunk]);
      if (!upgraded) {
        const end = input.indexOf("\r\n\r\n");
        if (end < 0) return;
        const key = input.subarray(0, end).toString().match(/Sec-WebSocket-Key: ([^\r]+)/i)[1].trim();
        const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
        socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
        input = input.subarray(end + 4); upgraded = true;
      }
      while (input.length >= 2) {
        let length = input[1] & 127, offset = 2;
        if (length === 126) { if (input.length < 4) return; length = input.readUInt16BE(2); offset = 4; }
        else if (length === 127) { if (input.length < 10) return; length = Number(input.readBigUInt64BE(2)); offset = 10; }
        const masked = (input[1] & 128) !== 0;
        const maskOffset = offset;
        if (masked) offset += 4;
        if (input.length < offset + length) return;
        const payload = Buffer.from(input.subarray(offset, offset + length));
        if (masked) for (let i = 0; i < length; i += 1) payload[i] ^= input[maskOffset + i % 4];
        const opcode = input[0] & 15;
        input = input.subarray(offset + length);
        if (opcode === 1) onMessage(JSON.parse(payload.toString()));
      }
    });
  });
  server.listen(0, "127.0.0.1", () => fs.writeFileSync(portfile, String(server.address().port)));
}
