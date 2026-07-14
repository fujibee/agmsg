#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_test_env
  export RELAY_RUN="$TEST_SKILL_DIR/relay-runtime"
  export RELAY_PLISTS="$TEST_SKILL_DIR/LaunchAgents"
  export FAKE_LAUNCHCTL_DIR="$TEST_SKILL_DIR/fake-launchctl-state"
  export FAKE_RELAY_RUNNER="$TYPES/codex/codex-desktop-relay-run.sh"
  export AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR="$RELAY_RUN"
  export AGMSG_CODEX_DESKTOP_RELAY_PLIST_DIR="$RELAY_PLISTS"
  export AGMSG_CODEX_DESKTOP_RELAY_PORT="$((51000 + RANDOM % 1000))"
  mkdir -p "$RELAY_RUN" "$RELAY_PLISTS" "$FAKE_LAUNCHCTL_DIR" "$TEST_SKILL_DIR/bin"

  local fake_codex="$TEST_SKILL_DIR/fake-relayctl-codex"
  cat > "$fake_codex" <<'NODE'
#!/usr/bin/env node
"use strict";
const readline = require("readline");
readline.createInterface({ input: process.stdin });
NODE
  chmod +x "$fake_codex"
  export AGMSG_CODEX_DESKTOP_RELAY_CODEX="$fake_codex"

  cat > "$TEST_SKILL_DIR/bin/uname" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-s" ]; then echo Darwin; else /usr/bin/uname "$@"; fi
SH
  cat > "$TEST_SKILL_DIR/bin/launchctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_LAUNCHCTL_DIR:?}"
case "${1:-}" in
  getenv)
    cat "$state/env" 2>/dev/null || true
    ;;
  setenv)
    printf '%s\n' "${3:-}" > "$state/env"
    ;;
  unsetenv)
    rm -f "$state/env"
    ;;
  print)
    pid="$(cat "$state/job.pid" 2>/dev/null || true)"
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
    ;;
  bootout)
    pid="$(cat "$state/job.pid" 2>/dev/null || true)"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.02; done
    fi
    rm -f "$state/job.pid"
    ;;
  bootstrap)
    cp "${3:?plist}" "$state/bootstrap.plist"
    [ "${FAKE_LAUNCHCTL_BOOTSTRAP_FAIL:-0}" != "1" ] || exit 19
    nohup "$FAKE_RELAY_RUNNER" > "$state/relay.log" 2>&1 &
    printf '%s\n' "$!" > "$state/job.pid"
    ;;
  kickstart)
    ;;
  *)
    echo "unexpected fake launchctl action: ${1:-}" >&2
    exit 2
    ;;
esac
SH
  chmod +x "$TEST_SKILL_DIR/bin/uname" "$TEST_SKILL_DIR/bin/launchctl"
  export PATH="$TEST_SKILL_DIR/bin:$PATH"
}

teardown() {
  launchctl bootout "gui/$(id -u)/com.agmsg.codex-desktop-relay" >/dev/null 2>&1 || true
  teardown_test_env
}

@test "relay runner stops cleanly after one permanent configuration failure" {
  local run="$TEST_SKILL_DIR/runner-terminal"
  mkdir -p "$run"
  printf 'short\n' >"$run/codex-desktop-relay.desktop-token"
  printf '%064d\n' 0 | tr '0' 'b' >"$run/codex-desktop-relay.bridge-token"
  chmod 600 "$run"/*-token

  AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR="$run" AGMSG_CODEX_DESKTOP_RELAY_PORT=0 \
    run bash "$TYPES/codex/codex-desktop-relay-run.sh"

  [ "$status" -eq 0 ]
  [ "$(grep -c 'desktop capability must be 32 random bytes' <<<"$output")" -eq 1 ]
}

@test "relay runner retries transient app-server crashes with delay" {
  local run="$TEST_SKILL_DIR/runner-transient" fake="$TEST_SKILL_DIR/fake-crashing-codex" calls="$TEST_SKILL_DIR/crash-calls"
  mkdir -p "$run"
  printf '%064d\n' 0 | tr '0' 'a' >"$run/codex-desktop-relay.desktop-token"
  printf '%064d\n' 0 | tr '0' 'b' >"$run/codex-desktop-relay.bridge-token"
  chmod 600 "$run"/*-token
  cat >"$fake" <<EOF
#!/usr/bin/env bash
printf 'call\n' >>"$calls"
exit 1
EOF
  chmod +x "$fake"

  AGMSG_CODEX_DESKTOP_RELAY_RUN_DIR="$run" AGMSG_CODEX_DESKTOP_RELAY_PORT=0 \
    AGMSG_CODEX_DESKTOP_RELAY_CODEX="$fake" \
    bash "$TYPES/codex/codex-desktop-relay-run.sh" >"$TEST_SKILL_DIR/runner-transient.log" 2>&1 &
  local pid=$!
  for _ in {1..150}; do
    [ "$(wc -l <"$calls" 2>/dev/null || echo 0)" -ge 2 ] && break
    sleep 0.02
  done
  [ "$(wc -l <"$calls")" -ge 2 ]
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
}

@test "relayctl rotates exposed tokens, reuses private tokens, and redacts every durable surface" {
  local desktop_token bridge_token output_text
  printf '%064d\n' 0 | tr '0' 'a' > "$RELAY_RUN/codex-desktop-relay.desktop-token"
  printf '%064d\n' 0 | tr '0' 'b' > "$RELAY_RUN/codex-desktop-relay.bridge-token"
  chmod 644 "$RELAY_RUN/codex-desktop-relay.desktop-token"
  chmod 600 "$RELAY_RUN/codex-desktop-relay.bridge-token"

  run bash "$TYPES/codex/codex-desktop-relayctl.sh" enable
  [ "$status" -eq 0 ]
  [[ "$output" == *"app_server=ws://127.0.0.1:"*"/<capability>"* ]]
  desktop_token="$(cat "$RELAY_RUN/codex-desktop-relay.desktop-token")"
  bridge_token="$(cat "$RELAY_RUN/codex-desktop-relay.bridge-token")"
  [ "$desktop_token" != "$(printf '%064d' 0 | tr '0' 'a')" ]
  [ "$bridge_token" = "$(printf '%064d' 0 | tr '0' 'b')" ]
  [ "$(stat -f '%Lp' "$RELAY_RUN/codex-desktop-relay.desktop-token")" = "600" ]
  [ "$(stat -f '%Lp' "$RELAY_RUN/codex-desktop-relay.bridge-token")" = "600" ]

  output_text="$(bash "$TYPES/codex/codex-desktop-relayctl.sh" status)"
  [[ "$output_text" != *"$desktop_token"* ]]
  [[ "$output_text" != *"$bridge_token"* ]]
  ! grep -q "$desktop_token\|$bridge_token" \
    "$FAKE_LAUNCHCTL_DIR/bootstrap.plist" "$RELAY_RUN/codex-desktop-relay.health" \
    "$FAKE_LAUNCHCTL_DIR/relay.log"
  grep -A3 -q '<key>KeepAlive</key>.*' "$FAKE_LAUNCHCTL_DIR/bootstrap.plist"
  grep -A2 '<key>KeepAlive</key>' "$FAKE_LAUNCHCTL_DIR/bootstrap.plist" \
    | grep -q '<key>SuccessfulExit</key>'

  # A second enable must retain capabilities that have remained private.
  run bash "$TYPES/codex/codex-desktop-relayctl.sh" enable
  [ "$status" -eq 0 ]
  [ "$(cat "$RELAY_RUN/codex-desktop-relay.desktop-token")" = "$desktop_token" ]
  [ "$(cat "$RELAY_RUN/codex-desktop-relay.bridge-token")" = "$bridge_token" ]
}

@test "relayctl bootstrap failure rolls back env, plist, runtime, and private endpoints" {
  printf '%s\n' 'ws://127.0.0.1:49999/desktop/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    > "$FAKE_LAUNCHCTL_DIR/env"
  export FAKE_LAUNCHCTL_BOOTSTRAP_FAIL=1

  run bash "$TYPES/codex/codex-desktop-relayctl.sh" enable
  [ "$status" -ne 0 ]
  [ "$(cat "$FAKE_LAUNCHCTL_DIR/env")" = 'ws://127.0.0.1:49999/desktop/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]
  [ ! -e "$RELAY_PLISTS/com.agmsg.codex-desktop-relay.plist" ]
  [ ! -e "$RELAY_RUN/codex-desktop-relay.desktop-token" ]
  [ ! -e "$RELAY_RUN/codex-desktop-relay.bridge-token" ]
  [ ! -e "$RELAY_RUN/codex-desktop-relay.desktop-endpoint" ]
  [ ! -e "$RELAY_RUN/codex-desktop-relay.bridge-endpoint" ]
  [ ! -e "$RELAY_RUN/codex-desktop-relay.pid" ]
}

@test "relayctl disable removes its stale Desktop env even when the endpoint file is missing" {
  local owned="ws://127.0.0.1:$AGMSG_CODEX_DESKTOP_RELAY_PORT/desktop/$(printf '%064d' 0 | tr '0' 'c')"
  printf '%s\n' "$owned" > "$FAKE_LAUNCHCTL_DIR/env"

  run bash "$TYPES/codex/codex-desktop-relayctl.sh" disable
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_LAUNCHCTL_DIR/env" ]
  [[ "$output" == *"/<capability>"* ]]
  [[ "$output" != *"$(printf '%064d' 0 | tr '0' 'c')"* ]]
}

@test "relayctl disable restores the Desktop endpoint that existed before enable" {
  local prior='ws://127.0.0.1:49998/desktop/original-endpoint'
  printf '%s\n' "$prior" > "$FAKE_LAUNCHCTL_DIR/env"

  run bash "$TYPES/codex/codex-desktop-relayctl.sh" enable
  [ "$status" -eq 0 ]
  [ "$(cat "$RELAY_RUN/codex-desktop-relay.prior-desktop-endpoint")" = "$prior" ]
  [ "$(stat -f '%Lp' "$RELAY_RUN/codex-desktop-relay.prior-desktop-endpoint")" = "600" ]

  run bash "$TYPES/codex/codex-desktop-relayctl.sh" disable
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_LAUNCHCTL_DIR/env")" = "$prior" ]
  [ ! -e "$RELAY_RUN/codex-desktop-relay.prior-desktop-endpoint" ]
}

@test "relayctl rejects a port owned by another listener before partial installation" {
  local holder="$TEST_SKILL_DIR/ctl-port-holder.js" port_file="$TEST_SKILL_DIR/ctl-port" holder_pid
  cat > "$holder" <<'NODE'
const fs = require("fs");
const net = require("net");
const server = net.createServer(() => {});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[2], `${server.address().port}\n`));
NODE
  node "$holder" "$port_file" &
  holder_pid=$!
  for _ in {1..100}; do [ -s "$port_file" ] && break; sleep 0.05; done
  export AGMSG_CODEX_DESKTOP_RELAY_PORT="$(cat "$port_file")"
  printf '%s\n' "$holder_pid" > "$RELAY_RUN/codex-desktop-relay.pid"

  run bash "$TYPES/codex/codex-desktop-relayctl.sh" enable
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"owned by another listener"* ]]
  [ ! -e "$RELAY_PLISTS/com.agmsg.codex-desktop-relay.plist" ]
  [ ! -e "$RELAY_RUN/codex-desktop-relay.desktop-token" ]
}

@test "relayctl status rejects a recycled pid with forged health" {
  sleep 60 &
  local unrelated_pid=$!
  printf '%s\n' "$unrelated_pid" > "$RELAY_RUN/codex-desktop-relay.pid"
  printf '%s\n' "$AGMSG_CODEX_DESKTOP_RELAY_PORT" > "$RELAY_RUN/codex-desktop-relay.port"
  cat > "$RELAY_RUN/codex-desktop-relay.health" <<EOF
status=ready
pid=$unrelated_pid
port=$AGMSG_CODEX_DESKTOP_RELAY_PORT
primary_connected=1
upstream_initialized=1
EOF

  run bash "$TYPES/codex/codex-desktop-relayctl.sh" status
  kill "$unrelated_pid" 2>/dev/null || true
  wait "$unrelated_pid" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"status=not_running"* ]]
}
