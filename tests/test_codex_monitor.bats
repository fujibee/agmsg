#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export CALL_LOG="$TEST_PROJECT/calls.log"
  export AGMSG_TEST_CODEX_THREAD_ID="00000000-0000-4000-8000-000000000001"

  # Fake codex for codex-monitor tests.
  #   --version            -> prints "codex-cli $FAKE_CODEX_VERSION"
  #   app-server --listen  -> FAKE_CODEX_MODE=broken: reject (emulate a release
  #                           that can't bring the app-server up); otherwise bind
  #                           a real loopback port, print the listening line, and
  #                           stay alive so reuse health checks see a live server.
  #   anything else        -> log the invocation to CALL_LOG (the plain/--remote
  #                           handoff target) and exit.
  export FAKE_CODEX="$TEST_PROJECT/real-codex"
  cat > "$FAKE_CODEX" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    echo "codex-cli ${FAKE_CODEX_VERSION:-0.142.2}"
    exit 0
    ;;
  app-server)
    if [ "${FAKE_CODEX_MODE:-listen}" = "broken" ]; then
      echo "error: unexpected argument '--listen' found" >&2
      exit 2
    fi
    # Run the listener as a CHILD (no exec) so this script stays the recorded pid;
    # its argv ("...real-codex app-server --listen") is what codex-monitor's
    # cmdline check matches. The child exits when this parent is killed.
    python3 - <<'PY' &
import socket, sys, os, time
time.sleep(float(os.environ.get("FAKE_CODEX_LISTEN_DELAY", "0")))
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(16); s.settimeout(0.2)
print("codex app-server (WebSockets)")
print("  listening on: ws://127.0.0.1:%d" % s.getsockname()[1]); sys.stdout.flush()
ppid = os.getppid()
while True:
    if os.getppid() != ppid:
        break
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
PY
    listener_pid=$!
    trap 'kill "$listener_pid" 2>/dev/null || true' EXIT INT TERM
    wait "$listener_pid"
    ;;
  *)
    printf 'plain-codex' >> "$CALL_LOG"
    for a in "$@"; do printf ' <%s>' "$a" >> "$CALL_LOG"; done
    printf '\n' >> "$CALL_LOG"
    ;;
esac
EOF
  chmod +x "$FAKE_CODEX"
}

teardown() {
  if [ -n "${ABANDONED_SERVER_PID:-}" ]; then
    kill "$ABANDONED_SERVER_PID" 2>/dev/null || true
  fi
  # Kill any app-server listeners these tests spawned.
  for pf in "$TEST_SKILL_DIR"/run/codex-app-server.*.pid; do
    [ -f "$pf" ] || continue
    kill "$(cat "$pf" 2>/dev/null)" 2>/dev/null || true
  done
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

project_hash() {
  local resolved
  resolved="$(cd "$TEST_PROJECT" && pwd)"
  printf '%s' "$resolved" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 )
}

seed_abandoned_starting_server() {
  local generation="$1" delay="$2" hash log
  hash="$(project_hash)"
  log="$TEST_SKILL_DIR/run/codex-app-server.$hash.$generation.log"
  mkdir -p "$TEST_SKILL_DIR/run"
  FAKE_CODEX_LISTEN_DELAY="$delay" "$FAKE_CODEX" app-server --listen "ws://127.0.0.1:0" >"$log" 2>&1 3>&- &
  ABANDONED_SERVER_PID=$!
  export ABANDONED_SERVER_PID
  SKILL_DIR="$TEST_SKILL_DIR" RUN_DIR="$TEST_SKILL_DIR/run" bash -c \
    'source "$1/lib/codex-lease.sh"; codex_record_write_starting "$2" "$3" "codex-cli 0.142.2" 999999; codex_marker_write "$2" "$3" msys "$4" "$5"' \
    _ "$SCRIPTS" "$hash" "$generation" "$ABANDONED_SERVER_PID" "$log"
}

# --- fail-open (A) ---

@test "codex-monitor: fails open to plain codex when the app-server won't start (#170)" {
  run env FAKE_CODEX_MODE=broken AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex -- --foo
  [ "$status" -eq 0 ]
  # Handed off to a plain codex (no --remote bridge), preserving the args.
  grep -qx 'plain-codex <--foo>' "$CALL_LOG"
  # And it did NOT exec the bridged form.
  ! grep -q -- '--remote' "$CALL_LOG"
  # The fallback is LOUD: the user is told real-time delivery is off.
  [[ "$output" == *"Real-time agmsg delivery is OFF"* ]]
}

@test "codex-monitor: fail-open preserves the resume command" {
  run env FAKE_CODEX_MODE=broken AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command resume --
  [ "$status" -eq 0 ]
  grep -qx 'plain-codex <resume>' "$CALL_LOG"
}

@test "codex-monitor: keeps a foreground wrapper instead of execing the native TUI" {
  # The launcher watches codex-monitor.sh's MSYS pid. Replacing that process
  # with npm/node/native Codex makes kill -0 unreliable across the Windows
  # process-domain boundary and can tear down the shared app-server under a
  # still-running TUI. Keep an explicit post-command status path so bash must
  # remain as the foreground wrapper until the child exits.
  local monitor="$TYPES/codex/codex-monitor.sh"
  ! grep -Eq 'exec[[:space:]]+"\$REAL_CODEX"[[:space:]]+(resume[[:space:]]+)?--remote' "$monitor"
  grep -Fq '"$REAL_CODEX" --remote "$SOCKET_URL"' "$monitor"
  grep -Fq '"$REAL_CODEX" resume --remote "$SOCKET_URL"' "$monitor"
  grep -Fq 'exit "$tui_status"' "$monitor"
}

@test "codex bridge launcher stops its Windows lease heartbeat gracefully" {
  local launcher="$TYPES/codex/codex-bridge-launcher.sh"
  grep -Fq 'heartbeat_stop_file=' "$launcher"
  grep -Fq ': >"$heartbeat_stop_file"' "$launcher"
  grep -Fq '[ ! -f "$heartbeat_stop_file" ]' "$launcher"
  ! grep -Fq 'kill "$tui_heartbeat_pid"' "$launcher"
}

@test "codex-monitor: installs SessionStart hooks before app-server startup" {
  # The remote app-server snapshots project hook configuration at startup. If
  # delivery.sh runs after the lifecycle loop, the first TUI never publishes
  # its exact hook session and monitor remains in waiting_first_turn.
  local monitor="$TYPES/codex/codex-monitor.sh" hook_line server_line
  hook_line="$(grep -n 'delivery.sh.*set monitor codex' "$monitor" | head -1 | cut -d: -f1)"
  server_line="$(grep -n '"$REAL_CODEX" app-server --listen' "$monitor" | head -1 | cut -d: -f1)"
  [ -n "$hook_line" ]
  [ -n "$server_line" ]
  [ "$hook_line" -lt "$server_line" ]
  [ "$(grep -c 'delivery.sh.*set monitor codex' "$monitor")" -eq 1 ]
}

@test "codex-monitor: exports its resolved identity before app-server startup" {
  # The app-server owns tool subprocesses for a remote TUI. It must inherit the
  # seat identity or every agmsg call performs another slow Windows discovery.
  local monitor="$TYPES/codex/codex-monitor.sh" identity_line export_line server_line
  identity_line="$(grep -n 'monitor_pairs=.*identities.sh' "$monitor" | head -1 | cut -d: -f1)"
  export_line="$(grep -n 'export AGMSG_TEAM=' "$monitor" | head -1 | cut -d: -f1)"
  server_line="$(grep -n '"$REAL_CODEX" app-server --listen' "$monitor" | head -1 | cut -d: -f1)"
  [ -n "$identity_line" ]
  [ -n "$export_line" ]
  [ -n "$server_line" ]
  [ "$identity_line" -lt "$server_line" ]
  [ "$export_line" -lt "$server_line" ]
  grep -Fq 'IDENTITY_TEAM="${AGMSG_CODEX_TEAM:-${AGMSG_TEAM:-}}"' "$monitor"
  grep -Fq 'IDENTITY_NAME="${AGMSG_CODEX_NAME:-${AGMSG_AGENT:-}}"' "$monitor"
}

@test "codex skill: native Windows commands never fall back to WSL" {
  local template="$TYPES/codex/template.md"
  grep -Fq 'C:\Program Files\Git\bin\bash.exe' "$template"
  grep -Fq -- "-lc 'exec \"\$@\"'" "$template"
  grep -Fq 'never** invoke bare `bash`, `sh`, `wsl`, `wsl.exe`' "$template"
  grep -Fq 'Never retry a failed Git Bash command through WSL.' "$template"
  grep -Fq 'skip the `whoami.sh` call' "$template"
  ! grep -Fq 'restart it with explicit `--team' "$template"
}

@test "codex-monitor: discovers the exact thread created by the serialized TUI launch" {
  local monitor="$TYPES/codex/codex-monitor.sh"
  grep -Fq -- '--list-loaded-only' "$monitor"
  grep -Fq 'codex_lifecycle_lock_acquire "$ROUTE_LOCK_HASH"' "$monitor"
  grep -Fq 'comm -13' "$monitor"
  grep -Fq 'thread=%s\napp_server=%s\nproject=%s\n' "$monitor"
  grep -Fq '"$REAL_CODEX" --remote "$SOCKET_URL"' "$monitor"
  grep -Fq 'request_published tui_loaded_delta' "$monitor"
  grep -Fq 'thread_ambiguous "loaded_delta_$new_count"' "$monitor"
}

@test "codex launcher waits for the bridge generation handshake before respawn" {
  local launcher="$TYPES/codex/codex-bridge-launcher.sh"
  grep -Fq 'bridge_spawn_ready=0' "$launcher"
  grep -Fq 'spawned_lease_pid' "$launcher"
  grep -Fq 'spawned_generation' "$launcher"
  grep -Fq 'bridge_starting handshake_pending' "$launcher"
  grep -Fq 'tui_heartbeat_pid' "$launcher"
  grep -Fq 'AGMSG_CODEX_BRIDGE_START_POLLS:-450' "$launcher"
}

@test "codex lifecycle lock records native Windows ownership" {
  local lease="$SCRIPTS/lib/codex-lease.sh"
  grep -Fq "printf 'format_version=2\\nowner_msys_pid=%s\\n'" "$lease"
  grep -Fq 'owner_winpid' "$lease"
  grep -Fq 'owner_creation' "$lease"
  grep -Fq 'compat_pid_state_native "$owner_winpid"' "$lease"
}

# --- reuse health check (B-lite) ---

@test "codex-monitor: recreates a stale app-server left by a different codex version" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  # Run 1: bring up the bridge app-server under an OLD codex version.
  run env FAKE_CODEX_VERSION=0.141.0 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  local pidf verf; pidf="$(ls "$TEST_SKILL_DIR"/run/codex-app-server.*.pid)"; verf="${pidf%.pid}.version"
  local old_pid; old_pid="$(cat "$pidf")"
  grep -q '0.141.0' "$verf"
  kill -0 "$old_pid"

  # Run 2: a codex upgrade. The recorded port still answers and the pid is alive,
  # but the version differs, so the stale server must be replaced, not reused.
  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  grep -q '0.142.2' "$verf"
  ! kill -0 "$old_pid" 2>/dev/null
}

@test "codex-monitor: reuses a live app-server from the same codex version" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  local pidf; pidf="$(ls "$TEST_SKILL_DIR"/run/codex-app-server.*.pid)"
  local first_pid; first_pid="$(cat "$pidf")"

  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  # Same server reused (pid unchanged), not recreated.
  [ "$(cat "$pidf")" = "$first_pid" ]
}

@test "codex-monitor: never kills a non-codex process recorded under a reused pid" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  # A foreign process holding the recorded port (e.g. the codex pid was recycled).
  local portf="$TEST_PROJECT/foreign.port"
  python3 -c '
import socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0)); s.listen(8); s.settimeout(0.5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
while True:
    try:
        c, _ = s.accept(); c.close()
    except Exception:
        pass
' "$portf" &
  local foreign_pid=$!
  while [ ! -s "$portf" ]; do sleep 0.05; done
  local foreign_port; foreign_port="$(cat "$portf")"

  # Seed the run artifacts to point the reuse logic at that foreign process.
  local resolved hash base run
  resolved="$(cd "$TEST_PROJECT" && pwd)"
  hash="$(printf '%s' "$resolved" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  run="$TEST_SKILL_DIR/run"; mkdir -p "$run"
  base="$run/codex-app-server.$hash"
  echo "$foreign_port" > "$base.port"
  echo "$foreign_pid"  > "$base.pid"
  echo "codex-cli 9.9.9" > "$base.version"

  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  # The foreign process must NOT have been killed...
  kill -0 "$foreign_pid"
  # ...and a fresh app-server of our own was started under a different pid.
  [ "$(cat "$base.pid")" != "$foreign_pid" ]

  kill "$foreign_pid" 2>/dev/null || true
}

@test "codex-monitor: adopts a marked app-server when its starter dies before listen" {
  [ "${AGMSG_TEST_FORCE_CODEX_MONITOR_LIFECYCLE:-0}" = 1 ] || \
    skip_on_windows "spawns a delayed python socket listener; covered on POSIX CI"
  seed_abandoned_starting_server generation-adopt 0.5

  run env AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=true AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]

  local record="$TEST_SKILL_DIR/run/codex-app-server.$(project_hash).record"
  [ "$(sed -n 's/^status=//p' "$record")" = ready ]
  [ "$(sed -n 's/^generation=//p' "$record")" = generation-adopt ]
  [ "$(sed -n 's/^pid=//p' "$record")" = "$ABANDONED_SERVER_PID" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-server.$(project_hash).spawning.generation-adopt" ]
  kill -0 "$ABANDONED_SERVER_PID"
}

@test "codex-monitor: concurrent successors publish one adopted generation" {
  [ "${AGMSG_TEST_FORCE_CODEX_MONITOR_LIFECYCLE:-0}" = 1 ] || \
    skip_on_windows "spawns a delayed python socket listener; covered on POSIX CI"
  seed_abandoned_starting_server generation-shared 0.8

  env AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=true AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex -- \
    >"$TEST_PROJECT/monitor-1.log" 2>&1 3>&- &
  local monitor1=$!
  sleep 0.05
  env AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=true AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex -- \
    >"$TEST_PROJECT/monitor-2.log" 2>&1 3>&- &
  local monitor2=$!
  local status1=0 status2=0
  wait "$monitor1" || status1=$?
  wait "$monitor2" || status2=$?
  [ "$status1" -eq 0 ]
  [ "$status2" -eq 0 ]

  local record="$TEST_SKILL_DIR/run/codex-app-server.$(project_hash).record"
  [ "$(sed -n 's/^status=//p' "$record")" = ready ]
  [ "$(sed -n 's/^generation=//p' "$record")" = generation-shared ]
  [ "$(sed -n 's/^pid=//p' "$record")" = "$ABANDONED_SERVER_PID" ]
  [ "$(grep -c '^plain-codex' "$CALL_LOG")" -eq 2 ]
}
