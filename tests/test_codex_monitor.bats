#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  export CALL_LOG="$TEST_PROJECT/calls.log"

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
[ -n "${CODEX_HOME_LOG:-}" ] && printf '%s\t%s\n' "${1:-}" "${CODEX_HOME:-}" >> "$CODEX_HOME_LOG"
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
    python3 - <<'PY'
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
  rm -rf "$TEST_PROJECT"
  teardown_test_env
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

@test "codex-monitor: isolates app-server and remote TUI in AGMSG_CODEX_HOME" {
  skip_on_windows "uses POSIX absolute paths and process replacement"
  local isolated="$TEST_PROJECT/codex-home"
  local home_log="$TEST_PROJECT/codex-home.log"

  run env AGMSG_CODEX_HOME="$isolated" CODEX_HOME_LOG="$home_log" \
    AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  [ -d "$isolated" ]
  grep -q $'^app-server\t'"$isolated"'$' "$home_log"
  grep -q $'^--remote\t'"$isolated"'$' "$home_log"
  local homef; homef="$(ls "$TEST_SKILL_DIR"/run/codex-app-server.*.home)"
  [ "$(cat "$homef")" = "$isolated" ]
}

@test "codex-monitor: never reuses an app-server from a different CODEX_HOME" {
  skip_on_windows "spawns a python socket listener; flaky on the Windows runner"
  run env AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  local pidf first_pid isolated
  pidf="$(ls "$TEST_SKILL_DIR"/run/codex-app-server.*.pid)"
  first_pid="$(cat "$pidf")"
  isolated="$TEST_PROJECT/isolated-home"

  run env AGMSG_CODEX_HOME="$isolated" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -eq 0 ]
  [ "$(cat "$pidf")" != "$first_pid" ]
  ! kill -0 "$first_pid" 2>/dev/null
  [ "$(cat "${pidf%.pid}.home")" = "$isolated" ]
}

@test "codex-monitor: rejects a relative AGMSG_CODEX_HOME before launch" {
  run env AGMSG_CODEX_HOME="relative/codex-home" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be an absolute path"* ]]
  [ ! -e "$TEST_PROJECT/relative" ]
}

@test "codex-monitor: rejects filesystem root as AGMSG_CODEX_HOME" {
  run env AGMSG_CODEX_HOME="/" AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex --
  [ "$status" -ne 0 ]
  [[ "$output" == *"must not be /"* ]]
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

@test "codex-monitor: a spawned seat (AGMSG_SPAWNED=1) fails CLOSED when the bridge cannot start" {
  # Fail-open exists for a person at the keyboard. A seat spawned by agmsg has
  # nobody at its pane, and a plain codex there never receives a message -- the
  # same outcome as the shim bypass spawn was fixed to close. So with the
  # spawn marker set, a broken bridge must refuse to start codex at all.
  run env FAKE_CODEX_MODE=broken AGMSG_SPAWNED=1 AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex -- --foo
  [ "$status" -ne 0 ]
  # No plain codex was started, bridged or not.
  [ ! -e "$CALL_LOG" ]
  # And the refusal says why, and that the session was spawned.
  printf '%s\n' "$output" | grep -qF 'Refusing to start a plain Codex'
  printf '%s\n' "$output" | grep -qF 'AGMSG_SPAWNED=1'
}

@test "codex-monitor: without the spawn marker the same failure still fails open (a person keeps a codex)" {
  # The control for the test above: the ONLY difference is the marker.
  run env FAKE_CODEX_MODE=broken AGMSG_REAL_CODEX="$FAKE_CODEX" \
    bash "$TYPES/codex/codex-monitor.sh" --project "$TEST_PROJECT" --codex-command codex -- --foo
  [ "$status" -eq 0 ]
  grep -qx 'plain-codex <--foo>' "$CALL_LOG"
}
