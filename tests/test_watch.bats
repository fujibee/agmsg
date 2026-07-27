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
  # Never inherit real herdr env from the test runner to prevent accidental
  # pane close on ctrl:despawn.
  unset HERDR_PANE_ID HERDR_ENV
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
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- &
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

@test "watch: restart delivers messages that arrived while the watcher was down" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-restart"

  # First watcher: fresh session, takes its mark at MAX(id)=0, then streams M1.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out1.log" 2>/dev/null 3>&- &
  local w1=$!
  # The watermark file appears as soon as the mark is taken, which is the
  # condition the old fixed 1.5s was standing in for.
  wait_for_file "$TEST_SKILL_DIR/run/watch.$(_iid "$sid").watermark"
  bash "$SCRIPTS/send.sh" team bob alice "M1-before-stop" >/dev/null
  local m1_id="$(_max_message_id)"
  wait_for_file_contains "$TEST_SKILL_DIR/out1.log" "M1-before-stop"
  # Kill only once the watermark has been PERSISTED past M1. The stdout line is
  # not enough: the watcher writes the line first and the mark after, so killing
  # on the line alone can lose the mark and make the restart re-deliver M1 —
  # exactly what this test denies. Waiting for the observable event is not the
  # same as waiting for the durable one.
  wait_for_file_is "$TEST_SKILL_DIR/run/watch.$(_iid "$sid").watermark" "$m1_id"
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
    >"$TEST_SKILL_DIR/fresh.log" 2>/dev/null 3>&- &
  local w=$!
  wait_for_file "$TEST_SKILL_DIR/run/watch.$(_iid "sess-fresh").watermark"
  bash "$SCRIPTS/send.sh" team bob alice "M-live" >/dev/null
  # M-live has a higher id than M0-history, so once it has been streamed the
  # watcher has passed the history row too — which is what makes the "history
  # is not replayed" assertion below meaningful rather than merely untimed.
  wait_for_file_contains "$TEST_SKILL_DIR/fresh.log" "M-live"
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
  local sesspid; sleep 600 3>&- & sesspid=$!
  local iid="sess-liveness.$sesspid"
  local wm="$TEST_SKILL_DIR/run/watch.$iid.watermark"
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"
  local out="$TEST_SKILL_DIR/liveness-delivery.log"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$iid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- &
  local w=$!
  # Wait for the watermark file, not just the pidfile: the pidfile is written
  # early (before the subscription is resolved and LAST is seeded), so sending a
  # message right after it appears would race the seed and the row would land at
  # or below the initial watermark and never be "new". The watermark file is
  # written once the watcher is ready to receive.
  wait_for_file "$wm"
  [ -f "$pf" ]

  bash "$SCRIPTS/send.sh" team bob alice "M1-delivered" >/dev/null
  wait_for_file_contains "$out" "M1-delivered"
  local first_id="$(_max_message_id)"

  # Owning session dies (reap it so kill -0 reports gone, not a zombie), then a
  # newer row arrives. The liveness guard runs before the DB poll, so the watcher
  # exits before it could deliver or watermark M2.
  kill "$sesspid" 2>/dev/null || true
  wait "$sesspid" 2>/dev/null || true
  bash "$SCRIPTS/send.sh" team bob alice "M2-undelivered" >/dev/null
  local second_id="$(_max_message_id)"

  wait_for_missing "$pf" || { kill "$w" 2>/dev/null || true; false; }
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
    1>&- 2>/dev/null 3>&- &
  local w=$!

  wait_for_file "$wm"
  [ -f "$pf" ]
  local initial="$(cat "$wm")"

  bash "$SCRIPTS/send.sh" team bob alice "M-after-closed-stdout" >/dev/null

  wait_for_missing "$pf" || {
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
    >/dev/null 2>&1 3>&- &
  local w=$!
  # Wait for the watcher to attach and signal readiness.
  local i
  for i in $(seq 1 50); do
    [ -e "$ready" ] && break
    sleep 0.1
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
    >/dev/null 2>&1 3>&- &
  local w=$! i
  for i in $(seq 1 50); do [ -e "$ready" ] && break; sleep 0.1; done
  # watch.sh stamps the instance id (composite under an agent ancestor).
  [ "$(cat "$ready")" = "$(_iid sess-own)" ]
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
}

@test "watch: cleanup leaves a sentinel that a successor session re-owned" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-old" "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local w=$! i
  for i in $(seq 1 50); do [ -e "$ready" ] && break; sleep 0.1; done
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
    >/dev/null 2>&1 3>&- &
  local wpid=$!

  # Resolve the instance id session-start.sh will compute for "sess1".
  local iid
  iid=$(_iid "sess1")
  local pf="$TEST_SKILL_DIR/run/watch.$iid.pid"
  wait_for_file "$pf"

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
  local sp1 sp2; sleep 600 3>&- & sp1=$!; sleep 600 3>&- & sp2=$!
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
  local sesspid; sleep 600 3>&- & sesspid=$!
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
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-hc" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- &
  local pid=$!
  # Stays a fixed sleep, deliberately: the assertion is that NOTHING further is
  # emitted, and there is no event to poll for when the expected outcome is the
  # absence of one. Must stay > one poll interval.
  sleep 2
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
# consumer closed and later messages were dropped while the watermark advanced
# past them. With the watcher streaming normally (no downstream truncation), a
# burst of N>5 consecutive messages must ALL be delivered.
@test "watch: delivers a burst of 8 consecutive messages without loss (#245)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-burst"
  local out="$TEST_SKILL_DIR/burst.log"
  local wm="$TEST_SKILL_DIR/run/watch.$(_iid "$sid").watermark"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null 3>&- &
  local w=$!
  wait_for_file "$wm"          # ready to receive (watermark seeded)

  local n
  for n in 1 2 3 4 5 6 7 8; do
    bash "$SCRIPTS/send.sh" team bob alice "BURST-$n" >/dev/null
  done

  # Wait for the last one to arrive, then assert EVERY message is present.
  wait_for_file_contains "$out" "BURST-8" || { kill "$w" 2>/dev/null || true; false; }
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  for n in 1 2 3 4 5 6 7 8; do
    grep -q "BURST-$n" "$out"
  done
}

@test "watch: empty session_id gets a generated fallback instead of a Usage error (#236)" {
  local out="$BATS_TEST_TMPDIR/empty-sid.out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "" "$PROJ" claude-code alice >"$out" 2>&1 3>&- &
  local pid=$!
  # A fallback id means a watch.agmsg-*.pid appears under run/ as the watcher arms.
  local i started=0
  for i in $(seq 1 50); do
    if ls "$TEST_SKILL_DIR/run"/watch.agmsg-*.pid >/dev/null 2>&1; then started=1; break; fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [ "$started" -eq 1 ]
  ! grep -q "Usage: watch.sh" "$out"
}

# Shifted-argument guard: some launcher shells (grok monitor tool re-eval) DROP
# a quoted-but-empty first argument entirely, so the watcher is invoked as
# `watch.sh <project> <type> <name>` — agent_type receives an agent name, the
# subscription resolves to zero pairs, and pre-guard the watcher kept polling
# silently while delivering nothing. It must fail loudly instead.
@test "watch: shifted arguments (agent name in the type slot) fail loudly instead of running with zero subscriptions" {
  run bash "$SCRIPTS/watch.sh" "$PROJ" claude-code alice
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: unknown agent type 'alice'"* ]]
  [[ "$output" == *"shifted"* ]]
  # It never armed: no pidfile was written for any derived id.
  ! ls "$TEST_SKILL_DIR/run"/watch.*.pid >/dev/null 2>&1
}

# A shifted THREE-argument launch (no active_name) leaves only two arguments.
# The old ${3:?} guard died on stderr, which a monitor tool consuming stdout
# never surfaces — the failure must land on stdout instead.
@test "watch: shifted three-arg launch (missing agent_type) fails loudly on stdout" {
  local out rc=0
  out="$(bash "$SCRIPTS/watch.sh" "$PROJ" claude-code 2>/dev/null)" || rc=$?
  [ "$rc" -ne 0 ]
  [[ "$out" == *"ERROR: watch.sh needs"* ]]
  [[ "$out" == *"shifted"* ]]
  ! ls "$TEST_SKILL_DIR/run"/watch.*.pid >/dev/null 2>&1
}

# A path-like value in the type slot must be rejected outright, not fed to the
# registry where it would concatenate into a filesystem path and could resolve
# to a builtin manifest (e.g. ../types/claude-code).
@test "watch: path-like agent type is rejected outright" {
  run bash "$SCRIPTS/watch.sh" sid-path "$PROJ" "../types/claude-code"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ERROR: invalid agent type"* ]]
  ! ls "$TEST_SKILL_DIR/run"/watch.*.pid >/dev/null 2>&1
}

# The caller-side companion of the guard above: command templates pass the
# sentinel "-" ("${GROK_SESSION_ID:--}") instead of a droppable empty string.
# watch.sh must fold "-" into the same generated-fallback path as "" (#236).
@test "watch: sentinel '-' session_id resolves like an empty one" {
  local out="$BATS_TEST_TMPDIR/dash-sid.out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" - "$PROJ" claude-code alice >"$out" 2>&1 3>&- &
  local pid=$!
  # Folded to empty => a generated fallback id, so a watch.agmsg-*.pid appears.
  local i started=0
  for i in $(seq 1 50); do
    if ls "$TEST_SKILL_DIR/run"/watch.agmsg-*.pid >/dev/null 2>&1; then started=1; break; fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  [ "$started" -eq 1 ]
  # No literal "-" session id leaked into the run dir key space.
  ! ls "$TEST_SKILL_DIR/run"/watch.-*.pid >/dev/null 2>&1
  ! grep -q "Usage: watch.sh" "$out"
  ! grep -q "ERROR: unknown agent type" "$out"
}

# read_at for the most recent message with the given body, empty if unread.
_read_at_for_body() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_sqlite "$(agmsg_db_path)" \
      "SELECT read_at FROM messages WHERE body='$1' ORDER BY id DESC LIMIT 1;" )
}


@test "watch: marks a delivered message's read_at so a later inbox.sh does not re-surface it" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local sid="sess-readat"
  local out="$TEST_SKILL_DIR/readat.log"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$out" 2>/dev/null 3>&- &
  local w=$!
  # Wait for the watcher to actually attach (watermark file appears) before
  # sending, instead of a fixed sleep — avoids flakiness on a slow/loaded CI
  # runner (2026-07-19 review finding).
  wait_for_file "$TEST_SKILL_DIR/run/watch.$(_iid "$sid").watermark" \
    || { kill "$w" 2>/dev/null || true; false; }
  bash "$SCRIPTS/send.sh" team bob alice "M-readat-check" >/dev/null

  # Delivered live...
  wait_for_file_contains "$out" "M-readat-check" \
    || { kill "$w" 2>/dev/null || true; false; }
  # ...and read_at follows shortly after delivery — poll instead of a fixed
  # sleep for the same flakiness reason.
  local i got=""
  for i in $(seq 1 50); do
    got="$(_read_at_for_body "M-readat-check")"
    [ -n "$got" ] && break
    sleep 0.1
  done
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  [ -n "$got" ]
  # A subsequent inbox.sh call must not report it as a new/unread message.
  ! bash "$SCRIPTS/inbox.sh" team alice | grep -q "M-readat-check"
}

@test "watch: a broad watcher does not mark read_at for a role with its own exclusive ready sentinel" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  # Simulate alice already having a live exclusive watcher elsewhere: the
  # sentinel's mere presence is the protocol (#108) — no live process needed
  # for this guard, which only checks the file (review finding, 2026-07-19).
  mkdir -p "$TEST_SKILL_DIR/run"
  touch "$TEST_SKILL_DIR/run/ready.team__alice"

  local sid="sess-broad-guard"
  local out="$TEST_SKILL_DIR/broad-guard.log"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$out" 2>/dev/null 3>&- &
  local w=$!
  wait_for_file "$TEST_SKILL_DIR/run/watch.$(_iid "$sid").watermark" \
    || { kill "$w" 2>/dev/null || true; false; }

  bash "$SCRIPTS/send.sh" team bob alice "M-broad-guard-alice" >/dev/null
  bash "$SCRIPTS/send.sh" team bob bob "M-broad-guard-bob" >/dev/null

  # Both stream through this broad watcher (PAIRS covers every project role)...
  wait_for_file_contains "$out" "M-broad-guard-bob" \
    || { kill "$w" 2>/dev/null || true; false; }

  # ...but only bob's (no exclusive owner) gets marked read by this watcher.
  local i got_bob=""
  for i in $(seq 1 50); do
    got_bob="$(_read_at_for_body "M-broad-guard-bob")"
    [ -n "$got_bob" ] && break
    sleep 0.1
  done
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  [ -n "$got_bob" ]
  # Alice's exclusive ready sentinel means this broad watcher must defer —
  # it must NOT have consumed the read state that alice's own watcher owns.
  [ -z "$(_read_at_for_body "M-broad-guard-alice")" ]
}

# --- ctrl:despawn, herdr placement ---
#
# The watcher may only close a herdr pane that agmsg itself placed. HERDR_* is
# inherited by every descendant of a pane, so "a pane id is in the environment"
# proves nothing about ownership — a watcher started by hand inside herdr, or
# by a test suite, carries the HOST pane's id. Acting on that closes the host,
# which is exactly what happened to a real session while this branch was being
# reviewed. The gate is HERDR_ENV=1 plus a placement record naming this pane.

# Stub `herdr` into a private bin dir; every call is appended to $2.
_stub_herdr() {
  local stub_bin="$1" log="$2"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/herdr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
echo '{"id":"cli:pane:close","result":{"type":"ok"}}'
STUB
  chmod +x "$stub_bin/herdr"
}

# Record a herdr placement for team/alice, as spawn would have written it.
_record_herdr_placement() {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'herdr:%s\t%s\tclaude-code\n' "$1" "$PROJ" \
    > "$TEST_SKILL_DIR/run/spawn.team__alice"
}

# Launch an actas watcher for alice under a synthetic herdr environment, send
# ctrl:despawn, and wait for it to finish. Extra env assignments come from $@.
_despawn_under_herdr() {
  local stub_bin="$1" errlog="$2"; shift 2
  setup_live_owner "$TEST_SKILL_DIR/run" sess-herdr
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE "$@" PATH="$stub_bin:$PATH" \
    bash "$SCRIPTS/watch.sh" sess-herdr "$PROJ" claude-code alice \
    >/dev/null 2>"$errlog" 3>&- &
  local wpid=$! i
  for i in $(seq 1 50); do
    [ -e "$TEST_SKILL_DIR/run/ready.team__alice" ] && break; sleep 0.1
  done
  [ -e "$TEST_SKILL_DIR/run/ready.team__alice" ]

  bash "$SCRIPTS/send.sh" team bob alice "ctrl:despawn" >/dev/null
  for i in $(seq 1 50); do
    kill -0 "$wpid" 2>/dev/null || break; sleep 0.1
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

@test "watch: ctrl:despawn closes the herdr pane agmsg placed for this role" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  local herdr_log="$TEST_SKILL_DIR/herdr-calls.log"
  local errlog="$TEST_SKILL_DIR/herdr-stderr.log"
  _stub_herdr "$stub_bin" "$herdr_log"

  # spawn recorded this pane as alice's placement, so the watcher owns it.
  _record_herdr_placement wC:p42

  _despawn_under_herdr "$stub_bin" "$errlog" HERDR_PANE_ID="wC:p42" HERDR_ENV=1

  [ -f "$herdr_log" ]
  grep -q "pane close wC:p42" "$herdr_log"
}

@test "watch: ctrl:despawn does NOT close a herdr pane the watcher merely inherited (no placement record)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  local herdr_log="$TEST_SKILL_DIR/herdr-calls.log"
  local errlog="$TEST_SKILL_DIR/herdr-stderr.log"
  _stub_herdr "$stub_bin" "$herdr_log"

  # No spawn record: this role was never placed by agmsg, so wC:p42 is the
  # host pane the watcher happened to start in.
  [ ! -f "$TEST_SKILL_DIR/run/spawn.team__alice" ]

  _despawn_under_herdr "$stub_bin" "$errlog" HERDR_PANE_ID="wC:p42" HERDR_ENV=1

  [ ! -f "$herdr_log" ] || ! grep -q "pane close" "$herdr_log"
  grep -q "close this window manually" "$errlog"
}

@test "watch: ctrl:despawn does NOT close a herdr pane when the placement record names a different pane" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  local herdr_log="$TEST_SKILL_DIR/herdr-calls.log"
  local errlog="$TEST_SKILL_DIR/herdr-stderr.log"
  _stub_herdr "$stub_bin" "$herdr_log"

  # agmsg placed alice in a DIFFERENT pane; this watcher is sitting somewhere
  # else, so it must not close either one.
  _record_herdr_placement wC:pOTHER

  _despawn_under_herdr "$stub_bin" "$errlog" HERDR_PANE_ID="wC:p42" HERDR_ENV=1

  [ ! -f "$herdr_log" ] || ! grep -q "pane close" "$herdr_log"
  grep -q "close this window manually" "$errlog"
}

@test "watch: ctrl:despawn does NOT close a herdr pane when HERDR_ENV is unset (stale id only)" {
  skip_on_windows "watcher background launch under Git Bash (#182)"
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  local herdr_log="$TEST_SKILL_DIR/herdr-calls.log"
  local errlog="$TEST_SKILL_DIR/herdr-stderr.log"
  _stub_herdr "$stub_bin" "$herdr_log"

  # Record matches, but the watcher is not running under herdr — only a stale
  # HERDR_PANE_ID survived in the environment. spawn requires HERDR_ENV=1 to
  # treat a process as herdr-hosted; the close path must agree.
  _record_herdr_placement wC:p42

  _despawn_under_herdr "$stub_bin" "$errlog" HERDR_PANE_ID="wC:p42"

  [ ! -f "$herdr_log" ] || ! grep -q "pane close" "$herdr_log"
  grep -q "close this window manually" "$errlog"
}
