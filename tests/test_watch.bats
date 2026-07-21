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

_max_message_id() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_sqlite "$(agmsg_db_path)" "SELECT COALESCE(MAX(id), 0) FROM messages;" )
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
  sleep 1.5
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
  run_watcher_for "$sid" "$TEST_SKILL_DIR/out2.log" 2

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
  local sesspid; sleep 600 & sesspid=$!
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
  ! grep -q "M2-undelivered" "$out"
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

  run_watcher_for "$sid" "$TEST_SKILL_DIR/closed-redelivery.log" 2
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
  run_watcher_for "sess-broad" "$TEST_SKILL_DIR/broad.log" 1.5
  [ ! -e "$TEST_SKILL_DIR/run/ready.team__alice" ]
  [ ! -e "$TEST_SKILL_DIR/run/ready.team__bob" ]
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

# Poll up to ~3s for <pidfile> to record <want_pid>.
_wait_pidfile() {
  local pf="$1" want="$2" i
  for i in $(seq 1 30); do
    [ -f "$pf" ] && [ "$(cat "$pf" 2>/dev/null)" = "$want" ] && return 0
    sleep 0.1
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
  local sp1 sp2; sleep 600 & sp1=$!; sleep 600 & sp2=$!
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
  local sesspid; sleep 600 & sesspid=$!
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
@test "watch: surfaces an unopenable DB once instead of spinning silently (#197)" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  local DB="$TEST_SKILL_DIR/db/messages.db"
  [ -f "$DB" ]                # init-db.sh created it in setup_test_env
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
