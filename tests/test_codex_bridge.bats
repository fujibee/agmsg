#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
}

teardown() {
  rm -rf "$PROJ"
  teardown_test_env
}

write_bridge_timeout_runner() {
  local runner="$TEST_SKILL_DIR/run-with-timeout.js"
  cat >"$runner" <<'EOF'
const { spawn } = require("child_process");

const timeoutMs = Number(process.argv[2]);
const command = process.argv[3];
const args = process.argv.slice(4);
let timedOut = false;
let exited = false;
let stdout = "";
let stderr = "";

const child = spawn(command, args, { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
child.stdout.on("data", (chunk) => { stdout += chunk; });
child.stderr.on("data", (chunk) => { stderr += chunk; });
child.on("error", (error) => {
  process.stderr.write(error.message);
  process.exit(127);
});

const timer = setTimeout(() => {
  timedOut = true;
  child.kill("SIGTERM");
  setTimeout(() => {
    if (!exited) child.kill("SIGKILL");
  }, 250).unref();
}, timeoutMs);

child.on("close", (code) => {
  exited = true;
  clearTimeout(timer);
  process.stdout.write(stdout);
  process.stderr.write(stderr);
  process.exit(timedOut ? 124 : (code ?? 1));
});
EOF
  printf '%s\n' "$runner"
}

@test "codex-bridge: help exits successfully" {
  run node "$TYPES/codex/codex-bridge.js" --help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Beta Codex app-server bridge" ]]
}

@test "codex-bridge: resolve-only prints the selected identity" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --team team --name alice --resolve-only
  [ "$status" -eq 0 ]
  [ "$output" = $'team\talice' ]
}

@test "codex-bridge: resolve-only rejects ambiguous identities" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --resolve-only
  [ "$status" -eq 1 ]
  [[ "$output" =~ "multiple identities match" ]]
}

@test "codex-bridge: rejects unsupported app-server endpoints" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --team team --name alice --app-server http://127.0.0.1:9999
  [ "$status" -eq 1 ]
  [[ "$output" =~ "supports only unix://PATH or ws://host:port" ]]
}

@test "codex-bridge: connects to unix app-server sockets over websocket" {
  run node -e 'const net = require("net"); const crypto = require("crypto"); if (!net || !crypto) process.exit(1);'
  if [ "$status" -ne 0 ]; then
    skip "node net/crypto modules are not available in this sandbox"
  fi
  run node -e 'const fs = require("fs"); const net = require("net"); const sock = process.argv[1]; try { fs.unlinkSync(sock); } catch (_) {} const server = net.createServer(); server.on("error", () => process.exit(2)); server.listen(sock, () => server.close(() => { try { fs.unlinkSync(sock); } catch (_) {} process.exit(0); }));' "$TEST_SKILL_DIR/probe.sock"
  if [ "$status" -ne 0 ]; then
    skip "unix socket listen is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-ws-app-server.js"
  local sock="$TEST_SKILL_DIR/fake-ws-app-server.sock"
  local log="$TEST_SKILL_DIR/fake-ws-app-server.log"
  cat >"$fake" <<'EOF'
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");

const sock = process.argv[2];
const log = process.argv[3];
try { fs.unlinkSync(sock); } catch (_) {}

function sendFrame(socket, value) {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function handleMessage(socket, message) {
  fs.appendFileSync(log, `${message.method}\n`);
  if (message.method === "initialize") {
    sendFrame(socket, { jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    sendFrame(socket, {
      jsonrpc: "2.0",
      id: message.id,
      result: { thread: { id: message.params.threadId, status: { type: "idle" } } },
    });
  } else if (message.method === "process/spawn") {
    sendFrame(socket, { jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      sendFrame(socket, {
        jsonrpc: "2.0",
        method: "process/exited",
        params: {
          processHandle: message.params.processHandle,
          exitCode: 0,
          stdout: "status=pending count=1 max_id=1\n",
          stderr: "",
        },
      });
    }, 10);
  } else if (message.method === "turn/start") {
    sendFrame(socket, { jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      sendFrame(socket, {
        jsonrpc: "2.0",
        method: "turn/completed",
        params: { threadId: message.params.threadId, turn: { id: "turn-1" } },
      });
    }, 10);
  }
}

function parseFrames(socket, state, chunk) {
  state.buffer = Buffer.concat([state.buffer, chunk]);
  while (state.buffer.length >= 2) {
    const opcode = state.buffer[0] & 0x0f;
    let length = state.buffer[1] & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (state.buffer.length < offset + 2) return;
      length = state.buffer.readUInt16BE(offset);
      offset += 2;
    } else if (length === 127) {
      if (state.buffer.length < offset + 8) return;
      length = state.buffer.readUInt32BE(offset + 4);
      offset += 8;
    }
    const masked = (state.buffer[1] & 0x80) !== 0;
    const maskOffset = offset;
    if (masked) offset += 4;
    if (state.buffer.length < offset + length) return;
    let payload = state.buffer.slice(offset, offset + length);
    if (masked) {
      const mask = state.buffer.slice(maskOffset, maskOffset + 4);
      payload = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
    }
    state.buffer = state.buffer.slice(offset + length);
    if (opcode === 0x1) handleMessage(socket, JSON.parse(payload.toString("utf8")));
  }
}

const server = net.createServer((socket) => {
  const state = { buffer: Buffer.alloc(0), upgraded: false, header: Buffer.alloc(0) };
  socket.on("data", (chunk) => {
    if (!state.upgraded) {
      state.header = Buffer.concat([state.header, chunk]);
      const end = state.header.indexOf("\r\n\r\n");
      if (end === -1) return;
      const header = state.header.slice(0, end).toString("utf8");
      const rest = state.header.slice(end + 4);
      const key = (header.match(/Sec-WebSocket-Key: (.*)\r\n/i) || [])[1].trim();
      const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
      socket.write([
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        `Sec-WebSocket-Accept: ${accept}`,
        "",
        "",
      ].join("\r\n"));
      state.upgraded = true;
      if (rest.length > 0) parseFrames(socket, state, rest);
      return;
    }
    parseFrames(socket, state, chunk);
  });
  socket.on("close", () => server.close(() => process.exit(0)));
});

server.listen(sock);
EOF

  node "$fake" "$sock" "$log" &
  local server_pid="$!"
  for _ in {1..50}; do
    [ -S "$sock" ] && break
    sleep 0.1
  done

  run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-existing \
    --app-server "unix://$sock" --timeout 1 --interval 1 --max-wakes 1

  kill "$server_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [[ "$output" =~ "resumed thread thread-existing" ]]
  [[ "$output" =~ "started turn" ]]
  grep -q "initialize" "$log"
  grep -q "thread/resume" "$log"
  grep -q "process/spawn" "$log"
  grep -q "turn/start" "$log"
}

@test "codex-bridge: connects to ws://host:port app-server endpoints" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node -e 'const net = require("net"); const crypto = require("crypto"); if (!net || !crypto) process.exit(1);'
  if [ "$status" -ne 0 ]; then
    skip "node net/crypto modules are not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-ws-tcp-app-server.js"
  local portfile="$TEST_SKILL_DIR/fake-ws-tcp.port"
  local log="$TEST_SKILL_DIR/fake-ws-tcp-app-server.log"
  rm -f "$portfile"
  cat >"$fake" <<'EOF'
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");

const portfile = process.argv[2];
const log = process.argv[3];

function sendFrame(socket, value) {
  const payload = Buffer.from(JSON.stringify(value), "utf8");
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x81, payload.length]);
  } else {
    header = Buffer.alloc(4);
    header[0] = 0x81;
    header[1] = 126;
    header.writeUInt16BE(payload.length, 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

function handleMessage(socket, message) {
  fs.appendFileSync(log, `${message.method}\n`);
  if (message.method === "initialize") {
    sendFrame(socket, { jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    sendFrame(socket, {
      jsonrpc: "2.0",
      id: message.id,
      result: { thread: { id: message.params.threadId, status: { type: "idle" } } },
    });
  } else if (message.method === "process/spawn") {
    sendFrame(socket, { jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      sendFrame(socket, {
        jsonrpc: "2.0",
        method: "process/exited",
        params: { processHandle: message.params.processHandle, exitCode: 0, stdout: "status=pending count=1 max_id=1\n", stderr: "" },
      });
    }, 10);
  } else if (message.method === "turn/start") {
    sendFrame(socket, { jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      sendFrame(socket, { jsonrpc: "2.0", method: "turn/completed", params: { threadId: message.params.threadId, turn: { id: "turn-1" } } });
    }, 10);
  }
}

function parseFrames(socket, state, chunk) {
  state.buffer = Buffer.concat([state.buffer, chunk]);
  while (state.buffer.length >= 2) {
    const opcode = state.buffer[0] & 0x0f;
    let length = state.buffer[1] & 0x7f;
    let offset = 2;
    if (length === 126) {
      if (state.buffer.length < offset + 2) return;
      length = state.buffer.readUInt16BE(offset);
      offset += 2;
    }
    const masked = (state.buffer[1] & 0x80) !== 0;
    const maskOffset = offset;
    if (masked) offset += 4;
    if (state.buffer.length < offset + length) return;
    let payload = state.buffer.slice(offset, offset + length);
    if (masked) {
      const mask = state.buffer.slice(maskOffset, maskOffset + 4);
      payload = Buffer.from(payload.map((byte, index) => byte ^ mask[index % 4]));
    }
    state.buffer = state.buffer.slice(offset + length);
    if (opcode === 0x1) handleMessage(socket, JSON.parse(payload.toString("utf8")));
  }
}

const server = net.createServer((socket) => {
  const state = { buffer: Buffer.alloc(0), upgraded: false, header: Buffer.alloc(0) };
  socket.on("data", (chunk) => {
    if (!state.upgraded) {
      state.header = Buffer.concat([state.header, chunk]);
      const end = state.header.indexOf("\r\n\r\n");
      if (end === -1) return;
      const header = state.header.slice(0, end).toString("utf8");
      const rest = state.header.slice(end + 4);
      const key = (header.match(/Sec-WebSocket-Key: (.*)\r\n/i) || [])[1].trim();
      const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
      socket.write(["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", `Sec-WebSocket-Accept: ${accept}`, "", ""].join("\r\n"));
      state.upgraded = true;
      if (rest.length > 0) parseFrames(socket, state, rest);
      return;
    }
    parseFrames(socket, state, chunk);
  });
  socket.on("close", () => server.close(() => process.exit(0)));
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portfile, String(server.address().port));
});
EOF

  node "$fake" "$portfile" "$log" &
  local server_pid="$!"
  for _ in {1..50}; do
    [ -s "$portfile" ] && break
    sleep 0.1
  done
  local port
  port="$(cat "$portfile")"

  run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-existing \
    --app-server "ws://127.0.0.1:$port" --timeout 1 --interval 1 --max-wakes 1

  kill "$server_pid" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [[ "$output" =~ "resumed thread thread-existing" ]]
  grep -q "initialize" "$log"
  grep -q "thread/resume" "$log"
}

@test "codex-bridge: times out when a websocket upgrade never completes" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node -e 'const net = require("net"); if (!net) process.exit(1);'
  if [ "$status" -ne 0 ]; then
    skip "node net module is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-ws-handshake-stall.js"
  local portfile="$TEST_SKILL_DIR/fake-ws-handshake-stall.port"
  local log="$TEST_SKILL_DIR/fake-ws-handshake-stall.log"
  rm -f "$portfile"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const net = require("net");

const portfile = process.argv[2];
const log = process.argv[3];

const server = net.createServer((socket) => {
  fs.appendFileSync(log, "accepted\n");
  socket.on("data", () => {
    fs.appendFileSync(log, "received-handshake\n");
  });
  socket.on("close", () => server.close(() => process.exit(0)));
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portfile, String(server.address().port));
});
EOF

  node "$fake" "$portfile" "$log" &
  local server_pid="$!"
  for _ in {1..50}; do
    [ -s "$portfile" ] && break
    sleep 0.1
  done
  local port
  port="$(cat "$portfile")"
  local runner
  runner="$(write_bridge_timeout_runner)"

  run node "$runner" 3000 node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-existing \
    --app-server "ws://127.0.0.1:$port" --connect-timeout-ms 100 --request-timeout-ms 1000 \
    --timeout 1 --interval 1

  kill "$server_pid" 2>/dev/null || true

  [ "$status" -eq 1 ]
  [[ "$output" =~ "websocket handshake timed out" ]]
  grep -q "accepted" "$log"
  grep -q "received-handshake" "$log"
}

@test "codex-bridge: times out when an app-server request never responds" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node -e 'const net = require("net"); const crypto = require("crypto"); if (!net || !crypto) process.exit(1);'
  if [ "$status" -ne 0 ]; then
    skip "node net/crypto modules are not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-ws-request-stall.js"
  local portfile="$TEST_SKILL_DIR/fake-ws-request-stall.port"
  local log="$TEST_SKILL_DIR/fake-ws-request-stall.log"
  rm -f "$portfile"
  cat >"$fake" <<'EOF'
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");

const portfile = process.argv[2];
const log = process.argv[3];

const server = net.createServer((socket) => {
  const state = { upgraded: false, header: Buffer.alloc(0) };
  socket.on("data", (chunk) => {
    if (!state.upgraded) {
      state.header = Buffer.concat([state.header, chunk]);
      const end = state.header.indexOf("\r\n\r\n");
      if (end === -1) return;
      const header = state.header.slice(0, end).toString("utf8");
      const key = (header.match(/Sec-WebSocket-Key: (.*)\r\n/i) || [])[1].trim();
      const accept = crypto.createHash("sha1").update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
      socket.write(["HTTP/1.1 101 Switching Protocols", "Upgrade: websocket", "Connection: Upgrade", `Sec-WebSocket-Accept: ${accept}`, "", ""].join("\r\n"));
      fs.appendFileSync(log, "upgraded\n");
      state.upgraded = true;
      return;
    }
    fs.appendFileSync(log, "ignored-frame\n");
  });
  socket.on("close", () => server.close(() => process.exit(0)));
});

server.listen(0, "127.0.0.1", () => {
  fs.writeFileSync(portfile, String(server.address().port));
});
EOF

  node "$fake" "$portfile" "$log" &
  local server_pid="$!"
  for _ in {1..50}; do
    [ -s "$portfile" ] && break
    sleep 0.1
  done
  local port
  port="$(cat "$portfile")"
  local runner
  runner="$(write_bridge_timeout_runner)"

  run node "$runner" 3000 node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-existing \
    --app-server "ws://127.0.0.1:$port" --connect-timeout-ms 1000 --request-timeout-ms 100 \
    --timeout 1 --interval 1

  kill "$server_pid" 2>/dev/null || true

  [ "$status" -eq 1 ]
  [[ "$output" =~ "app-server request 'initialize' timed out" ]]
  grep -q "upgraded" "$log"
  grep -q "ignored-frame" "$log"
}

@test "codex-bridge: times out when a stdio app-server request never responds" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-stdio-request-stall.js"
  local log="$TEST_SKILL_DIR/fake-stdio-request-stall.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");

const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });

rl.on("line", (line) => {
  const message = JSON.parse(line);
  fs.appendFileSync(log, `${message.method}\n`);
  // Deliberately keep the process alive and never answer initialize.
});
EOF

  local runner
  runner="$(write_bridge_timeout_runner)"

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$runner" 3000 node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-existing \
    --request-timeout-ms 500 --timeout 1 --interval 1

  [ "$status" -eq 1 ]
  [[ "$output" =~ "app-server request 'initialize' timed out" ]]
  grep -q "initialize" "$log"
}

@test "codex-bridge: refuses when the same identity already has a live bridge" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  mkdir -p "$TEST_SKILL_DIR/run"
  echo "$$" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"

  run node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --team team --name alice
  [ "$status" -eq 1 ]
  [[ "$output" =~ "bridge already running" ]]
}

@test "codex-bridge: starts a turn when app-server reports watch-once pending" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: { thread: { id: "thread-1", status: { type: "idle" } } },
    });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "process/exited",
        params: {
          processHandle: message.params.processHandle,
          exitCode: 0,
          stdout: "status=pending count=1 max_id=1\n",
          stderr: "",
        },
      });
    }, 10);
  } else if (message.method === "turn/start") {
    if (!message.params.input[0].text.includes("agmsg has unread messages")) {
      send({ jsonrpc: "2.0", id: message.id, error: { message: "missing wakeup prompt" } });
      return;
    }
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "turn/completed",
        params: { threadId: message.params.threadId, turn: { id: "turn-1" } },
      });
    }, 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 --max-wakes 1

  [ "$status" -eq 0 ]
  [[ "$output" =~ "wakeup 1" ]]
}

@test "codex-bridge: resumes an existing thread before arming" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-resume.js"
  local log="$TEST_SKILL_DIR/fake-app-server-resume.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  fs.appendFileSync(log, `${message.method}\n`);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: { thread: { id: message.params.threadId, status: { type: "idle" } } },
    });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => process.exit(0), 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-existing --timeout 20

  [ "$status" -eq 0 ]
  grep -q "thread/resume" "$log"
  ! grep -q "thread/start" "$log"
}

@test "codex-bridge: --thread loaded discovers the live thread via thread/loaded/list" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-loaded.js"
  local log="$TEST_SKILL_DIR/fake-app-server-loaded.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  fs.appendFileSync(log, `${message.method}\n`);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/loaded/list") {
    send({ jsonrpc: "2.0", id: message.id, result: { data: ["thread-live-42"] } });
  } else if (message.method === "thread/resume") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: { thread: { id: message.params.threadId, status: { type: "idle" } } },
    });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => process.exit(0), 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread loaded --loaded-timeout 5000 --timeout 20

  [ "$status" -eq 0 ]
  grep -q "thread/loaded/list" "$log"
  grep -q "thread/resume" "$log"
  ! grep -q "thread/start" "$log"
}

@test "codex-bridge: --thread loaded errors when no thread is loaded in time" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-empty-loaded.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/loaded/list") {
    send({ jsonrpc: "2.0", id: message.id, result: { data: [] } });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread loaded --loaded-timeout 1500 --timeout 20

  [ "$status" -ne 0 ]
  [[ "$output" =~ "no loaded codex thread" ]]
}

@test "codex-bridge: inline-inbox includes unread message text in turn input" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  bash "$SCRIPTS/send.sh" team bob alice "inline body reaches prompt" >/dev/null

  local fake="$TEST_SKILL_DIR/fake-app-server-inline.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: { thread: { id: "thread-1", status: { type: "idle" } } },
    });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "process/exited",
        params: {
          processHandle: message.params.processHandle,
          exitCode: 0,
          stdout: "status=pending count=1 max_id=1\n",
          stderr: "",
        },
      });
    }, 10);
  } else if (message.method === "turn/start") {
    if (!message.params.input[0].text.includes("inline body reaches prompt")) {
      send({ jsonrpc: "2.0", id: message.id, error: { message: "missing inline inbox body" } });
      return;
    }
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "turn/completed",
        params: { threadId: message.params.threadId, turn: { id: "turn-1" } },
      });
    }, 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 --max-wakes 1 --inline-inbox

  [ "$status" -eq 0 ]
  [[ "$output" =~ "started turn" ]]
}

@test "codex-bridge: stops instead of looping on the same unread max_id" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-loop.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
let spawns = 0;

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({
      jsonrpc: "2.0",
      id: message.id,
      result: { thread: { id: "thread-1", status: { type: "idle" } } },
    });
  } else if (message.method === "process/spawn") {
    spawns += 1;
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "process/exited",
        params: {
          processHandle: message.params.processHandle,
          exitCode: 0,
          stdout: `status=pending count=1 max_id=7\nspawn=${spawns}\n`,
          stderr: "",
        },
      });
    }, 10);
  } else if (message.method === "turn/start") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "turn/completed",
        params: { threadId: message.params.threadId, turn: { id: "turn-1" } },
      });
    }, 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1

  [ "$status" -eq 1 ]
  [[ "$output" =~ "wakeup 1" ]]
  [[ "$output" =~ "stopping to avoid a repeated wakeup loop" ]]
}

@test "codex-bridge: stops after the configured watch-once failure limit" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-watch-fail.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "process/exited",
        params: {
          processHandle: message.params.processHandle,
          exitCode: 1,
          stdout: "",
          stderr: "fake watch failure",
        },
      });
    }, 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 \
    --request-timeout-ms 1000 --watch-failure-limit 1

  [ "$status" -eq 1 ]
  [[ "$output" =~ "watch-once failed with exit 1: fake watch failure" ]]
  [[ "$output" =~ "stopping after 1 consecutive watch-once failure" ]]
}

@test "codex-bridge: watch-once timeout exit does not count toward failure limit" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-watch-timeout-then-wake.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
let spawns = 0;

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    spawns += 1;
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      if (spawns === 1) {
        send({
          jsonrpc: "2.0",
          method: "process/exited",
          params: { processHandle: message.params.processHandle, exitCode: 2, stdout: "", stderr: "" },
        });
        return;
      }
      send({
        jsonrpc: "2.0",
        method: "process/exited",
        params: {
          processHandle: message.params.processHandle,
          exitCode: 0,
          stdout: "status=pending count=1 max_id=1\n",
          stderr: "",
        },
      });
    }, 10);
  } else if (message.method === "turn/start") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "turn/completed", params: { threadId: message.params.threadId, turn: { id: "turn-1" } } });
    }, 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 \
    --request-timeout-ms 1000 --watch-failure-limit 1 --max-wakes 1

  [ "$status" -eq 0 ]
  [[ "$output" =~ "wakeup 1" ]]
  [[ "$output" != *"stopping after"* ]]
}

@test "codex-bridge: re-arm spawn request timeout exits without a phantom watch" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-rearm-spawn-stall.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
let spawns = 0;

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    spawns += 1;
    if (spawns === 1) {
      send({ jsonrpc: "2.0", id: message.id, result: {} });
      setTimeout(() => {
        send({
          jsonrpc: "2.0",
          method: "process/exited",
          params: { processHandle: message.params.processHandle, exitCode: 2, stdout: "", stderr: "" },
        });
      }, 10);
    }
    // The second process/spawn deliberately never receives a response.
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  local runner
  runner="$(write_bridge_timeout_runner)"

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$runner" 3000 node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 \
    --request-timeout-ms 500 --watch-failure-limit 1

  [ "$status" -eq 1 ]
  [[ "$output" =~ "process/exited handler failed: app-server request 'process/spawn' timed out" ]]
}

@test "codex-bridge: delayed re-arm after sub-limit watch failure times out fatally" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-delayed-rearm-stall.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
let spawns = 0;

function send(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    spawns += 1;
    if (spawns === 1) {
      send({ jsonrpc: "2.0", id: message.id, result: {} });
      setTimeout(() => {
        send({
          jsonrpc: "2.0",
          method: "process/exited",
          params: {
            processHandle: message.params.processHandle,
            exitCode: 1,
            stdout: "",
            stderr: "fake transient watch failure",
          },
        });
      }, 10);
    }
    // The delayed re-arm process/spawn deliberately never receives a response.
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  local runner
  runner="$(write_bridge_timeout_runner)"

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$runner" 10000 node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 \
    --request-timeout-ms 3000 --watch-failure-limit 2

  [ "$status" -eq 1 ]
  [[ "$output" =~ "watch-once failed with exit 1: fake transient watch failure" ]]
  [[ "$output" =~ "process/exited handler failed: app-server request 'process/spawn' timed out" ]]
  [[ "$output" != *"stopping after 2 consecutive watch-once failure"* ]]
}

# --- re-arm regression (#41): real app-server may never send turn/completed ---

@test "codex-bridge: re-arms after a turn via the watchdog when no turn/completed arrives" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  # Fake app-server that ACKs turn/start but NEVER sends turn/completed or idle.
  # Each watch-once spawn reports a fresh (incrementing) max_id so the wake is
  # not treated as stale. Without re-arm, the bridge would stop after wakeup 1.
  local fake="$TEST_SKILL_DIR/fake-app-server-norearm.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
let maxId = 0;
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    maxId += 1;
    const id = maxId;
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "process/exited", params: { processHandle: message.params.processHandle, exitCode: 0, stdout: `status=pending count=1 max_id=${id}\n`, stderr: "" } });
    }, 10);
  } else if (message.method === "turn/start") {
    // ACK only — deliberately emit no turn/completed and no idle status.
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 --turn-timeout 1 --max-wakes 2

  [ "$status" -eq 0 ]
  [[ "$output" =~ "wakeup 1" ]]
  [[ "$output" =~ "wakeup 2" ]]   # proves the watch-once was re-armed without turn/completed
}

@test "codex-bridge: re-arms after a turn when the app-server reports idle (not turn/completed)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-idle.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
let maxId = 0;
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    maxId += 1;
    const id = maxId;
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "process/exited", params: { processHandle: message.params.processHandle, exitCode: 0, stdout: `status=pending count=1 max_id=${id}\n`, stderr: "" } });
    }, 10);
  } else if (message.method === "turn/start") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    // Report idle instead of turn/completed — the bridge must treat idle as the
    // end of the turn and re-arm.
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "thread/status/changed", params: { threadId: message.params.threadId, status: { type: "idle" } } });
    }, 20);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 --turn-timeout 30 --max-wakes 2

  [ "$status" -eq 0 ]
  [[ "$output" =~ "wakeup 1" ]]
  [[ "$output" =~ "wakeup 2" ]]
}

@test "codex-bridge: delivers a wake observed while the resumed thread was still active (no stale-stop)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  # Regression: the bridge resumes an ALREADY-ACTIVE thread (SessionStart fires
  # on the first user turn, so the human's turn is in flight when the bridge
  # attaches). watch-once fires while that turn runs, so tryStartTurn() defers
  # the wake. When the thread later goes idle, onTurnEnded() must DELIVER the
  # pending wake — not just re-arm, which would re-observe the same unread
  # max_id and stop the bridge on the stale-wake guard (exit 1).
  local fake="$TEST_SKILL_DIR/fake-app-server-active-resume.js"
  local log="$TEST_SKILL_DIR/fake-app-server-active-resume.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });
let turns = 0;
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  const message = JSON.parse(line);
  fs.appendFileSync(log, `${message.method}\n`);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    // Resume an already-ACTIVE thread; the human's turn ends shortly after.
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: message.params.threadId, status: { type: "active" } } } });
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "thread/status/changed", params: { threadId: message.params.threadId, status: { type: "idle" } } });
    }, 80);
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    // Same unread max_id (5) until the wake is delivered; a second message (6)
    // appears afterwards so the run terminates via --max-wakes.
    const id = turns === 0 ? 5 : 6;
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "process/exited", params: { processHandle: message.params.processHandle, exitCode: 0, stdout: `status=pending count=1 max_id=${id}\n`, stderr: "" } });
    }, 10);
  } else if (message.method === "turn/start") {
    turns += 1;
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "turn/completed", params: { threadId: message.params.threadId } });
    }, 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-active --timeout 1 --interval 1 --turn-timeout 30 --max-wakes 2

  [ "$status" -eq 0 ]              # not exit 1 from the stale-wake guard
  [[ "$output" =~ "wakeup 1" ]]
  [[ "$output" =~ "wakeup 2" ]]    # proves wakeup 1 was delivered, not stale-stopped
  grep -q "turn/start" "$log"      # the deferred wake actually reached a turn
}
