#!/usr/bin/env bats

# Regression tests for the store-owned per-(team,agent) read cursor. Inbox and
# monitor share this frontier, so restarts deliver gaps without replaying rows
# already consumed by either delivery path.

load test_helper

setup() {
  setup_test_env
  # On MSYS2, the compat shim makes the ppid walk succeed; _iid() (bats
  # subshell) and watch.sh (standalone bash) have different process trees, so
  # the walk can produce different instance IDs. Pin to bare-sid on MSYS2 so
  # both contexts agree deterministically.
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) export AGMSG_AGENT_PID="" ;; esac
  export PROJ="/tmp/agmsg-watch-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

# Run watch.sh in the background for <secs> seconds, capturing stdout to <out>.
# Returns once the watcher has been stopped.
run_watcher_for() {
  local sid="$1" out="$2" secs="$3"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Run watch.sh in the background until <condition> holds, capturing stdout to
# <out>, then stop it. Returns non-zero if the condition never arrived.
#
# These wait for the thing the caller is about to assert instead of sleeping a
# fixed number of seconds. A fixed sleep encodes "the watcher is usually done by
# now", which is a claim about the machine rather than about the watcher: on a
# loaded runner it is false, and the test then fails on its own assertion with no
# hint that timing was the cause. `watch: persists a watermark file for the
# session` failed exactly that way on main (macos shard 3/4), and `watch: restart
# delivers messages that arrived while the watcher was down` failed the same way
# the day before. Same class of defect as #503, same fix.
#
# A wait that times out returns non-zero HERE, so the failure names the condition
# that never happened rather than surfacing later as a missing grep.
# The launch is written out in each helper rather than factored into a
# `pid=$(_start_watcher ...)` helper on purpose. A command substitution is a
# subshell, so the watcher's parent would exit the instant the substitution
# returned, and watch.sh — which stops within one interval once its session is
# gone (#67) — would tear itself down before the condition could ever arrive. A
# function call is not a subshell, so launching here keeps the test process as
# the watcher's parent, exactly as the fixed-sleep version did.
_stop_watcher() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}

# Stop once <file> exists.
run_watcher_until_file() {
  local sid="$1" out="$2" file="$3" pid rc=0
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- &
  pid=$!
  wait_for_file "$file" || rc=1
  _stop_watcher "$pid"
  return "$rc"
}

# Stop once <out> contains <needle>.
run_watcher_until_contains() {
  local sid="$1" out="$2" needle="$3" pid rc=0
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- &
  pid=$!
  wait_for_file_contains "$out" "$needle" || rc=1
  _stop_watcher "$pid"
  return "$rc"
}

run_watcher_until() {
  local sid="$1" out="$2" needle="$3" before
  before=$(_read_cursor team alice 2>/dev/null || echo 0)
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  _wait_for_file_contains "$out" "$needle"
  local found=$?
  if [ "$found" -eq 0 ]; then
    local i cursor
    for i in $(seq 1 100); do
      cursor=$(_read_cursor team alice 2>/dev/null || echo 0)
      [ "${cursor:-0}" -gt "${before:-0}" ] && break
      sleep 0.1
    done
    [ "${cursor:-0}" -gt "${before:-0}" ] || found=1
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return "$found"
}

# Compute the per-process instance id (#93) that watch.sh / session-end key on
# for <sid>, the same way the scripts do. Resolves to a composite "<sid>.<pid>"
# when an agent ancestor is present (e.g. running the suite under a Claude Code
# session) and to the bare sid otherwise (e.g. CI) — so filename/owner
# assertions hold in both environments instead of hardcoding the bare form.
_iid() {
  ( export SKILL_DIR="$TEST_SKILL_DIR"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/resolve-project.sh"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/instance-id.sh"
    agmsg_normalize_instance_id "$1" claude-code 2>/dev/null )
}

# Takes the team, because there is a store per team and no default one to fall
# back to. No caller today; a call without the argument fails loudly rather
# than reading whichever store happened to be first.
_max_message_id() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_sqlite "$(agmsg_db_path "$1")" "SELECT COALESCE(MAX(id), 0) FROM messages;" )
}

# Read one pair's store-owned local frontier.
_read_cursor() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    storage_read_cursor_get "$1" "$2" )
}

_wait_for_file() {
  local file="$1" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && return 0
    sleep 0.1
  done
  [ "${cursor:-0}" -gt 0 ]
  return 1
}

_wait_for_missing() {
  local file="$1" i
  for i in $(seq 1 100); do
    [ ! -e "$file" ] && return 0
    sleep 0.1
  done
  return 1
}

_wait_for_file_contains() {
  local file="$1" needle="$2" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && grep -q "$needle" "$file" && return 0
    sleep 0.1
  done
  return 1
}

@test "watch: restart delivers messages that arrived while the watcher was down" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-restart"

  # First watcher consumes M1 into the shared store frontier.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out1.log" 2>/dev/null 3>&- 4>&- &
  local w1=$!
  bash "$SCRIPTS/send.sh" team bob alice "M1-before-stop" >/dev/null
  _wait_for_file_contains "$TEST_SKILL_DIR/out1.log" "M1-before-stop"
  local i cursor
  for i in $(seq 1 100); do
    cursor=$(_read_cursor team alice 2>/dev/null || echo 0)
    [ "${cursor:-0}" -gt 0 ] && break
    sleep 0.1
  done
  kill "$w1" 2>/dev/null || true
  wait "$w1" 2>/dev/null || true
  grep -q "M1-before-stop" "$TEST_SKILL_DIR/out1.log"

  # A message arrives while NO watcher is running for this session.
  bash "$SCRIPTS/send.sh" team bob alice "M2-in-gap" >/dev/null

  # Any later watcher resumes from the store frontier (session id is irrelevant).
  run_watcher_until "$sid" "$TEST_SKILL_DIR/out2.log" "M2-in-gap"

  # In-gap message is delivered on restart...
  grep -q "M2-in-gap" "$TEST_SKILL_DIR/out2.log"
  # ...and the already-streamed message is NOT re-delivered.
  ! grep -q "M1-before-stop" "$TEST_SKILL_DIR/out2.log"
}

@test "watch: a fresh session delivers existing unread; a later watcher does not replay it" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  # Pre-existing message before any watcher for this session ever runs.
  bash "$SCRIPTS/send.sh" team bob alice "M0-history" >/dev/null

  run_watcher_until "sess-fresh" "$TEST_SKILL_DIR/fresh1.log" "M0-history"
  grep -q "M0-history" "$TEST_SKILL_DIR/fresh1.log"

  bash "$SCRIPTS/send.sh" team bob alice "M-live" >/dev/null
  run_watcher_until "sess-fresh2" "$TEST_SKILL_DIR/fresh2.log" "M-live"
  grep -q "M-live" "$TEST_SKILL_DIR/fresh2.log"
  ! grep -q "M0-history" "$TEST_SKILL_DIR/fresh2.log"
}

@test "watch: exits when its session dies without consuming an undelivered row (#67)" {
  skip_on_windows "watcher session liveness under Git Bash (#182)"
  # REWRITTEN from "closed consumer does not advance watermark...". The old test
  # asserted that a closed *downstream* consumer (`watch.sh | head -n 1`) made
  # the watcher stop and not advance the watermark. That contract is unachievable
  # on a plain pipe: a closed reader raises no portable signal until the next
  # write (printf '' is silent), and macOS buffers a final write into a dead
  # reader — so the watcher would keep delivering+watermarking and then spin
  # silently (100% hang on macOS, flaky on Linux; the macOS-runner 33-min stall).
  # The real, observable contract is session liveness (#67): when the agent
  # process that owns the watcher dies, the liveness guard (run at the top of the
  # poll loop) makes the watcher exit within ~1 interval, BEFORE polling/
  # delivering any newer row — so it neither hangs nor advances the watermark
  # past an unconsumed message. A controllable stand-in session pid (embedded in
  # the composite instance id) makes that deterministic. Cross-restart
  # redelivery itself is covered by "watch: restart delivers messages that
  # arrived while the watcher was down".
  local sesspid; sleep 600 3>&- & sesspid=$!
  local iid="sess-liveness.$sesspid"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"
  local out="$TEST_SKILL_DIR/liveness-delivery.log"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local w=$!
  # There is no seed race: a pre-poll message remains unread at cursor zero.
  _wait_for_file "$pf"
  [ -f "$pf" ]

  bash "$SCRIPTS/send.sh" team bob alice "M1-delivered" >/dev/null
  _wait_for_file_contains "$out" "M1-delivered"
  local first_cursor="$(_read_cursor team alice)"

  # Owning session dies (reap it so kill -0 reports gone, not a zombie), then a
  # newer row arrives. The liveness guard runs before the DB poll, so the watcher
  # exits before it could deliver or watermark M2.
  kill "$sesspid" 2>/dev/null || true
  wait "$sesspid" 2>/dev/null || true
  bash "$SCRIPTS/send.sh" team bob alice "M2-undelivered" >/dev/null
  _wait_for_missing "$pf" || { kill "$w" 2>/dev/null || true; false; }
  run kill -0 "$w"; [ "$status" -ne 0 ]
  [ "$(_read_cursor team alice)" = "$first_cursor" ]
  refute grep -q "M2-undelivered" "$out"
  run_watcher_for "after-liveness" "$TEST_SKILL_DIR/liveness-redelivery.log" 2
  grep -q "M2-undelivered" "$TEST_SKILL_DIR/liveness-redelivery.log"
}

@test "watch: closed stdout exits without advancing the read cursor" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-stdout-closed"
  local iid="$(_iid "$sid")"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    1>&- 2>/dev/null 3>&- 4>&- &
  local w=$!

  _wait_for_file "$pf"
  [ -f "$pf" ]
  local initial="$(_read_cursor team alice)"

  bash "$SCRIPTS/send.sh" team bob alice "M-after-closed-stdout" >/dev/null

  _wait_for_missing "$pf" || {
    kill "$w" 2>/dev/null || true
    wait "$w" 2>/dev/null || true
    false
  }
  wait "$w" 2>/dev/null || true

  [ "$(_read_cursor team alice)" = "$initial" ]

  run_watcher_until_contains "$sid" "$TEST_SKILL_DIR/closed-redelivery.log" \
    "M-after-closed-stdout"
  grep -q "M-after-closed-stdout" "$TEST_SKILL_DIR/closed-redelivery.log"
}

@test "session-end: leaves the store-owned read cursor intact" {
  bash "$SCRIPTS/send.sh" team bob alice "read-before-end" >/dev/null
  run bash "$SCRIPTS/inbox.sh" team alice
  local before="$(_read_cursor team alice)"
  printf '{"session_id":"sess-end"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  [ "$(_read_cursor team alice)" = "$before" ]
}

@test "watch: actas-mode watcher creates a ready sentinel and removes it on exit" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-ready" "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- 4>&- &
  local w=$!
  # Wait for the watcher to attach and signal readiness.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$ready" ] && break
    sleep 0.5
  done
  [ -e "$ready" ]
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  # Removed on exit (sentinel tracks a live watcher).
  [ ! -e "$ready" ]
}

@test "watch: a broad (non-actas) watcher does not create a ready sentinel" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  # An absence cannot be waited for, so wait for positive evidence that the
  # watcher got PAST the point where a sentinel would have been written.
  #
  # Startup artifacts are not that evidence. The pidfile is written well before
  # the ready block, so observing it and stopping would leave that block
  # unreached and the absence would hold for the wrong reason. Streamed delivery
  # is the evidence, because it happens in the main loop, which is after the
  # ready block.
  #
  # Upstream sent the marker only after the per-session watermark file appeared,
  # so that it would carry a higher id than the mark taken at startup. There is
  # no such file here -- read progress is store-owned under the unified cursor
  # model -- and the wait is not needed either way: a fresh session delivers
  # existing unread ("watch: a fresh session delivers existing unread" above),
  # so the marker is streamed whether it lands before or after the first cursor
  # read. The wait below is still the evidence; only the ordering crutch is gone.
  local out="$TEST_SKILL_DIR/broad.log"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-broad" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- &
  local w=$!
  bash "$SCRIPTS/send.sh" team bob alice "M-broad-marker" >/dev/null
  wait_for_file_contains "$out" "M-broad-marker"

  # Asserted while the watcher is STILL RUNNING, and that is the whole point.
  # cleanup() removes on exit every sentinel this watcher owns, so an assertion
  # made after the kill cannot tell "never created" from "created, then cleaned
  # up" — it holds either way. Checking it here is what makes the absence mean
  # something. Verified by injection: with watch.sh's `[ -n "$ACTIVE_NAME" ]`
  # guard removed so a broad watcher writes the sentinels, this test fails,
  # while the kill-then-assert form it replaces still passes.
  local rc=0 _s
  for _s in ready.team__alice ready.team__bob; do
    if [ -e "$TEST_SKILL_DIR/run/$_s" ]; then
      echo "broad watcher created $_s" >&2
      rc=1
    fi
  done
  _stop_watcher "$w"
  return "$rc"
}

@test "watch: ready sentinel records the owner session_id" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-own" "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- 4>&- &
  local w=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$ready" ] && break; sleep 0.5; done
  # watch.sh stamps the instance id (composite under an agent ancestor).
  [ "$(cat "$ready")" = "$(_iid sess-own)" ]
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
}

@test "watch: cleanup leaves a sentinel that a successor session re-owned" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-old" "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- 4>&- &
  local w=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$ready" ] && break; sleep 0.5; done
  # A successor watcher overwrites the sentinel with its own id.
  printf 'sess-new\n' > "$ready"
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  # The old watcher must NOT delete the successor's live sentinel.
  [ -f "$ready" ]
  [ "$(cat "$ready")" = "sess-new" ]
}

@test "session-start: skips directive when watcher already alive (compact dedup)" {
  skip_on_windows "#134"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # Start a watcher so a pidfile exists with a live pid.
  AGMSG_WATCH_INTERVAL=60 bash "$SCRIPTS/watch.sh" "sess1" "$PROJ" claude-code \
    >/dev/null 2>&1 3>&- 4>&- &
  local wpid=$!

  # Resolve the instance id session-start.sh will compute for "sess1".
  local iid
  iid=$(_iid "sess1")
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"
  _wait_for_file "$pf"

  # Record cc-instance so the dedup path sees "same instance".
  echo "$iid" > "$TEST_SKILL_DIR/run/cc-instance.$$"

  # Fire session-start with the same session_id (simulates /compact re-fire).
  local out
  out=$(printf '{"session_id":"sess1"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" 2>/dev/null || true)

  # The directive must NOT tell the agent to invoke Monitor.
  [[ "$out" == *"already streaming"* ]]
  [[ "$out" != *"invoke the Monitor tool"* ]]

  # The original watcher must still be alive.
  kill -0 "$wpid" 2>/dev/null

  kill "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

@test "session-start: GCs a stale ready sentinel but keeps a live one" {
  skip_on_windows "watcher live-owner liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  # Stale (owner has no live cc-instance).
  echo deadsid > "$TEST_SKILL_DIR/run/ready.team__ghost"
  # Live owner.
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  echo LIVESID > "$TEST_SKILL_DIR/run/ready.team__live"

  printf '{"session_id":"somesess"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ ! -f "$TEST_SKILL_DIR/run/ready.team__ghost" ]
  [ -f "$TEST_SKILL_DIR/run/ready.team__live" ]
}

# --- #93: parallel --continue/--resume sessions sharing a session_id ---

# Poll up to ~10s for <pidfile> to record <want_pid>. A watcher relaunch does
# a real fork + lock-acquire + SIGTERM-the-predecessor + self-write before the
# pidfile reflects it, and a loaded CI runner can push that past the 3s this
# used to allow -- the flake #595 caught on a macos-latest shard. On timeout,
# reports what it was waiting for and what it last saw, per #595's ask for a
# failure message that distinguishes "never arrived" from "arrived as
# something else" rather than a bare assertion failure.
#
# `last saw` alone is the LAST poll and nothing else, so it cannot separate
# "the file never appeared" from "it appeared, then went away again" -- and
# those two have different causes. The distinct values are kept instead, with
# the poll each was first seen at.
#
# Four states, not two. `cat` returns the empty string for a path that does
# not exist, a file that exists and is empty, and a file that exists and
# cannot be read; collapsing them into one `<missing>` loses the difference
# this trail exists to show (raised in review). They are named apart.
#
# Existence is decided by a test; readability is decided by THE READ. `-r`
# only predicts what a read would do, and a read can still fail after it
# passes -- a permission change, a replacement, a path that is not a regular
# file, an I/O error. Classifying on `-r` and then swallowing the read's
# failure with `|| true` reports `<empty>`, merging the two states this
# exists to separate (raised in review; the chmod control drove the `-r`
# branch and never reached the failing read).
_observe_pidfile() {
  local pf="$1" v
  if [ ! -e "$pf" ]; then printf '<no-file>'; return 0; fi
  if v="$(cat "$pf" 2>/dev/null)"; then
    if [ -z "$v" ]; then printf '<empty>'; else printf '%s' "$v"; fi
  else
    printf '<unreadable>'
  fi
}

_wait_pidfile() {
  # `last` starts at a value no read can produce -- seeded with "" it would
  # swallow the first observation in the case that matters most, a file that
  # is missing from the very first poll.
  local pf="$1" want="$2" i seen last="__no_poll_yet__" trail=""
  for i in $(seq 1 100); do
    seen="$(_observe_pidfile "$pf")"
    [ "$seen" = "$want" ] && return 0
    if [ "$seen" != "$last" ]; then
      trail="$trail poll$i='$seen'"
      last="$seen"
    fi
    sleep 0.1
  done
  echo "_wait_pidfile: timed out waiting for '$pf' to record pid $want (last saw: '$seen')" >&2
  echo "_wait_pidfile: distinct observations, first poll each:$trail" >&2
  # What this can say about $want, and no more: signal 0 reaching a pid does
  # not establish that the pid is still the process we started -- pids are
  # reused (raised in review). So the command line is printed rather than a
  # liveness verdict, and the reader decides.
  if kill -0 "$want" 2>/dev/null; then
    echo "_wait_pidfile: signal 0 reaches pid $want; its command line now is:" >&2
    ps -o pid=,stat=,etime=,command= -p "$want" >&2 2>/dev/null || echo "  (ps could not describe it)" >&2
  else
    echo "_wait_pidfile: signal 0 does not reach pid $want (exited, or never ours)" >&2
  fi
  # The watcher writes its own log beside the pidfile and says there what it
  # was doing. A successor that is running and has not yet claimed the slot is
  # waiting on something, and this is the only place that says what.
  echo "_wait_pidfile: run dir and watcher logs:" >&2
  ls -la "$(dirname "$pf")" >&2 2>/dev/null || true
  for _l in "$(dirname "$pf")"/watch.*.log; do
    [ -f "$_l" ] || continue
    echo "--- $_l" >&2
    tail -20 "$_l" >&2 2>/dev/null || true
  done
  return 1
}

@test "watch: two sessions sharing a session_id keep independent watchers (#93)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  # Pre-composite instance ids (same sid prefix, different agent pid) — what
  # session-start bakes into the directive for two parallel resume processes.
  # The embedded pids must be live: the liveness guard (#67) exits a watcher
  # whose session pid is dead, so use real stand-in session processes rather
  # than fabricated pids (which would pass or fail by accident of what pid
  # happens to exist on the host).
  local sp1 sp2; sleep 600 3>&- & sp1=$!; sleep 600 3>&- & sp2=$!
  local pf1="$TEST_SKILL_DIR/run/watch.shared.$sp1.pid"
  local pf2="$TEST_SKILL_DIR/run/watch.shared.$sp2.pid"

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "shared.$sp1" "$PROJ" claude-code >/dev/null 2>&1 3>&- 4>&- &
  local w1=$!
  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "shared.$sp2" "$PROJ" claude-code >/dev/null 2>&1 3>&- 4>&- &
  local w2=$!

  _wait_pidfile "$pf1" "$w1"
  _wait_pidfile "$pf2" "$w2"

  # Distinct pidfiles, and crucially neither watcher killed the other.
  run kill -0 "$w1"; [ "$status" -eq 0 ]
  run kill -0 "$w2"; [ "$status" -eq 0 ]
  [ "$(cat "$pf1")" = "$w1" ]
  [ "$(cat "$pf2")" = "$w2" ]

  kill "$w1" "$w2" "$sp1" "$sp2" 2>/dev/null || true
  wait "$w1" 2>/dev/null || true
  wait "$w2" 2>/dev/null || true
  wait "$sp1" 2>/dev/null || true
  wait "$sp2" 2>/dev/null || true
}

@test "watch: relaunch with the SAME instance id replaces the previous watcher (#66 preserved)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  # The composite instance id's pid must belong to a LIVE process: the watcher's
  # liveness guard (#67) exits any watcher whose embedded session pid is dead, so
  # a fabricated dead pid (the old "solo.2002") would self-exit before the
  # relaunch could be observed. Use a real stand-in session process instead.
  local sesspid; sleep 600 3>&- & sesspid=$!
  local iid="solo.$sesspid"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >/dev/null 2>&1 3>&- 4>&- &
  local w1=$!
  _wait_pidfile "$pf" "$w1"

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >/dev/null 2>&1 3>&- 4>&- &
  local w2=$!
  # Successor claims the pidfile slot...
  _wait_pidfile "$pf" "$w2"
  # ...and the previous holder was killed. The successor SIGTERMs the old holder
  # and then writes its own pid, so the pidfile can flip to w2 a beat before w1's
  # TERM trap has run — poll for w1's exit rather than checking the instant the
  # pidfile changes (the old single check raced this and flaked).
  local i; for i in $(seq 1 30); do kill -0 "$w1" 2>/dev/null || break; sleep 0.1; done
  run kill -0 "$w1"; [ "$status" -ne 0 ]

  kill "$w2" "$sesspid" 2>/dev/null || true
  wait "$w2" 2>/dev/null || true
  wait "$sesspid" 2>/dev/null || true
}

# DB-open healthcheck (#197): a store that exists but cannot be opened (the
# native sqlite3.exe / Git Bash /c/ path mismatch, or bad perms) must surface a
# loud error rather than spin silently delivering nothing.
# Run watch.sh for <secs> with an active name (actas mode), then stop it.
run_named_watcher_for() {
  local sid="$1" out="$2" secs="$3" name="$4" pid
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code "$name" >"$out" 2>/dev/null 3>&- &
  pid=$!
  sleep "$secs"
  _stop_watcher "$pid"
}

# Record the ORDER THAT ACTUALLY HAPPENED; do not try to impose one (#595).
#
# Two earlier versions of this control were wrong in the same way twice. The
# first slept between the steps, so the ordering was decided by machine load.
# The second had the processes rendezvous on marker files, with a bounded wait
# — and a bound that PROCEEDS when it expires turns the negative control green
# on the broken code: if the predecessor is slow to reach its cleanup, the
# successor's wait times out, it writes anyway, and the predecessor then reads
# a pidfile that already names the successor and correctly deletes nothing.
# The control would have reported the defect as fixed (raised in review).
#
# So nothing is imposed and nothing is waited for. Each process APPENDS a word
# to one file as it passes the point that matters, and the assertion is about
# the sequence that came out. Under either implementation the events happen in
# whatever order they happen; the fix's whole content is which order that is,
# and a recorded order cannot be lost to load.
#
#   claim   the successor wrote its own pid to the pidfile
#   signal  the successor sent the previous holder its signal
#   read    the departing predecessor read the pidfile in its EXIT guard
#
# The fix says `claim` precedes `signal`. Everything else follows from that:
# a `read` triggered by the signal necessarily lands after the claim, and the
# guard then sees a pid that is not its own.
_record_handover_events() {
  local sh="$SCRIPTS/watch.sh" applied
  export AGMSG_TEST_EVENTS="$TEST_SKILL_DIR/run/handover.events"
  mkdir -p "$TEST_SKILL_DIR/run"
  : > "$AGMSG_TEST_EVENTS"
  perl -0pi -e 's/(\[ -f "\$PIDFILE" \] && IFS= read -r pidfile_pid < "\$PIDFILE" \|\| true)/$1\n  [ -n "\${AGMSG_TEST_EVENTS:-}" ] && printf %s\\ %s\\\\n read \$\$ >> "\$AGMSG_TEST_EVENTS"  # RECORDED/' "$sh"
  perl -0pi -e 's/^echo \$\$ > "\$PIDFILE"$/echo \$\$ > "\$PIDFILE"\n[ -n "\${AGMSG_TEST_EVENTS:-}" ] && printf %s\\ %s\\\\n claim \$\$ >> "\$AGMSG_TEST_EVENTS"  # RECORDED/m' "$sh"
  perl -0pi -e 's/(kill "\$PREV_PID_TO_DISPLACE" 2>\/dev\/null \|\| true|kill "\$prev_pid" 2>\/dev\/null \|\| true)/[ -n "\${AGMSG_TEST_EVENTS:-}" ] \&\& printf %s\\ %s\\\\n signal \$\$ >> "\$AGMSG_TEST_EVENTS"  # RECORDED\n      $1/g' "$sh"
  # A control on the instrumentation: an edit that matched nothing would leave
  # every assertion below reading an empty file and passing.
  applied="$(grep -c 'RECORDED' "$sh")"
  [ "$applied" -ge 3 ]
}

@test "watch: the successor claims the pidfile before it signals, and keeps its record (#595)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  _record_handover_events

  local sesspid; sleep 600 3>&- & sesspid=$!
  local iid="solo.$sesspid"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >/dev/null 2>&1 3>&- 4>&- &
  local w1=$!
  _wait_pidfile "$pf" "$w1"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >/dev/null 2>&1 3>&- 4>&- &
  local w2=$!

  # Wait for the PREDECESSOR TO BE GONE, which is a condition and not a
  # duration: its remove is the last thing it does, so once it is gone nothing
  # else can touch the pidfile.
  local i
  for i in $(seq 1 200); do
    kill -0 "$w1" 2>/dev/null || break
    sleep 0.1
  done
  run kill -0 "$w1"; [ "$status" -ne 0 ]
  run kill -0 "$w2"; [ "$status" -eq 0 ]

  # The order that actually occurred. Both events must be present -- an
  # assertion over a sequence that is missing one of its terms proves nothing.
  local claim_at signal_at read_at
  # BY PID, not by event name. Both watchers claim the slot -- the predecessor
  # when it starts -- so a search for the first `claim` finds the wrong one and
  # the assertion passes on the broken code. The mutation caught that before
  # CI did; the events carry the pid that wrote them for exactly this reason.
  claim_at="$(grep -n "^claim $w2\$"  "$AGMSG_TEST_EVENTS" | head -1 | cut -d: -f1)"
  signal_at="$(grep -n "^signal $w2\$" "$AGMSG_TEST_EVENTS" | head -1 | cut -d: -f1)"
  read_at="$(grep -n "^read $w1\$"    "$AGMSG_TEST_EVENTS" | head -1 | cut -d: -f1)"
  [ -n "$claim_at" ]
  [ -n "$signal_at" ]
  [ -n "$read_at" ]
  # The fix, stated as the thing it is: the slot is claimed first.
  [ "$claim_at" -lt "$signal_at" ]
  # And the consequence, which is what the operator actually loses when the
  # order is wrong: the record the live watcher wrote is still there.
  [ "$read_at" -gt "$claim_at" ]
  local seen; seen="$( [ -e "$pf" ] && cat "$pf" 2>/dev/null || printf '<no-file>' )"
  [ "$seen" = "$w2" ]

  kill "$w2" "$sesspid" 2>/dev/null || true
  wait "$w2" 2>/dev/null || true
}


@test "watch: the slot is claimed before the previous holder is signalled (#595)" {
  # The property is an ORDER between two statements, and the failure it
  # prevents is a race, so this is asserted where the order lives rather than
  # by trying to lose the race on purpose. A timing test here would pass on
  # every machine that happens to win it -- which is how the defect survived:
  # `bats tests/test_watch.bats` is green on a developer machine and the
  # failure only ever appeared on a CI runner.
  #
  # What the order buys: the predecessor's EXIT guard removes the pidfile only
  # if it still records the predecessor's pid, and that read-check-remove is
  # three steps. Signalling first lets the successor's write land between the
  # read and the remove, and the successor's record is deleted by a process on
  # its way out. Writing first makes the guard's own read see the successor.
  local watch_sh="$SCRIPTS/watch.sh" claim displace
  claim="$(grep -n '^echo \$\$ > "\$PIDFILE"$' "$watch_sh" | head -1 | cut -d: -f1)"
  displace="$(grep -n 'kill "\$PREV_PID_TO_DISPLACE"' "$watch_sh" | head -1 | cut -d: -f1)"

  # Both anchors must exist, or this test passes by finding nothing -- the
  # failure mode of every grep-based check.
  [ -n "$claim" ]
  [ -n "$displace" ]
  [ "$displace" -gt "$claim" ]

  # And the takeover block must not signal anyone on its own. The first
  # version of this line anchored the pattern to the start of a line, and a
  # mutation that put the old `kill "$prev_pid"` back INSIDE the case arm --
  # where it lived before, after the pattern and a `)` -- left this test
  # green. Unanchored, because what matters is that the previous holder is
  # never signalled through that variable at all, wherever it is written.
  refute grep -n 'kill "\$prev_pid"' "$watch_sh"
}

@test "watch: a second unfiltered watcher says it is sharing, and a lone one does not" {
  # Two watchers with no active name subscribe to the same unclaimed pairs. The
  # read cursor is one per (team, agent), so whoever polls first takes the row
  # and the other never sees it — and `inbox.sh` then truthfully says "no new
  # messages", because it was read. Nothing observable is left behind, so this
  # is said at the only moment it can be: startup.
  #
  # Asserted from the LOG. In the configuration this runs in, fd2 is /dev/null
  # (#691) — the helpers above redirect it too — so a warning written only to
  # stderr would be invisible here and in production.
  #
  # Composite ids: a bare token is normalized on the way in (watch.sh:92), so
  # naming the pidfile from a bare id waits for a file never written. Measured.
  local run_dir="$TEST_SKILL_DIR/run"
  local solo_id="solo-sid.$$" first_id="first-sid.$$" second_id="second-sid.$$" third_id="third-sid.$$"

  # NEGATIVE FIRST, on the ordinary case: one watcher, alone. An implementation
  # that always warns passes the positive half below and is wrong every start.
  # Given seconds rather than a file to wait for, because the assertion is an
  # ABSENCE — there is no arrival to synchronise on, and waiting longer only
  # makes the negative stronger.
  run_watcher_for "$solo_id" "$BATS_TEST_TMPDIR/solo.out" 2
  refute grep -qF -- "another watcher" "$run_dir/watch.$solo_id.log"

  # Now a live one, and a second started while it runs.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$first_id" "$PROJ" claude-code \
    >"$BATS_TEST_TMPDIR/first.out" 2>/dev/null 3>&- &
  local first_pid=$!
  wait_for_file "$run_dir/watch.$first_id.pid"

  # Waits for the LAST of the three lines, not for the pidfile: the pidfile is
  # written before the warning, so a test that waits on it kills the watcher
  # mid-sentence and sees a partial message. Measured — that is how this failed.
  local second_log="$run_dir/watch.$second_id.log"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$second_id" "$PROJ" claude-code \
    >"$BATS_TEST_TMPDIR/second.out" 2>/dev/null 3>&- &
  local second_pid=$!
  wait_for_file_contains "$second_log" "/agmsg actas"
  _stop_watcher "$second_pid"

  grep -q -F -- "another watcher" "$second_log"
  # The remedy, not only the cause. A warning that names neither what is lost
  # nor what to type leaves the reader stopped.
  grep -q -F -- "polls first" "$second_log"
  grep -q -F -- "/agmsg actas" "$second_log"

  # And a filtered watcher stays quiet even with the same unfiltered one alive:
  # it is not sharing anything.
  run_named_watcher_for "$third_id" "$BATS_TEST_TMPDIR/third.out" 2 alice
  refute grep -qF -- "another watcher" "$run_dir/watch.$third_id.log"

  # A DIFFERENT PROJECT does not warn, even with this project's unfiltered
  # watcher still live. `RUN_DIR` is per install, so the scan sees that pidfile
  # — but the subscription is per project and they share no pairs. Without the
  # project in the metadata this case warns, which is a false alarm on every
  # installation serving two projects (raised in review).
  local other_proj="/tmp/agmsg-watch-proj-other" other_id="other-proj-sid.$$"
  bash "$SCRIPTS/join.sh" otherteam carol claude-code "$other_proj" >/dev/null
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$other_id" "$other_proj" claude-code \
    >"$BATS_TEST_TMPDIR/other.out" 2>/dev/null 3>&- &
  local other_pid=$!
  sleep 2
  _stop_watcher "$other_pid"
  refute grep -qF -- "another watcher" "$run_dir/watch.$other_id.log"

  _stop_watcher "$first_pid"
}

@test "watch: a filtered watcher is never mistaken for unfiltered while starting" {
  # A reader that finds a live pid with no filter file SKIPS it: it cannot tell
  # the role or the project. If the pidfile were published first, every filtered
  # watcher would sit in exactly that state for the length of its startup
  # window, and a scan landing inside it would reach the wrong conclusion about
  # a watcher whose metadata was already on its way.
  #
  # Asserted on the ARTEFACTS rather than by racing: whenever a pidfile exists,
  # its filter file exists too, and names this watcher's role. That is the
  # property the ordering buys, and it holds at every instant rather than at the
  # one this test happened to look.
  # Read WHILE IT RUNS. The filter file is removed on exit by its own recorded
  # owner (not by the pidfile's), so inspecting after the watcher stops measures
  # the cleanup rather than the ordering — measured, that is how the first
  # version of this failed.
  local run_dir="$TEST_SKILL_DIR/run" named_id="named-order.$$"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$named_id" "$PROJ" claude-code alice \
    >"$BATS_TEST_TMPDIR/named.out" 2>/dev/null 3>&- &
  local named_pid=$!
  wait_for_file "$run_dir/watch.$named_id.pid"

  # Whenever the pidfile exists, the filter file exists too and names the role.
  # That is what publishing the metadata first buys, and it holds at every
  # instant rather than at the one this test happened to look at.
  [ -f "$run_dir/watch.$named_id.filter" ]
  [ "$(sed -n '1p' "$run_dir/watch.$named_id.filter")" = "alice" ]
  [ "$(sed -n '2p' "$run_dir/watch.$named_id.filter")" = "$PROJ" ]

  _stop_watcher "$named_pid"
}

@test "watch: a watcher does not delete filter metadata it did not write" {
  # The replacement path signals the previous watcher for this session id and
  # does not wait for it, so a successor writes its filter file while the
  # pidfile still names the predecessor. Deciding the filter's fate by the
  # PIDFILE lets the predecessor delete metadata the successor just wrote — and
  # the successor is then live with a pidfile and no filter, which a reader
  # classifies as pre-change and skips. A second unfiltered watcher in the same
  # project then goes unreported, which is the whole point of the warning.
  #
  # Driven deterministically rather than by racing two watchers: the race window
  # is real but does not reproduce on demand, and a control that only sometimes
  # enters the window is a control that only sometimes tests anything. Measured
  # — the racing version passed with the ownership check removed.
  #
  # What is driven is the real `cleanup` in the real process: the file on disk
  # is made to belong to somebody else, and the watcher is then stopped.
  local run_dir="$TEST_SKILL_DIR/run" sid="owner.$$"
  local pf="$run_dir/watch.$sid.pid" ff="$run_dir/watch.$sid.filter"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$BATS_TEST_TMPDIR/owner.out" 2>/dev/null 3>&- &
  local w=$!
  wait_for_file "$pf"
  [ -f "$ff" ]
  # Its own pid while it runs — the ordinary case, and the premise of the swap
  # below. Without this the test could pass on a watcher that never wrote one.
  [ "$(sed -n '3p' "$ff")" = "$(cat "$pf")" ]

  # Now the file belongs to a successor: same role and project, different owner.
  printf '%s\n%s\n%s\n' alice "$PROJ" 999999 > "$ff"

  _stop_watcher "$w"

  # The watcher owned the PIDFILE and removed it. It did not own the filter.
  refute test -f "$pf"
  [ -f "$ff" ]
  [ "$(sed -n '3p' "$ff")" = "999999" ]
}

@test "watch: surfaces an unopenable DB once instead of spinning silently (#197)" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  # The watcher opens the subscribed team's store, so that is the file to make
  # unopenable — install no longer creates one store for everybody. A send
  # brings it into existence first; a team that has never been written to has
  # no store at all, which is a different (and legitimate) state.
  bash "$SCRIPTS/send.sh" team bob alice "seed the store" >/dev/null
  local DB="$TEST_SKILL_DIR/db/messages.db"
  [ -f "$DB" ]
  chmod 000 "$DB"
  local out="$BATS_TEST_TMPDIR/hc.out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-hc" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!
  sleep 2                     # > one poll interval; a spinning watcher would re-emit
  kill "$pid" 2>/dev/null || true   # no-op if the healthcheck already exited
  wait "$pid" 2>/dev/null || true
  chmod 644 "$DB" 2>/dev/null || true
  # Exactly one line: 0 would mean a silent spin, >1 a re-emitting loop.
  [ "$(grep -c 'ERROR: cannot open message DB' "$out")" -eq 1 ]
}

# Empty session_id fallback (#236 grok monitor): Grok's `monitor` tool may run
# the launch command with an empty $GROK_SESSION_ID, so watch.sh must self-assign
# an id and start, not die with a "Usage" error (which left the monitor down).
# No silent message loss across a burst (#245): the head-5 truncation bug had a
# grok agent append `| head -5` to the monitor command, so after the 5th line the
# consumer closed and later messages were dropped while the cursor advanced
# past them. With the watcher streaming normally (no downstream truncation), a
# burst of N>5 consecutive messages must ALL be delivered.
@test "watch: delivers a burst of 8 consecutive messages without loss (#245)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-burst"
  local out="$TEST_SKILL_DIR/burst.log"
  local pf="$TEST_SKILL_DIR/run/watch.$(_iid "$sid").pid"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- 4>&- &
  local w=$!
  _wait_for_file "$pf"          # watcher process is live; unread has no seed race

  local n
  for n in 1 2 3 4 5 6 7 8; do
    bash "$SCRIPTS/send.sh" team bob alice "BURST-$n" >/dev/null
  done

  # Wait for the last one to arrive, then assert EVERY message is present.
  _wait_for_file_contains "$out" "BURST-8" || { kill "$w" 2>/dev/null || true; false; }
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  for n in 1 2 3 4 5 6 7 8; do
    grep -q "BURST-$n" "$out"
  done
}

@test "watch: empty session_id gets a generated fallback instead of a Usage error (#236)" {
  local out="$BATS_TEST_TMPDIR/empty-sid.out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "" "$PROJ" claude-code alice >"$out" 2>&1 3>&- 4>&- &
  local pid=$!
  # A fallback id means a watch.agmsg-*.pid appears under run/ as the watcher arms.
  local i started=0
  for i in $(seq 1 25); do
    if ls "$TEST_SKILL_DIR/run"/watch.agmsg-*.pid >/dev/null 2>&1; then started=1; break; fi
    sleep 0.2
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [ "$started" -eq 1 ]
  ! grep -q "Usage: watch.sh" "$out"
}

# Callers pass "${GROK_SESSION_ID:--}" (and the same pattern for other hosts)
# so a launcher that drops a quoted-empty first arg cannot shift project/type.
# watch.sh must fold "-" into the same generated-fallback path as "" (#236).
@test "watch: sentinel '-' session_id resolves like an empty one (#477)" {
  local out="$BATS_TEST_TMPDIR/dash-sid.out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" - "$PROJ" claude-code alice >"$out" 2>&1 3>&- &
  local pid=$!
  # Folded to empty => a generated fallback id, so a watch.agmsg-*.pid appears.
  local i started=0
  for i in $(seq 1 25); do
    if ls "$TEST_SKILL_DIR/run"/watch.agmsg-*.pid >/dev/null 2>&1; then started=1; break; fi
    sleep 0.2
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [ "$started" -eq 1 ]
  # No literal "-" session id leaked into the run dir key space.
  refute ls "$TEST_SKILL_DIR/run"/watch.-*.pid >/dev/null 2>&1
  refute grep -q "Usage: watch.sh" "$out"
  refute grep -q "ERROR: unknown agent type" "$out"
}
