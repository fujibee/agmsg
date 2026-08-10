#!/usr/bin/env bats

# #693: a watcher whose session id could not be resolved to an agent pid (a
# "bare" instance id) has no liveness gate at all. watch.sh's own per-cycle
# self-check only fires for composite ids (see watch.sh's liveness guard,
# #67); a bare id keeps polling and consuming forever once its owning session
# is gone. These tests prove the mechanism is real (positive control: an
# orphaned bare-id watcher DOES consume a message) before proving the fix
# (agmsg_reap_orphan_bare_watchers, run from session-start.sh) stops it.

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watcher-bare-reap-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() { teardown_test_env; }

_read_cursor() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    storage_read_cursor_get "$1" "$2" )
}

_wait_for_file_contains() {
  local file="$1" needle="$2" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && grep -q "$needle" "$file" && return 0
    sleep 0.1
  done
  return 1
}

_wait_for_cursor_above() {
  local team="$1" agent="$2" before="$3" i cursor
  for i in $(seq 1 100); do
    cursor=$(_read_cursor "$team" "$agent" 2>/dev/null || echo 0)
    [ "${cursor:-0}" -gt "${before:-0}" ] && return 0
    sleep 0.1
  done
  return 1
}

# Run the new reaper against $TEST_SKILL_DIR/run, as session-start.sh would.
_run_reaper() {
  ( export SKILL_DIR="$TEST_SKILL_DIR"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/resolve-project.sh"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/instance-id.sh"
    agmsg_reap_orphan_bare_watchers "$$" )
}

# Same, but with every `kill` call inside the reaper forced to fail — a
# function definition shadows the builtin for the rest of this subshell, which
# is the seam: simulates EPERM/signal-refused without touching production code
# or the real process table.
_run_reaper_with_kill_failing() {
  ( export SKILL_DIR="$TEST_SKILL_DIR"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/resolve-project.sh"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/instance-id.sh"
    kill() { return 1; }
    agmsg_reap_orphan_bare_watchers "$$" )
}

@test "any_agent_ancestor_pid: no match when the starting pid does not exist" {
  # A nonexistent pid has no ppid to walk to, so the real walk (no override)
  # must fail at the first hop. Deliberately not testing this against a real
  # live pid here: this suite may itself be running inside an actual agent
  # session, in which case a real walk from $$ legitimately finds one (the
  # override tested below exists precisely so callers are not at the mercy of
  # that ambient fact).
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/resolve-project.sh"
  ! agmsg_any_agent_ancestor_pid 999999
}

@test "any_agent_ancestor_pid: AGMSG_ANY_AGENT_ANCESTOR_PID overrides the walk" {
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/resolve-project.sh"
  AGMSG_ANY_AGENT_ANCESTOR_PID="" run agmsg_any_agent_ancestor_pid "$$"
  [ "$status" -ne 0 ]
  AGMSG_ANY_AGENT_ANCESTOR_PID="$$" run agmsg_any_agent_ancestor_pid 1234
  [ "$status" -eq 0 ]
  [ "$output" = "$$" ]
}

@test "orphaned bare-id watcher consumes a message, then stops after the reap fix (#693)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-bare-orphan"

  # Force this watcher's own id to stay bare, and force the reaper's later
  # ancestor walk over ITS pid to also come back empty — deterministic
  # regardless of the ambient process tree this suite happens to run under
  # (which may or may not itself have a real claude/codex ancestor).
  export AGMSG_AGENT_PID=""
  export AGMSG_ANY_AGENT_ANCESTOR_PID=""
  # These tests reap seconds-old watchers on purpose; the grace period exists
  # for real deployments, not for a test that already controls every other
  # variable (#737 review).
  export AGMSG_REAP_GRACE_SECONDS=0

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out.log" 2>/dev/null 3>&- 4>&- &
  local wpid=$!

  local before
  before=$(_read_cursor team alice 2>/dev/null || echo 0)
  bash "$SCRIPTS/send.sh" team bob alice "M1-while-orphaned" >/dev/null

  # --- Positive control: prove the bug's mechanism is real before fixing it.
  # An orphaned bare-id watcher, with no resolvable owning session, still
  # delivers and marks the message read. If this does not happen the rest of
  # the test proves nothing.
  _wait_for_file_contains "$TEST_SKILL_DIR/out.log" "M1-while-orphaned"
  _wait_for_cursor_above team alice "$before"
  grep -q "M1-while-orphaned" "$TEST_SKILL_DIR/out.log"
  kill -0 "$wpid" 2>/dev/null   # still alive: watch.sh's own loop never self-checks a bare id

  # --- Apply the fix: reap it from outside, the way session-start.sh does on
  # every new/resumed session.
  _run_reaper
  wait_for_pid_exit "$wpid"
  [ ! -f "$TEST_SKILL_DIR/run/watch.$sid.pid" ]

  # --- After the fix: nobody is left to consume. A second message sent to the
  # same pair stays unread.
  local after_reap
  after_reap=$(_read_cursor team alice 2>/dev/null || echo 0)
  bash "$SCRIPTS/send.sh" team bob alice "M2-after-reap" >/dev/null
  sleep 1.5
  local final
  final=$(_read_cursor team alice 2>/dev/null || echo 0)
  [ "$final" = "$after_reap" ]
}

@test "a bare-id watcher WITH a live ancestor is not reaped (#693 negative control)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-bare-live"

  export AGMSG_AGENT_PID=""
  # Pin the reaper's ancestor walk to report THIS bats process as a live
  # "ancestor" — simulating a watcher whose own id happened to come back bare,
  # but whose owning session is in fact still alive and resolvable.
  export AGMSG_ANY_AGENT_ANCESTOR_PID="$$"
  # Zero the grace period so this test exercises the ancestor check itself,
  # not the age floor added in #737 review (which would otherwise protect a
  # seconds-old watcher regardless of ancestor).
  export AGMSG_REAP_GRACE_SECONDS=0

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out2.log" 2>/dev/null 3>&- 4>&- &
  local wpid=$!
  # Give it one cycle to write its pidfile before the reaper looks for it.
  for i in $(seq 1 50); do
    [ -f "$TEST_SKILL_DIR/run/watch.$sid.pid" ] && break
    sleep 0.1
  done

  _run_reaper
  sleep 1
  kill -0 "$wpid" 2>/dev/null   # still alive: the reaper must not touch it

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

@test "a stale pidfile naming a reused pid does not kill the live watcher actually holding it (#737 review)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local real_sid="sess-victim-real"
  local stale_sid="sess-old-dead"

  # The pid this test cares about is a REAL, live, ancestor-less watch.sh —
  # exactly the shape the reaper is allowed to reap. The point of this test is
  # that it must be reaped (if at all) ONLY via ITS OWN pidfile naming its own
  # sid — never via an unrelated pidfile that merely happens to hold the same
  # pid, simulating pid reuse after some OTHER watcher's process exited
  # without cleaning up.
  export AGMSG_AGENT_PID=""
  export AGMSG_ANY_AGENT_ANCESTOR_PID=""
  # These tests reap seconds-old watchers on purpose; the grace period exists
  # for real deployments, not for a test that already controls every other
  # variable (#737 review).
  export AGMSG_REAP_GRACE_SECONDS=0

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$real_sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out3.log" 2>/dev/null 3>&- 4>&- &
  local wpid=$!
  local real_pf="$TEST_SKILL_DIR/run/watch.$real_sid.pid"
  for i in $(seq 1 50); do
    [ -f "$real_pf" ] && break
    sleep 0.1
  done
  [ -f "$real_pf" ]

  # Craft the reuse: a pidfile for a DIFFERENT, stale sid, holding this SAME
  # live pid, and remove the real/correct pidfile so the loop's only route to
  # this pid is the wrong one. This is the scenario, not a proxy for it: some
  # earlier watch.sh for stale_sid really did exit leaving this pidfile
  # behind, and the OS handed its pid to today's real_sid watcher.
  local stale_pf="$TEST_SKILL_DIR/run/watch.$stale_sid.pid"
  printf '%s' "$wpid" > "$stale_pf"
  rm -f "$real_pf"

  _run_reaper
  sleep 1
  kill -0 "$wpid" 2>/dev/null   # still alive: the stale/wrong pidfile must not authorize this kill

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

@test "a kill failure leaves the pidfile in place for a future retry (#737 review)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-bare-kill-fails"

  export AGMSG_AGENT_PID=""
  export AGMSG_ANY_AGENT_ANCESTOR_PID=""
  # These tests reap seconds-old watchers on purpose; the grace period exists
  # for real deployments, not for a test that already controls every other
  # variable (#737 review).
  export AGMSG_REAP_GRACE_SECONDS=0

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out4.log" 2>/dev/null 3>&- 4>&- &
  local wpid=$!
  local pf="$TEST_SKILL_DIR/run/watch.$sid.pid"
  for i in $(seq 1 50); do
    [ -f "$pf" ] && break
    sleep 0.1
  done
  [ -f "$pf" ]

  _run_reaper_with_kill_failing
  sleep 1
  # The signal never actually landed (every kill in the reaper was forced to
  # fail), so both must still be true: the watcher is alive, AND its pidfile
  # -- the only record a future pass could use to find and retry it -- is
  # still there. Losing either would turn "could not reap it this time" into
  # "can never reap it, and no longer even know it exists" (#693 made worse,
  # not fixed).
  kill -0 "$wpid" 2>/dev/null
  [ -f "$pf" ]

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

@test "a bare-id watcher younger than the grace period is not reaped even with no ancestor (#737 review)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-bare-too-young"

  # No AGMSG_REAP_GRACE_SECONDS override here: the default must protect a
  # watcher that only just started, in exactly the shape that made
  # session-start.sh's own "compact dedup" test fail in real CI (ubuntu-latest
  # and macos-latest both showed the reaper killing that test's seconds-old
  # watcher, because CI has no claude/codex process anywhere in the tree, so
  # EVERY bare watcher looks ancestor-less from the instant it starts, not
  # only genuinely orphaned ones).
  export AGMSG_AGENT_PID=""
  export AGMSG_ANY_AGENT_ANCESTOR_PID=""

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out5.log" 2>/dev/null 3>&- 4>&- &
  local wpid=$!
  local pf="$TEST_SKILL_DIR/run/watch.$sid.pid"
  for i in $(seq 1 50); do
    [ -f "$pf" ] && break
    sleep 0.1
  done
  [ -f "$pf" ]

  _run_reaper
  sleep 1
  kill -0 "$wpid" 2>/dev/null   # still alive: too young to be a reap candidate yet

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}
