#!/usr/bin/env bats

# Unit tests for codex-bridge-launcher.sh thread resolution (#350).
# The launcher must bind the bridge to the role's RECORDED codex thread instead
# of the app-server's ambiguous "loaded" thread (which a co-resident codex thread
# in the same cwd could otherwise capture). A mock bridge (AGMSG_CODEX_BRIDGE_CMD)
# records the --thread the launcher passes.

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
}

teardown() { teardown_test_env; }

# Write a role-session record (team, agent) -> thread for a project.
put_record() {
  SKILL_DIR="$TEST_SKILL_DIR" bash -c \
    'source "$1/lib/role-session.sh"; agmsg_role_session_record "$2" "$3" "$4" "$5" "$6"' \
    _ "$SCRIPTS" "$@"
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
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
}

@test "launcher: binds the recorded thread when the record's project matches (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ -f "$CAPTURE" ]
  grep -q -- "--thread rec-thread-1" "$CAPTURE"
  ! grep -q -- "--thread loaded" "$CAPTURE"
}

@test "launcher: falls back to 'loaded' when no record exists (#350)" {
  run_launcher
  [ -f "$CAPTURE" ]
  grep -q -- "--thread loaded" "$CAPTURE"
}

@test "launcher: falls back to 'loaded' when the record is for a different project (#350)" {
  put_record team alice other-thread "/some/other/project" codex
  run_launcher
  [ -f "$CAPTURE" ]
  grep -q -- "--thread loaded" "$CAPTURE"
  ! grep -q -- "--thread other-thread" "$CAPTURE"
}

@test "launcher: writes the bound-thread file so a later launcher can rebind (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ "$(cat "$RUN_DIR/codex-bridge.team.alice.thread" 2>/dev/null)" = "rec-thread-1" ]
}

@test "launcher: disabled marker prevents lease publication and bridge start" {
  local disabled="$RUN_DIR/codex-monitor-disabled.$(project_hash)"
  : >"$disabled"
  run_launcher
  [ ! -e "$CAPTURE" ]
  ! find "$RUN_DIR" -maxdepth 1 -name 'codex-tui-lease.*' -print -quit | grep -q .
}

@test "launcher: thread rebind replaces its lease and app-server ref then cleans both" {
  put_record team alice rec-thread-1 "$PROJ" codex
  seed_ready_record server-generation

  sleep 8 3>&- & local parent_pid=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_pid" >/dev/null 2>&1 3>&- &
  local launcher_pid=$!
  for _ in $(seq 1 50); do
    [ -s "$CAPTURE" ] && break
    sleep 0.1
  done
  [ -s "$CAPTURE" ]
  local old_lease
  old_lease="$(awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i == "--tui-lease") { print $(i+1); exit } }' "$CAPTURE")"
  [ -f "$old_lease" ]

  put_record team alice rec-thread-2 "$PROJ" codex
  for _ in $(seq 1 60); do
    grep -q -- '--thread rec-thread-2' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- '--thread rec-thread-2' "$CAPTURE"
  local new_lease
  new_lease="$(awk '/--thread rec-thread-2/ { for (i=1; i<=NF; i++) if ($i == "--tui-lease") { print $(i+1); exit } }' "$CAPTURE")"
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
