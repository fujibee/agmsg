#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  TEST_RECEIVER_PIDS=""
  # Failure-path tests must not emit real macOS notifications to the user.
  export AGMSG_CODEX_APP_MONITOR_DISABLE_NOTIFY=1
}

teardown() {
  local pid
  for pid in ${TEST_RECEIVER_PIDS:-}; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

project_hash() {
  local resolved
  resolved="$(cd "$TEST_PROJECT" && pwd)"
  printf '%s' "$resolved" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 )
}

join_codex_roles() {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
}

install_fake_launchctl() {
  local fakebin="$TEST_SKILL_DIR/fakebin"
  export AGMSG_FAKE_LAUNCHCTL_LOG="$TEST_SKILL_DIR/fake-launchctl.log"
  mkdir -p "$fakebin"
  cat > "$fakebin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
  print) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$fakebin/launchctl"
  export PATH="$fakebin:$PATH"
}

@test "codex actas in turn mode persists the selected role without a background receiver" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  run env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=visible_turn_only"* ]]
  [[ "$output" == *"name=bob"* ]]

  local state="$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv"
  [ -f "$state" ]
  awk -F '\t' '$2 == "codex" && $3 == "team" && $4 == "bob" { found=1 } END { exit !found }' "$state"

  local hooks="$TEST_PROJECT/.codex/hooks.json"
  grep -q "check-inbox.sh" "$hooks"
  [[ "$output" != *"lease_id=codex-monitor-lease."* ]]
  run ! grep -q "session-start.sh" "$hooks"
}

@test "codex actas resolves an allowed role name containing spaces" {
  local name='codex receiver'
  bash "$SCRIPTS/join.sh" team "$name" codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  run env CODEX_THREAD_ID=thread-spaced \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex "$name" thread-spaced

  [ "$status" -eq 0 ]
  [[ "$output" == *"status=visible_turn_only"* ]]
  [[ "$output" == *"name=$name"* ]]
}

@test "codex SessionStart rebinds only the same exact task and cannot move the role" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  env CODEX_THREAD_ID=thread-before \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-before >/dev/null
  rm -f "$TEST_SKILL_DIR/run/codex-chat-visible.$(project_hash).team.bob.meta"

  run env CODEX_THREAD_ID=thread-after \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]

  local meta="$TEST_SKILL_DIR/run/codex-chat-visible.$(project_hash).team.bob.meta"
  [ ! -e "$meta" ]
  awk -F '\t' '$5 == "thread-before" { found=1 } END { exit !found }' \
    "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv"

  run env CODEX_THREAD_ID=thread-before \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  [ -f "$meta" ]
  grep -qx "name=bob" "$meta"
  grep -qx "thread=thread-before" "$meta"
  grep -qx "transport=codex-chat-visible-turn" "$meta"
}

@test "codex actas refuses a second exact task while the role lease is held" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  env CODEX_THREAD_ID=thread-owner \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-owner >/dev/null
  run env CODEX_THREAD_ID=thread-thief \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-thief

  [ "$status" -eq 5 ]
  [[ "$output" == *"status=role_held"* ]]
  [[ "$output" == *"owner_thread=thread-owner"* ]]
  awk -F '\t' '$5 == "thread-owner" { found=1 } END { exit !found }' \
    "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv"
  awk -F '\t' '$5 == "thread-owner" { found=1 } END { exit !found }' \
    "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv"
  grep -q '^codex-seat:' "$TEST_SKILL_DIR/run/actas.team__bob.session"
}

@test "codex actas refuses a role held by a live generic actas owner" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  setup_live_owner "$TEST_SKILL_DIR/run" "generic-owner"
  printf 'generic-owner\n' > "$TEST_SKILL_DIR/run/actas.team__bob.session"

  run env CODEX_THREAD_ID=thread-codex \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-codex

  [ "$status" -eq 5 ]
  [[ "$output" == *"status=role_held"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv" ]
  [ "$(cat "$TEST_SKILL_DIR/run/actas.team__bob.session")" = "generic-owner" ]
}

@test "codex seats allow different roles in the same project to stay bound to different tasks" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null

  env CODEX_THREAD_ID=thread-bob \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-bob >/dev/null
  env CODEX_THREAD_ID=thread-alice \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex alice thread-alice >/dev/null

  awk -F '\t' '$4 == "bob" && $5 == "thread-bob" { found=1 } END { exit !found }' \
    "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv"
  awk -F '\t' '$4 == "alice" && $5 == "thread-alice" { found=1 } END { exit !found }' \
    "$TEST_SKILL_DIR/run/codex-seat.team.alice.tsv"
  [ -e "$TEST_SKILL_DIR/run/codex-chat-visible.$(project_hash).team.bob.meta" ]
  [ -e "$TEST_SKILL_DIR/run/codex-chat-visible.$(project_hash).team.alice.meta" ]
}

@test "codex global role seat refuses the same team role from another project" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  local other="$TEST_SKILL_DIR/other-seat-project"
  mkdir -p "$other"
  bash "$SCRIPTS/join.sh" team bob codex "$other" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn codex "$other" >/dev/null
  env CODEX_THREAD_ID=thread-owner \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-owner >/dev/null

  run env CODEX_THREAD_ID=thread-other \
    bash "$TYPES/codex/actas-monitor.sh" "$other" codex bob thread-other

  [ "$status" -eq 5 ]
  [[ "$output" == *"owner_thread=thread-owner"* ]]
}

@test "codex fallback boots out the exact meta-less launchd job without changing monitor mode" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  install_fake_launchctl
  local state_key="$(project_hash).team.bob"
  local base="$TEST_SKILL_DIR/run/codex-bridge.$state_key"
  mkdir -p "$TEST_SKILL_DIR/run"
  : > "$base.plist"

  run env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123

  [ "$status" -eq 0 ]
  [[ "$output" == *"effective_mode=turn"* ]]
  grep -qx "bootout gui/$(id -u)/com.agmsg.codex-bridge.$state_key" "$AGMSG_FAKE_LAUNCHCTL_LOG"
  [ ! -e "$base.plist" ]
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [[ "$output" == *"mode: monitor"* ]]
}

@test "codex fallback ignores a forged launch label and unrelated recycled pid" {
  skip_on_windows "process liveness assertion uses POSIX kill semantics"
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  install_fake_launchctl
  local state_key="$(project_hash).team.bob"
  local base="$TEST_SKILL_DIR/run/codex-bridge.$state_key" unrelated_pid
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 60 &
  unrelated_pid=$!
  TEST_RECEIVER_PIDS="$TEST_RECEIVER_PIDS $unrelated_pid"
  printf '%s\n' "$unrelated_pid" > "$base.pid"
  cat > "$base.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=bob
thread=thread-forged
launch_label=com.example.unrelated-job
EOF
  cat > "$base.plist" <<'EOF'
<plist><dict><key>Label</key><string>com.example.other-unrelated-job</string></dict></plist>
EOF

  run env CODEX_THREAD_ID=thread-forged \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-forged

  [ "$status" -eq 0 ]
  kill -0 "$unrelated_pid" 2>/dev/null
  ! grep -q 'com.example' "$AGMSG_FAKE_LAUNCHCTL_LOG"
  grep -qx "bootout gui/$(id -u)/com.agmsg.codex-bridge.$state_key" "$AGMSG_FAKE_LAUNCHCTL_LOG"
  [ ! -e "$base.pid" ]
  [ ! -e "$base.meta" ]
  [ ! -e "$base.plist" ]
}

@test "codex SessionEnd releases the exact lease and meta-less launchd job" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  install_fake_launchctl
  env CODEX_THREAD_ID=thread-ending \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-ending >/dev/null
  local state_key="$(project_hash).team.bob"
  local base="$TEST_SKILL_DIR/run/codex-bridge.$state_key"
  : > "$base.plist"
  rm -f "$base.meta" "$base.pid"

  printf '%s\n' '{"session_id":"thread-ending"}' | \
    bash "$SCRIPTS/session-end.sh" codex "$TEST_PROJECT"

  grep -qx "bootout gui/$(id -u)/com.agmsg.codex-bridge.$state_key" "$AGMSG_FAKE_LAUNCHCTL_LOG"
  [ ! -e "$base.plist" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv" ]
  [ ! -e "$TEST_SKILL_DIR/run/actas.team__bob.session" ]
}

@test "codex reset removes only the target role's meta-less launchd job and lease" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  install_fake_launchctl
  env CODEX_THREAD_ID=thread-drop \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-drop >/dev/null
  local bob_key="$(project_hash).team.bob"
  local alice_key="$(project_hash).team.alice"
  : > "$TEST_SKILL_DIR/run/codex-bridge.$bob_key.plist"
  : > "$TEST_SKILL_DIR/run/codex-bridge.$alice_key.plist"

  run bash "$SCRIPTS/reset.sh" "$TEST_PROJECT" codex bob

  [ "$status" -eq 0 ]
  grep -qx "bootout gui/$(id -u)/com.agmsg.codex-bridge.$bob_key" "$AGMSG_FAKE_LAUNCHCTL_LOG"
  ! grep -q "com.agmsg.codex-bridge.$alice_key" "$AGMSG_FAKE_LAUNCHCTL_LOG"
  [ ! -e "$TEST_SKILL_DIR/run/codex-bridge.$bob_key.plist" ]
  [ -e "$TEST_SKILL_DIR/run/codex-bridge.$alice_key.plist" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv" ]
  [ ! -e "$TEST_SKILL_DIR/run/actas.team__bob.session" ]
}

@test "codex reset stops a bridge owned by a non-ASCII team and role" {
  skip_on_windows "process ownership assertion uses POSIX command lines"
  local team='日本チーム' name='受信係' thread='thread-japanese'
  bash "$SCRIPTS/join.sh" "$team" "$name" codex "$TEST_PROJECT" >/dev/null
  install_fake_launchctl
  local safe_team safe_name state_key base bridge_pid
  safe_team="$(SKILL_DIR="$TEST_SKILL_DIR" bash -c '. "$1/lib/actas-lock.sh"; _actas_lock_encode "$2"' _ "$SCRIPTS" "$team")"
  safe_name="$(SKILL_DIR="$TEST_SKILL_DIR" bash -c '. "$1/lib/actas-lock.sh"; _actas_lock_encode "$2"' _ "$SCRIPTS" "$name")"
  state_key="$(project_hash).$safe_team.$safe_name"
  base="$TEST_SKILL_DIR/run/codex-bridge.$state_key"
  mkdir -p "$TEST_SKILL_DIR/run"
  cat > "$TYPES/codex/codex-bridge.js" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "$TYPES/codex/codex-bridge.js"
  "$TYPES/codex/codex-bridge.js" --project "$TEST_PROJECT" --type codex \
    --team "$team" --name "$name" --state-key "$state_key" \
    --app-server-file "$base.appserver" --thread "$thread" &
  bridge_pid=$!
  TEST_RECEIVER_PIDS="$bridge_pid"
  printf '%s\n' "$bridge_pid" > "$base.pid"
  cat > "$base.meta" <<EOF
pid=$bridge_pid
project=$TEST_PROJECT
type=codex
team=$team
name=$name
thread=$thread
EOF
  : > "$base.plist"

  run bash "$SCRIPTS/reset.sh" "$TEST_PROJECT" codex "$name"

  [ "$status" -eq 0 ]
  run ! kill -0 "$bridge_pid"
  [ ! -e "$base.pid" ]
  [ ! -e "$base.meta" ]
  [ ! -e "$base.plist" ]
  TEST_RECEIVER_PIDS=""
}

@test "codex delivery off removes only this project's meta-less jobs and preserves the global relay" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  install_fake_launchctl
  env CODEX_THREAD_ID=thread-off \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-off >/dev/null
  local project_key="$(project_hash).team.bob"
  local other_project="$TEST_SKILL_DIR/other-project" other_hash other_key relay_pid
  mkdir -p "$other_project"
  other_hash="$(printf '%s' "$(cd "$other_project" && pwd)" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  other_key="$other_hash.team.bob"
  : > "$TEST_SKILL_DIR/run/codex-bridge.$project_key.plist"
  : > "$TEST_SKILL_DIR/run/codex-bridge.$other_key.plist"
  sleep 60 &
  relay_pid=$!
  TEST_RECEIVER_PIDS="$TEST_RECEIVER_PIDS $relay_pid"
  printf '%s\n' "$relay_pid" > "$TEST_SKILL_DIR/run/codex-desktop-relay.pid"

  run bash "$SCRIPTS/delivery.sh" set off codex "$TEST_PROJECT"

  [ "$status" -eq 0 ]
  grep -qx "bootout gui/$(id -u)/com.agmsg.codex-bridge.$project_key" "$AGMSG_FAKE_LAUNCHCTL_LOG"
  ! grep -q "com.agmsg.codex-bridge.$other_key" "$AGMSG_FAKE_LAUNCHCTL_LOG"
  [ ! -e "$TEST_SKILL_DIR/run/codex-bridge.$project_key.plist" ]
  [ -e "$TEST_SKILL_DIR/run/codex-bridge.$other_key.plist" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-seat.team.bob.tsv" ]
  kill -0 "$relay_pid"
}

@test "codex visible Stop hook exposes only pending metadata for the last actas role" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123 >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob "visible-bob-message" >/dev/null

  run env CODEX_THREAD_ID=thread-123 bash "$SCRIPTS/check-inbox.sh" codex "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 unread agmsg message(s) pending for team=team role=bob"* ]]
  [[ "$output" != *"visible-bob-message"* ]]
  [[ "$output" != *"alice"* ]]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT read_at IS NULL FROM messages WHERE body='visible-bob-message';")" = "1" ]

  run bash "$SCRIPTS/inbox.sh" team bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"visible-bob-message"* ]]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT read_at IS NOT NULL FROM messages WHERE body='visible-bob-message';")" = "1" ]
}

@test "codex background thread receiver is always disabled" {
  run bash "$TYPES/codex/codex-app-monitor.sh" \
    "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 64 ]
  [[ "$output" == *"background-only handling is prohibited"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
}

make_fake_codex() {
  local fake="$TEST_SKILL_DIR/fake-codex"
  cat > "$fake" <<'EOF'
#!/usr/bin/env bash
printf 'ARGS' >> "$AGMSG_FAKE_CODEX_LOG"
printf ' <%s>' "$@" >> "$AGMSG_FAKE_CODEX_LOG"
printf '\n' >> "$AGMSG_FAKE_CODEX_LOG"
printf 'BACKGROUND <%s>\n' "${AGMSG_CODEX_BACKGROUND_RESUME:-}" >> "$AGMSG_FAKE_CODEX_LOG"
if [ "${1:-}" = "mcp" ]; then
  exit 0
fi
if [ "${1:-}" = "exec" ]; then
  prompt="$(cat)"
  printf '%s\n' "$prompt" > "$AGMSG_FAKE_CODEX_PROMPT"
  if [ "${AGMSG_FAKE_CODEX_CONSUME:-}" = "1" ]; then
    bash "$AGMSG_FAKE_CODEX_INBOX" team bob >/dev/null
  fi
  exit "${AGMSG_FAKE_CODEX_EXEC_STATUS:-0}"
fi
exit 0
EOF
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

@test "legacy background opt-in cannot resume a Codex thread or consume unread mail" {
  join_codex_roles
  bash "$SCRIPTS/send.sh" team alice bob "preserve-visible-mail" >/dev/null
  local fake log prompt
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-123
  [ "$status" -eq 64 ]
  [[ "$output" == *"background-only handling is prohibited"* ]]
  [ ! -e "$log" ]
  [ ! -e "$prompt" ]

  run bash "$TYPES/codex/watch-once.sh" "$TEST_PROJECT" codex \
    --team team --name bob --timeout 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=1"* ]]
}

@test "monitor request without a visible app-server downgrades to turn and preserves unread mail" {
  join_codex_roles
  bash "$SCRIPTS/send.sh" team alice bob "visible-turn-required" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  local fake log prompt
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  run env CODEX_THREAD_ID=thread-123 \
    AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/actas-monitor.sh" \
      "$TEST_PROJECT" codex bob thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"requested_mode=monitor"* ]]
  [[ "$output" == *"effective_mode=turn"* ]]
  [[ "$output" == *"reason=visible_app_server_unavailable"* ]]
  [ ! -e "$log" ]
  [ ! -e "$prompt" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]

  run bash "$TYPES/codex/watch-once.sh" "$TEST_PROJECT" codex \
    --team team --name bob --timeout 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=1"* ]]
}

@test "monitor with a relay but no visible Desktop downgrades to turn and leaves mail unread" {
  join_codex_roles
  bash "$SCRIPTS/send.sh" team alice bob "relay-restart-mail" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  local server port_file bridge_pid
  server="$TEST_SKILL_DIR/stalled-relay.js"
  port_file="$TEST_SKILL_DIR/stalled-relay.port"
  cat > "$server" <<'NODE'
#!/usr/bin/env node
const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const portFile = process.argv[2];
const server = net.createServer((socket) => {
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    const end = buffer.indexOf("\r\n\r\n");
    if (end === -1) return;
    const header = buffer.slice(0, end).toString("utf8");
    const key = (/sec-websocket-key:\s*([^\r\n]+)/i.exec(header) || [])[1];
    if (!key) return socket.destroy();
    const accept = crypto.createHash("sha1").update(`${key.trim()}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.removeAllListeners("data");
  });
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(portFile, String(server.address().port)));
NODE
  node "$server" "$port_file" &
  local server_pid=$!
  TEST_RECEIVER_PIDS="$server_pid"
  for _ in {1..50}; do [ -s "$port_file" ] && break; sleep 0.05; done
  [ -s "$port_file" ]
  local port="$(cat "$port_file")"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'ws://127.0.0.1:%s/bridge/%s\n' "$port" "$(printf '%064d' 0 | tr '0' 'b')" \
    > "$TEST_SKILL_DIR/run/codex-desktop-relay.bridge-endpoint"
  chmod 600 "$TEST_SKILL_DIR/run/codex-desktop-relay.bridge-endpoint"
  cat > "$TEST_SKILL_DIR/run/codex-desktop-relay.health" <<EOF
status=waiting_for_desktop
pid=$server_pid
port=$port
primary_connected=0
upstream_initialized=1
EOF

  run env CODEX_THREAD_ID=thread-123 \
    AGMSG_CODEX_ACTAS_READY_SECONDS=1 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=visible_turn_only"* ]]
  [[ "$output" == *"effective_mode=turn"* ]]
  [[ "$output" == *"reason=desktop_relay_not_ready"* ]]
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [[ "$output" == *"mode: monitor"* ]]
  run bash -c "compgen -G '$TEST_SKILL_DIR/run/codex-bridge.*.pid' >/dev/null"
  [ "$status" -ne 0 ]
  run bash "$TYPES/codex/watch-once.sh" "$TEST_PROJECT" codex \
    --team team --name bob --timeout 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"count=1"* ]]
}

@test "repeated monitor requests without a visible app-server never start a receiver" {
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"effective_mode=turn"* ]]

  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  run env CODEX_THREAD_ID=thread-123 \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-123
  [ "$status" -eq 0 ]
  [[ "$output" == *"effective_mode=turn"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
}

@test "delivery turn stops an app monitor even when no bridge pidfile exists" {
  skip_on_windows "process liveness assertion uses POSIX kill semantics"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  cat > "$TYPES/codex/codex-app-monitor.sh" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "$TYPES/codex/codex-app-monitor.sh"
  "$TYPES/codex/codex-app-monitor.sh" \
    "$(cd "$TEST_PROJECT" && pwd -P)" codex team alice thread-123 &
  local app_pid=$!
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$app_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=alice
thread=thread-123
transport=codex-background-thread-resume
EOF
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.plist"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.health"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.log"
  bash "$TYPES/codex/codex-monitor-lease.sh" arm \
    "$TEST_PROJECT" team alice thread-123 >/dev/null
  bash "$TYPES/codex/codex-monitor-lease.sh" automation \
    "$TEST_PROJECT" team alice thread-123 heartbeat-id watchdog-id >/dev/null

  run bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopped 1 Codex bridge/app monitor process"* ]]
  [[ "$output" == *"heartbeat_automation_id=heartbeat-id"* ]]
  [[ "$output" == *"watchdog_automation_id=watchdog-id"* ]]
  run ! kill -0 "$app_pid"
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.plist" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.health" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.log" ]

  run bash "$TYPES/codex/codex-monitor-lease.sh" status \
    "$TEST_PROJECT" team alice thread-123
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=inactive"* ]]
}

@test "delivery cleanup removes forged app-monitor state without signaling its pid or label" {
  skip_on_windows "process liveness assertion uses POSIX kill semantics"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  install_fake_launchctl

  sleep 60 &
  local unrelated_pid=$!
  TEST_RECEIVER_PIDS="$TEST_RECEIVER_PIDS $unrelated_pid"
  local base="$TEST_SKILL_DIR/run/codex-app-monitor.team.alice"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$unrelated_pid" > "$base.pid"
  cat > "$base.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=alice
thread=thread-forged
launch_label=com.example.unrelated-job
EOF
  cat > "$base.plist" <<'EOF'
<plist><dict><key>Label</key><string>com.example.other-unrelated-job</string></dict></plist>
EOF

  run bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"

  [ "$status" -eq 0 ]
  kill -0 "$unrelated_pid" 2>/dev/null
  ! grep -q 'com.example' "$AGMSG_FAKE_LAUNCHCTL_LOG"
  [ ! -e "$base.pid" ]
  [ ! -e "$base.meta" ]
  [ ! -e "$base.plist" ]
}

@test "dropping one codex role stops only that role's background receiver" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  local sleeper="$TYPES/codex/codex-app-monitor.sh" bob_pid alice_pid
  cat > "$sleeper" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do
  sleep 1
done
EOF
  chmod +x "$sleeper"

  "$sleeper" "$TEST_PROJECT" codex team bob thread-bob &
  bob_pid=$!
  "$sleeper" "$TEST_PROJECT" codex team alice thread-alice &
  alice_pid=$!
  TEST_RECEIVER_PIDS="$bob_pid $alice_pid"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$bob_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=bob
thread=thread-bob
transport=codex-background-thread-resume
EOF
  printf '%s\n' "$alice_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=alice
thread=thread-alice
transport=codex-background-thread-resume
EOF

  run bash "$SCRIPTS/reset.sh" "$TEST_PROJECT" codex bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reset complete"* ]]
  run ! kill -0 "$bob_pid"
  kill -0 "$alice_pid" 2>/dev/null
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
  [ -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.alice.pid" ]

  kill "$alice_pid" 2>/dev/null || true
  wait "$alice_pid" 2>/dev/null || true
  TEST_RECEIVER_PIDS=""
}

@test "legacy monitor opt-in cannot create a second hidden receiver" {
  join_codex_roles
  local fake log prompt
  fake="$(make_fake_codex)"
  log="$TEST_SKILL_DIR/fake-codex.log"
  prompt="$TEST_SKILL_DIR/fake-codex.prompt"

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-owner
  [ "$status" -eq 64 ]

  run env AGMSG_CODEX_ALLOW_BACKGROUND_THREAD_RESUME=1 \
    AGMSG_CODEX_APP_MONITOR_CODEX="$fake" \
    AGMSG_FAKE_CODEX_LOG="$log" \
    AGMSG_FAKE_CODEX_PROMPT="$prompt" \
    AGMSG_FAKE_CODEX_INBOX="$SCRIPTS/inbox.sh" \
    bash "$TYPES/codex/codex-app-monitor.sh" \
      "$TEST_PROJECT" codex team bob thread-duplicate
  [ "$status" -eq 64 ]
  [ ! -e "$log" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
}

@test "background resume hooks do not rebind or stop their parent receiver" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  env CODEX_THREAD_ID=thread-parent \
    bash "$TYPES/codex/actas-monitor.sh" "$TEST_PROJECT" codex bob thread-parent >/dev/null
  rm -f "$TEST_SKILL_DIR/run/codex-chat-visible.team.bob.meta"

  env AGMSG_CODEX_BACKGROUND_RESUME=1 CODEX_THREAD_ID=thread-parent \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" </dev/null
  [ ! -e "$TEST_SKILL_DIR/run/codex-chat-visible.team.bob.meta" ]

  local sleeper="$TYPES/codex/codex-app-monitor.sh" receiver_pid
  cat > "$sleeper" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "$sleeper"
  "$sleeper" "$TEST_PROJECT" codex team bob thread-ending &
  receiver_pid=$!
  TEST_RECEIVER_PIDS="$receiver_pid"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$receiver_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=bob
thread=thread-parent
transport=codex-background-thread-resume
EOF

  printf '%s\n' '{"session_id":"thread-parent"}' | \
    env AGMSG_CODEX_BACKGROUND_RESUME=1 bash "$SCRIPTS/session-end.sh" codex "$TEST_PROJECT"
  kill -0 "$receiver_pid" 2>/dev/null
  [ -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
}

@test "codex SessionEnd stops only the receiver bound to that visible thread" {
  skip_on_windows "background receiver liveness uses POSIX signals"
  join_codex_roles
  local sleeper="$TYPES/codex/codex-app-monitor.sh" receiver_pid
  cat > "$sleeper" <<'EOF'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "$sleeper"
  "$sleeper" "$TEST_PROJECT" codex team bob thread-ending &
  receiver_pid=$!
  TEST_RECEIVER_PIDS="$receiver_pid"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\n' "$receiver_pid" > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid"
  cat > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" <<EOF
project=$TEST_PROJECT
type=codex
team=team
name=bob
thread=thread-ending
transport=codex-background-thread-resume
EOF
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.plist"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health"
  : > "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.log"

  printf '%s\n' '{"session_id":"thread-ending"}' | \
    bash "$SCRIPTS/session-end.sh" codex "$TEST_PROJECT"

  run ! kill -0 "$receiver_pid"
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.pid" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.meta" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.plist" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.health" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-monitor.team.bob.log" ]
  TEST_RECEIVER_PIDS=""
}

@test "codex monitor never falls back to hidden resume or a new task" {
  grep -q 'background-only handling is prohibited' "$TYPES/codex/codex-app-monitor.sh"
  grep -q 'desktop_relay_endpoint_unavailable' "$TYPES/codex/actas-monitor.sh"
  run grep -q 'start_codex_app_monitor "$THREAD_ID"' "$TYPES/codex/actas-monitor.sh"
  [ "$status" -ne 0 ]
  run grep -q 'start_bridge ""' "$TYPES/codex/actas-monitor.sh"
  [ "$status" -ne 0 ]
  run grep -q 'THREAD_ID="new"' "$TYPES/codex/actas-monitor.sh"
  [ "$status" -ne 0 ]
  run grep -Eq 'codex-app-monitor|background-thread-resume|unix://|THREAD_ID="loaded"|resolve_thread_id|thread/start' "$TYPES/codex/actas-monitor.sh"
  [ "$status" -ne 0 ]
}
