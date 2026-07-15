#!/usr/bin/env bats

# Unit tests for generation-scoped launcher routing. A mock bridge records the
# exact --thread the launcher passes without touching a real app-server.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export PROJ="$TEST_SKILL_DIR/proj"; mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null

  export CAPTURE="$TEST_SKILL_DIR/thread-capture.txt"
  export MOCK="$TEST_SKILL_DIR/mock-bridge.sh"
  cat > "$MOCK" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CAPTURE"
exit 0
EOF
  chmod +x "$MOCK"
  export AGMSG_CODEX_BRIDGE_CMD="$MOCK"
  export LAUNCHER="$SCRIPTS/drivers/types/codex/codex-bridge-launcher.sh"
  export TUI_GEN="test-tui-generation"
  export REQUEST="$RUN_DIR/codex-bridge-request.$(project_hash).$TUI_GEN"
  export STATE="$RUN_DIR/codex-monitor-state.$(project_hash).$TUI_GEN"
}

teardown() { teardown_test_env; }

put_request() {
  local thread="$1" generation="${2:-$TUI_GEN}" app_server="${3:-ws://127.0.0.1:1}"
  {
    printf 'format_version=2\n'
    printf 'generation=%s\ntype=codex\nteam=team\nname=alice\n' "$generation"
    printf 'thread=%s\napp_server=%s\nproject=%s\ncreated_at=%s\n' \
      "$thread" "$app_server" "$PROJ" "$(date +%s)"
  } >"$REQUEST"
}

project_hash() {
  printf '%s' "$PROJ" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 )
}

seed_ready_record() {
  SKILL_DIR="$TEST_SKILL_DIR" RUN_DIR="$RUN_DIR" bash -c \
    'source "$1/lib/codex-lease.sh"; codex_record_write_ready "$2" "$3" "codex-cli test" msys 999999 1234' \
    _ "$SCRIPTS" "$(project_hash)" "${1:-server-generation}"
}

# Drive the launcher against a short-lived parent, blocking until it exits. fd 3
# is closed on the backgrounded parent and the launcher so a stray descriptor
# can't keep bats from exiting on macOS (#bats-fd3).
run_launcher() {
  # Windows process startup and isolated DB initialization can consume most of a
  # two-second parent lifetime before the launcher reaches identity resolution.
  sleep 5 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" "$TUI_GEN" "$REQUEST" "" "" "$STATE" \
    >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
}

@test "launcher: binds an exact generation-scoped request and consumes it" {
  put_request exact-thread-1
  run_launcher
  [ -f "$CAPTURE" ]
  grep -q -- "--thread exact-thread-1" "$CAPTURE"
  ! grep -q -- "--thread loaded" "$CAPTURE"
  [ ! -e "$REQUEST" ]
}

@test "launcher: waits for an exact hook request instead of guessing a loaded thread" {
  run_launcher
  [ ! -e "$CAPTURE" ]
}

@test "launcher: ignores the legacy project-global request" {
  printf '%s\n' $'codex\tteam\talice\tstale-global-thread\tws://127.0.0.1:9' \
    >"$RUN_DIR/codex-bridge-request.$(project_hash)"
  run_launcher
  [ ! -e "$CAPTURE" ]
  ! grep -q -- "--thread stale-global-thread" "$CAPTURE"
}

@test "launcher: rejects a request for another generation or app-server" {
  put_request wrong-generation another-generation
  run_launcher
  [ ! -e "$CAPTURE" ]
  ! grep -q -- "--thread wrong-generation" "$CAPTURE"
  [ ! -e "$REQUEST" ]

  put_request wrong-server "$TUI_GEN" ws://127.0.0.1:9
  run_launcher
  [ ! -e "$CAPTURE" ]
  ! grep -q -- "--thread wrong-server" "$CAPTURE"
}

@test "launcher: writes the bound-thread file from an exact request" {
  put_request exact-thread-1
  run_launcher
  [ "$(cat "$RUN_DIR/codex-bridge.team.alice.thread" 2>/dev/null)" = "exact-thread-1" ]
}

@test "launcher: invalidated exact route waits for and accepts a fresh exact request" {
  put_request stale-thread
  sleep 8 3>&- & local parent_pid=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_pid" "$TUI_GEN" "$REQUEST" "" "" "$STATE" \
    >/dev/null 2>&1 3>&- &
  local launcher_pid=$!
  for _ in $(seq 1 50); do
    grep -q -- '--thread stale-thread' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- '--thread stale-thread' "$CAPTURE"
  cat >"$STATE" <<EOF
format_version=1
phase=route_invalid
detail=requested_thread_not_loaded
updated_at=$(date +%s)
EOF
  for _ in $(seq 1 50); do
    grep -qx 'phase=waiting_first_turn' "$STATE" 2>/dev/null && break
    sleep 0.1
  done
  grep -qx 'phase=waiting_first_turn' "$STATE"
  ! grep -q -- '--thread loaded' "$CAPTURE"

  put_request fresh-thread
  for _ in $(seq 1 60); do
    grep -q -- '--thread fresh-thread' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- '--thread fresh-thread' "$CAPTURE"

  kill "$parent_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
}

@test "launcher: disabled marker prevents lease publication and bridge start" {
  local disabled="$RUN_DIR/codex-monitor-disabled.$(project_hash)"
  : >"$disabled"
  run_launcher
  [ ! -e "$CAPTURE" ]
  ! find "$RUN_DIR" -maxdepth 1 -name 'codex-tui-lease.*' -print -quit | grep -q .
}

@test "launcher: thread rebind replaces its lease and app-server ref then cleans both" {
  put_request exact-thread-1
  seed_ready_record server-generation

  sleep 8 3>&- & local parent_pid=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_pid" "$TUI_GEN" "$REQUEST" "" "" "$STATE" \
    >/dev/null 2>&1 3>&- &
  local launcher_pid=$!
  for _ in $(seq 1 50); do
    [ -s "$CAPTURE" ] && break
    sleep 0.1
  done
  [ -s "$CAPTURE" ]
  local old_lease
  old_lease="$(awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "--tui-lease") { print $(i+1); exit } }' "$CAPTURE")"
  [ -f "$old_lease" ]

  put_request exact-thread-2
  for _ in $(seq 1 60); do
    grep -q -- '--thread exact-thread-2' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- '--thread exact-thread-2' "$CAPTURE"
  local new_lease
  new_lease="$(awk '/--thread exact-thread-2/ { for (i=1; i<=NF; i++) if ($i == "--tui-lease") { print $(i+1); exit } }' "$CAPTURE")"
  [ "$new_lease" != "$old_lease" ]
  [ ! -e "$old_lease" ]
  [ -f "$new_lease" ]

  local refs="$RUN_DIR/codex-app-server.$(project_hash).refs"
  [ "$(find "$refs" -maxdepth 1 -type f | wc -l | tr -d ' ')" = 1 ]

  kill "$parent_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  [ ! -e "$new_lease" ]
  ! find "$refs" -maxdepth 1 -type f -print -quit 2>/dev/null | grep -q .
}

@test "launcher: a second TUI cannot steal a live same-identity bridge generation" {
  local old_generation="older-live-tui" native_pid_file="$TEST_SKILL_DIR/old-bridge.pid"
  node -e 'require("fs").writeFileSync(process.argv[1], String(process.pid)); setTimeout(() => {}, 60000);' \
    "$native_pid_file" codex-bridge.js &
  local node_job=$!
  trap 'kill "$node_job" 2>/dev/null || true' EXIT
  local bridge_pid=""
  for _ in $(seq 1 30); do
    [ -s "$native_pid_file" ] && bridge_pid="$(tr -d '\r\n' <"$native_pid_file")" && break
    sleep 0.1
  done
  [ -n "$bridge_pid" ]

  local old_lease bridge_lease
  old_lease="$(SKILL_DIR="$TEST_SKILL_DIR" RUN_DIR="$RUN_DIR" bash -c \
    '. "$1/lib/codex-lease.sh"; codex_write_tui_lease team alice old-thread "$2" "$3" ws://127.0.0.1:1 $$' \
    _ "$SCRIPTS" "$old_generation" "$PROJ")"
  bridge_lease="$RUN_DIR/codex-bridge-lease.team.alice"
  printf '%s\n' "$bridge_pid" >"$RUN_DIR/codex-bridge.team.alice.pid"
  cat >"$RUN_DIR/codex-bridge.team.alice.meta" <<EOF
pid=$bridge_pid
pid_domain=native
project=$PROJ
team=team
name=alice
type=codex
EOF
  printf '%s' 'ws://127.0.0.1:1' >"$RUN_DIR/codex-bridge.team.alice.appserver"
  printf '%s' old-thread >"$RUN_DIR/codex-bridge.team.alice.thread"
  cat >"$bridge_lease" <<EOF
format_version=1
owner_kind=bridge
pid_domain=native
owner_winpid=$bridge_pid
bound_thread_id=old-thread
bound_generation=$old_generation
app_server=ws://127.0.0.1:1
phase=watch_armed
updated_at=$(date +%s)
EOF

  put_request new-thread

  sleep 8 3>&- & local parent_pid=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_pid" "$TUI_GEN" "$REQUEST" "" "" "$STATE" \
    >/dev/null 2>&1 3>&- &
  local launcher_pid=$!
  for _ in $(seq 1 50); do
    grep -qx 'phase=identity_conflict' "$STATE" 2>/dev/null && break
    sleep 0.1
  done

  grep -qx 'phase=identity_conflict' "$STATE"
  kill -0 "$node_job" 2>/dev/null
  [ ! -e "$CAPTURE" ]
  [ -f "$old_lease" ]

  kill "$parent_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  kill "$node_job" 2>/dev/null || true
  trap - EXIT
}
