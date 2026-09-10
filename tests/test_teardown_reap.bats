#!/usr/bin/env bats
#
# teardown_test_env must kill a detached process still holding $TEST_SKILL_DIR before
# it removes the tree. The detached codex children (codex-bridge-launcher.sh and the
# codex-bridge.js it starts) outlive the test body and keep writing $TEST_SKILL_DIR/run,
# so the bare rm races them and fails "Directory not empty" (#662 == #1036 == #1049).
# The reaper is scoped to the unique mktemp $TEST_SKILL_DIR so it can never reach a real
# bridge or another test — that scope safety is asserted here, not just the kill.
#
# Assertions use plain commands / `refute`, never a non-last `[[ ]]` or `! cmd` (#670).

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Spawn a detached holder whose argv carries $TEST_SKILL_DIR (as the launcher's does),
# keeping run/ busy. Echoes its pid once it is actually writing run/.
_start_holder() {
  mkdir -p "$TEST_SKILL_DIR/run"
  local holder="$TEST_SKILL_DIR/scripts/holder.sh"
  cat > "$holder" <<'H'
#!/usr/bin/env bash
d="$1"; while :; do : > "$d/run/held.$$"; sleep 0.05; done
H
  chmod +x "$holder"
  # ORPHAN it in a subshell (the subshell exits, the holder reparents to init) so it
  # matches the real detached launcher — and so that after the reaper's SIGKILL it is
  # reaped by init rather than lingering as a zombie of this test shell, which would
  # still answer `kill -0` and defeat the "it is dead" assertion. It records its own pid.
  # Close the command substitution's stdout/stderr: leaving either descriptor open in
  # the orphan makes the caller wait for EOF forever before it can reap the holder.
  ( "$holder" "$TEST_SKILL_DIR" </dev/null >/dev/null 2>&1 & printf '%s\n' "$!" > "$TEST_SKILL_DIR/holder.pid" )
  local hp; hp="$(cat "$TEST_SKILL_DIR/holder.pid" 2>/dev/null)"
  _wait_for_holder_ready "$TEST_SKILL_DIR/run/held.$hp" || {
    echo "holder $hp did not become ready before the bounded wait expired" >&2
    return 1
  }
  printf '%s\n' "$hp"
}

# Wait for the holder to prove it is writing run/, with an explicit ceiling. Keep the
# knobs injectable so the timeout behavior can be tested without adding five seconds
# to the suite.
_wait_for_holder_ready() {
  local marker="$1" ticks="${2:-100}" interval="${3:-0.05}" n=0
  while [ ! -e "$marker" ] && [ "$n" -lt "$ticks" ]; do
    sleep "$interval"
    n=$((n + 1))
  done
  [ -e "$marker" ]
}

@test "holder readiness times out and fails instead of waiting forever" {
  run _wait_for_holder_ready "$TEST_SKILL_DIR/never-ready" 2 0.01
  [ "$status" -ne 0 ]
}

@test "teardown reaper kills a detached process holding TEST_SKILL_DIR (#662)" {
  local hp; hp="$(_start_holder)"
  kill -0 "$hp"                       # holder is alive and holding run/
  _reap_test_skill_dir_procs         # THE FIX — a no-op reaper leaves it alive (mutation)
  refute kill -0 "$hp"               # reaper killed it, so run/ is free for the rm
}

@test "teardown reaper leaves a process that does NOT reference TEST_SKILL_DIR alone (scope safety)" {
  # The reaper must never reach a developer's live bridge or another test's process.
  # A plain `sleep` whose argv does not contain this test's mktemp dir must survive.
  sleep 30 &
  local other=$!
  _reap_test_skill_dir_procs
  kill -0 "$other"                   # untouched
  kill "$other" 2>/dev/null || true
}

@test "teardown reaper is a no-op when nothing holds TEST_SKILL_DIR" {
  run _reap_test_skill_dir_procs
  [ "$status" -eq 0 ]
}

@test "teardown reaper fails when its bounded wait expires" {
  # Keep the process list non-empty while replacing the side effects with no-ops. The
  # 60-tick ceiling then runs quickly and this test proves timeout is not reported green.
  _pids_referencing_dir() { printf '%s\n' 999999; }
  kill() { :; }
  sleep() { :; }
  run _reap_test_skill_dir_procs
  [ "$status" -ne 0 ]
}

@test "teardown reaper refuses to scan when TEST_SKILL_DIR is not a temp path (guard)" {
  # A mis-set TEST_SKILL_DIR must never turn the scan loose on a short/rooty prefix
  # (which would match — and kill — nearly every process).
  sleep 30 &
  local other=$!
  TEST_SKILL_DIR="/"    _reap_test_skill_dir_procs
  TEST_SKILL_DIR="/usr" _reap_test_skill_dir_procs
  kill -0 "$other"                   # nothing was scanned or killed for a rooty dir
  kill "$other" 2>/dev/null || true
}

@test "teardown reaper fails closed on a NON-temp TEST_SKILL_DIR for a degenerate TMPDIR: unset / empty / root (#662, co2 BLOCKING)" {
  # utildev measured that ubuntu-latest's `mktemp -d` uses /tmp with TMPDIR UNSET, so a
  # guard pattern assembled from $TMPDIR degenerates to ?* there and would turn this KILL
  # loose on CI Linux. Prove fail-closed: with a NON-temp TEST_SKILL_DIR and TMPDIR unset,
  # "", or "/", a probe whose argv carries that dir must SURVIVE. A bare `sleep` cannot
  # show this — the degenerate scan would find nothing to kill and pass vacuously — so the
  # probe gives the scan a real target, and its survival is what distinguishes refuse from
  # scan-and-kill. (Mutation: restore the old `"${TMPDIR:+${TMPDIR%/}/}"?*` guard and this
  # reds — the probe gets killed under the non-temp dir.)
  local marker="/agmsg-nontemp-probe-$$"
  local probe="$TEST_SKILL_DIR/scripts/probe.sh"
  mkdir -p "$(dirname "$probe")"
  printf '%s\n' '#!/usr/bin/env bash' 'while :; do sleep 0.1; done' > "$probe"
  chmod +x "$probe"
  local pp
  _spawn_probe() {
    # Orphaned (subshell) so it reparents to init like the real detached launcher. Its
    # argv carries $marker (so the reaper scoped to $marker would hit it if it degenerated)
    # AND $TEST_SKILL_DIR (the probe.sh path), so the real teardown reaps it afterwards.
    ( "$probe" "$marker" & printf '%s\n' "$!" > "$TEST_SKILL_DIR/probe.pid" )
    pp="$(cat "$TEST_SKILL_DIR/probe.pid")"
    kill -0 "$pp"   # running, so "survives" below is meaningful rather than a race
  }
  _spawn_probe; ( unset TMPDIR; TEST_SKILL_DIR="$marker" _reap_test_skill_dir_procs ); kill -0 "$pp"; kill "$pp" 2>/dev/null || true
  _spawn_probe; TMPDIR=""  TEST_SKILL_DIR="$marker" _reap_test_skill_dir_procs;         kill -0 "$pp"; kill "$pp" 2>/dev/null || true
  _spawn_probe; TMPDIR="/" TEST_SKILL_DIR="$marker" _reap_test_skill_dir_procs;         kill -0 "$pp"; kill "$pp" 2>/dev/null || true
}
