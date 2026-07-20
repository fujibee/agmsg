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

@test "codex-bridge: toPosixPath maps Windows drive paths to POSIX paths" {
  run node -e 'const { toPosixPath } = require(process.argv[1]); const expected = "/c/Users/me/OneDrive/codex-work"; if (toPosixPath(String.raw`C:\Users\me\OneDrive\codex-work`) !== expected) process.exit(1); if (toPosixPath("C:/Users/me/OneDrive/codex-work") !== expected) process.exit(1);' "$TYPES/codex/codex-bridge.js"
  [ "$status" -eq 0 ]
}

@test "codex-bridge: toPosixPath leaves POSIX paths unchanged" {
  run node -e 'const { toPosixPath } = require(process.argv[1]); if (toPosixPath("/c/Users/me/OneDrive/codex-work") !== "/c/Users/me/OneDrive/codex-work") process.exit(1); if (toPosixPath("/home/me/x") !== "/home/me/x") process.exit(1);' "$TYPES/codex/codex-bridge.js"
  [ "$status" -eq 0 ]
}

@test "codex-bridge: toPosixPath maps UNC paths to POSIX paths" {
  run node -e 'const { toPosixPath } = require(process.argv[1]); if (toPosixPath(String.raw`\\host\share\proj`) !== "//host/share/proj") process.exit(1);' "$TYPES/codex/codex-bridge.js"
  [ "$status" -eq 0 ]
}

@test "codex-bridge: toPosixPath preserves a literal backslash in a POSIX path" {
  # On POSIX hosts a backslash is a valid filename character; a driveless path
  # must be returned byte-for-byte so a genuine registration is not mangled.
  run node -e 'const { toPosixPath } = require(process.argv[1]); const p = String.raw`/tmp/proj\withslash`; if (toPosixPath(p) !== p) process.exit(1);' "$TYPES/codex/codex-bridge.js"
  [ "$status" -eq 0 ]
}

@test "codex-bridge: resolve-only prints the selected identity" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --team team --name alice --resolve-only
  [ "$status" -eq 0 ]
  [ "$output" = $'team\talice' ]
}

@test "codex-bridge: resolve-only rejects multiple identities without a role pair" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --resolve-only
  [ "$status" -eq 1 ]
  [[ "$output" =~ "launch one bridge per --pair" ]]
}

@test "codex-bridge: explicit --pair keeps a single identity" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  run node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --pair $'team\tbob' --resolve-only
  [ "$status" -eq 0 ]
  [ "$output" = $'team\tbob' ]
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

@test "codex-bridge: accepts its PID when the launcher records it before startup (#442)" {
  skip_on_windows "codex bridge identity resolution on Windows (#182)"
  mkdir -p "$TEST_SKILL_DIR/run"
  local wrapper="$TEST_SKILL_DIR/run-with-preseeded-pid.sh"
  cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
pidfile="$1"
shift
printf '%s\n' "$$" > "$pidfile"
exec "$@"
EOF
  chmod +x "$wrapper"

  AGMSG_CODEX_APP_SERVER_CMD="exit 1" run "$wrapper" \
    "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid" \
    node "$TYPES/codex/codex-bridge.js" --project "$PROJ" --team team --name alice

  [ "$status" -ne 0 ]
  [[ ! "$output" =~ "bridge already running" ]]
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

@test "codex-bridge: falls back to idle instead of dying when thread/resume itself fails (#276)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  # Codex 0.142+'s --remote sessions may not create a rollout, so the
  # thread/resume request itself can fail outright (not merely return a
  # mismatched thread). turn/start only needs threadId, so the bridge should
  # keep running in idle state instead of die()ing.
  local fake="$TEST_SKILL_DIR/fake-app-server-resume-fails.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    send({ jsonrpc: "2.0", id: message.id, error: { message: "no rollout for this thread" } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({
        jsonrpc: "2.0",
        method: "process/exited",
        params: { processHandle: message.params.processHandle, exitCode: 0, stdout: "status=pending count=1 max_id=1\n", stderr: "" },
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
    --project "$PROJ" --team team --name alice --thread thread-no-rollout \
    --timeout 1 --interval 1 --max-wakes 1

  [ "$status" -eq 0 ]
  [[ "$output" =~ "thread/resume failed" ]]
  [[ "$output" =~ "proceeding without resume" ]]
  [[ "$output" =~ "started turn" ]]
}

@test "codex-bridge: still dies when thread/resume succeeds but returns the wrong thread id (#276)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  # This is a DISTINCT failure mode from the request itself erroring -- the
  # request succeeded but the app-server handed back a different thread. The
  # #276 fallback must not swallow it: the try/catch added there wraps only
  # the request, not this validation.
  local fake="$TEST_SKILL_DIR/fake-app-server-resume-wrong-id.js"
  cat >"$fake" <<'EOF'
const readline = require("readline");
const rl = readline.createInterface({ input: process.stdin });
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "some-other-thread", status: { type: "idle" } } } });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-expected --timeout 20

  [ "$status" -ne 0 ]
  [[ "$output" =~ "did not return the requested thread id" ]]
  [[ "$output" != *"proceeding without resume"* ]]
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
    const expectedRoots = [
      process.env.PROJ,
      `${process.env.TEST_SKILL_DIR}/custom-store`,
      `${process.env.TEST_SKILL_DIR}/teams`,
      `${process.env.TEST_SKILL_DIR}/run`,
    ];
    if (JSON.stringify(message.params.runtimeWorkspaceRoots) !== JSON.stringify(expectedRoots)) {
      send({ jsonrpc: "2.0", id: message.id, error: { message: "wrong runtime workspace roots" } });
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
    --project "$PROJ" \
    --workspace-root "$TEST_SKILL_DIR/custom-store" \
    --workspace-root "$TEST_SKILL_DIR/teams" \
    --workspace-root "$TEST_SKILL_DIR/run" \
    --workspace-root "$PROJ" \
    --team team --name alice --timeout 1 --interval 1 --max-wakes 1 --inline-inbox

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

# --- deadlock hardening (#299): the bridge must never leave an app-server
# request unanswered, and a watchdog must always be armed while a turn is
# active, even when the bridge did not start that turn itself. ---

@test "codex-bridge: auto-declines an approval request from the app-server (#299)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-approval.js"
  local log="$TEST_SKILL_DIR/fake-app-server-approval.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  fs.appendFileSync(log, `${line}\n`);
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "process/exited", params: { processHandle: message.params.processHandle, exitCode: 0, stdout: "status=pending count=1 max_id=1\n", stderr: "" } });
    }, 10);
  } else if (message.method === "turn/start") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    // A server-initiated request: only a human could normally answer this.
    setTimeout(() => {
      send({ jsonrpc: "2.0", id: 500, method: "item/commandExecution/requestApproval", params: { command: ["rm", "-rf", "/"] } });
    }, 10);
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "turn/completed", params: { threadId: message.params.threadId, turn: { id: "turn-1" } } });
    }, 40);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 --max-wakes 1

  [ "$status" -eq 0 ]
  [[ "$output" =~ "auto-declining an approval request" ]]
  grep -q '"id":500' "$log"          # the bridge's reply, echoed back by the fake server
  grep -q '"decision":"decline"' "$log"
}

@test "codex-bridge: an unhandled server-initiated request gets a method-not-found reply instead of hanging (#299)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  local fake="$TEST_SKILL_DIR/fake-app-server-unknown-request.js"
  local log="$TEST_SKILL_DIR/fake-app-server-unknown-request.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  fs.appendFileSync(log, `${line}\n`);
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    // A future/unknown request type the bridge has no handler for.
    send({ jsonrpc: "2.0", id: 9001, method: "totally/unknown/method", params: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "process/exited", params: { processHandle: message.params.processHandle, exitCode: 0, stdout: "status=pending count=1 max_id=1\n", stderr: "" } });
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

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 --max-wakes 1

  [ "$status" -eq 0 ]
  [[ "$output" =~ "no handler for app-server request 'totally/unknown/method'" ]]
  grep -q '"id":9001' "$log"
  grep -q '"code":-32601' "$log"
}

@test "codex-bridge: an approval request id colliding with our own pending request id is still answered (#299 review)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  # Client and server number their OWN outbound requests independently on
  # this bidirectional connection, so a server-initiated request's id can
  # collide with the id of one of our still-outstanding requests. Reuse the
  # exact id the bridge assigned to its own pending "turn/start" (message.id
  # at that point, whatever it happens to be) for the approval request, and
  # send it BEFORE turn/start's real ack -- while that id is still pending.
  # A handleLine() that checked `pending` before `method` would wrongly
  # resolve turn/start with the approval's params and never reply to the
  # approval at all, silently swallowing the real ack too.
  local fake="$TEST_SKILL_DIR/fake-app-server-id-collision.js"
  local log="$TEST_SKILL_DIR/fake-app-server-id-collision.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  fs.appendFileSync(log, `${line}\n`);
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/start") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: "thread-1", status: { type: "idle" } } } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "process/exited", params: { processHandle: message.params.processHandle, exitCode: 0, stdout: "status=pending count=1 max_id=1\n", stderr: "" } });
    }, 10);
  } else if (message.method === "turn/start") {
    const collideId = message.id;
    send({ jsonrpc: "2.0", id: collideId, method: "item/commandExecution/requestApproval", params: { command: ["rm", "-rf", "/"] } });
    send({ jsonrpc: "2.0", id: collideId, result: {} });
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "turn/completed", params: { threadId: message.params.threadId, turn: { id: "turn-1" } } });
    }, 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --timeout 1 --interval 1 --max-wakes 1

  [ "$status" -eq 0 ]
  [[ "$output" =~ "auto-declining an approval request" ]]
  [[ "$output" =~ "started turn" ]]   # proves turn/start's real ack was NOT swallowed by the collision
  grep -q '"decision":"decline"' "$log"
}

@test "codex-bridge: the turn watchdog rescues a resumed thread already active with no bridge-owned turn (#299)" {
  run node -e 'const r = require("child_process").spawnSync("/bin/sh", ["-c", "true"]); if (r.error) { console.error(r.error.message); process.exit(1); }'
  if [ "$status" -ne 0 ]; then
    skip "node child_process.spawn is not available in this sandbox"
  fi

  # Regression: thread/resume reports the thread already "active" (e.g. a
  # stuck approval predating this bridge) and this fake NEVER sends
  # turn/completed or an idle notification -- the pre-#299 bridge had no
  # watchdog for a turn it did not start itself, so a pending wake would wait
  # forever. With the fix, startTurnWatchdog() is armed on resume too, so the
  # deferred wake still gets delivered once the (short, test-only) turn
  # timeout elapses.
  local fake="$TEST_SKILL_DIR/fake-app-server-stuck-active.js"
  local log="$TEST_SKILL_DIR/fake-app-server-stuck-active.log"
  cat >"$fake" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const rl = readline.createInterface({ input: process.stdin });
let spawns = 0;
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
rl.on("line", (line) => {
  const message = JSON.parse(line);
  fs.appendFileSync(log, `${message.method}\n`);
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: message.params.threadId, status: { type: "active" } } } });
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    spawns += 1;
    // Same unread max_id (5) until the deferred wake is delivered; a second
    // message (6) follows so the run then terminates via --max-wakes, same
    // pattern as the "delivers a wake observed while..." test above.
    const id = spawns === 1 ? 5 : 6;
    setTimeout(() => {
      send({ jsonrpc: "2.0", method: "process/exited", params: { processHandle: message.params.processHandle, exitCode: 0, stdout: `status=pending count=1 max_id=${id}\n`, stderr: "" } });
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

  AGMSG_CODEX_APP_SERVER_CMD="node $fake $log" run node "$TYPES/codex/codex-bridge.js" \
    --project "$PROJ" --team team --name alice --thread thread-active \
    --timeout 1 --interval 1 --turn-timeout 1 --max-wakes 2

  [ "$status" -eq 0 ]
  [[ "$output" =~ "wakeup 1" ]]
  [[ "$output" =~ "wakeup 2" ]]
  [[ "$output" =~ "started turn" ]]
  grep -q "turn/start" "$log"
}
