#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export PROJ="$TEST_SKILL_DIR/proj"
  mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  export BRIDGE="$TYPES/codex/codex-bridge.js"
  export FAKE="$TEST_SKILL_DIR/fake-persistent-app-server.js"
  export FAKE_LOG="$TEST_SKILL_DIR/fake-persistent-app-server.log"
  write_fake_app_server
}

teardown() {
  teardown_test_env
}

write_fake_app_server() {
  cat >"$FAKE" <<'EOF'
const fs = require("fs");
const readline = require("readline");
const log = process.argv[2];
const mode = process.env.FAKE_MODE || "normal";
const maxId = Number(process.env.FAKE_MAX_ID || 1);
let dispatches = 0;
let spawns = 0;
function send(value) { process.stdout.write(`${JSON.stringify(value)}\n`); }
function record(value) { fs.appendFileSync(log, `${value}\n`); }
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") {
    record("initialize");
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  } else if (message.method === "thread/resume") {
    record(`resume ${message.params.threadId}`);
    if (mode === "bad-thread") {
      send({ jsonrpc: "2.0", id: message.id, error: { message: "thread not found" } });
    } else {
      send({ jsonrpc: "2.0", id: message.id, result: { thread: { id: message.params.threadId, status: { type: "idle" } } } });
    }
  } else if (message.method === "process/spawn") {
    spawns += 1;
    record(`spawn ${spawns}`);
    send({ jsonrpc: "2.0", id: message.id, result: {} });
    setTimeout(() => send({
      jsonrpc: "2.0",
      method: "process/exited",
      params: {
        processHandle: message.params.processHandle,
        exitCode: mode === "watch-fail" ? 1 : 0,
        stdout: mode === "watch-fail" ? "" : `status=pending count=1 max_id=${maxId}\n`,
        stderr: mode === "watch-fail" ? "injected watcher failure" : "",
      },
    }), 5);
  } else if (message.method === "agmsg/wake/dispatch") {
    dispatches += 1;
    record(`dispatch ${message.params.maxId} ${message.params.clientUserMessageId}`);
    if (mode === "ambiguous-once" && dispatches === 1) return;
    record(`accepted ${message.params.maxId}`);
    send({ jsonrpc: "2.0", id: message.id, result: { status: "accepted", maxId: message.params.maxId } });
    if (mode === "secret-delta") {
      send({ jsonrpc: "2.0", method: "item/agentMessage/delta", params: { threadId: message.params.threadId, delta: "TOP-SECRET-CONTENT" } });
    }
    setTimeout(() => send({
      jsonrpc: "2.0",
      method: "turn/completed",
      params: { threadId: message.params.threadId, turn: { id: `turn-${message.params.maxId}` } },
    }), 10);
  } else if (message.method === "process/kill") {
    send({ jsonrpc: "2.0", id: message.id, result: {} });
  }
});
EOF
}

write_timeout_runner() {
  local runner="$TEST_SKILL_DIR/run-with-timeout.js"
  cat >"$runner" <<'EOF'
const { spawn } = require("child_process");
const timeout = Number(process.argv[2]);
const child = spawn(process.argv[3], process.argv.slice(4), { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
let output = "";
child.stdout.on("data", (chunk) => { output += chunk; });
child.stderr.on("data", (chunk) => { output += chunk; });
const timer = setTimeout(() => child.kill("SIGTERM"), timeout);
child.on("close", (code) => {
  clearTimeout(timer);
  process.stdout.write(output);
  process.exit(code == null ? 1 : code);
});
EOF
  printf '%s\n' "$runner"
}

bridge_args() {
  printf '%s\n' \
    --project "$PROJ" --type codex --team team --name alice \
    --state-key state-team-alice --thread thread-exact \
    --timeout 1 --interval 1 --turn-timeout 1 --request-timeout-ms 200
}

@test "codex-bridge persistence: requires an exact thread and rejects discovery aliases" {
  run node "$BRIDGE" --project "$PROJ" --team team --name alice
  [ "$status" -ne 0 ]
  [[ "$output" =~ "one exact --thread id is required" ]]

  run node "$BRIDGE" --project "$PROJ" --team team --name alice --thread loaded
  [ "$status" -ne 0 ]
  [[ "$output" =~ "discovery aliases are not supported" ]]
}

@test "codex-bridge persistence: a recycled unrelated pid is never killed or treated as the owner" {
  mkdir -p "$TEST_SKILL_DIR/run"
  local base="$TEST_SKILL_DIR/run/codex-bridge.state-team-alice"
  printf '%s\n' "$$" >"$base.pid"
  cat >"$base.meta" <<EOF
pid=$$
project=$PROJ
team=team
name=alice
type=codex
thread=thread-exact
EOF

  AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" run node "$BRIDGE" \
    $(bridge_args) --max-wakes 1

  [ "$status" -eq 0 ]
  kill -0 "$$"
  grep -q '^accepted 1$' "$FAKE_LOG"
}

@test "codex-bridge persistence: three restarts suppress the same max id and a new max wakes once" {
  local runner
  runner="$(write_timeout_runner)"

  AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" run node "$BRIDGE" \
    $(bridge_args) --max-wakes 1
  [ "$status" -eq 0 ]

  for _ in 1 2; do
    AGMSG_CODEX_BRIDGE_SAME_UNREAD_DELAY_MS=30 \
      AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" \
      run node "$runner" 250 node "$BRIDGE" $(bridge_args)
    [ "$status" -eq 0 ]
  done
  [ "$(grep -c '^accepted 1$' "$FAKE_LOG")" -eq 1 ]
  [ "$(grep -c '^dispatch 1 ' "$FAKE_LOG")" -eq 1 ]

  FAKE_MAX_ID=2 AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" run node "$BRIDGE" \
    $(bridge_args) --max-wakes 1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^accepted 2$' "$FAKE_LOG")" -eq 1 ]
  [ "$(grep -c '^dispatch ' "$FAKE_LOG")" -eq 2 ]

  local state
  state="$(find "$TEST_SKILL_DIR/run" -name 'codex-bridge.state-team-alice.wake.*.json' -print -quit)"
  [ -n "$state" ]
  [ "$(stat -f '%Lp' "$state" 2>/dev/null || stat -c '%a' "$state")" = "600" ]
}

@test "codex-bridge persistence: an ambiguous dispatch retries the same deterministic id" {
  FAKE_MODE=ambiguous-once \
    AGMSG_CODEX_BRIDGE_RETRY_BASE_MS=20 AGMSG_CODEX_BRIDGE_RETRY_MAX_MS=20 \
    AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" \
    run node "$BRIDGE" $(bridge_args) --request-timeout-ms 40 --max-wakes 1

  [ "$status" -eq 0 ]
  [ "$(grep -c '^dispatch 1 ' "$FAKE_LOG")" -eq 2 ]
  [ "$(grep -c '^accepted 1$' "$FAKE_LOG")" -eq 1 ]
  [ "$(awk '/^dispatch 1 /{print $3}' "$FAKE_LOG" | sort -u | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$output" =~ "paused" || "$output" =~ "ambiguous" ]]
}

@test "codex-bridge persistence: repeated watcher failures back off without exiting" {
  local log="$TEST_SKILL_DIR/bridge.out"
  FAKE_MODE=watch-fail \
    AGMSG_CODEX_BRIDGE_RETRY_BASE_MS=20 AGMSG_CODEX_BRIDGE_RETRY_MAX_MS=40 \
    AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" \
    node "$BRIDGE" $(bridge_args) --watch-failure-limit 1 >"$log" 2>&1 &
  local pid=$!
  for _ in {1..60}; do
    [ "$(grep -c '^spawn ' "$FAKE_LOG" 2>/dev/null || true)" -ge 3 ] && break
    sleep 0.02
  done
  kill -0 "$pid"
  grep -qx 'status=paused_watch_failure' "$TEST_SKILL_DIR/run/codex-bridge.state-team-alice.health"
  kill -TERM "$pid"
  wait "$pid"
}

@test "codex-bridge persistence: managed terminal thread errors exit cleanly without a restart loop" {
  FAKE_MODE=bad-thread AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" \
    run node "$BRIDGE" $(bridge_args)

  [ "$status" -eq 0 ]
  [ "$(grep -c '^initialize$' "$FAKE_LOG")" -eq 1 ]
  grep -qx 'status=terminal_thread_error' "$TEST_SKILL_DIR/run/codex-bridge.state-team-alice.health"
  [[ "$output" =~ "terminal configuration error" ]]
}

@test "codex-bridge persistence: bridge logs never contain agent message deltas" {
  FAKE_MODE=secret-delta AGMSG_CODEX_APP_SERVER_CMD="node $FAKE $FAKE_LOG" \
    run node "$BRIDGE" $(bridge_args) --max-wakes 1

  [ "$status" -eq 0 ]
  [[ "$output" != *"TOP-SECRET-CONTENT"* ]]
}
