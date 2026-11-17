#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export CODEX_HOME="$TEST_SKILL_DIR/test-codex-home"
  export TEST_PROJECT="$(mktemp -d)"
  export CALL_LOG="$TEST_PROJECT/calls.log"
  export APP_SERVER_ARGV_LOG="$TEST_PROJECT/app-server-argv.log"
  export APP_SERVER_ENV_LOG="$TEST_PROJECT/app-server-env.log"

  # Fake codex for codex-monitor tests.
  #   --version            -> prints "codex-cli $FAKE_CODEX_VERSION"
  #   app-server --listen  -> logs this invocation's argv to
  #                           APP_SERVER_ARGV_LOG (a separate file from
  #                           CALL_LOG: some tests assert CALL_LOG does not
  #                           exist at all, which app-server always being
  #                           called first would break). FAKE_CODEX_MODE=broken:
  #                           reject (emulate a release that can't bring the
  #                           app-server up); otherwise bind a real loopback
  #                           port, print the listening line, and stay alive
  #                           so reuse health checks see a live server.
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
    for a in "$@"; do printf ' <%s>' "$a" >> "$APP_SERVER_ARGV_LOG"; done
    printf '\n' >> "$APP_SERVER_ARGV_LOG"
    printf 'pid=%s\n' "$$" >> "$APP_SERVER_ENV_LOG"
    printf 'flag=%s\n' "${AGMSG_CODEX_BRIDGE_LAUNCHER:-}" >> "$APP_SERVER_ENV_LOG"
    if [ "${FAKE_CODEX_MODE:-listen}" = "once" ] && [ ! -f "$TEST_PROJECT/attempted" ]; then
      : > "$TEST_PROJECT/attempted"
      exit 2
    fi
    if [ "${FAKE_CODEX_MODE:-listen}" = "broken" ]; then
      echo "error: unexpected argument '--listen' found" >&2
      exit 2
    fi
    # Run the listener as a CHILD (no exec) so this script stays the recorded pid;
    # its argv ("...real-codex app-server --listen") is what codex-monitor's
    # cmdline check matches. The child is backgrounded and teardown's kill is
    # forwarded to it: native Python on Windows never sees its parent change
    # (os.getppid() stays put), so the loop below cannot be what ends it (#1612).
    python3 - <<'PY' &
import socket, sys, os, glob, time, hashlib
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
if os.environ.get("FAKE_CODEX_MODE") in ("delayed-port", "blocked-port"):
    pending_port = s.getsockname()[1]
    s.close()
    print("  listening on: ws://127.0.0.1:%d" % pending_port); sys.stdout.flush()
    for _ in range(600):
        if os.path.exists(os.path.join(os.environ["TEST_PROJECT"], "release-port")):
            break
        if os.environ.get("FAKE_CODEX_MODE") != "blocked-port" and glob.glob(os.path.join(os.environ["TEST_SKILL_DIR"], "run/down/codex-monitor.*." + hashlib.sha1(os.environ["AGMSG_CODEX_SEAT_KEY"].encode()).hexdigest() + ".json")):
            break
        time.sleep(0.05)
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", pending_port))
s.listen(16); s.settimeout(0.2)
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
  chmod +x "$FAKE_CODEX"
}

teardown() {
  # Kill any app-server listeners these tests spawned, and WAIT for them.
  # Signalling and moving on is enough on POSIX, where an open file does not
  # stop its directory being unlinked. Windows holds the directory while any
  # process inside it is alive, so the rm below fails with "Directory not
  # empty" and the test reports a failure whose assertions all passed.
  local pf pid
  for pf in "$TEST_SKILL_DIR"/run/codex-app-server.*.pid "$TEST_SKILL_DIR"/run/codex-app-server.*.record; do
    [ -f "$pf" ] || continue
    case "$pf" in
      *.record) pid="$(awk -F= '/^pid=/{print $2; exit}' "$pf" 2>/dev/null)" ;;
      *)        pid="$(cat "$pf" 2>/dev/null)" ;;
    esac
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait_for_pid_exit "$pid" || true
  done
  if [ -n "${MONITOR_TEST_LAUNCHER_PID_FILE:-}" ]; then
    # The detached dispatcher can still be initializing messages.db after the
    # fake TUI exits. Let its foreground SQLite children and EXIT trap finish
    # before removing their store; killing just the shell can orphan sqlite3.
    if ! wait_for_file_contains "$MONITOR_TEST_LAUNCHER_PID_FILE" '^[0-9][0-9]*$'; then
      echo "codex-monitor teardown: launcher did not publish its pid" >&2
      return 1
    fi
    pid="$(cat "$MONITOR_TEST_LAUNCHER_PID_FILE")"
    if ! wait_for_pid_exit "$pid"; then
      echo "codex-monitor teardown: launcher $pid did not exit; retaining its store" >&2
      return 1
    fi
  fi
  rm -rf "$TEST_PROJECT"
  teardown_test_env
}

# Pending startup is cancellable; only fixture children are involved.
run_pending_startup() {
  local monitor_pid result=0
  env FAKE_CODEX_MODE="${MONITOR_PENDING_MODE:-broken}" AGMSG_REAL_CODEX="$FAKE_CODEX" "$@" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex \
    >"$TEST_PROJECT/pending.log" 2>&1 &
  monitor_pid=$!
  wait_for_file_contains "$TEST_PROJECT/pending.log" 'retrying' || result=1
  bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT" >"$TEST_PROJECT/pending.status" || result=1
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  cat "$TEST_PROJECT/pending.log"
  return "$result"
}

@test "codex-monitor: an exited app-server remains pending with down status and no plain fallback" {
  run run_pending_startup
  [ "$status" -eq 0 ]
  [ ! -e "$CALL_LOG" ]
  grep -Fq 'Codex app-server exited before readiness' "$TEST_PROJECT/pending.status"
}

@test "codex-monitor: a confirmed exited server is retried and preserves resume arguments" {
  run env FAKE_CODEX_MODE=once AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command resume -- --foo
  [ "$status" -eq 0 ]
  grep -q 'plain-codex <resume> <--remote> <ws://127.0.0.1:[0-9][0-9]*> <--foo>' "$CALL_LOG"
  [ "$(wc -l < "$APP_SERVER_ARGV_LOG" | tr -d ' ')" -eq 2 ]
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  refute grep -Fq 'Codex app-server exited before readiness' <<<"$output"
}

@test "codex-monitor: a live server survives more than one hundred empty banner observations" {
  skip_on_windows "uses POSIX shell command shims for a deterministic observation barrier"
  local stubdir="$TEST_PROJECT/slow-bin" real_sed real_sleep
  real_sed="$(command -v sed)"
  real_sleep="$(command -v sleep)"
  mkdir -p "$stubdir"
  export MONITOR_SCAN_COUNT="$TEST_PROJECT/scans"
  cat > "$stubdir/sed" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"listening on"*)
    n=0
    [ ! -r "\$MONITOR_SCAN_COUNT" ] || read -r n < "\$MONITOR_SCAN_COUNT"
    n=\$((n + 1))
    printf '%s\n' "\$n" > "\$MONITOR_SCAN_COUNT"
    [ "\$n" -gt 105 ] || exit 0
    ;;
esac
exec "$real_sed" "\$@"
EOF
  cat > "$stubdir/sleep" <<EOF
#!/usr/bin/env bash
if [ "\$1" = 0.1 ]; then exec "$real_sleep" 0.001; fi
exec "$real_sleep" "\$@"
EOF
  chmod +x "$stubdir/sed" "$stubdir/sleep"
  PATH="$stubdir:$PATH" AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    run bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex
  [ "$status" -eq 0 ]
  [ "$(cat "$MONITOR_SCAN_COUNT")" -gt 100 ]
  [ "$(wc -l < "$APP_SERVER_ARGV_LOG" | tr -d ' ')" -eq 1 ]
  grep -Fq 'keeping the live server and retrying' <<<"$output"
  grep -q -- '<--remote> <ws://' "$CALL_LOG"
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  refute grep -Fq 'has not reported a listening port' <<<"$output"
}

@test "codex-monitor: a temporarily unreachable port recovers on the same live server" {
  run env FAKE_CODEX_MODE=delayed-port AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex
  [ "$status" -eq 0 ]
  grep -Fq 'port is not reachable yet' <<<"$output"
  [ "$(wc -l < "$APP_SERVER_ARGV_LOG" | tr -d ' ')" -eq 1 ]
  grep -q -- '<--remote> <ws://' "$CALL_LOG"
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  refute grep -Fq 'port is not reachable yet' <<<"$output"
}

@test "codex-monitor: cancelling pending startup stops only its owned live child" {
  export MONITOR_PENDING_MODE=blocked-port
  run run_pending_startup
  [ "$status" -eq 0 ]
  [ ! -e "$CALL_LOG" ]
  local child_pid
  child_pid="$(sed -n 's/^pid=//p' "$APP_SERVER_ENV_LOG" | head -1)"
  [ -n "$child_pid" ]
  wait_for_pid_exit "$child_pid"
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  refute grep -Fq 'port is not reachable yet' <<<"$output"
}

@test "codex-monitor: real notice I/O failure keeps startup alive and retries set and clear" {
  export MONITOR_TEST_LAUNCHER_PID_FILE="$TEST_PROJECT/io-launcher.pid"
  local retry_launcher="$TEST_PROJECT/retry-launcher"
  cat > "$retry_launcher" <<'SH'
#!/usr/bin/env bash
exec 2>>"$TEST_PROJECT/retry-debug.log"
printf '%s\n' "$$" > "$MONITOR_TEST_LAUNCHER_PID_FILE"
SCRIPT_DIR="$TYPES/codex"
source "$SCRIPTS/lib/hash.sh"
PROJECT_PHYS="$2"
SEAT_KEY="$AGMSG_CODEX_SEAT_KEY"
ROLE_PAIR=""
sed -n '/^MONITOR_NOTICE_DIRTY=/,/^# End monitor notice recovery/p' "$SCRIPT_DIR/codex-bridge-launcher.sh" > "$TEST_PROJECT/retry-functions.sh"
source "$TEST_PROJECT/retry-functions.sh"
for i in $(seq 1 100); do
  monitor_notice_retry
  [ "$MONITOR_NOTICE_DIRTY" = 1 ] || exit 0
  sleep 0.1
done
exit 1
SH
  chmod +x "$retry_launcher"
  local notice_root="$TEST_PROJECT/notice-io" monitor_pid record child_pid result=0
  mkdir "$notice_root"
  printf blocked > "$notice_root/run"
  env AGMSG_DOWN_NOTICE_ROOT="$notice_root" FAKE_CODEX_MODE=blocked-port \
    AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD="$retry_launcher" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex \
    >"$TEST_PROJECT/io.log" 2>&1 &
  monitor_pid=$!
  if ! wait_for_file_contains "$TEST_PROJECT/io.log" 'could not record'; then result=1; fi
  kill -0 "$monitor_pid" 2>/dev/null || result=1
  mv "$notice_root/run" "$notice_root/blocked"
  # Wait for the same pending reason to publish after storage recovers.
  local i
  for i in $(seq 1 100); do
    for record in "$notice_root"/run/down/codex-monitor.*.json; do [ -f "$record" ] && break 2; done
    sleep 0.1
  done
  if [ -f "$record" ]; then
    mv "$record" "$notice_root/previous"
    mkdir "$record"
    : > "$TEST_PROJECT/release-port"
    if ! wait_for_file_contains "$TEST_PROJECT/io.log" 'could not clear'; then result=1; fi
    # Delivery hands off while the failed clear is still dirty.
    if ! wait_for_file_contains "$CALL_LOG" '<--remote>'; then result=1; fi
    [ -d "$record" ] || result=1
    rmdir "$record"
    mv "$notice_root/previous" "$record"
    if ! wait_for_missing "$record"; then result=1; fi
  else
    result=1
  fi
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  cat "$TEST_PROJECT/io.log"
  [ ! -f "$TEST_PROJECT/retry-debug.log" ] || cat "$TEST_PROJECT/retry-debug.log"
  [ "$result" -eq 0 ]
  [ ! -e "$record" ]
  grep -q -- '<--remote> <ws://' "$CALL_LOG"
}

# --- #1537: the seat key must reach tool commands under any shell_environment_policy ---

# A monitor launch through the shim used to run `delivery status` twice (the shim's own
# check, then again when `set monitor` asked the PATH shim for `codex --version`) and
# rewrite hooks that were already in place. Each is dozens of processes, which is
# the bulk of a Windows launch (#1613). Counted, not timed. `set` may be skipped only
# when hooks.json is exactly what the last `set monitor` left, so a file that differs
# in ONE entry (here SessionEnd's project) must run it again.
@test "codex-monitor: a shim launch runs delivery status once, and set only when hooks.json is not exactly what set last left (#1613)" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  export DELIVERY_LOG="$TEST_PROJECT/delivery.log"
  mv "$SCRIPTS/delivery.sh" "$SCRIPTS/delivery.real.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$DELIVERY_LOG"' \
    'exec bash "$(dirname "$0")/delivery.real.sh" "$@"' > "$SCRIPTS/delivery.sh"
  chmod +x "$SCRIPTS/delivery.sh"
  # codex on PATH is the shim itself, as in a real install, so any nested
  # `codex --version` re-enters it.
  mkdir -p "$TEST_PROJECT/shimbin"
  ln -s "$TYPES/codex/codex-shim.sh" "$TEST_PROJECT/shimbin/codex"
  _launch() {
    : > "$DELIVERY_LOG"
    run bash -c 'cd "$TEST_PROJECT" && PATH="$TEST_PROJECT/shimbin:$PATH" AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true codex'
    [ "$status" -eq 0 ]
    [ "$(grep -c '^status ' "$DELIVERY_LOG")" -eq 1 ]
  }

  # No marker yet: the one full set runs and leaves its marker.
  _launch
  [ "$(grep -c '^set ' "$DELIVERY_LOG")" -eq 1 ]
  # Same file, same install: skipped.
  _launch
  [ "$(grep -c '^set ' "$DELIVERY_LOG" || true)" -eq 0 ]
  grep -q 'plain-codex <--remote> <ws://127\.0\.0\.1:[0-9][0-9]*>' "$CALL_LOG"
  # Only SessionEnd's project differs: not what set left, so it runs again and repairs it.
  sed 's#session-end.sh\(.\{1,3\}\)[^ ]* \{0,1\}[^"]*"#session-end.sh\1 codex /tmp/wrong-project"#' "$TEST_PROJECT/.codex/hooks.json" > "$TEST_PROJECT/hooks.edited"
  refute cmp -s "$TEST_PROJECT/hooks.edited" "$TEST_PROJECT/.codex/hooks.json"
  cp "$TEST_PROJECT/hooks.edited" "$TEST_PROJECT/.codex/hooks.json"
  _launch
  [ "$(grep -c '^set ' "$DELIVERY_LOG")" -eq 1 ]
  refute grep -q '/tmp/wrong-project' "$TEST_PROJECT/.codex/hooks.json"
}

@test "codex-monitor: the app-server is launched with the seat key as a shell_environment_policy.set override (#1537)" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  # A restrictive shell_environment_policy.inherit (e.g. "core" or "none") on
  # the model's shell commands excludes a plain env var not in the policy's
  # keep-list (Codex 0.158+, openai/codex#48099). `set` is applied after
  # `inherit`, so the key must also be passed as a `-c
  # shell_environment_policy.set.AGMSG_CODEX_SEAT_KEY=...` override to reach
  # those commands regardless of the user's own inherit setting.
  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  grep -q -- '<-c> <shell_environment_policy\.set\.AGMSG_CODEX_SEAT_KEY="[0-9.]\{1,\}">' "$APP_SERVER_ARGV_LOG"
}

@test "codex-monitor: the app-server inherits AGMSG_CODEX_BRIDGE_LAUNCHER=1 so SessionStart sees the launcher flag" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  # Unset the parent's flag so only the value codex-monitor sets is observed (prevents a false pass from the parent environment).
  run env -u AGMSG_CODEX_BRIDGE_LAUNCHER FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  grep -qx 'flag=1' "$APP_SERVER_ENV_LOG"
}

# --- #1254: one app-server per seat, never reused ---

@test "codex-monitor: a second launch in the same project never reuses the first launch's server (#1254)" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"

  # The dispatcher (codex-bridge-launcher.sh) stops a seat's server once its
  # TUI exits, and this fixture's fake "TUI" (the catch-all case in FAKE_CODEX)
  # exits the instant codex-monitor.sh execs it -- nothing like a real
  # interactive session's lifetime. Left running, the dispatcher would race to
  # tear the record down concurrently with this test's own assertions. That
  # stop behavior has its own coverage in the launcher's test suite; disable
  # the launcher here via its existing override seam so this test verifies
  # only codex-monitor.sh's own never-reuse behavior, deterministically.
  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  local first_pidf; first_pidf="$(ls "$TEST_SKILL_DIR"/run/codex-app-server.*.record)"
  local first_pid first_port
  first_pid="$(awk -F= '/^pid=/{print $2; exit}' "$first_pidf")"
  first_port="$(awk -F= '/^port=/{print $2; exit}' "$first_pidf")"
  [ -n "$first_pid" ] && [ -n "$first_port" ]
  kill -0 "$first_pid"

  run env FAKE_CODEX_VERSION=0.142.2 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  # A second record now exists, distinct from the first -- never one file
  # rewritten in place. Both seats' servers stay live and independent.
  local count; count="$(ls "$TEST_SKILL_DIR"/run/codex-app-server.*.record | grep -c .)"
  [ "$count" -eq 2 ]
  local second_pidf second_pid second_port
  for second_pidf in "$TEST_SKILL_DIR"/run/codex-app-server.*.record; do
    [ "$second_pidf" = "$first_pidf" ] && continue
    second_pid="$(awk -F= '/^pid=/{print $2; exit}' "$second_pidf")"
    second_port="$(awk -F= '/^port=/{print $2; exit}' "$second_pidf")"
  done
  [ -n "$second_pid" ] && [ -n "$second_port" ]
  [ "$second_pid" != "$first_pid" ]
  [ "$second_port" != "$first_port" ]
  # The first seat's own server is untouched by the second launch.
  kill -0 "$first_pid"
  kill -0 "$second_pid"
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
    printf 'flag=%s\nseat=%s\nurl=%s\n' \
      "${AGMSG_CODEX_BRIDGE_LAUNCHER:-}" "${AGMSG_CODEX_SEAT_KEY:-}" \
      "${AGMSG_CODEX_BRIDGE_APP_SERVER:-}" > "$TEST_PROJECT/app-server-env"
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

  # Keep the real dispatcher, but retain its PID so teardown can wait for all
  # of its DB work, including lock release, rather than racing a detached child.
  export MONITOR_TEST_LAUNCHER_PID_FILE="$TEST_PROJECT/launcher.pid"
  local tracked_launcher="$TEST_PROJECT/tracked-launcher"
  cat > "$tracked_launcher" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$MONITOR_TEST_LAUNCHER_PID_FILE"
exec "$TYPES/codex/codex-bridge-launcher.sh" "$@"
EOF
  chmod +x "$tracked_launcher"

  run env AGMSG_REAL_CODEX="$win_codex" \
    AGMSG_CODEX_BRIDGE_LAUNCHER_CMD="$tracked_launcher" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  grep -q 'plain-codex <--remote> <ws://127\.0\.0\.1:[0-9][0-9]*>' "$CALL_LOG"
  grep -qx 'flag=1' "$TEST_PROJECT/app-server-env"
  grep -qx 'url=' "$TEST_PROJECT/app-server-env"
  local seat record port restored
  seat="$(sed -n 's/^seat=//p' "$TEST_PROJECT/app-server-env")"
  [ -n "$seat" ]
  record="$TEST_SKILL_DIR/run/codex-app-server.$seat.record"
  [ -f "$record" ]
  port="$(sed -n 's/^port=//p' "$record")"
  restored="$(SKILL_DIR="$TEST_SKILL_DIR" AGMSG_CODEX_SEAT_KEY="$seat" \
    bash -c 'source "$1"; _agmsg_codex_app_server_url "$2"' bash \
      "$TYPES/codex/_app-server.sh" "$TEST_PROJECT")"
  [ "$restored" = "ws://127.0.0.1:$port" ]
  [[ "$output" != *"did not report a listening port"* ]]
}

@test "codex monitor: the seat record is published atomically, never written in place" {
  # A reader turns this record's port field into a URL, and a numeric PREFIX of
  # a real port is itself a valid port — 5296 while 52962 is being written names
  # a DIFFERENT app-server, possibly another seat's, which would answer and let
  # its thread be seated here. No reader-side check can tell those apart, so the
  # partial state has to be unobservable rather than filtered. codex-monitor.sh
  # itself never writes the record directly -- _seat-key.sh's writer is the one
  # place that does, via temp file plus rename.
  local src="$SCRIPTS/drivers/types/codex/_seat-key.sh"
  grep -q 'mv "\$tmp" "\$path"' "$src"
  # codex-monitor.sh itself never writes a record path directly -- it only
  # calls the writer above.
  ! grep -q 'SEAT_RECORD"$' "$SCRIPTS/drivers/types/codex/codex-monitor.sh"
}

# --- fail-closed for a spawned seat ---

@test "codex-monitor: a spawned seat keeps startup recovery armed" {
  run run_pending_startup AGMSG_SPAWNED=1
  [ "$status" -eq 0 ]
  [ ! -e "$CALL_LOG" ]
  grep -Fq 'Codex app-server exited before readiness' "$TEST_PROJECT/pending.status"
}

@test "codex-monitor: elevation does not turn a startup failure into plain Codex" {
  run run_pending_startup AGMSG_WINDOWS_ELEVATED=1
  [ "$status" -eq 0 ]
  [ ! -e "$CALL_LOG" ]
}

# --- #1401: a resumed seat arms its own bridge request when it can (without guessing) ---
#
# A restarted Codex seat used to have no bridge until either its SessionStart
# hook eventually ran (observed taking minutes, and in at least one real case
# never, until someone manually re-ran codex-record-session.sh) or a person did
# that by hand -- neither automatic. The thread being resumed is already known
# in argv, before codex itself starts, so codex-monitor.sh now arms the
# request itself when that thread matches exactly one role's record for this
# project.
@test "codex-monitor: resume arms the bridge request when the thread matches exactly one role's record, and does not otherwise" {
  local SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  # codex-record-session.sh always records the CANONICAL (symlink-resolved)
  # project, and codex-monitor.sh's own lookup canonicalizes the same way
  # before matching -- macOS's mktemp -d hands back a path through /var/
  # folders, itself a symlink to /private/var/folders, so recording the raw
  # $TEST_PROJECT here would silently never match. Match reality, not a
  # convenient shortcut.
  local canon_project; canon_project="$(cd "$TEST_PROJECT" && pwd -P)"

  # No matching record at all: nothing armed, and the launch still proceeds
  # (the request stays the SessionStart hook's / a manual re-run's job, exactly
  # as before this existed).
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command resume -- thread-unrecorded
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TEST_SKILL_DIR"/run/codex-bridge-request.* 2>/dev/null)" ]

  # Exactly one matching role: armed immediately, with that role's identity and
  # this launch's own socket URL, in the same tab-separated shape
  # codex-record-session.sh itself writes.
  agmsg_role_session_record team alice thread-A "$canon_project" codex
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command resume -- thread-A
  [ "$status" -eq 0 ]
  local req; req="$(ls "$TEST_SKILL_DIR"/run/codex-bridge-request.* 2>/dev/null)"
  [ -n "$req" ]
  local line; line="$(sed -n '1p' "$req")"
  [ "$(printf '%s' "$line" | cut -f1)" = codex ]
  [ "$(printf '%s' "$line" | cut -f2)" = thread-A ]
  [ "$(printf '%s' "$line" | cut -f3)" != "" ]   # the socket URL, generated per launch
  [ "$(printf '%s' "$line" | cut -f4)" = team ]
  [ "$(printf '%s' "$line" | cut -f5)" = alice ]
  rm -f "$req"

  # Two roles recorded against the SAME thread: ambiguous, nothing armed --
  # guessing which role owns a resumed thread is worse than leaving it unarmed.
  agmsg_role_session_record team bob thread-A "$canon_project" codex
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command resume -- thread-A
  [ "$status" -eq 0 ]
  [ -z "$(ls "$TEST_SKILL_DIR"/run/codex-bridge-request.* 2>/dev/null)" ]

  # A unique match, but the write itself fails (review finding: this used to
  # be silent, reproducing the exact "resume never gets a bridge" symptom
  # under a different cause). Codex must still launch, and the failure must
  # be named on stderr rather than swallowed. A fresh thread id: thread-A is
  # now ambiguous (alice AND bob) from the case above, so it would never
  # reach the write at all.
  agmsg_role_session_record team bob thread-B "$canon_project" codex
  local unwritable_dir="$TEST_PROJECT/unwritable-run"
  mkdir -p "$unwritable_dir"
  chmod 555 "$unwritable_dir"
  # chmod 555 does not make the directory unwritable everywhere (Windows/NTFS,
  # or a process holding CAP_DAC_OVERRIDE such as root). The write cannot be
  # made to fail there, so skip rather than assert a failure that never occurs.
  if touch "$unwritable_dir/.probe" 2>/dev/null; then
    rm -f "$unwritable_dir/.probe"
    chmod 755 "$unwritable_dir"
    skip "chmod 555 does not make the directory unwritable here (Windows/NTFS or CAP_DAC_OVERRIDE such as root)"
  fi
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" AGMSG_CODEX_BRIDGE_LAUNCHER_CMD=/bin/true \
    AGMSG_CODEX_TEST_RESUME_REQUEST_DIR="$unwritable_dir" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command resume -- thread-B
  chmod 755 "$unwritable_dir"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F "could not arm the bridge request for team/bob"
  [ -z "$(ls "$unwritable_dir"/codex-bridge-request.* 2>/dev/null)" ]
  [ -z "$(find "$unwritable_dir" -name '*.tmp' -o -name '*.[0-9]*' 2>/dev/null)" ]
  [ -n "$(ls "$TEST_SKILL_DIR"/run/codex-app-server.*.record 2>/dev/null)" ]

  # The printed fallback is meant to be pasted into an ordinary shell and run
  # (review finding: "codex-record-session.sh <args>" alone is not a PATH
  # command and would fail as command-not-found; it must be a full `bash
  # <script path> <args>` line). Confirm it by actually running it -- not by
  # grepping a substring, which the earlier, broken form would also match --
  # and checking it reaches the real script, as bash, with the exact
  # team/agent/project this failure was for.
  local record_script="$TYPES/codex/codex-record-session.sh"
  local record_spy_out="$TEST_PROJECT/record-spy.out"
  cp "$record_script" "$record_script.orig"
  cat > "$record_script" <<SPYEOF
#!/usr/bin/env bash
printf '%s\n' "\$0" "\$1" "\$2" "\$3" > "$record_spy_out"
SPYEOF
  local fallback_line
  fallback_line="$(printf '%s\n' "$output" | grep -F 'Run this by hand')"
  fallback_line="${fallback_line#*bring it: }"
  bash -c "$fallback_line"
  mv "$record_script.orig" "$record_script"
  [ "$(sed -n '1p' "$record_spy_out")" = "$record_script" ]
  [ "$(sed -n '2p' "$record_spy_out")" = team ]
  [ "$(sed -n '3p' "$record_spy_out")" = bob ]
  [ "$(sed -n '4p' "$record_spy_out")" = "$(cd "$TEST_PROJECT" && pwd -P)" ]
}
