#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export CALL_LOG="$TEST_PROJECT/calls.log"
  export TEST_MONITOR_PID=""
  export TEST_TUI_RELEASE_FILE=""
  export TEST_TUI_EXIT_FILE=""

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
    [ -z "${AGMSG_TEST_APP_SERVER_KEY_LOG:-}" ] || printf '%s' "${AGMSG_CODEX_APP_SERVER_KEY:-}" > "$AGMSG_TEST_APP_SERVER_KEY_LOG"
    [ -z "${AGMSG_TEST_APP_SERVER_INHERITED_URL_LOG:-}" ] || printf '%s' "${AGMSG_CODEX_BRIDGE_APP_SERVER:-}" > "$AGMSG_TEST_APP_SERVER_INHERITED_URL_LOG"
    if [ -n "${AGMSG_TEST_APP_SERVER_URL_LOG:-}" ]; then
      (
        SKILL_DIR="$TEST_SKILL_DIR"
        source "$SKILL_DIR/scripts/lib/hash.sh"
        source "$SKILL_DIR/scripts/drivers/types/codex/_app-server.sh"
        nested_url=""
        for _probe in $(seq 1 100); do
          nested_url="$(_agmsg_codex_app_server_url "$AGMSG_TEST_APP_SERVER_PROJECT")"
          [ -n "$nested_url" ] && break
          sleep 0.05
        done
        printf '%s' "$nested_url" > "$AGMSG_TEST_APP_SERVER_URL_LOG"
      ) &
    fi
    # Run the listener as a CHILD (no exec) so this script stays the recorded pid;
    # its argv ("...real-codex app-server --listen") is what codex-monitor's
    # cmdline check matches.
    python3 - <<'PY' &
import socket, sys, os
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
    child=$!
    record_server_term() {
      [ -z "${FAKE_TERM_LOG:-}" ] || printf 'server TERM\n' >> "$FAKE_TERM_LOG"
      kill "$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
      exit 0
    }
    trap record_server_term TERM
    [ -z "${FAKE_SERVER_READY_FILE:-}" ] || printf '%s' "$$" > "$FAKE_SERVER_READY_FILE"
    wait "$child"
    ;;
  *)
    record_tui_term() {
      [ -z "${FAKE_TUI_TERM_LOG:-}" ] || printf 'tui TERM\n' > "$FAKE_TUI_TERM_LOG"
      [ -z "${FAKE_TUI_EXIT_MARKER:-}" ] || : > "$FAKE_TUI_EXIT_MARKER"
      exit 143
    }
    trap record_tui_term TERM
    [ -z "${FAKE_TUI_PID_FILE:-}" ] || printf '%s' "$$" > "$FAKE_TUI_PID_FILE"
    [ -z "${AGMSG_TEST_TUI_CWD_LOG:-}" ] || printf '%s\n' "$PWD" >> "$AGMSG_TEST_TUI_CWD_LOG"
    printf 'plain-codex' >> "$CALL_LOG"
    for a in "$@"; do printf ' <%s>' "$a" >> "$CALL_LOG"; done
    printf '\n' >> "$CALL_LOG"
    [ -z "${FAKE_TUI_READY_FILE:-}" ] || printf '%s' "$$" > "$FAKE_TUI_READY_FILE"
    while [ -n "${FAKE_TUI_GATE:-}" ] && [ ! -e "$FAKE_TUI_GATE" ]; do sleep 0.1; done
    [ -z "${FAKE_TUI_EXIT_MARKER:-}" ] || : > "$FAKE_TUI_EXIT_MARKER"
    exit "${FAKE_TUI_STATUS:-0}"
    ;;
esac
EOF
  chmod +x "$FAKE_CODEX"
}

teardown() {
  # Kill any app-server listeners these tests spawned, and WAIT for them.
  # Signalling and moving on is enough on POSIX, where an open file does not
  # stop its directory being unlinked. Windows holds the directory while any
  # process inside it is alive, so the rm below fails with "Directory not
  # empty" and the test reports a failure whose assertions all passed.
  local pf pid
  if [ -n "${TEST_MONITOR_PID:-}" ]; then
    kill "$TEST_MONITOR_PID" 2>/dev/null || true
    wait "$TEST_MONITOR_PID" 2>/dev/null || true
  fi
  [ -z "${TEST_TUI_RELEASE_FILE:-}" ] || : > "$TEST_TUI_RELEASE_FILE"
  [ -z "${TEST_TUI_EXIT_FILE:-}" ] || wait_for_file "$TEST_TUI_EXIT_FILE" || true
  for pf in "$TEST_SKILL_DIR"/run/codex-app-server.*.pid; do
    [ -f "$pf" ] || continue
    pid="$(cat "$pf" 2>/dev/null)"
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" || true
  done
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

_make_term_recording_launcher() {
  local launcher="$1"
  cat > "$launcher" <<'EOF'
#!/usr/bin/env bash
record_launcher_term() {
  printf 'launcher TERM\n' > "$FAKE_LAUNCHER_TERM_LOG"
  exit 0
}
trap record_launcher_term TERM
printf '%s' "$$" > "$FAKE_LAUNCHER_READY_FILE"
while :; do sleep 0.1; done
EOF
  chmod +x "$launcher"
}

# --- fail-open (A) ---

@test "codex-monitor: fails open to plain codex when the app-server won't start (#170)" {
  run env FAKE_CODEX_MODE=broken AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex -- --foo
  [ "$status" -eq 0 ]
  # Handed off to a plain codex (no --remote bridge), preserving the args.
  grep -qx 'plain-codex <--foo>' "$CALL_LOG"
  # And it did NOT exec the bridged form.
  refute grep -q -- '--remote' "$CALL_LOG"
  # The fallback is LOUD: the user is told real-time delivery is off.
  [[ "$output" == *"Real-time agmsg delivery is OFF"* ]]
}

@test "codex-monitor: fail-open preserves the resume command" {
  run env FAKE_CODEX_MODE=broken AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command resume --
  [ "$status" -eq 0 ]
  grep -qx 'plain-codex <resume>' "$CALL_LOG"
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

@test "codex-monitor: invocation scope is consumed before Codex argv" {
  local key_log="$TEST_PROJECT/app-server-key"
  local inherited_url_log="$TEST_PROJECT/inherited-app-server-url"
  run env AGMSG_CODEX_BRIDGE_APP_SERVER=ws://127.0.0.1:3333 \
    AGMSG_TEST_APP_SERVER_KEY_LOG="$key_log" \
    AGMSG_TEST_APP_SERVER_INHERITED_URL_LOG="$inherited_url_log" \
    AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" \
    --project "$TEST_PROJECT" --invocation-scope scope-A --codex-command codex -- --foo
  [ "$status" -eq 0 ]
  grep -Eq 'plain-codex <--remote> <ws://127\.0\.0\.1:[0-9]+> <--foo>' "$CALL_LOG"
  refute grep -q -- '--invocation-scope' "$CALL_LOG"
  local expected_key
  expected_key="$(printf '%s\n%s' "$(cd "$TEST_PROJECT" && pwd)" scope-A | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  [ "$(cat "$key_log")" = "$expected_key" ]
  [ "$(cat "$inherited_url_log")" = "ws://127.0.0.1:3333" ]
}

@test "codex-monitor: malformed and duplicate scopes fail before launch" {
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" bash "$TYPES/codex/codex-monitor.sh" \
    --project "$TEST_PROJECT" --invocation-scope
  [ "$status" -eq 2 ]
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" bash "$TYPES/codex/codex-monitor.sh" \
    --project "$TEST_PROJECT" --invocation-scope bad/scope --codex-command codex --
  [ "$status" -eq 2 ]
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" bash "$TYPES/codex/codex-monitor.sh" \
    --project "$TEST_PROJECT" --invocation-scope one --invocation-scope two \
    --codex-command codex --
  [ "$status" -eq 2 ]
  [ ! -e "$CALL_LOG" ]
}

@test "codex-monitor: help distinguishes legacy reuse from scoped supervision" {
  run bash "$TYPES/codex/codex-monitor.sh" --help
  [ "$status" -eq 0 ]
  grep -Fq -- "--invocation-scope TOKEN" <<< "$output"
  grep -Fq -- "Without --invocation-scope, starts/reuses" <<< "$output"
  grep -Fq -- "then execs" <<< "$output"
  grep -Fq -- "Scoped mode waits for its captured TUI, app-server, and bridge launcher processes." <<< "$output"
}

@test "codex-monitor: physical project aliases share scoped leases and one dispatcher" {
  skip_on_windows "requires POSIX symlink and process semantics"

  local physical="$TEST_PROJECT/physical-project"
  local project_alias="$TEST_PROJECT/project-alias"
  local gate_a="$TEST_PROJECT/release-a" gate_b="$TEST_PROJECT/release-b"
  local cwd_log="$TEST_PROJECT/tui-cwds"
  local project_hash key_a key_b pidfile_a pidfile_b first_pidfile first_pid
  local second_pid_log dispatcher_log probe_pid probe_status second_pid dispatcher_rows i
  mkdir -p "$physical"
  mkdir -p "$TEST_SKILL_DIR/run"
  ln -s "$physical" "$project_alias"
  physical="$(cd "$physical" && pwd -P)"
  project_hash="$(printf '%s' "$physical" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  key_a="$(printf '%s\n%s' "$physical" scope-A | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  key_b="$(printf '%s\n%s' "$physical" scope-B | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  pidfile_a="$TEST_SKILL_DIR/run/codex-app-server.$key_a.pid"
  pidfile_b="$TEST_SKILL_DIR/run/codex-app-server.$key_b.pid"

  env FAKE_TUI_GATE="$gate_a" AGMSG_TEST_TUI_CWD_LOG="$cwd_log" \
    AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$project_alias" \
    --invocation-scope scope-A --codex-command codex -- &
  TEST_MONITOR_PID=$!
  first_pidfile=""
  for i in $(seq 1 100); do
    first_pidfile="$(find "$TEST_SKILL_DIR/run" -name 'codex-app-server.*.pid' -type f | head -1)"
    [ -n "$first_pidfile" ] && break
    sleep 0.1
  done
  [ -n "$first_pidfile" ]
  first_pid="$(cat "$first_pidfile")"

  run env AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$physical" \
    --invocation-scope scope-A --codex-command codex --
  if [ "$status" -eq 0 ]; then
    echo "same physical project and scope launched twice through alias paths" >&2
    false
  fi
  [ "$first_pidfile" = "$pidfile_a" ]
  [ "$(cat "$pidfile_a")" = "$first_pid" ]

  second_pid_log="$TEST_PROJECT/scope-b-pid"
  dispatcher_log="$TEST_PROJECT/dispatcher-rows"
  (
    set -e
    trap ': > "$gate_b"' EXIT
    wait_for_file "$pidfile_b"
    second_pid="$(cat "$pidfile_b")"
    [ "$first_pid" != "$second_pid" ]
    kill -0 "$first_pid"
    kill -0 "$second_pid"
    dispatcher_rows=""
    for i in $(seq 1 100); do
      dispatcher_rows="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" \
        "SELECT resource FROM locks WHERE resource LIKE 'codex-dispatcher:%' ORDER BY resource;" 2>/dev/null || true)"
      [ -n "$dispatcher_rows" ] && break
      sleep 0.1
    done
    printf '%s' "$second_pid" > "$second_pid_log"
    printf '%s' "$dispatcher_rows" > "$dispatcher_log"
  ) &
  probe_pid=$!
  run env FAKE_TUI_GATE="$gate_b" AGMSG_TEST_TUI_CWD_LOG="$cwd_log" \
    AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$physical" \
    --invocation-scope scope-B --codex-command codex --
  [ "$status" -eq 0 ]
  if wait "$probe_pid"; then probe_status=0; else probe_status=$?; fi
  [ "$probe_status" -eq 0 ]
  second_pid="$(cat "$second_pid_log")"
  dispatcher_rows="$(cat "$dispatcher_log")"
  [ "$first_pid" != "$second_pid" ]
  [ "$dispatcher_rows" = "codex-dispatcher:$project_hash" ]
  grep -Fq "$physical" "$physical/.codex/hooks.json"
  refute grep -Fq "$project_alias" "$physical/.codex/hooks.json"

  for i in $(seq 1 100); do
    [ "$(wc -l < "$cwd_log" 2>/dev/null | tr -d ' ')" -eq 2 ] && break
    sleep 0.1
  done
  [ "$(wc -l < "$cwd_log" | tr -d ' ')" -eq 2 ]
  [ "$(sort -u "$cwd_log")" = "$physical" ]

  : > "$gate_a"
  wait "$TEST_MONITOR_PID"
  TEST_MONITOR_PID=""
}

@test "codex-monitor: no-scope server ignores inherited scoped routing" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  local hash base key_log nested_url_log nested_url own_url
  hash="$(printf '%s' "$(cd "$TEST_PROJECT" && pwd -P)" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  base="$TEST_SKILL_DIR/run/codex-app-server.$hash"
  key_log="$TEST_PROJECT/app-server-key"
  nested_url_log="$TEST_PROJECT/nested-app-server-url"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '1111' > "$TEST_SKILL_DIR/run/codex-app-server.outer-scope.port"

  run env AGMSG_CODEX_APP_SERVER_KEY=outer-scope \
    AGMSG_CODEX_BRIDGE_APP_SERVER=ws://127.0.0.1:3333 \
    AGMSG_TEST_APP_SERVER_KEY_LOG="$key_log" \
    AGMSG_TEST_APP_SERVER_URL_LOG="$nested_url_log" \
    AGMSG_TEST_APP_SERVER_PROJECT="$TEST_PROJECT" \
    AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  wait_for_file "$nested_url_log"
  [ -f "$base.pid" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-app-server.outer-scope.pid" ]
  nested_url="$(cat "$nested_url_log")"
  own_url="ws://127.0.0.1:$(cat "$base.port")"
  if [ "$nested_url" != "$own_url" ]; then
    echo "nested no-scope URL=$nested_url; own project URL=$own_url" >&2
    false
  fi
  [ ! -s "$key_log" ]
  grep -Fq "<--remote> <$own_url>" "$CALL_LOG"
}

@test "codex-monitor: no-scope duplicate dispatcher does not inherit scoped standby" {
  skip_on_windows "uses POSIX process and lock-owner semantics"

  local hash resource barrier gate owner sentinel_pid probe_log probe_pid probe_status
  local barrier_count observed_owner
  hash="$(printf '%s' "$(cd "$TEST_PROJECT" && pwd -P)" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  resource="codex-dispatcher:$hash"
  barrier="$TEST_PROJECT/standby-observed"
  gate="$TEST_PROJECT/release-tui"
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 3>&- &
  TEST_MONITOR_PID=$!
  sentinel_pid="$TEST_MONITOR_PID"
  owner="$(bash -c 'source "$1"; agmsg_runtime_lock_acquire "$2" "$3"' \
    _ "$SCRIPTS/lib/storage.sh" "$resource" "$sentinel_pid")"
  [ "$owner" = "$sentinel_pid" ]
  printf '%s' "$sentinel_pid" > "$TEST_SKILL_DIR/run/codex-app-server.outer-scope.pid"

  probe_log="$TEST_PROJECT/dispatcher-probe"
  (
    set -e
    trap ': > "$gate"' EXIT
    wait_for_file_contains "$CALL_LOG" plain-codex
    sleep 1
    barrier_count="$(find "$TEST_PROJECT" -maxdepth 1 -name 'standby-observed.*' -type f | wc -l | tr -d ' ')"
    [ "$barrier_count" -eq 0 ]
    observed_owner="$(bash -c 'source "$1"; agmsg_runtime_lock_owner "$2"' \
      _ "$SCRIPTS/lib/storage.sh" "$resource")"
    [ "$observed_owner" = "$sentinel_pid" ]
    printf '%s\n%s\n' "$barrier_count" "$observed_owner" > "$probe_log"
  ) &
  probe_pid=$!
  run env AGMSG_CODEX_APP_SERVER_KEY=outer-scope \
    AGMSG_CODEX_BRIDGE_APP_SERVER=ws://127.0.0.1:3333 \
    AGMSG_TEST_LOCK_STANDBY_BARRIER="$barrier" FAKE_TUI_GATE="$gate" \
    AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  if wait "$probe_pid"; then probe_status=0; else probe_status=$?; fi
  [ "$probe_status" -eq 0 ]
  [ "$(sed -n '1p' "$probe_log")" -eq 0 ]
  [ "$(sed -n '2p' "$probe_log")" = "$sentinel_pid" ]

  kill "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
  TEST_MONITOR_PID=""
}

@test "codex-monitor: scoped TUI exit preserves status and removes exact artifacts" {
  run env FAKE_TUI_STATUS=37 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-exit --codex-command resume -- --last -C "$TEST_PROJECT"
  [ "$status" -eq 37 ]
  grep -Eq '^plain-codex <resume> <--remote> <ws://127\.0\.0\.1:[0-9]+> <--last> <-C>' "$CALL_LOG"
  [ "$(find "$TEST_SKILL_DIR/run" -name 'codex-app-server.*' -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "codex-monitor: scoped TUI exit sends TERM to its captured server and launcher children" {
  local term_log="$TEST_PROJECT/server-term.log"
  local launcher_term_log="$TEST_PROJECT/launcher-term.log"
  local launcher="$TEST_PROJECT/fake-launcher"
  local gate="$TEST_PROJECT/release-tui"
  local tui_exit="$TEST_PROJECT/tui-exit"
  local server_ready="$TEST_PROJECT/server-ready"
  local launcher_ready="$TEST_PROJECT/launcher-ready"
  local tui_ready="$TEST_PROJECT/tui-ready"
  _make_term_recording_launcher "$launcher"
  TEST_TUI_RELEASE_FILE="$gate"
  TEST_TUI_EXIT_FILE="$tui_exit"

  env FAKE_TERM_LOG="$term_log" FAKE_SERVER_READY_FILE="$server_ready" \
    FAKE_LAUNCHER_TERM_LOG="$launcher_term_log" FAKE_LAUNCHER_READY_FILE="$launcher_ready" \
    FAKE_TUI_GATE="$gate" FAKE_TUI_READY_FILE="$tui_ready" FAKE_TUI_EXIT_MARKER="$tui_exit" \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD="$launcher" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-term --codex-command codex -- &
  TEST_MONITOR_PID=$!
  wait_for_file_contains "$server_ready" '[0-9]'
  wait_for_file_contains "$launcher_ready" '[0-9]'
  wait_for_file_contains "$tui_ready" '[0-9]'
  : > "$gate"
  wait "$TEST_MONITOR_PID"
  TEST_MONITOR_PID=""

  grep -qx 'server TERM' "$term_log"
  grep -qx 'launcher TERM' "$launcher_term_log"
}

@test "codex-monitor: scoped cleanup failure preserves TUI status and releases lease" {
  local stubdir="$TEST_PROJECT/stub-bin"
  local marker="$TEST_PROJECT/fail-cleanup-rm"
  local real_rm key pidfile returned_status server_pid lock_owner
  mkdir -p "$stubdir"
  real_rm="$(command -v rm)"
  cat > "$stubdir/rm" <<EOF
#!/usr/bin/env bash
if [ -e "\$FAKE_RM_FAIL_MARKER" ]; then
  exit 74
fi
exec "$real_rm" "\$@"
EOF
  chmod +x "$stubdir/rm"

  key="$(printf '%s\n%s' "$(cd "$TEST_PROJECT" && pwd)" scope-cleanup-failure | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  pidfile="$TEST_SKILL_DIR/run/codex-app-server.$key.pid"
  run env PATH="$stubdir:$PATH" FAKE_RM_FAIL_MARKER="$marker" \
    FAKE_TUI_EXIT_MARKER="$marker" FAKE_TUI_STATUS=37 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-cleanup-failure --codex-command codex --
  returned_status="$status"

  wait_for_file "$pidfile"
  server_pid="$(cat "$pidfile")"
  wait_for_pid_exit "$server_pid"
  lock_owner="$(. "$SCRIPTS/lib/storage.sh"; agmsg_runtime_lock_owner "codex-app-server:$key")"
  if [ "$returned_status:$lock_owner" != "37:" ]; then
    echo "cleanup observation: status=$returned_status lock_owner=${lock_owner:-<empty>}" >&2
  fi
  [ "$returned_status:$lock_owner" = "37:" ]
}

@test "codex-monitor: scoped direct TERM reaps TUI and returns signal status" {
  skip_on_windows "uses POSIX direct-child signal semantics"

  local gate="$TEST_PROJECT/hold-tui"
  local server_ready="$TEST_PROJECT/server-ready"
  local launcher_ready="$TEST_PROJECT/launcher-ready"
  local tui_ready="$TEST_PROJECT/tui-ready"
  local server_term="$TEST_PROJECT/server-term.log"
  local launcher_term="$TEST_PROJECT/launcher-term.log"
  local tui_term="$TEST_PROJECT/tui-term.log"
  local tui_exit="$TEST_PROJECT/tui-exit"
  local tui_pid_file="$TEST_PROJECT/tui.pid"
  local launcher="$TEST_PROJECT/fake-launcher"
  local key pidfile server_pid launcher_pid tui_pid monitor_status tui_gone lock_owner
  _make_term_recording_launcher "$launcher"
  TEST_TUI_RELEASE_FILE="$gate"
  TEST_TUI_EXIT_FILE="$tui_exit"

  key="$(printf '%s\n%s' "$(cd "$TEST_PROJECT" && pwd)" scope-direct-term | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  pidfile="$TEST_SKILL_DIR/run/codex-app-server.$key.pid"
  env FAKE_TERM_LOG="$server_term" FAKE_SERVER_READY_FILE="$server_ready" \
    FAKE_LAUNCHER_TERM_LOG="$launcher_term" FAKE_LAUNCHER_READY_FILE="$launcher_ready" \
    FAKE_TUI_GATE="$gate" FAKE_TUI_READY_FILE="$tui_ready" FAKE_TUI_EXIT_MARKER="$tui_exit" \
    FAKE_TUI_PID_FILE="$tui_pid_file" FAKE_TUI_TERM_LOG="$tui_term" \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD="$launcher" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-direct-term --codex-command codex -- &
  TEST_MONITOR_PID=$!

  wait_for_file_contains "$server_ready" '[0-9]'
  wait_for_file_contains "$launcher_ready" '[0-9]'
  wait_for_file_contains "$tui_ready" '[0-9]'
  server_pid="$(cat "$pidfile")"
  launcher_pid="$(cat "$launcher_ready")"
  tui_pid="$(cat "$tui_pid_file")"

  kill -TERM "$TEST_MONITOR_PID"
  if wait "$TEST_MONITOR_PID"; then monitor_status=0; else monitor_status=$?; fi
  TEST_MONITOR_PID=""

  tui_gone=1
  if ! wait_for_pid_exit "$tui_pid"; then
    tui_gone=0
    : > "$gate"
    wait_for_file "$tui_exit" || true
    wait_for_pid_exit "$tui_pid" || true
  fi
  lock_owner="$(. "$SCRIPTS/lib/storage.sh"; agmsg_runtime_lock_owner "codex-app-server:$key")"

  [ "$monitor_status" -eq 143 ]
  if [ "$tui_gone" -ne 1 ]; then
    echo "signal observation: status=$monitor_status tui_gone=$tui_gone" >&2
  fi
  [ "$tui_gone" -eq 1 ]
  wait_for_pid_exit "$server_pid"
  wait_for_pid_exit "$launcher_pid"
  grep -qx 'tui TERM' "$tui_term"
  grep -qx 'server TERM' "$server_term"
  grep -qx 'launcher TERM' "$launcher_term"
  [ "$(find "$TEST_SKILL_DIR/run" -name 'codex-app-server.*' -type f | wc -l | tr -d ' ')" -eq 0 ]
  [ -z "$lock_owner" ]
}

@test "codex-monitor: scoped fail-open exit preserves status and argv" {
  run env FAKE_CODEX_MODE=broken FAKE_TUI_STATUS=37 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-fail-open --codex-command resume -- --last -C "$TEST_PROJECT"
  [ "$status" -eq 37 ]
  grep -Eq '^plain-codex <resume> <--last> <-C>' "$CALL_LOG"
  refute grep -q -- '--remote' "$CALL_LOG"
  printf '%s\n' "$output" | grep -Fq 'Real-time agmsg delivery is OFF'
  [ "$(find "$TEST_SKILL_DIR/run" -name 'codex-app-server.*' -type f | wc -l | tr -d ' ')" -eq 0 ]
}

@test "codex-monitor: scoped cleanup never signals a foreign pidfile target" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  local gate="$TEST_PROJECT/release-tui"
  local key pidfile server_pid sentinel_pid monitor_pid
  key="$(printf '%s\n%s' "$(cd "$TEST_PROJECT" && pwd)" scope-foreign | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  pidfile="$TEST_SKILL_DIR/run/codex-app-server.$key.pid"

  env FAKE_TUI_GATE="$gate" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-foreign --codex-command codex -- &
  monitor_pid=$!
  wait_for_file "$pidfile"
  wait_for_file_contains "$CALL_LOG" plain-codex
  server_pid="$(cat "$pidfile")"

  sleep 60 &
  sentinel_pid=$!
  printf '%s' "$sentinel_pid" > "$pidfile"
  : > "$gate"
  wait "$monitor_pid"

  wait_for_pid_exit "$server_pid"
  kill -0 "$sentinel_pid"
  [ "$(cat "$pidfile")" = "$sentinel_pid" ]
  kill "$sentinel_pid" 2>/dev/null || true
  wait "$sentinel_pid" 2>/dev/null || true
}

@test "codex-monitor: different invocation scopes use different live app-servers" {
  skip_on_windows "spawns python socket listeners; flaky on the Windows runner"

  local gate_a="$TEST_PROJECT/release-tui-a" gate_b="$TEST_PROJECT/release-tui-b"
  local key_a key_b pidfile_a pidfile_b
  key_a="$(printf '%s\n%s' "$(cd "$TEST_PROJECT" && pwd)" scope-A | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  key_b="$(printf '%s\n%s' "$(cd "$TEST_PROJECT" && pwd)" scope-B | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  pidfile_a="$TEST_SKILL_DIR/run/codex-app-server.$key_a.pid"
  pidfile_b="$TEST_SKILL_DIR/run/codex-app-server.$key_b.pid"

  env FAKE_TUI_GATE="$gate_a" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-A --codex-command codex -- &
  local scope_a_monitor=$!

  wait_for_file "$pidfile_a"
  local scope_a_server="$(cat "$pidfile_a")"

  env FAKE_TUI_GATE="$gate_b" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-B --codex-command codex -- &
  local scope_b_monitor=$!

  wait_for_file "$pidfile_b"
  local scope_b_server="$(cat "$pidfile_b")"
  [ "$scope_a_server" != "$scope_b_server" ]
  kill -0 "$scope_a_server"
  kill -0 "$scope_b_server"

  : > "$gate_a"
  wait "$scope_a_monitor"
  wait_for_pid_exit "$scope_a_server"
  kill -0 "$scope_b_monitor"
  kill -0 "$scope_b_server"

  : > "$gate_b"
  wait "$scope_b_monitor"
  wait_for_pid_exit "$scope_b_server"
}

@test "codex-monitor: same live invocation scope fails without changing its server" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  local gate="$TEST_PROJECT/release-tui"
  env FAKE_TUI_GATE="$gate" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" \
    --invocation-scope scope-A --codex-command codex -- &
  local first_monitor=$!

  local i pidfiles
  for i in $(seq 1 100); do
    pidfiles=("$TEST_SKILL_DIR"/run/codex-app-server.*.pid)
    [ -f "${pidfiles[0]}" ] && break
    sleep 0.1
  done
  [ -f "${pidfiles[0]}" ]
  local first_pid="$(cat "${pidfiles[0]}")"

  run env AGMSG_REAL_CODEX="$FAKE_CODEX" bash "$TYPES/codex/codex-monitor.sh" \
    --project "$TEST_PROJECT" --invocation-scope scope-A --codex-command codex --
  [ "$status" -ne 0 ]
  [ "$(cat "${pidfiles[0]}")" = "$first_pid" ]

  : > "$gate"
  wait "$first_monitor"
}

# --- port discovery vs colorized banner (codex 0.144+) ---

@test "codex-monitor: discovers the port when codex colorizes the banner (0.144+)" {
  run node -e 'const net = require("net"); if (!net) process.exit(1);'
  if [ "$status" -ne 0 ]; then
    skip "node net module is not available in this sandbox"
  fi

  # codex 0.144.1 writes ANSI SGR sequences into the banner even when stdout is
  # a redirected file (NO_COLOR is ignored), so this fake reproduces the
  # colorized "listening on:" line verbatim. The python fake above prints a
  # plain banner and can never catch a color regression; this one uses a node
  # listener so it also runs on the Windows runner where the python fake skips.
  local ansi_codex="$TEST_PROJECT/ansi-codex"
  cat > "$ansi_codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.144.1"; exit 0 ;;
  app-server)
    # Run the listener as a CHILD and forward teardown's kill to it, so it dies
    # with this wrapper instead of holding the bats capture fd until its timer
    # fires — the same dies-with-parent model as the python fake above. The
    # wrapper stays the recorded pid (its argv is what the cmdline check reads).
    node - <<'JS' &
const net = require('net');
const s = net.createServer((c) => c.destroy());
s.listen(0, '127.0.0.1', () => {
  const e = '\x1b';
  console.log(e + '[36;1mcodex app-server (WebSockets)' + e + '[0m');
  console.log('  ' + e + '[2mlistening on:' + e + '[0m ' + e + '[32mws://127.0.0.1:' + s.address().port + e + '[0m');
});
setTimeout(() => process.exit(0), 60000); // backstop if the forwarded kill never arrives
JS
    child=$!
    trap 'kill "$child" 2>/dev/null' TERM INT
    wait "$child" 2>/dev/null || wait "$child" 2>/dev/null
    ;;
  *)
    printf 'plain-codex' >> "$CALL_LOG"
    for a in "$@"; do printf ' <%s>' "$a" >> "$CALL_LOG"; done
    printf '\n' >> "$CALL_LOG"
    ;;
esac
EOF
  chmod +x "$ansi_codex"

  run env AGMSG_REAL_CODEX="$ansi_codex" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  # The port was parsed out of the colorized banner: the handoff must be the
  # BRIDGED form (--remote ws://...), not the plain-codex fail-open.
  grep -q 'plain-codex <--remote> <ws://127\.0\.0\.1:[0-9][0-9]*>' "$CALL_LOG"
  [[ "$output" != *"did not report a listening port"* ]]
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
' "$portf" 3>&- &
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
  wait "$foreign_pid" 2>/dev/null || true
}


# --- which pid space (#567) ---
#
# Both tests below model Git Bash: MSYSTEM set, and a `tasklist` that answers as
# the real one does for a pid it has no record of -- nothing. The app-server pid
# is minted by $! in codex-monitor.sh, so it lives in the MSYS pid space and
# tasklist never reports it; a probe that asks tasklist calls a running server
# dead. Setting MSYSTEM does not otherwise disturb a POSIX run: compat.sh picks
# its platform from `uname -s`, and the only other reader is a pid-range bound.

# Answers nothing, like tasklist asked about a pid it does not know.
_stub_tasklist() {
  local dir="$1"
  mkdir -p "$dir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/tasklist"
  chmod +x "$dir/tasklist"
}

@test "codex-monitor: waits for the port when tasklist cannot see the app-server (#567)" {
  skip_on_windows "stubs tasklist to model Git Bash; the real one is authoritative there"
  run node -e 'const net = require("net"); if (!net) process.exit(1);'
  if [ "$status" -ne 0 ]; then
    skip "node net module is not available in this sandbox"
  fi

  local stubdir="$TEST_PROJECT/stub-bin"
  _stub_tasklist "$stubdir"

  # Reaching the liveness probe is fixed by ORDER, not by a delay. Each pass of
  # the wait loop reads the log with sed and only probes when that came back
  # empty, so a server that has already announced itself breaks out on the first
  # pass and the probe never runs -- against which this test would pass whatever
  # the probe answered. An earlier revision leaned on a 600ms banner delay for
  # that, which is a race: deschedule the parent past it and the seam is gone.
  #
  # The shim forces the first port-extracting sed to come back empty, so the
  # first pass always reaches the probe, and hands every later call to the real
  # sed so the second pass finds the banner. It matches on the argument rather
  # than on being the first sed of the run: other sed calls in this script would
  # otherwise consume the one intercept and the seam would miss silently.
  export SED_SHIM_MARKER="$TEST_PROJECT/sed-shim-fired"
  local real_sed; real_sed="$(command -v sed)"
  cat > "$stubdir/sed" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"listening on"*)
    if [ ! -e "\$SED_SHIM_MARKER" ]; then
      : > "\$SED_SHIM_MARKER"
      exit 0
    fi
    ;;
esac
exec "$real_sed" "\$@"
EOF
  chmod +x "$stubdir/sed"

  run env MSYSTEM=MINGW64 PATH="$stubdir:$PATH" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  # The seam was actually taken. Without this the assertions below could hold
  # for the wrong reason -- a run that never entered the loop body at all.
  [ -e "$SED_SHIM_MARKER" ]
  # Bridged, not the fail-open: the wait outlasted a probe that could not see
  # the process.
  grep -q 'plain-codex <--remote> <ws://127\.0\.0\.1:[0-9][0-9]*>' "$CALL_LOG"
  [[ "$output" != *"did not report a listening port"* ]]
}

@test "codex-monitor: reuses a live app-server when tasklist cannot see it (#567)" {
  skip_on_windows "stubs tasklist to model Git Bash; the real one is authoritative there"
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  local stubdir="$TEST_PROJECT/stub-bin"
  _stub_tasklist "$stubdir"

  # First launch records port + pid; the recorded pid is this file's own $!.
  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  local resolved hash base first_pid first_port
  resolved="$(cd "$TEST_PROJECT" && pwd)"
  hash="$(printf '%s' "$resolved" | ( . "$SCRIPTS/lib/hash.sh"; agmsg_sha1 ))"
  base="$TEST_SKILL_DIR/run/codex-app-server.$hash"
  first_pid="$(cat "$base.pid")"
  first_port="$(cat "$base.port")"
  [ -n "$first_pid" ] && [ -n "$first_port" ]

  # Second launch, now under Git Bash's pid rules. Reading the pid back out of a
  # pidfile does not move it into the Windows pid space, so a probe that asks
  # tasklist calls the live server dead and starts another one beside it.
  run env FAKE_CODEX_VERSION=0.142.2 MSYSTEM=MINGW64 PATH="$stubdir:$PATH" \
    AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  # Same server: same pid on record, same port in the handoff.
  [ "$(cat "$base.pid")" = "$first_pid" ]
  grep -q "plain-codex <--remote> <ws://127\.0\.0\.1:$first_port>" "$CALL_LOG"
}

# --- native Windows: the effect, not the premise (#567) ---

@test "codex-monitor: windows-native reaches the bridged handoff (#567)" {
  skip_unless_windows "the point is the real tasklist and the real MSYS pid space"
  # Everything else about #567 is proved against a tasklist STUB on a POSIX host,
  # which shows what the code does when a probe answers "not found" -- not that
  # Git Bash answers that way, and not that a launch survives it. This runs on
  # windows-latest with the real tasklist, the real MSYSTEM, and no stub: the
  # app-server pid is genuinely in the MSYS space, tasklist genuinely has no
  # record of it, and the assertion is that the launch still reaches the bridge.
  #
  # Mutate codex-monitor.sh's wait loop back to _agmsg_pid_alive and this fails
  # where it counts -- on Windows, with nothing simulated.
  run node -e 'const net = require("net"); if (!net) process.exit(1);'
  [ "$status" -eq 0 ] || skip "node net module is not available"

  local win_codex="$TEST_PROJECT/win-codex"
  cat > "$win_codex" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "codex-cli 0.144.1"; exit 0 ;;
  app-server)
    node - <<'JS' &
const net = require('net');
const s = net.createServer((c) => c.destroy());
s.listen(0, '127.0.0.1', () => {
  console.log('codex app-server (WebSockets)');
  console.log('  listening on: ws://127.0.0.1:' + s.address().port);
});
setTimeout(() => process.exit(0), 60000);
JS
    child=$!
    trap 'kill "$child" 2>/dev/null' TERM INT
    wait "$child" 2>/dev/null || wait "$child" 2>/dev/null
    ;;
  *)
    printf 'plain-codex' >> "$CALL_LOG"
    for a in "$@"; do printf ' <%s>' "$a" >> "$CALL_LOG"; done
    printf '\n' >> "$CALL_LOG"
    ;;
esac
EOF
  chmod +x "$win_codex"

  run env AGMSG_REAL_CODEX="$win_codex" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  grep -q 'plain-codex <--remote> <ws://127\.0\.0\.1:[0-9][0-9]*>' "$CALL_LOG"
  [[ "$output" != *"did not report a listening port"* ]]
}

@test "codex monitor: the port file is published atomically, never written in place" {
  # A reader turns this file's contents into a URL, and a numeric PREFIX of a
  # real port is itself a valid port — 5296 while 52962 is being written names a
  # DIFFERENT app-server, possibly another project's, which would answer and let
  # its thread be seated here. No reader-side check can tell those apart, so the
  # partial state has to be unobservable rather than filtered.
  local src="$SCRIPTS/drivers/types/codex/codex-monitor.sh"
  grep -q 'agmsg_write_atomic "$PORT_FILE"' "$src"
  # No truncating redirect to the published path.
  ! grep -qE '>[[:space:]]*"\$PORT_FILE"' "$src"
}
