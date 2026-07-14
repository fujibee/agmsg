#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_test_env
  RELAY_PID=""
  EXTRA_PIDS=""
  DESKTOP_TOKEN="$(printf 'd%.0s' {1..64})"
  BRIDGE_TOKEN="$(printf 'b%.0s' {1..64})"
  ROLE_TOKEN="$(printf 'a%.0s' {1..64})"
  printf '%s\n' "$DESKTOP_TOKEN" > "$TEST_SKILL_DIR/desktop.token"
  printf '%s\n' "$BRIDGE_TOKEN" > "$TEST_SKILL_DIR/bridge.token"
  chmod 600 "$TEST_SKILL_DIR/desktop.token" "$TEST_SKILL_DIR/bridge.token"
}

teardown() {
  local pid
  if [ -n "${RELAY_PID:-}" ]; then
    kill "$RELAY_PID" 2>/dev/null || true
    wait "$RELAY_PID" 2>/dev/null || true
  fi
  for pid in ${EXTRA_PIDS:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

make_fake_app_server() {
  local fake="$TEST_SKILL_DIR/fake-relay-codex"
  cat > "$fake" <<'NODE'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const readline = require("readline");
const log = process.env.AGMSG_FAKE_RELAY_LOG;
const historyFile = process.env.AGMSG_FAKE_RELAY_HISTORY_FILE || "";
if (log) fs.appendFileSync(log, `ws-env=${process.env.CODEX_APP_SERVER_WS_URL ? "set" : "unset"}\n`);
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (log) fs.appendFileSync(
    log,
    `${message.method || "response"}\t${String(message.id ?? "")}\t${String(message.params && message.params.processHandle || "")}\t${String(message.error && message.error.message || "")}\n`,
  );
  if (message.method === "initialize") {
    send({ jsonrpc: "2.0", id: message.id, result: { serverInfo: { name: "fake", version: "1" } } });
  } else if (message.method === "thread/resume") {
    send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: message.params.threadId } } });
  } else if (message.method === "test/echo") {
    send({ jsonrpc: "2.0", id: message.id, result: { value: message.params.value } });
  } else if (message.method === "thread/read") {
    const finishRead = () => {
      const clientId = historyFile && fs.existsSync(historyFile) ? fs.readFileSync(historyFile, "utf8").trim() : "";
      send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: message.params.threadId, turns: [{ items: [{ type: "userMessage", clientId, content: "PRIVATE-HISTORY" }] }] } } });
    };
    const readDelay = Number(process.env.AGMSG_FAKE_RELAY_DELAY_READ_MS || 0);
    if (readDelay > 0) setTimeout(finishRead, readDelay); else finishRead();
  } else if (message.method === "turn/start") {
    if (historyFile && process.env.AGMSG_FAKE_RELAY_DROP_FIRST_TURN === "1" && !fs.existsSync(historyFile)) {
      fs.writeFileSync(historyFile, message.params.clientUserMessageId);
      return;
    }
    const finishTurn = () => {
      if (historyFile) fs.writeFileSync(historyFile, message.params.clientUserMessageId);
      send({ jsonrpc: "2.0", id: message.id, result: { turn: { id: "turn-1" } } });
      send({ jsonrpc: "2.0", method: "turn/started", params: { threadId: message.params.threadId } });
      send({ jsonrpc: "2.0", method: "item/agentMessage/delta", params: { threadId: message.params.threadId, delta: "visible" } });
      send({ jsonrpc: "2.0", method: "turn/completed", params: { threadId: message.params.threadId, turn: { id: "turn-1" } } });
    };
    const delay = Number(process.env.AGMSG_FAKE_RELAY_DELAY_TURN_MS || 0);
    if (delay > 0) setTimeout(finishTurn, delay); else finishTurn();
  } else if (message.method === "process/spawn") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    if (process.env.AGMSG_FAKE_RELAY_PROCESS_EXIT === "0") return;
    setTimeout(() => send({
      jsonrpc: "2.0",
      method: "process/output",
      params: { processHandle: message.params.processHandle, stdout: "partial", stderr: "" },
    }), 10);
    setTimeout(() => send({
      jsonrpc: "2.0",
      method: "process/exited",
      params: { processHandle: message.params.processHandle, exitCode: 0, stdout: "status=timeout\n", stderr: "" },
    }), 50);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "test/triggerServer") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    send({ jsonrpc: "2.0", id: "server-disconnect", method: "test/serverRequest", params: { value: 1 } });
  }
});
NODE
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

start_relay() {
  local fake="$1" log="$2"
  AGMSG_FAKE_RELAY_LOG="$log" \
    AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR="${AGMSG_TEST_RELAY_RUN_DIR:-$TEST_SKILL_DIR/run}" \
    node "$TYPES/codex/codex-desktop-relay.js" \
    --codex "$fake" --host 127.0.0.1 --port 0 \
    --desktop-token-file "$TEST_SKILL_DIR/desktop.token" \
    --bridge-token-file "$TEST_SKILL_DIR/bridge.token" \
    --health "$TEST_SKILL_DIR/relay.health" \
    --port-file "$TEST_SKILL_DIR/relay.port" \
    --pid-file "$TEST_SKILL_DIR/relay.pid" \
    >"$TEST_SKILL_DIR/relay.log" 2>&1 &
  RELAY_PID=$!
  for _ in {1..100}; do
    [ -s "$TEST_SKILL_DIR/relay.port" ] && return 0
    kill -0 "$RELAY_PID" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

write_bridge_binding() {
  local token="$1" state_key="$2" thread="$3" team="${4:-team}" name="${5:-alice}" project="${6:-$TEST_SKILL_DIR}"
  mkdir -p "$TEST_SKILL_DIR/run"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.$state_key.binding" <<EOF
token=$token
project=$(cd "$project" && pwd -P)
type=codex
team=$team
name=$name
thread=$thread
state_key=$state_key
EOF
  chmod 600 "$TEST_SKILL_DIR/run/codex-bridge.$state_key.binding"
}

@test "codex desktop relay waits for the visible Desktop before initializing bridge clients" {
  local fake log port runner
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream.log"
  write_bridge_binding "$ROLE_TOKEN" default.team.alice thread-visible
  start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/relay-client-test.js"
  cat > "$runner" <<'NODE'
"use strict";
const fs = require("fs");
const crypto = require("crypto");
const path = require("path");
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
const desktopToken = process.argv[4];
const bridgeSeed = process.argv[5];
const roleToken = process.argv[6];
function client(role) {
  const requestPath = role === "desktop" ? `/desktop/${desktopToken}` : `/bridge/${bridgeSeed}/${roleToken}`;
  const value = new WebSocketAppServerClient(
    { host: "127.0.0.1", port },
    `ws://127.0.0.1:${port}/<capability>`,
    { connectTimeoutMs: 3000, requestTimeoutMs: 3000, requestPath },
  );
  value.start();
  return value;
}
async function initialize(value, name, title) {
  await value.ready();
  const result = await value.request("initialize", {
    clientInfo: { name, title, version: "1" },
    capabilities: { experimentalApi: true, requestAttestation: false, optOutNotificationMethods: [] },
  });
  value.notify("initialized");
  return result;
}
(async () => {
  const bridge = client("bridge");
  let bridgeInitialized = false;
  const bridgeInit = initialize(bridge, "codex-desktop", "forged Desktop name").then(() => {
    bridgeInitialized = true;
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  if (bridgeInitialized) throw new Error("bridge initialized before a visible Desktop client connected");
  const desktop = client("desktop");
  await initialize(desktop, "codex-desktop", "Codex Desktop");
  await bridgeInit;

  const [desktopEcho, bridgeResume] = await Promise.all([
    desktop.request("test/echo", { value: "desktop" }),
    bridge.request("thread/resume", { threadId: "thread-visible" }),
  ]);
  if (desktopEcho.value !== "desktop" || bridgeResume.thread.id !== "thread-visible") {
    throw new Error("request responses crossed clients");
  }
  let methodRejected = false;
  try {
    await bridge.request("test/echo", { value: "bridge" });
  } catch (error) {
    methodRejected = /not allowed/.test(error.message);
  }
  if (!methodRejected) throw new Error("bridge method allowlist was bypassed");

  const seen = { desktopStarted: false, desktopDelta: false, bridgeCompleted: false };
  desktop.on("turn/started", () => { seen.desktopStarted = true; });
  desktop.on("item/agentMessage/delta", () => { seen.desktopDelta = true; });
  bridge.on("turn/completed", () => { seen.bridgeCompleted = true; });
  const project = fs.realpathSync(path.dirname(process.argv[7]));
  const clientUserMessageId = `agmsg-wake-v1-${crypto.createHash("sha256").update(["default.team.alice", "thread-visible", "1"].join("\0")).digest("hex")}`;
  let injectedPayloadRejected = false;
  try {
    await bridge.request("agmsg/wake/dispatch", {
      threadId: "thread-visible", maxId: 1, clientUserMessageId,
      dispatchMode: "start-or-reconcile", cwd: project, runtimeWorkspaceRoots: [project],
      input: "UNTRUSTED-WAKE-PAYLOAD",
    });
  } catch (error) {
    injectedPayloadRejected = /exact role binding/.test(error.message);
  }
  if (!injectedPayloadRejected) throw new Error("bridge supplied wake payload was accepted");
  const wakeResult = await bridge.request("agmsg/wake/dispatch", {
    threadId: "thread-visible",
    maxId: 1,
    clientUserMessageId,
    dispatchMode: "start-or-reconcile",
    cwd: project,
    runtimeWorkspaceRoots: [project],
  });
  if (JSON.stringify(wakeResult).includes("PRIVATE-HISTORY") || wakeResult.status !== "accepted" || wakeResult.maxId !== 1) {
    throw new Error(`wake response was not sanitized: ${JSON.stringify(wakeResult)}`);
  }
  await new Promise((resolve) => setTimeout(resolve, 100));
  if (!seen.desktopStarted || !seen.desktopDelta || !seen.bridgeCompleted) {
    throw new Error(`notifications were not broadcast: ${JSON.stringify(seen)}`);
  }
  bridge.stop();
  await new Promise((resolve) => setTimeout(resolve, 100));
  const health = fs.readFileSync(process.argv[7], "utf8");
  if (!/^status=ready$/m.test(health)) throw new Error(`bridge close lowered relay health: ${health}`);
  desktop.stop();
  console.log("relay-visible-broadcast-ok");
})().catch((error) => {
  console.error(error.stack || error);
  process.exit(1);
});
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" \
    "$BRIDGE_TOKEN" "$ROLE_TOKEN" "$TEST_SKILL_DIR/relay.health"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relay-visible-broadcast-ok"* ]]
  [ "$(grep -c $'^initialize\t' "$log")" -eq 1 ]
  [ "$(awk -F '\t' '$1 == "test/echo" || $1 == "thread/resume" { print $2 }' "$log" | sort -u | wc -l | tr -d ' ')" -eq 2 ]
  grep -qx 'status=waiting_for_desktop' "$TEST_SKILL_DIR/relay.health"
  grep -qx "upstream_initialized=1" "$TEST_SKILL_DIR/relay.health"
  grep -qx "primary_connected=0" "$TEST_SKILL_DIR/relay.health"
  ! grep -q "$DESKTOP_TOKEN\|$BRIDGE_TOKEN\|$ROLE_TOKEN" "$TEST_SKILL_DIR/relay.log" "$TEST_SKILL_DIR/relay.health"
  [ -e "$TEST_SKILL_DIR/run/codex-bridge.default.team.alice.binding" ]
}

@test "codex desktop relay rejects missing and incorrect capability paths" {
  local fake log port runner
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-auth.log"
  write_bridge_binding "$ROLE_TOKEN" auth.team.alice thread-auth
  start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/relay-auth-test.js"
  cat > "$runner" <<'NODE'
"use strict";
const { WebSocketAppServerClient } = require(process.argv[2]);
const crypto = require("crypto");
const port = Number(process.argv[3]);
const bridgeSeed = process.argv[4];
const roleToken = process.argv[5];
async function rejected(requestPath) {
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port },
    `ws://127.0.0.1:${port}/<redacted>`,
    { connectTimeoutMs: 1000, requestTimeoutMs: 1000, requestPath },
  );
  client.start();
  try {
    await client.ready();
  } catch (error) {
    client.stop();
    return /403 Forbidden/.test(error.message);
  }
  client.stop();
  return false;
}
(async () => {
  if (!await rejected("/")
      || !await rejected(`/bridge/${"0".repeat(64)}/${roleToken}`)
      || !await rejected(`/bridge/${bridgeSeed}`)
      || !await rejected(`/bridge/${bridgeSeed}/${"0".repeat(64)}`)) {
    throw new Error("unauthorized websocket path was accepted");
  }
  console.log("relay-capability-rejected");
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$BRIDGE_TOKEN" "$ROLE_TOKEN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relay-capability-rejected"* ]]
}

@test "codex desktop relay rejects symlink capability and binding files" {
  local fake real_binding binding_path
  fake="$(make_fake_app_server)"
  ln -s "$TEST_SKILL_DIR/desktop.token" "$TEST_SKILL_DIR/desktop-link.token"
  run node "$TYPES/codex/codex-desktop-relay.js" \
    --codex "$fake" --host 127.0.0.1 --port 0 \
    --desktop-token-file "$TEST_SKILL_DIR/desktop-link.token" \
    --bridge-token-file "$TEST_SKILL_DIR/bridge.token"
  [ "$status" -ne 0 ]
  [[ "$output" == *"regular non-symlink file"* ]]

  ln -s "$TEST_SKILL_DIR/bridge.token" "$TEST_SKILL_DIR/bridge-link.token"
  run node "$TYPES/codex/codex-desktop-relay.js" \
    --codex "$fake" --host 127.0.0.1 --port 0 \
    --desktop-token-file "$TEST_SKILL_DIR/desktop.token" \
    --bridge-token-file "$TEST_SKILL_DIR/bridge-link.token"
  [ "$status" -ne 0 ]
  [[ "$output" == *"regular non-symlink file"* ]]

  write_bridge_binding "$ROLE_TOKEN" symlink.team.alice thread-symlink
  binding_path="$TEST_SKILL_DIR/run/codex-bridge.symlink.team.alice.binding"
  real_binding="$binding_path.real"
  mv "$binding_path" "$real_binding"
  ln -s "$real_binding" "$binding_path"
  start_relay "$fake" "$TEST_SKILL_DIR/upstream-symlink.log"
  local port runner
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/relay-binding-symlink-test.js"
  cat > "$runner" <<'NODE'
"use strict";
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
const seed = process.argv[4];
const role = process.argv[5];
const client = new WebSocketAppServerClient(
  { host: "127.0.0.1", port },
  "ws://127.0.0.1/<redacted>",
  { connectTimeoutMs: 1000, requestTimeoutMs: 1000, requestPath: `/bridge/${seed}/${role}` },
);
client.start();
client.ready().then(() => {
  client.stop();
  throw new Error("symlink binding was accepted");
}).catch((error) => {
  client.stop();
  if (!/403 Forbidden/.test(error.message)) throw error;
  console.log("relay-binding-symlink-rejected");
});
NODE
  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$BRIDGE_TOKEN" "$ROLE_TOKEN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relay-binding-symlink-rejected"* ]]
}

@test "codex desktop relay honors a validated custom run directory for role bindings" {
  local fake log port runner custom
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-custom-run.log"
  custom="$TEST_SKILL_DIR/private-run"
  mkdir -p "$custom"
  cat >"$custom/codex-bridge.custom.team.alice.binding" <<EOF
token=$ROLE_TOKEN
project=$(cd "$TEST_SKILL_DIR" && pwd -P)
type=codex
team=team
name=alice
thread=thread-custom
state_key=custom.team.alice
EOF
  chmod 600 "$custom/codex-bridge.custom.team.alice.binding"
  AGMSG_TEST_RELAY_RUN_DIR="$custom" start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/custom-run-client.js"
  cat >"$runner" <<'NODE'
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
function make(path) {
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port }, "custom-run", { requestPath: path, connectTimeoutMs: 1000, requestTimeoutMs: 1000 },
  );
  client.start();
  return client;
}
async function init(client, name) {
  await client.ready();
  await client.request("initialize", { clientInfo: { name, title: name, version: "1" }, capabilities: {} });
  client.notify("initialized");
}
(async () => {
  const desktop = make(`/desktop/${process.argv[4]}`);
  await init(desktop, "desktop");
  const bridge = make(`/bridge/${process.argv[5]}/${process.argv[6]}`);
  await init(bridge, "bridge");
  const result = await bridge.request("thread/resume", { threadId: "thread-custom" });
  if (result.thread.id !== "thread-custom") throw new Error("custom binding was not loaded");
  bridge.stop(); desktop.stop();
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" "$BRIDGE_TOKEN" "$ROLE_TOKEN"
  [ "$status" -eq 0 ]
  grep -q $'^thread/resume\t' "$log"
}

@test "codex desktop relay removes its endpoint capability from the app-server child environment" {
  local fake log
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-child-env.log"
  CODEX_APP_SERVER_WS_URL="ws://127.0.0.1:1/secret-capability" start_relay "$fake" "$log"

  for _ in {1..50}; do [ -s "$log" ] && break; sleep 0.02; done
  grep -qx 'ws-env=unset' "$log"
  ! grep -q 'secret-capability' "$TEST_SKILL_DIR/relay.log" "$log"
}

@test "codex desktop relay reconciles an accepted wake after the first response is lost" {
  local fake log port runner history project
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-reconcile.log"
  history="$TEST_SKILL_DIR/persisted-client-id"
  project="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  write_bridge_binding "$ROLE_TOKEN" reconcile.team.alice thread-reconcile team alice "$project"
  AGMSG_FAKE_RELAY_HISTORY_FILE="$history" AGMSG_FAKE_RELAY_DROP_FIRST_TURN=1 start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/reconcile-client.js"
  cat >"$runner" <<'NODE'
const crypto = require("crypto");
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
function make(path, timeout) {
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port }, "reconcile", { requestPath: path, connectTimeoutMs: 1000, requestTimeoutMs: timeout },
  );
  client.start();
  return client;
}
async function init(client, name) {
  await client.ready();
  await client.request("initialize", { clientInfo: { name, title: name, version: "1" }, capabilities: {} });
  client.notify("initialized");
}
(async () => {
  const desktop = make(`/desktop/${process.argv[4]}`, 1000);
  await init(desktop, "desktop");
  const bridge = make(`/bridge/${process.argv[5]}/${process.argv[6]}`, 100);
  await init(bridge, "bridge");
  await bridge.request("thread/resume", { threadId: "thread-reconcile" });
  const maxId = 9;
  const clientUserMessageId = `agmsg-wake-v1-${crypto.createHash("sha256").update(["reconcile.team.alice", "thread-reconcile", String(maxId)].join("\0")).digest("hex")}`;
  const params = {
    threadId: "thread-reconcile", maxId, clientUserMessageId,
    dispatchMode: "start-or-reconcile",
    cwd: process.argv[7], runtimeWorkspaceRoots: [process.argv[7]],
  };
  let timedOut = false;
  try { await bridge.request("agmsg/wake/dispatch", params); } catch (error) { timedOut = /timed out/.test(error.message); }
  if (!timedOut) throw new Error("the injected lost response did not time out");
  params.dispatchMode = "reconcile-only";
  const result = await bridge.request("agmsg/wake/dispatch", params);
  if (JSON.stringify(result) !== JSON.stringify({ status: "reconciled", maxId })) {
    throw new Error(`history leaked or reconciliation failed: ${JSON.stringify(result)}`);
  }
  bridge.stop(); desktop.stop();
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" "$BRIDGE_TOKEN" "$ROLE_TOKEN" "$project"
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^turn/start\t' "$log")" -eq 1 ]
  [ "$(grep -c $'^thread/read\t' "$log")" -eq 2 ]
}

@test "codex desktop relay never starts a concurrent duplicate while acceptance is pending" {
  local fake log port runner history project
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-inflight.log"
  history="$TEST_SKILL_DIR/inflight-client-id"
  project="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  write_bridge_binding "$ROLE_TOKEN" inflight.team.alice thread-inflight team alice "$project"
  AGMSG_FAKE_RELAY_HISTORY_FILE="$history" AGMSG_FAKE_RELAY_DELAY_TURN_MS=200 start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/inflight-client.js"
  cat >"$runner" <<'NODE'
const crypto = require("crypto");
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
function make(path, timeout) {
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port }, "inflight", { requestPath: path, connectTimeoutMs: 1000, requestTimeoutMs: timeout },
  );
  client.start(); return client;
}
async function init(client, name) {
  await client.ready();
  await client.request("initialize", { clientInfo: { name, title: name, version: "1" }, capabilities: {} });
  client.notify("initialized");
}
(async () => {
  const desktop = make(`/desktop/${process.argv[4]}`, 1000); await init(desktop, "desktop");
  const bridge = make(`/bridge/${process.argv[5]}/${process.argv[6]}`, 80); await init(bridge, "bridge");
  await bridge.request("thread/resume", { threadId: "thread-inflight" });
  const maxId = 10;
  const clientUserMessageId = `agmsg-wake-v1-${crypto.createHash("sha256").update(["inflight.team.alice", "thread-inflight", String(maxId)].join("\0")).digest("hex")}`;
  const params = { threadId: "thread-inflight", maxId, clientUserMessageId, dispatchMode: "start-or-reconcile", cwd: process.argv[7], runtimeWorkspaceRoots: [process.argv[7]] };
  try { await bridge.request("agmsg/wake/dispatch", params); } catch (_) {}
  params.dispatchMode = "reconcile-only";
  let ambiguous = false;
  try { await bridge.request("agmsg/wake/dispatch", params); } catch (error) { ambiguous = /still ambiguous/.test(error.message); }
  if (!ambiguous) throw new Error("retry did not fail closed while the original turn was pending");
  await new Promise((resolve) => setTimeout(resolve, 250));
  const result = await bridge.request("agmsg/wake/dispatch", params);
  if (result.status !== "reconciled") throw new Error(`accepted turn was not reconciled: ${JSON.stringify(result)}`);
  bridge.stop(); desktop.stop();
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" "$BRIDGE_TOKEN" "$ROLE_TOKEN" "$project"
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^turn/start\t' "$log")" -eq 1 ]
  [ "$(grep -c $'^thread/read\t' "$log")" -eq 3 ]
}

@test "codex bridge rejects a symlink app-server endpoint file" {
  local project endpoint
  project="$TEST_SKILL_DIR/symlink-project"
  mkdir -p "$project"
  endpoint="$TEST_SKILL_DIR/private-app-server.endpoint"
  printf 'ws://127.0.0.1:1/bridge/%s/%s\n' "$BRIDGE_TOKEN" "$ROLE_TOKEN" > "$endpoint"
  chmod 600 "$endpoint"
  ln -s "$endpoint" "$TEST_SKILL_DIR/app-server-link.endpoint"

  run node "$TYPES/codex/codex-bridge.js" \
    --project "$project" --app-server-file "$TEST_SKILL_DIR/app-server-link.endpoint"
  [ "$status" -ne 0 ]
  [[ "$output" == *"regular non-symlink file"* ]]
}

@test "codex desktop relay isolates bridge process handles and routes exit only to the owner" {
  local fake log port runner second_token
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-process.log"
  second_token="$(printf 'c%.0s' {1..64})"
  write_bridge_binding "$ROLE_TOKEN" first.team.alice thread-one team alice
  write_bridge_binding "$second_token" second.team.bob thread-two team bob
  start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/relay-process-owner-test.js"
  cat > "$runner" <<'NODE'
"use strict";
const { WebSocketAppServerClient } = require(process.argv[2]);
const crypto = require("crypto");
const port = Number(process.argv[3]);
const desktopToken = process.argv[4];
const bridgeSeed = process.argv[5];
const firstToken = process.argv[6];
const secondToken = process.argv[7];
const project = process.argv[8];
const watchOnce = process.argv[9];
function wakeId(stateKey, threadId, maxId) {
  return `agmsg-wake-v1-${crypto.createHash("sha256").update([stateKey, threadId, String(maxId)].join("\0")).digest("hex")}`;
}
function make(role, tokenOverride = "") {
  const requestPath = role === "desktop" ? `/desktop/${desktopToken}` : `/bridge/${bridgeSeed}/${tokenOverride}`;
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port },
    `ws://127.0.0.1:${port}/<capability>`,
    { connectTimeoutMs: 2000, requestTimeoutMs: 2000, requestPath },
  );
  client.start();
  return client;
}
async function initialize(client, name) {
  await client.ready();
  await client.request("initialize", {
    clientInfo: { name, title: name, version: "1" },
    capabilities: { experimentalApi: true, requestAttestation: false, optOutNotificationMethods: [] },
  });
  client.notify("initialized");
}
(async () => {
  const desktop = make("desktop");
  await initialize(desktop, "desktop");
  const first = make("bridge", firstToken);
  const second = make("bridge", secondToken);
  await Promise.all([initialize(first, "bridge-one"), initialize(second, "bridge-two")]);
  const duplicate = make("bridge", firstToken);
  let duplicateRejected = false;
  try { await duplicate.ready(); } catch (error) { duplicateRejected = /403 Forbidden/.test(error.message); }
  duplicate.stop();
  let wrongThreadRejected = false;
  try {
    await first.request("thread/resume", { threadId: "thread-two" });
  } catch (error) { wrongThreadRejected = /exact thread/.test(error.message); }
  let resumeOverrideRejected = false;
  try {
    await first.request("thread/resume", { threadId: "thread-one", history: [] });
  } catch (error) { resumeOverrideRejected = /exact thread/.test(error.message); }
  await Promise.all([
    first.request("thread/resume", { threadId: "thread-one" }),
    second.request("thread/resume", { threadId: "thread-two" }),
  ]);
  const seen = {
    desktopOwner: false,
    desktopOwnOutput: false,
    desktopOwnExit: false,
    firstOutput: "",
    firstExit: "",
    firstThreads: [],
    secondUnexpectedProcess: false,
    secondThreads: [],
  };
  desktop.on("process/output", (params) => {
    if (params.processHandle === "desktop-owned") seen.desktopOwnOutput = true;
    else seen.desktopOwner = true;
  });
  desktop.on("process/exited", (params) => {
    if (params.processHandle === "desktop-owned") seen.desktopOwnExit = true;
    else seen.desktopOwner = true;
  });
  first.on("process/output", (params) => { seen.firstOutput = params.processHandle; });
  first.on("process/exited", (params) => { seen.firstExit = params.processHandle; });
  second.on("process/output", () => { seen.secondUnexpectedProcess = true; });
  second.on("process/exited", () => { seen.secondUnexpectedProcess = true; });
  first.on("turn/started", (params) => { seen.firstThreads.push(params.threadId); });
  second.on("turn/started", (params) => { seen.secondThreads.push(params.threadId); });
  await Promise.all([
    first.request("agmsg/wake/dispatch", {
      threadId: "thread-one", maxId: 1,
      clientUserMessageId: wakeId("first.team.alice", "thread-one", 1),
      dispatchMode: "start-or-reconcile",
      cwd: project, runtimeWorkspaceRoots: [project],
    }),
    second.request("agmsg/wake/dispatch", {
      threadId: "thread-two", maxId: 1,
      clientUserMessageId: wakeId("second.team.bob", "thread-two", 1),
      dispatchMode: "start-or-reconcile",
      cwd: project, runtimeWorkspaceRoots: [project],
    }),
  ]);
  await first.request("process/spawn", {
    command: [
      "/bin/bash", watchOnce, project, "codex",
      "--team", "team", "--name", "alice",
      "--owner", "agmsg-codex-bridge-123.123", "--claim",
      "--timeout", "300", "--interval", "2",
    ],
    processHandle: "agmsg-watch-owned",
    cwd: project,
    outputBytesCap: 8192,
    timeoutMs: 312000,
  });
  let arbitraryCommandRejected = false;
  try {
    await first.request("process/spawn", {
      command: ["/bin/echo", watchOnce, project, "codex", "--team", "team", "--name", "alice", "--owner", "agmsg-codex-bridge-1.1", "--claim", "--timeout", "300", "--interval", "2"],
      processHandle: "agmsg-watch-arbitrary", cwd: project, outputBytesCap: 8192, timeoutMs: 312000,
    });
  } catch (error) { arbitraryCommandRejected = /spawn only/.test(error.message); }
  let spawnOverrideRejected = false;
  try {
    await first.request("process/spawn", {
      command: ["/bin/bash", watchOnce, project, "codex", "--team", "team", "--name", "alice", "--owner", "agmsg-codex-bridge-2.2", "--claim", "--timeout", "300", "--interval", "2"],
      processHandle: "agmsg-watch-env", cwd: project, outputBytesCap: 8192, timeoutMs: 312000,
      env: { PATH: "/tmp" },
    });
  } catch (error) { spawnOverrideRejected = /spawn only/.test(error.message); }
  let timeoutMismatchRejected = false;
  try {
    await first.request("process/spawn", {
      command: ["/bin/bash", watchOnce, project, "codex", "--team", "team", "--name", "alice", "--owner", "agmsg-codex-bridge-3.3", "--claim", "--timeout", "300", "--interval", "2"],
      processHandle: "agmsg-watch-timeout", cwd: project, outputBytesCap: 8192, timeoutMs: 311999,
    });
  } catch (error) { timeoutMismatchRejected = /spawn only/.test(error.message); }
  let killOverrideRejected = false;
  try {
    await first.request("process/kill", { processHandle: "agmsg-watch-owned", signal: "SIGKILL" });
  } catch (error) { killOverrideRejected = /kill only/.test(error.message); }
  let rejected = false;
  try {
    await second.request("process/kill", { processHandle: "agmsg-watch-owned" });
  } catch (error) {
    rejected = /does not own/.test(error.message);
  }
  await new Promise((resolve) => setTimeout(resolve, 120));
  await desktop.request("process/spawn", {
    command: ["/bin/true"],
    processHandle: "desktop-owned",
  });
  await new Promise((resolve) => setTimeout(resolve, 120));
  if (
    !duplicateRejected
    || !wrongThreadRejected
    || !resumeOverrideRejected
    || !arbitraryCommandRejected
    || !spawnOverrideRejected
    || !timeoutMismatchRejected
    || !killOverrideRejected
    || !rejected
    || seen.firstOutput !== "agmsg-watch-owned"
    || seen.firstExit !== "agmsg-watch-owned"
    || seen.secondUnexpectedProcess
    || seen.desktopOwner
    || !seen.desktopOwnOutput
    || !seen.desktopOwnExit
    || seen.firstThreads.join(",") !== "thread-one"
    || seen.secondThreads.join(",") !== "thread-two"
  ) {
    throw new Error(`process ownership failed: ${JSON.stringify({ duplicateRejected, wrongThreadRejected, resumeOverrideRejected, arbitraryCommandRejected, spawnOverrideRejected, timeoutMismatchRejected, killOverrideRejected, rejected, seen })}`);
  }
  desktop.stop(); first.stop(); second.stop();
  console.log("relay-process-owner-ok");
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" \
    "$BRIDGE_TOKEN" "$ROLE_TOKEN" "$second_token" "$(cd "$TEST_SKILL_DIR" && pwd -P)" \
    "$(cd "$(dirname "$TYPES/codex/watch-once.sh")" && pwd -P)/watch-once.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relay-process-owner-ok"* ]]
  grep -Eq $'^process/spawn\t[0-9]+\tagmsg-relay-[0-9]+-agmsg-watch-owned\t$' "$log"
}

@test "codex desktop relay sends server requests only to Desktop and fails them on disconnect" {
  local fake log port runner
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-server-request.log"
  write_bridge_binding "$ROLE_TOKEN" server.team.alice thread-server
  start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/relay-server-request-test.js"
  cat > "$runner" <<'NODE'
"use strict";
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
const desktopToken = process.argv[4];
const bridgeSeed = process.argv[5];
const roleToken = process.argv[6];
function make(role) {
  const requestPath = role === "desktop" ? `/desktop/${desktopToken}` : `/bridge/${bridgeSeed}/${roleToken}`;
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port },
    "ws://127.0.0.1/<capability>",
    { connectTimeoutMs: 2000, requestTimeoutMs: 2000, requestPath },
  );
  client.start();
  return client;
}
async function initialize(client, name) {
  await client.ready();
  await client.request("initialize", { clientInfo: { name, title: name, version: "1" }, capabilities: {} });
  client.notify("initialized");
}
(async () => {
  const desktop = make("desktop");
  await initialize(desktop, "desktop");
  const bridge = make("bridge");
  await initialize(bridge, "bridge");
  let desktopSeen = false;
  let bridgeSeen = false;
  desktop.on("test/serverRequest", () => {
    desktopSeen = true;
    return new Promise(() => {});
  });
  bridge.on("test/serverRequest", () => { bridgeSeen = true; return {}; });
  await desktop.request("test/triggerServer", {});
  for (let index = 0; index < 50 && !desktopSeen; index += 1) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  if (!desktopSeen || bridgeSeen) throw new Error("server request was not isolated to Desktop");
  desktop.stop();
  await new Promise((resolve) => setTimeout(resolve, 100));
  bridge.stop();
  console.log("relay-server-request-disconnect-ok");
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" "$BRIDGE_TOKEN" "$ROLE_TOKEN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"relay-server-request-disconnect-ok"* ]]
  grep -Eq $'^response\tserver-disconnect\t\tVisible Codex Desktop client disconnected$' "$log"
}

@test "codex desktop relay shutdown terminates the app-server process group" {
  skip_on_windows "POSIX process groups are required"
  local fake log child_pid_file child_pid
  fake="$TEST_SKILL_DIR/fake-relay-process-tree"
  child_pid_file="$TEST_SKILL_DIR/fake-relay-child.pid"
  cat > "$fake" <<'NODE'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const { spawn } = require("child_process");
const child = spawn(process.execPath, ["-e", "process.on('SIGTERM',()=>{}); setInterval(()=>{},1000)"], { stdio: "ignore" });
fs.writeFileSync(process.env.AGMSG_FAKE_CHILD_PID, `${child.pid}\n`);
setInterval(() => {}, 1000);
NODE
  chmod +x "$fake"
  log="$TEST_SKILL_DIR/upstream-process-tree.log"
  AGMSG_FAKE_CHILD_PID="$child_pid_file" \
    AGMSG_CODEX_DESKTOP_RELAY_SHUTDOWN_GRACE_MS=200 start_relay "$fake" "$log"
  for _ in {1..100}; do [ -s "$child_pid_file" ] && break; sleep 0.05; done
  [ -s "$child_pid_file" ]
  child_pid="$(cat "$child_pid_file")"
  kill -0 "$child_pid"

  kill "$RELAY_PID"
  wait "$RELAY_PID"
  RELAY_PID=""
  for _ in {1..100}; do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.05
  done
  run kill -0 "$child_pid"
  [ "$status" -ne 0 ]
}

@test "codex desktop relay port collision never starts an upstream process" {
  local holder port_file holder_pid port fake marker
  holder="$TEST_SKILL_DIR/relay-port-holder.js"
  port_file="$TEST_SKILL_DIR/relay-held.port"
  cat > "$holder" <<'NODE'
const fs = require("fs");
const net = require("net");
const server = net.createServer(() => {});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[2], `${server.address().port}\n`));
NODE
  node "$holder" "$port_file" &
  holder_pid=$!
  EXTRA_PIDS="$holder_pid"
  for _ in {1..100}; do [ -s "$port_file" ] && break; sleep 0.05; done
  port="$(cat "$port_file")"
  fake="$TEST_SKILL_DIR/fake-must-not-start"
  marker="$TEST_SKILL_DIR/upstream-started"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
: > "$AGMSG_UPSTREAM_STARTED_MARKER"
sleep 60
EOF
  chmod +x "$fake"

  AGMSG_UPSTREAM_STARTED_MARKER="$marker" node "$TYPES/codex/codex-desktop-relay.js" \
    --codex "$fake" --host 127.0.0.1 --port "$port" \
    --desktop-token-file "$TEST_SKILL_DIR/desktop.token" \
    --bridge-token-file "$TEST_SKILL_DIR/bridge.token" \
    --health "$TEST_SKILL_DIR/collision.health" \
    --port-file "$TEST_SKILL_DIR/collision.port" \
    --pid-file "$TEST_SKILL_DIR/collision.pid" \
    >"$TEST_SKILL_DIR/collision.log" 2>&1 &
  RELAY_PID=$!
  local relay_status=0
  wait "$RELAY_PID" || relay_status=$?
  [ "$relay_status" -ne 0 ]
  RELAY_PID=""
  [ ! -e "$marker" ]
  [ ! -e "$TEST_SKILL_DIR/collision.pid" ]
}

@test "codex desktop relay reaps a stubborn process group after the upstream leader crashes" {
  skip_on_windows "POSIX process groups are required"
  local fake log child_pid_file child_pid
  fake="$TEST_SKILL_DIR/fake-relay-crash-tree"
  child_pid_file="$TEST_SKILL_DIR/fake-relay-crash-child.pid"
  cat > "$fake" <<'NODE'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const { spawn } = require("child_process");
const child = spawn(process.execPath, ["-e", "process.on('SIGTERM',()=>{}); setInterval(()=>{},1000)"], { stdio: "ignore" });
fs.writeFileSync(process.env.AGMSG_FAKE_CHILD_PID, `${child.pid}\n`);
setTimeout(() => process.exit(17), 50);
NODE
  chmod +x "$fake"
  log="$TEST_SKILL_DIR/upstream-crash-tree.log"
  AGMSG_FAKE_CHILD_PID="$child_pid_file" \
    AGMSG_CODEX_DESKTOP_RELAY_SHUTDOWN_GRACE_MS=200 start_relay "$fake" "$log"
  for _ in {1..100}; do [ -s "$child_pid_file" ] && break; sleep 0.05; done
  [ -s "$child_pid_file" ]
  child_pid="$(cat "$child_pid_file")"
  local relay_status=0
  wait "$RELAY_PID" || relay_status=$?
  [ "$relay_status" -ne 0 ]
  RELAY_PID=""
  for _ in {1..100}; do
    kill -0 "$child_pid" 2>/dev/null || break
    sleep 0.05
  done
  run kill -0 "$child_pid"
  [ "$status" -ne 0 ]
}

@test "codex actas binds one exact visible thread through the authenticated relay" {
  local fake log port project desktop_runner desktop_pid project_hash base bridge_pid token
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-actas.log"
  AGMSG_FAKE_RELAY_PROCESS_EXIT=0 start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'ws://127.0.0.1:%s/bridge/%s\n' "$port" "$BRIDGE_TOKEN" \
    > "$TEST_SKILL_DIR/run/codex-desktop-relay.bridge-endpoint"
  chmod 600 "$TEST_SKILL_DIR/run/codex-desktop-relay.bridge-endpoint"

  project="$TEST_SKILL_DIR/actas-project"
  mkdir -p "$project"
  bash "$SCRIPTS/join.sh" team bob codex "$project" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$project" >/dev/null
  cp "$TEST_SKILL_DIR/relay.health" "$TEST_SKILL_DIR/run/codex-desktop-relay.health"
  run env CODEX_THREAD_ID=thread-visible-exact AGMSG_CODEX_BRIDGE_SUPERVISOR=direct \
    AGMSG_CODEX_ACTAS_READY_SECONDS=1 \
    bash "$TYPES/codex/actas-monitor.sh" "$project" codex bob thread-visible-exact
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=visible_turn_only"* ]]
  [[ "$output" == *"requested_mode=monitor"* ]]
  [[ "$output" == *"effective_mode=turn"* ]]
  run bash "$SCRIPTS/delivery.sh" status codex "$project"
  [[ "$output" == *"mode: monitor"* ]]

  desktop_runner="$TEST_SKILL_DIR/relay-desktop-owner.js"
  cat > "$desktop_runner" <<'NODE'
"use strict";
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
const token = process.argv[4];
const client = new WebSocketAppServerClient(
  { host: "127.0.0.1", port },
  "ws://127.0.0.1/<capability>",
  { connectTimeoutMs: 2000, requestTimeoutMs: 2000, requestPath: `/desktop/${token}` },
);
client.start();
(async () => {
  await client.ready();
  await client.request("initialize", { clientInfo: { name: "desktop", title: "desktop", version: "1" }, capabilities: {} });
  client.notify("initialized");
  console.log("desktop-ready");
  setInterval(() => {}, 1000);
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE
  node "$desktop_runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" \
    > "$TEST_SKILL_DIR/desktop-owner.log" 2>&1 &
  desktop_pid=$!
  EXTRA_PIDS="$EXTRA_PIDS $desktop_pid"
  for _ in {1..100}; do grep -q desktop-ready "$TEST_SKILL_DIR/desktop-owner.log" 2>/dev/null && break; sleep 0.05; done
  grep -q desktop-ready "$TEST_SKILL_DIR/desktop-owner.log"
  for _ in {1..100}; do grep -qx status=ready "$TEST_SKILL_DIR/relay.health" 2>/dev/null && break; sleep 0.05; done
  cp "$TEST_SKILL_DIR/relay.health" "$TEST_SKILL_DIR/run/codex-desktop-relay.health"

  run env CODEX_THREAD_ID=thread-visible-exact AGMSG_CODEX_BRIDGE_SUPERVISOR=direct \
    AGMSG_CODEX_ACTAS_READY_SECONDS=3 \
    bash "$SCRIPTS/session-start.sh" codex "$project" </dev/null
  [ "$status" -eq 0 ]
  grep -q 'status=ok' "$TEST_SKILL_DIR/run/codex-actas-restore.log"
  grep -q 'thread=thread-visible-exact' "$TEST_SKILL_DIR/run/codex-actas-restore.log"
  grep -q "app_server=ws://127.0.0.1:$port/<capability>" "$TEST_SKILL_DIR/run/codex-actas-restore.log"
  ! grep -q "$BRIDGE_TOKEN" "$TEST_SKILL_DIR/run/codex-actas-restore.log"

  project_hash="$(printf '%s' "$(cd "$project" && pwd)" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  base="$TEST_SKILL_DIR/run/codex-bridge.$project_hash.team.bob"
  bridge_pid="$(cat "$base.pid")"
  EXTRA_PIDS="$EXTRA_PIDS $bridge_pid"
  kill -0 "$bridge_pid"
  grep -qx 'thread=thread-visible-exact' "$base.meta"
  grep -qx 'thread=thread-visible-exact' "$base.health"
  grep -qx "app_server=ws://127.0.0.1:$port/<capability>" "$base.meta"
  [ "$(stat -f '%Lp' "$base.appserver")" = "600" ]
  token="$(cat "$TEST_SKILL_DIR/run/codex-desktop-relay.bridge-endpoint")"
  ! grep -Fq "$token" "$base.meta" "$base.health" "$base.log"
  grep -q $'^thread/resume\t' "$log"
  ! grep -q $'^thread/start\t' "$log"

  sed -i.bak 's/^status=ready$/status=paused_ambiguous_wake/' "$base.health"
  rm -f "$base.health.bak"
  printf '%s\n' '{"durable":"sentinel"}' >"$base.wake.sentinel.json"
  printf '%s\n' '{"relay":"sentinel"}' >"$base.relay-wake.json"
  run env AGMSG_CODEX_ACTAS_THREAD=thread-visible-exact AGMSG_CODEX_BRIDGE_SUPERVISOR=direct \
    bash "$TYPES/codex/actas-monitor.sh" "$project" codex bob thread-visible-exact
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]
  [[ "$output" == *"health=ready"* ]]
  [ "$(cat "$base.pid")" != "$bridge_pid" ]
  [ ! -f "$base.wake.sentinel.json" ]
  [ ! -f "$base.relay-wake.json" ]
  bridge_pid="$(cat "$base.pid")"

  bash "$SCRIPTS/delivery.sh" set turn codex "$project" >/dev/null
  run kill -0 "$bridge_pid"
  [ "$status" -ne 0 ]
  kill -0 "$RELAY_PID"
}

@test "codex desktop relay restart never blindly replays a durable dispatch" {
  local fake log port runner project relay_status=0
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-durable-restart.log"
  project="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  write_bridge_binding "$ROLE_TOKEN" durable.team.alice thread-durable team alice "$project"
  AGMSG_FAKE_RELAY_DELAY_TURN_MS=5000 start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/durable-restart-client.js"
  cat >"$runner" <<'NODE'
const crypto = require("crypto");
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
const phase = process.argv[7];
function make(path) {
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port }, "durable-restart",
    { requestPath: path, connectTimeoutMs: 2000, requestTimeoutMs: 800 },
  );
  client.start();
  return client;
}
async function init(client, name) {
  await client.ready();
  await client.request("initialize", { clientInfo: { name, title: name, version: "1" }, capabilities: {} });
  client.notify("initialized");
}
(async () => {
  const desktop = make(`/desktop/${process.argv[4]}`);
  await init(desktop, "desktop");
  const bridge = make(`/bridge/${process.argv[5]}/${process.argv[6]}`);
  await init(bridge, "bridge");
  await bridge.request("thread/resume", { threadId: "thread-durable" });
  const clientUserMessageId = `agmsg-wake-v1-${crypto.createHash("sha256").update(["durable.team.alice", "thread-durable", "41"].join("\0")).digest("hex")}`;
  try {
    await bridge.request("agmsg/wake/dispatch", {
      threadId: "thread-durable", maxId: 41, clientUserMessageId,
      dispatchMode: "start-or-reconcile", cwd: process.argv[8], runtimeWorkspaceRoots: [process.argv[8]],
    });
    throw new Error(`${phase} unexpectedly accepted`);
  } catch (error) {
    const expected = phase === "first" ? /timed out/ : /still ambiguous/;
    if (!expected.test(error.message)) throw error;
  } finally {
    bridge.stop(); desktop.stop();
  }
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" \
    "$BRIDGE_TOKEN" "$ROLE_TOKEN" first "$project"
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^turn/start\t' "$log")" -eq 1 ]
  [ -s "$TEST_SKILL_DIR/run/codex-bridge.durable.team.alice.relay-wake.json" ]

  kill "$RELAY_PID"
  wait "$RELAY_PID" || relay_status=$?
  [ "$relay_status" -eq 0 ]
  RELAY_PID=""
  rm -f "$TEST_SKILL_DIR/relay.port"

  start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" \
    "$BRIDGE_TOKEN" "$ROLE_TOKEN" second "$project"
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^turn/start\t' "$log")" -eq 1 ]
}

@test "codex desktop relay clears read-stage inflight state when a bridge socket closes" {
  local fake log port runner project
  fake="$(make_fake_app_server)"
  log="$TEST_SKILL_DIR/upstream-read-disconnect.log"
  project="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  write_bridge_binding "$ROLE_TOKEN" disconnect.team.alice thread-disconnect team alice "$project"
  AGMSG_FAKE_RELAY_DELAY_READ_MS=400 start_relay "$fake" "$log"
  port="$(cat "$TEST_SKILL_DIR/relay.port")"
  runner="$TEST_SKILL_DIR/read-disconnect-client.js"
  cat >"$runner" <<'NODE'
const crypto = require("crypto");
const { WebSocketAppServerClient } = require(process.argv[2]);
const port = Number(process.argv[3]);
function make(path) {
  const client = new WebSocketAppServerClient(
    { host: "127.0.0.1", port }, "read-disconnect",
    { requestPath: path, connectTimeoutMs: 2000, requestTimeoutMs: 3000 },
  );
  client.start();
  return client;
}
async function init(client, name) {
  await client.ready();
  await client.request("initialize", { clientInfo: { name, title: name, version: "1" }, capabilities: {} });
  client.notify("initialized");
}
(async () => {
  const desktop = make(`/desktop/${process.argv[4]}`);
  await init(desktop, "desktop");
  const clientUserMessageId = `agmsg-wake-v1-${crypto.createHash("sha256").update(["disconnect.team.alice", "thread-disconnect", "7"].join("\0")).digest("hex")}`;
  const first = make(`/bridge/${process.argv[5]}/${process.argv[6]}`);
  await init(first, "bridge-one");
  await first.request("thread/resume", { threadId: "thread-disconnect" });
  first.request("agmsg/wake/dispatch", {
    threadId: "thread-disconnect", maxId: 7, clientUserMessageId,
    dispatchMode: "start-or-reconcile", cwd: process.argv[7], runtimeWorkspaceRoots: [process.argv[7]],
  }).catch(() => {});
  await new Promise((resolve) => setTimeout(resolve, 50));
  first.stop();
  await new Promise((resolve) => setTimeout(resolve, 100));

  const second = make(`/bridge/${process.argv[5]}/${process.argv[6]}`);
  await init(second, "bridge-two");
  await second.request("thread/resume", { threadId: "thread-disconnect" });
  const result = await second.request("agmsg/wake/dispatch", {
    threadId: "thread-disconnect", maxId: 7, clientUserMessageId,
    dispatchMode: "start-or-reconcile", cwd: process.argv[7], runtimeWorkspaceRoots: [process.argv[7]],
  });
  if (result.status !== "accepted") throw new Error(`wake was not retried safely: ${JSON.stringify(result)}`);
  second.stop(); desktop.stop();
})().catch((error) => { console.error(error.stack || error); process.exit(1); });
NODE

  run node "$runner" "$TYPES/codex/codex-bridge.js" "$port" "$DESKTOP_TOKEN" \
    "$BRIDGE_TOKEN" "$ROLE_TOKEN" "$project"
  [ "$status" -eq 0 ]
  [ "$(grep -c $'^turn/start\t' "$log")" -eq 1 ]
}

@test "codex desktop relay exits nonzero and reaps app-server when its runner disappears" {
  skip_on_windows "POSIX parent liveness and process groups are required"
  local fake parent_pid upstream_pid relay_status=0
  fake="$(make_fake_app_server)"
  sleep 60 &
  parent_pid=$!
  EXTRA_PIDS="$EXTRA_PIDS $parent_pid"
  AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR="$TEST_SKILL_DIR/run" \
    node "$TYPES/codex/codex-desktop-relay.js" \
    --codex "$fake" --host 127.0.0.1 --port 0 \
    --desktop-token-file "$TEST_SKILL_DIR/desktop.token" \
    --bridge-token-file "$TEST_SKILL_DIR/bridge.token" \
    --health "$TEST_SKILL_DIR/parent.health" \
    --port-file "$TEST_SKILL_DIR/parent.port" \
    --pid-file "$TEST_SKILL_DIR/parent.pid" \
    --parent-pid "$parent_pid" >"$TEST_SKILL_DIR/parent-relay.log" 2>&1 &
  RELAY_PID=$!
  for _ in {1..100}; do [ -s "$TEST_SKILL_DIR/parent.health" ] && break; sleep 0.05; done
  upstream_pid="$(sed -n 's/^upstream_pid=//p' "$TEST_SKILL_DIR/parent.health" | head -1)"
  [ -n "$upstream_pid" ]
  kill "$parent_pid"
  wait "$parent_pid" 2>/dev/null || true
  wait "$RELAY_PID" || relay_status=$?
  [ "$relay_status" -ne 0 ]
  RELAY_PID=""
  for _ in {1..100}; do kill -0 "$upstream_pid" 2>/dev/null || break; sleep 0.05; done
  run kill -0 "$upstream_pid"
  [ "$status" -ne 0 ]
}

@test "codex desktop relay rejects non-loopback listeners" {
  run node "$TYPES/codex/codex-desktop-relay.js" --host 0.0.0.0 --port 0 --codex /bin/false
  [ "$status" -ne 0 ]
  [[ "$output" == *"--host must be loopback"* ]]
}
