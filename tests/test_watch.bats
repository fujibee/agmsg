#!/usr/bin/env bats

# Regression tests for the watch.sh per-session watermark (#107): a Monitor
# restart must deliver messages that arrived during the restart gap, without
# re-delivering anything already streamed, while a fresh session still starts
# from "now" rather than replaying history.

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
}

teardown() {
  teardown_test_env
}

# Run watch.sh in the background for <secs> seconds, capturing stdout to <out>.
# Returns once the watcher has been stopped.
run_watcher_for() {
  local sid="$1" out="$2" secs="$3"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
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

_wait_for_file() {
  local file="$1" i
  for i in $(seq 1 100); do
    [ -f "$file" ] && return 0
    sleep 0.1
  done
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

  # First watcher: fresh session, takes its mark at MAX(id)=0, then streams M1.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out1.log" 2>/dev/null &
  local w1=$!
  sleep 1.5
  bash "$SCRIPTS/send.sh" team bob alice "M1-before-stop" >/dev/null
  sleep 2
  kill "$w1" 2>/dev/null || true
  wait "$w1" 2>/dev/null || true
  grep -q "M1-before-stop" "$TEST_SKILL_DIR/out1.log"

  # A message arrives while NO watcher is running for this session.
  bash "$SCRIPTS/send.sh" team bob alice "M2-in-gap" >/dev/null

  # Restart the SAME session_id — should resume from the persisted watermark.
  run_watcher_for "$sid" "$TEST_SKILL_DIR/out2.log" 2

  # In-gap message is delivered on restart...
  grep -q "M2-in-gap" "$TEST_SKILL_DIR/out2.log"
  # ...and the already-streamed message is NOT re-delivered.
  ! grep -q "M1-before-stop" "$TEST_SKILL_DIR/out2.log"
}

@test "watch: a fresh session starts from now and does not replay history" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  # Pre-existing message before any watcher for this session ever runs.
  bash "$SCRIPTS/send.sh" team bob alice "M0-history" >/dev/null

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-fresh" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/fresh.log" 2>/dev/null &
  local w=$!
  sleep 1.5
  bash "$SCRIPTS/send.sh" team bob alice "M-live" >/dev/null
  sleep 2
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  # Live message after attach is delivered; pre-existing history is not replayed.
  grep -q "M-live" "$TEST_SKILL_DIR/fresh.log"
  ! grep -q "M0-history" "$TEST_SKILL_DIR/fresh.log"
}

@test "watch: persists a watermark file for the session" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  run_watcher_for "sess-wm" "$TEST_SKILL_DIR/wm.log" 1.5
  [ -f "$TEST_SKILL_DIR/run/watch.$(_iid sess-wm).watermark" ]
}

@test "watch: exits within one interval when its session dies, without advancing the watermark past an undelivered row (#67)" {
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
  local wm="$TEST_SKILL_DIR/run/watch.$iid.watermark"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"
  local out="$TEST_SKILL_DIR/liveness-delivery.log"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >"$out" 2>/dev/null &
  local w=$!
  # Wait for the watermark file, not just the pidfile: the pidfile is written
  # early (before the subscription is resolved and LAST is seeded), so sending a
  # message right after it appears would race the seed and the row would land at
  # or below the initial watermark and never be "new". The watermark file is
  # written once the watcher is ready to receive.
  _wait_for_file "$wm"
  [ -f "$pf" ]

  bash "$SCRIPTS/send.sh" team bob alice "M1-delivered" >/dev/null
  _wait_for_file_contains "$out" "M1-delivered"
  local first_id="$(_max_message_id)"

  # Owning session dies (reap it so kill -0 reports gone, not a zombie), then a
  # newer row arrives. The liveness guard runs before the DB poll, so the watcher
  # exits before it could deliver or watermark M2.
  kill "$sesspid" 2>/dev/null || true
  wait "$sesspid" 2>/dev/null || true
  bash "$SCRIPTS/send.sh" team bob alice "M2-undelivered" >/dev/null
  local second_id="$(_max_message_id)"

  _wait_for_missing "$pf" || { kill "$w" 2>/dev/null || true; false; }
  run kill -0 "$w"; [ "$status" -ne 0 ]
  [ "$first_id" != "$second_id" ]
  [ "$(cat "$wm")" = "$first_id" ]
  ! grep -q "M2-undelivered" "$out"
}

@test "watch: closed stdout exits without advancing the watermark" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-stdout-closed"
  local iid="$(_iid "$sid")"
  local wm="$TEST_SKILL_DIR/run/watch.$iid.watermark"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    1>&- 2>/dev/null &
  local w=$!

  _wait_for_file "$wm"
  [ -f "$pf" ]
  local initial="$(cat "$wm")"

  bash "$SCRIPTS/send.sh" team bob alice "M-after-closed-stdout" >/dev/null

  _wait_for_missing "$pf" || {
    kill "$w" 2>/dev/null || true
    wait "$w" 2>/dev/null || true
    false
  }
  wait "$w" 2>/dev/null || true

  [ "$(cat "$wm")" = "$initial" ]

  run_watcher_for "$sid" "$TEST_SKILL_DIR/closed-redelivery.log" 2
  grep -q "M-after-closed-stdout" "$TEST_SKILL_DIR/closed-redelivery.log"
}

@test "session-end: removes the session watermark file" {
  # Key the watermark under the same instance id session-end will derive.
  local wm="$TEST_SKILL_DIR/run/watch.$(_iid sess-end).watermark"
  mkdir -p "$TEST_SKILL_DIR/run"
  echo 5 > "$wm"
  printf '{"session_id":"sess-end"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  [ ! -f "$wm" ]
}

@test "watch: actas-mode watcher creates a ready sentinel and removes it on exit" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-ready" "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
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
    >/dev/null 2>&1 &
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
    >/dev/null 2>&1 &
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

@test "session-start: GCs stale watermark/ready but keeps live ones" {
  skip_on_windows "watcher live-owner liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  # Stale (owner has no live cc-instance).
  echo 5 > "$TEST_SKILL_DIR/run/watch.deadsid.watermark"
  echo deadsid > "$TEST_SKILL_DIR/run/ready.team__ghost"
  # Live owner.
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  echo 7 > "$TEST_SKILL_DIR/run/watch.LIVESID.watermark"
  echo LIVESID > "$TEST_SKILL_DIR/run/ready.team__live"

  printf '{"session_id":"somesess"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ ! -f "$TEST_SKILL_DIR/run/watch.deadsid.watermark" ]
  [ ! -f "$TEST_SKILL_DIR/run/ready.team__ghost" ]
  [ -f "$TEST_SKILL_DIR/run/watch.LIVESID.watermark" ]
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

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "shared.$sp1" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
  local w1=$!
  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "shared.$sp2" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
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

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
  local w1=$!
  _wait_pidfile "$pf" "$w1"

  AGMSG_WATCH_INTERVAL=5 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >/dev/null 2>&1 3>&- &
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
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-hc" "$PROJ" claude-code >"$out" 2>/dev/null &
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
@test "watch: empty session_id gets a generated fallback instead of a Usage error (#236)" {
  local out="$BATS_TEST_TMPDIR/empty-sid.out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "" "$PROJ" claude-code alice >"$out" 2>&1 &
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
