#!/usr/bin/env bats

# Unit tests for codex-bridge-launcher.sh thread resolution (#350).
# The launcher must bind the bridge to the role's RECORDED codex thread instead
# of the app-server's ambiguous "loaded" thread (which a co-resident codex thread
# in the same cwd could otherwise capture). A mock bridge records the --thread
# the launcher passes.
#
# The mock replaces codex-bridge.js itself (the file the launcher's DEFAULT
# bridge_run resolves to) rather than being swapped in via AGMSG_CODEX_BRIDGE_CMD
# (#595). AGMSG_CODEX_BRIDGE_CMD is a real, documented user-facing override (a
# custom bridge wrapper), and codex-bridge-launcher.sh takes a materially
# different code path for it (a synchronous wait on the launched process) than
# for its default codex-bridge.js path -- exercising that override path here
# tested a branch these tests have no interest in and does not run for anyone
# using agmsg without a custom wrapper, and its wait, sized for a real bridge
# process's lifetime, raced these tests' shorter deregistration-response
# assertions. Only tests/ files change here: setup_test_env already copies the
# whole scripts/ tree into an isolated $TEST_SKILL_DIR per test, so overwriting
# codex-bridge.js below mutates only that disposable copy.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export PROJ="$TEST_SKILL_DIR/proj"; mkdir -p "$PROJ"
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null

  export CAPTURE="$TEST_SKILL_DIR/thread-capture.txt"
  # A leaked AGMSG_CODEX_BRIDGE_CMD from the ambient environment (not this
  # file, which no longer sets it) would silently put the launcher back on the
  # override code path this suite is no longer testing -- unset it explicitly
  # rather than relying on it merely being absent here (#595).
  unset AGMSG_CODEX_BRIDGE_CMD
  [ -z "${AGMSG_CODEX_BRIDGE_CMD:-}" ]
  # Overwrite the (already-isolated, per-test) copy of codex-bridge.js with a
  # mock that records its argv. AGMSG_NODE is the documented override for the
  # Node binary codex-bridge-launcher.sh resolves this file through; pointing
  # it at bash makes bash the interpreter for this file regardless of its .js
  # name, so the launcher's default (no-custom-wrapper) path runs unmodified.
  # Mock bridge: records argv AND publishes the same per-PID identity lease the
  # real bridge does (so the reaper, which reads leases, can find/spare it). All
  # of $CAPTURE / $SCRIPTS / $RUN_DIR come from the environment it inherits.
  cat > "$SCRIPTS/drivers/types/codex/codex-bridge.js" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CAPTURE"
source "$SCRIPTS/lib/hash.sh" 2>/dev/null || true
_proj=""; _parr=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --project) _proj="$2"; shift 2 ;;
    --pair) _parr+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
_lease="$RUN_DIR/codex-bridge-lease.$$"
# Start token exactly as codex-bridge-launcher.sh _start_token computes it: /proc
# field 22 where available, else a trimmed `ps -o lstart=`.
if [ -r "/proc/$$/stat" ]; then
  _s="$(cat "/proc/$$/stat")"; _r="${_s##*)}"; read -ra _a <<< "$_r"
  _start="${_a[19]}"; _ssrc=proc
else
  _start="$(ps -o lstart= -p $$)"
  _start="${_start#"${_start%%[![:space:]]*}"}"; _start="${_start%"${_start##*[![:space:]]}"}"
  _ssrc=ps
fi
_ph=""
for _pv in "${_parr[@]}"; do _ph="$_ph$(printf '%s' "$_pv" | agmsg_sha1)
"; done
_pairs_hash="$(printf '%s' "$(printf '%s' "$_ph" | LC_ALL=C sort | sed '/^$/d')" | agmsg_sha1)"
{ printf 'v=1\nproject=%s\npairs=%s\nhost=%s\npid=%s\nstart=%s\nstartsrc=%s\n' \
    "$(printf '%s' "$_proj" | agmsg_sha1)" \
    "$_pairs_hash" \
    "$(hostname)" "$$" "$_start" "$_ssrc" ; } > "$_lease.tmp" && mv "$_lease.tmp" "$_lease"
trap 'rm -f "$_lease"' EXIT
[ -z "${MOCK_BRIDGE_SLEEP:-}" ] || sleep "$MOCK_BRIDGE_SLEEP"
exit 0
EOF
  chmod +x "$SCRIPTS/drivers/types/codex/codex-bridge.js"
  export AGMSG_NODE="$(command -v bash)"
  export LAUNCHER="$SCRIPTS/drivers/types/codex/codex-bridge-launcher.sh"
}

# PIDs of live per-role child launchers for this test's project: any process
# whose argv contains both LAUNCHER and PROJ, one line per pid. Not scoped to a
# single role name -- teardown must reap every role's child a test spawned
# (e.g. "the identity cache still sees a role added mid-loop" joins a second
# role, "bob", mid-test), unlike count_child_launchers below, which measures
# one specific role on purpose. This also does not dedupe transient
# command-substitution subshells by parent pid -- for killing that distinction
# does not matter, signaling and waiting on a subshell that has already
# exited on its own is a harmless no-op.
_launcher_child_pids() {
  ps -Ao pid=,args= 2>/dev/null | grep -F "$LAUNCHER" | grep -F "$PROJ" | awk '{print $1}'
}

# PIDs of bridge processes this test's launchers started. The bridge itself
# runs as "bash codex-bridge.js ..." -- its argv never contains LAUNCHER, so
# _launcher_child_pids cannot see it, and a child launcher's EXIT trap only
# releases its runtime lock; it does not kill a bridge it already nohup'd. Read
# from pidfiles instead, which live under this test's own $RUN_DIR ($TEST_
# SKILL_DIR is unique per test), so this cannot reach another test's process.
_launcher_bridge_pids() {
  local f
  for f in "$RUN_DIR"/codex-bridge.*.pid; do
    [ -f "$f" ] || continue
    cat "$f" 2>/dev/null
  done
}

# A test's own kill/wait sequence reaches the dispatcher and the short-lived
# parent it was handed, but a per-role child (nohup'd, independent of both) and
# the bridge process it launched are not direct children of anything a test
# holds a pid for, so they are not swept by "kill $dispatcher; kill $parent"
# alone -- the child only self-exits once it next notices its parent is gone,
# and never kills its own bridge except when it does so as part of noticing
# deregistration. Snapshot the pid set once, signal all of it, then wait for
# all of it, rather than interleaving kill/wait per pid against a ps/pidfile
# view that can keep changing underneath. Reaping here, and WAITING for the
# reap rather than just signaling and moving on, is what keeps
# teardown_test_env's rm -rf from racing a process still touching this test's
# $TEST_SKILL_DIR (#595/#615).
teardown() {
  local pid pids
  pids="$(_launcher_child_pids; _launcher_bridge_pids)"
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in $pids; do
    wait_for_pid_exit "$pid" || true
  done
  teardown_test_env
}

# Write a role-session record (team, agent) -> thread for a project.
put_record() {
  SKILL_DIR="$TEST_SKILL_DIR" bash -c \
    'source "$1/lib/role-session.sh"; agmsg_role_session_record "$2" "$3" "$4" "$5" "$6"' \
    _ "$SCRIPTS" "$@"
}

write_request() {
  local thread="$1" hash
  hash=$(SKILL_DIR="$TEST_SKILL_DIR" bash -c \
    'source "$1/lib/hash.sh"; printf "%s" "$2" | agmsg_sha1' _ "$SCRIPTS" "$PROJ")
  printf 'codex\t%s\tws://127.0.0.1:1\n' "$thread" > "$RUN_DIR/codex-bridge-request.$hash"
}

# Drive the launcher against a short-lived parent, blocking until it exits. fd 3
# is closed on the backgrounded parent and the launcher so a stray descriptor
# can't keep bats from exiting on macOS (#bats-fd3).
run_launcher() {
  sleep 6 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  # The launcher starts the mock through nohup. Its bound-thread metadata is
  # written synchronously, but the mock's capture can land just after the
  # parent exits, especially now that a per-role child launcher is involved.
  local i
  for i in {1..30}; do
    [ -f "$CAPTURE" ] && break
    sleep 0.1
  done
}

@test "launcher: binds the recorded thread when the record's project matches (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ -f "$CAPTURE" ]
  grep -q -- "--thread rec-thread-1" "$CAPTURE"
  ! grep -q -- "--thread loaded" "$CAPTURE"
}

@test "launcher: passes the active storage override as a workspace root" {
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/custom-store"
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher

  grep -q -- "--workspace-root $AGMSG_STORAGE_PATH" "$CAPTURE"
  ! grep -q -- "--workspace-root $TEST_SKILL_DIR/db" "$CAPTURE"
}

@test "launcher: leaves a role without a recorded live thread unsubscribed (#150)" {
  run_launcher
  [ ! -f "$CAPTURE" ]
}

@test "launcher: leaves a role with a foreign-project record unsubscribed (#150)" {
  put_record team alice other-thread "/some/other/project" codex
  run_launcher
  [ ! -f "$CAPTURE" ]
}

@test "launcher: writes the bound-thread file so a later launcher can rebind (#350)" {
  put_record team alice rec-thread-1 "$PROJ" codex
  run_launcher
  [ "$(cat "$RUN_DIR/codex-bridge.team.alice.thread" 2>/dev/null)" = "rec-thread-1" ]
}

@test "launcher: replaces a stale role pidfile with the spawned bridge pid" {
  put_record team alice rec-thread-1 "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=3
  printf '%s\n' 99999999 > "$RUN_DIR/codex-bridge.team.alice.pid"
  run_launcher 3>&- & local driver_pid=$!

  local i recorded=""
  for i in {1..50}; do
    recorded="$(cat "$RUN_DIR/codex-bridge.team.alice.pid" 2>/dev/null || true)"
    [ -n "$recorded" ] && [ "$recorded" != 99999999 ] && break
    sleep 0.1
  done
  [ -n "$recorded" ]
  [ "$recorded" != 99999999 ]
  kill -0 "$recorded"

  wait "$driver_pid" 2>/dev/null || true
}

@test "launcher: starts one bridge per recorded role and thread (#150 phase 2)" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  put_record team bob thread-bob "$PROJ" codex
  run_launcher

  local i lines=0
  for i in {1..30}; do
    if [ -f "$CAPTURE" ]; then
      lines=$(wc -l < "$CAPTURE" | tr -d ' ')
    fi
    [ "$lines" -ge 2 ] && break
    sleep 0.1
  done
  [ "$lines" -ge 2 ]
  grep -q -- $'--pair team\talice --thread thread-alice' "$CAPTURE"
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"
}

@test "launcher: only one dispatcher runs per project" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=8
  sleep 10 3>&- & local parent_a=$!
  sleep 10 3>&- & local parent_b=$!

  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local launcher_a=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local launcher_b=$!

  local i
  for i in {1..50}; do
    [ -f "$CAPTURE" ] && break
    sleep 0.1
  done
  [ -f "$CAPTURE" ]
  [ "$(wc -l < "$CAPTURE" | tr -d ' ')" -eq 1 ]

  wait "$launcher_a" 2>/dev/null || true
  wait "$launcher_b" 2>/dev/null || true
  wait "$parent_a" 2>/dev/null || true
  wait "$parent_b" 2>/dev/null || true
}

@test "launcher: stale dispatcher reclamation remains singleton under contention" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=8
  local hash lock_db
  hash=$(printf '%s' "$PROJ" | bash -c 'source "$1"; agmsg_sha1' _ "$SCRIPTS/lib/hash.sh")
  lock_db="$TEST_SKILL_DIR/db/messages.db"
  sqlite3 "$lock_db" "CREATE TABLE locks(resource TEXT PRIMARY KEY, owner_pid INTEGER NOT NULL, acquired_at TEXT NOT NULL); INSERT INTO locks VALUES('codex-dispatcher:$hash', 99999999, datetime('now'));"
  # A crash from the former two-directory implementation can leave this behind.
  # The transactional lock protocol must not depend on that legacy reaper.
  mkdir "$RUN_DIR/codex-bridge-dispatcher.$hash.reap"
  export AGMSG_TEST_DISPATCHER_STALE_BARRIER="$TEST_SKILL_DIR/stale-observed"
  sleep 10 3>&- & local parent_a=$!
  sleep 10 3>&- & local parent_b=$!

  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local launcher_a=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local launcher_b=$!

  local i
  for i in {1..50}; do
    [ -f "$CAPTURE" ] && break
    sleep 0.1
  done
  [ -f "$CAPTURE" ]
  [ "$(wc -l < "$CAPTURE" | tr -d ' ')" -eq 1 ]

  wait "$launcher_a" 2>/dev/null || true
  wait "$launcher_b" 2>/dev/null || true
  wait "$parent_a" 2>/dev/null || true
  wait "$parent_b" 2>/dev/null || true
}

@test "launcher: project request thread never overrides per-role recorded threads (#150 phase 2)" {
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  put_record team bob thread-bob "$PROJ" codex
  write_request thread-bob
  run_launcher

  grep -q -- $'--pair team\talice --thread thread-alice' "$CAPTURE"
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"
  ! grep -q -- $'--pair team\talice --thread thread-bob' "$CAPTURE"
}

@test "launcher: role record update keeps child scoped to the same pair" {
  put_record team alice thread-before "$PROJ" codex
  sleep 6 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" $'team\talice' >/dev/null 2>&1 3>&- &
  local launcher_pid=$!
  local i
  for i in {1..50}; do
    grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE"
  put_record team alice thread-after "$PROJ" codex
  wait "$launcher_pid" 2>/dev/null || true
  wait "$p" 2>/dev/null || true

  grep -q -- $'--pair team\talice --thread thread-before' "$CAPTURE"
  grep -q -- $'--pair team\talice --thread thread-after' "$CAPTURE"
  ! grep -q -- '--pair team bob' "$CAPTURE"
}

# Count live role-child launcher processes for this test's project. A child is
# distinguished from a dispatcher by carrying the role pair as its 5th argument;
# match on the agent name rather than the whole pair, because macOS ps renders
# the tab inside that argument as the escape sequence \011, not a literal tab.
#
# Only processes whose parent is not itself a match are counted. Every command
# substitution the launcher runs forks a subshell that inherits the launcher's
# argv, so those subshells are indistinguishable from a real child by command
# line alone -- a naive count reads 3 where there is one child, depending purely
# on when the sample lands. Filtering on ppid counts independent children, which
# is the property these tests are actually about.
count_child_launchers() {
  ps -Ao pid=,ppid=,args= 2>/dev/null \
    | grep -F "$LAUNCHER" \
    | grep -F "$PROJ" \
    | grep alice \
    | awk '{ pid[$1] = 1; parent[$1] = $2 }
           END { n = 0; for (p in pid) if (!(parent[p] in pid)) n++; print n }'
}

# Block until the child count settles on <n>, then return it. Spawn and exit are
# both asynchronous, so sampling on the first sighting races the transition.
wait_for_child_count() {
  local want="$1" i
  for i in {1..100}; do
    [ "$(count_child_launchers)" -eq "$want" ] && break
    sleep 0.1
  done
  count_child_launchers
}

@test "launcher: a replacement dispatcher does not double the role children (#485)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=12
  sleep 14 3>&- & local parent_a=$!
  sleep 14 3>&- & local parent_b=$!

  # Dispatcher A spawns the role child, which is nohup'd and outlives A.
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_a" >/dev/null 2>&1 3>&- &
  local dispatcher_a=$!
  [ "$(wait_for_child_count 1)" -eq 1 ]

  # SIGKILL is what a pane teardown effectively does to a dispatcher that never
  # trapped the signal: the EXIT trap does not run, so the lock row is left
  # behind owned by a dead pid, exactly the state a replacement dispatcher hits.
  kill -9 "$dispatcher_a" 2>/dev/null || true
  wait "$dispatcher_a" 2>/dev/null || true
  [ "$(wait_for_child_count 1)" -eq 1 ]

  # Dispatcher B reclaims the stale lock and, with an empty known_pairs, spawns
  # a second child for the SAME pair. Without the per-role lock that child would
  # live on and poll forever alongside the first.
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent_b" >/dev/null 2>&1 3>&- &
  local dispatcher_b=$!
  # The duplicate is spawned and then has to lose the lock race; settle on the
  # steady state rather than on whichever side of that transition we land.
  [ "$(wait_for_child_count 1)" -eq 1 ]
  sleep 1
  [ "$(count_child_launchers)" -eq 1 ]

  kill "$dispatcher_b" 2>/dev/null || true
  wait "$dispatcher_b" 2>/dev/null || true
  kill "$parent_a" "$parent_b" 2>/dev/null || true
  wait "$parent_a" 2>/dev/null || true
  wait "$parent_b" 2>/dev/null || true
}

@test "launcher: a re-registered role gets a fresh child after deregistration (#485)" {
  put_record team alice thread-alice "$PROJ" codex
  # A custom bridge command is waited synchronously by its role launcher. Keep
  # the mock lifetime below wait_for_child_count's 10-second ceiling so this
  # test measures deregistration, not the intentionally blocking test adapter.
  export MOCK_BRIDGE_SLEEP=2
  sleep 20 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!
  [ "$(wait_for_child_count 1)" -eq 1 ]

  # Deregistering the role retires its child through the existing re-exec path.
  run bash "$SCRIPTS/leave.sh" team alice
  [ "$status" -eq 0 ]
  [ "$(wait_for_child_count 0)" -eq 0 ]

  # The dispatcher must have forgotten the pair. Otherwise known_pairs still
  # lists it, the re-spawn is suppressed, and the role silently never gets a
  # bridge again for the rest of the app-server's life.
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  put_record team alice thread-alice "$PROJ" codex
  [ "$(wait_for_child_count 1)" -eq 1 ]

  kill "$dispatcher" 2>/dev/null || true
  wait "$dispatcher" 2>/dev/null || true
  kill "$parent" 2>/dev/null || true
  wait "$parent" 2>/dev/null || true
}

@test "launcher: the identity cache still sees a role added mid-loop (#466)" {
  # The poll no longer re-runs identities.sh every tick; it serves a cache
  # guarded on the team configs' mtimes. This is the test that fails if that
  # guard never invalidates: a role joined while the dispatcher is already
  # looping has to be picked up anyway.
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=20
  sleep 25 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- &
  local dispatcher=$!
  local i
  for i in {1..80}; do
    grep -q -- $'--pair team\talice' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- $'--pair team\talice' "$CAPTURE"

  # Let the loop settle into its backed-off steady state before changing
  # anything, so this exercises a cache hit being invalidated rather than a
  # loop that happened to still be resolving every tick.
  sleep 3
  bash "$SCRIPTS/join.sh" team bob codex "$PROJ" >/dev/null
  put_record team bob thread-bob "$PROJ" codex
  for i in {1..100}; do
    grep -q -- $'--pair team\tbob' "$CAPTURE" 2>/dev/null && break
    sleep 0.1
  done
  grep -q -- $'--pair team\tbob --thread thread-bob' "$CAPTURE"

  kill "$dispatcher" 2>/dev/null || true
  wait "$dispatcher" 2>/dev/null || true
  kill "$parent" 2>/dev/null || true
  wait "$parent" 2>/dev/null || true
}

# --- which pid space (#567) ---

@test "launcher: starts the bridge when tasklist cannot see the parent (#567)" {
  skip_on_windows "stubs tasklist to model Git Bash; the real one is authoritative there"
  # Every pid the launcher waits on -- PARENT_PID, LIFETIME_PID, the dispatcher
  # lock owner -- is minted by $! or $$ in one of these shells, so under Git Bash
  # it is numbered in the MSYS space and `tasklist` has no record of it. A probe
  # that asks tasklist calls the live parent dead: the startup loop is never
  # entered, the supervision loop never runs, and no bridge is ever launched.
  # Measured on our own Windows runner -- $$, $! and a pid read back from a
  # pidfile all report tasklist_hits=0 while kill -0 answers yes.
  local stubdir="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stubdir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stubdir/tasklist"
  chmod +x "$stubdir/tasklist"

  put_record team alice thread-msys "$PROJ" codex

  sleep 6 3>&- & local p=$!
  MSYSTEM=MINGW64 PATH="$stubdir:$PATH" \
    bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  local i
  for i in {1..30}; do [ -f "$CAPTURE" ] && break; sleep 0.1; done

  # A bridge was launched at all -- this is what the whole class costs on Windows.
  [ -f "$CAPTURE" ] || { echo "no bridge was started under a blind tasklist"; false; }
  grep -q -- '--thread thread-msys' "$CAPTURE"
}

@test "launcher: windows-native starts the bridge (#567)" {
  skip_unless_windows "the point is the real tasklist and the real MSYS pid space"
  # The counterpart to codex-monitor's windows-native test, and the half #582
  # does NOT fix: reaching the bridged handoff is not the same as delivering a
  # message. PARENT_PID is codex-monitor.sh's own $$, so on Git Bash the loops
  # at :291 and :381 are asking tasklist about an MSYS pid -- false on the first
  # evaluation, which means neither loop turns over and no bridge is ever
  # started. Real tasklist, no stub.
  put_record team alice thread-win "$PROJ" codex

  sleep 6 3>&- & local p=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$p" >/dev/null 2>&1 3>&- || true
  wait "$p" 2>/dev/null || true
  local i
  for i in {1..30}; do [ -f "$CAPTURE" ] && break; sleep 0.1; done

  [ -f "$CAPTURE" ] || { echo "no bridge was started on native Windows"; false; }
  grep -q -- '--thread thread-win' "$CAPTURE"
}

# --- #937: reap a same-(project,role) orphan via its per-PID identity lease ---

_count_role_bridges() { # <project> <name>
  # Match the role name at a word boundary, not as a substring: "alice" must not
  # also count "alice2" (the survive tests turn on exactly that distinction), so a
  # trailing digit/letter excludes it. Names here are plain [a-z0-9] test tokens.
  ps -Ao pid=,args= 2>/dev/null | grep -F "codex-bridge.js" | grep -F -- "--project $1 " | grep -E "$2([^0-9A-Za-z]|\$)" | grep -c . | tr -d ' '
}
# Poll until this project's role-bridge count settles at <want>, then echo it --
# a fixed sleep before a point-in-time count races the reap-and-respawn.
_wait_role_count() { # <project> <name> <want>
  local i
  for i in {1..100}; do
    [ "$(_count_role_bridges "$1" "$2")" -eq "$3" ] && break
    sleep 0.1
  done
  _count_role_bridges "$1" "$2"
}
# Run the mock bridge directly for a given (project, pairs) so it publishes a
# lease of that identity and stays alive. Sets FAKE_PID (NOT via $(...) -- a
# background job in command substitution is killed when that subshell exits).
_spawn_fake() { # <project> <pair...>
  local proj="$1"; shift
  local args=(--project "$proj") pv
  for pv in "$@"; do args+=(--pair "$pv"); done
  MOCK_BRIDGE_SLEEP=25 bash "$SCRIPTS/drivers/types/codex/codex-bridge.js" "${args[@]}" 3>&- &
  FAKE_PID=$!
}

@test "launcher: reaps a same-(project,role) orphan the pidfile lost, converging to one (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  local i; for i in {1..80}; do [ "$(_count_role_bridges "$PROJ" alice)" -ge 1 ] && break; sleep 0.1; done
  [ "$(_count_role_bridges "$PROJ" alice)" -eq 1 ]
  rm -f "$RUN_DIR"/codex-bridge.*.pid
  [ "$(_wait_role_count "$PROJ" alice 1)" -eq 1 ]
  kill "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true
}

@test "launcher: a reap for one role leaves a same-project OTHER role alive (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  local tab; tab=$(printf '\t')
  _spawn_fake "$PROJ" "team${tab}bob"; local bob=$FAKE_PID
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  local i; for i in {1..80}; do [ "$(_count_role_bridges "$PROJ" alice)" -ge 1 ] && break; sleep 0.1; done
  rm -f "$RUN_DIR"/codex-bridge.*.pid
  [ "$(_wait_role_count "$PROJ" alice 1)" -eq 1 ]
  kill -0 "$bob"
  kill "$bob" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$bob" 2>/dev/null || true
}

@test "launcher: a reap for one project leaves the SAME role in another project alive (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  local tab; tab=$(printf '\t')
  _spawn_fake "$TEST_SKILL_DIR/other-proj" "team${tab}alice"; local other=$FAKE_PID
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  local i; for i in {1..80}; do [ "$(_count_role_bridges "$PROJ" alice)" -ge 1 ] && break; sleep 0.1; done
  rm -f "$RUN_DIR"/codex-bridge.*.pid
  [ "$(_wait_role_count "$PROJ" alice 1)" -eq 1 ]
  kill -0 "$other"
  kill "$other" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$other" 2>/dev/null || true
}

@test "launcher: a reap for role 'alice' does not sweep the prefix-colliding 'alice2' (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  local tab; tab=$(printf '\t')
  _spawn_fake "$PROJ" "team${tab}alice2"; local alice2=$FAKE_PID
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  local i; for i in {1..80}; do [ "$(_count_role_bridges "$PROJ" alice)" -ge 1 ] && break; sleep 0.1; done
  rm -f "$RUN_DIR"/codex-bridge.*.pid
  [ "$(_wait_role_count "$PROJ" alice 1)" -eq 1 ]
  kill -0 "$alice2"
  kill "$alice2" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$alice2" 2>/dev/null || true
}

@test "launcher: an alice reaper does not kill a bridge that also serves bob (pair superset) (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  local tab; tab=$(printf '\t')
  _spawn_fake "$PROJ" "team${tab}alice" "team${tab}bob"; local both=$FAKE_PID
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  local i; for i in {1..80}; do [ "$(_count_role_bridges "$PROJ" alice)" -ge 1 ] && break; sleep 0.1; done
  rm -f "$RUN_DIR"/codex-bridge.*.pid
  [ "$(_wait_role_count "$PROJ" alice 1)" -eq 1 ]
  # Its pair set is {alice,bob}, not {alice}: set inequality spares it.
  kill -0 "$both"
  kill "$both" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$both" 2>/dev/null || true
}

@test "launcher: a live bridge with no lease (legacy) is left alone, not killed (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  local tab; tab=$(printf '\t')
  # A same-(project,role) process that never published a lease -- an older bridge
  # build. Fail-open: no lease, no kill. Spawn it, then remove its lease.
  _spawn_fake "$PROJ" "team${tab}alice"; local legacy=$FAKE_PID
  local j; for j in {1..50}; do [ -f "$RUN_DIR/codex-bridge-lease.$legacy" ] && break; sleep 0.1; done
  rm -f "$RUN_DIR/codex-bridge-lease.$legacy"
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  sleep 3
  kill -0 "$legacy"
  kill "$legacy" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$legacy" 2>/dev/null || true
}

# --- #937 finding (4): the lease is the reaper's authority, so a broken one is a
# new failure surface. Every malformed/partial/foreign lease must fail CLOSED
# (no kill), asserted by a same-(project,alice) fake surviving the reaper. Each
# starts from the valid lease the mock published, then corrupts that one file. ---
_fake_alice_lease() { # sets FAKE_PID once its lease file exists
  local tab; tab=$(printf '\t')
  _spawn_fake "$PROJ" "team${tab}alice"
  local j; for j in {1..50}; do [ -f "$RUN_DIR/codex-bridge-lease.$FAKE_PID" ] && break; sleep 0.1; done
}

@test "launcher: a truncated lease (missing fields) is not killed, fail-closed (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  _fake_alice_lease; local victim=$FAKE_PID lease="$RUN_DIR/codex-bridge-lease.$FAKE_PID"
  head -3 "$lease" > "$lease.x"; mv "$lease.x" "$lease"
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  sleep 3
  kill -0 "$victim"
  kill "$victim" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$victim" 2>/dev/null || true
}

@test "launcher: a lease with a foreign host is not killed, fail-closed (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  _fake_alice_lease; local victim=$FAKE_PID lease="$RUN_DIR/codex-bridge-lease.$FAKE_PID"
  awk '{ if ($0 ~ /^host=/) print "host=some-other-host.invalid"; else print }' "$lease" > "$lease.x"; mv "$lease.x" "$lease"
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  sleep 3
  kill -0 "$victim"
  kill "$victim" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$victim" 2>/dev/null || true
}

@test "launcher: a lease with an unknown extra key is not killed, fail-closed (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  _fake_alice_lease; local victim=$FAKE_PID lease="$RUN_DIR/codex-bridge-lease.$FAKE_PID"
  { cat "$lease"; printf 'rogue=1\n'; } > "$lease.x"; mv "$lease.x" "$lease"
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  sleep 3
  kill -0 "$victim"
  kill "$victim" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$victim" 2>/dev/null || true
}

@test "launcher: a lease with a duplicated key is not killed, fail-closed (#937)" {
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  _fake_alice_lease; local victim=$FAKE_PID lease="$RUN_DIR/codex-bridge-lease.$FAKE_PID"
  { cat "$lease"; printf 'pid=99999\n'; } > "$lease.x"; mv "$lease.x" "$lease"
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  sleep 3
  kill -0 "$victim"
  kill "$victim" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$victim" 2>/dev/null || true
}

@test "launcher: a lease whose start token no longer matches the live pid is not killed (#937)" {
  # The reuse guard: if the process now at that pid started at a different time
  # than the lease records (a recycled pid, an unrelated bridge), killing it would
  # be a wrong-kill. The token must PROVE the live process is the leased one, or
  # nothing happens. Same identity as the launcher, so only the token spares it.
  put_record team alice thread-alice "$PROJ" codex
  export MOCK_BRIDGE_SLEEP=25
  _fake_alice_lease; local victim=$FAKE_PID lease="$RUN_DIR/codex-bridge-lease.$FAKE_PID"
  # Rewrite start= to a value that cannot equal the live process's actual token
  # (its src stays valid so the lease still parses; only the token is wrong).
  awk '{ if ($0 ~ /^start=/) print "start=1"; else print }' "$lease" > "$lease.x"; mv "$lease.x" "$lease"
  sleep 22 3>&- & local parent=$!
  bash "$LAUNCHER" codex "$PROJ" "ws://127.0.0.1:1" "$parent" >/dev/null 2>&1 3>&- & local disp=$!
  sleep 3
  kill -0 "$victim"
  kill "$victim" "$disp" "$parent" 2>/dev/null || true; wait "$disp" 2>/dev/null || true; wait "$victim" 2>/dev/null || true
}

# --- Windows start token: the lease schema must admit the source
# codex-bridge.js writeLease() records on Windows, where /proc does not exist and
# the only `ps` likely to be on PATH (MSYS's) rejects -o outright, so both POSIX
# sources yield an empty token and the bridge can never publish a lease at all.
#
# _read_lease is the reaper's ONLY gate on a lease, so its accept/reject set is
# the contract. These exercise it directly -- the pattern test_remote.bats uses
# for _remote_endpoint_display -- rather than through the reaper: the reaper
# needs a spawnable bridge and a live pid, which is exactly what does not work on
# Git Bash (#567), and the schema question has nothing to do with either. Kept
# out of the `windows-native` filter deliberately: nothing here runs PowerShell,
# so these belong on every leg, not only the Windows one. ---
_lease_verdict() { # <startsrc> <start> -> prints accept|reject
  local h40=0123456789abcdef0123456789abcdef01234567
  printf 'v=1\nproject=%s\npairs=%s\nhost=h\npid=123\nstart=%s\nstartsrc=%s\n' \
    "$h40" "$h40" "$2" "$1" > "$TEST_SKILL_DIR/lease-under-test"
  bash -c '
    eval "$(sed -n "/^_read_lease() {/,/^}/p" "$1")"
    _read_lease "$2" && echo accept || echo reject
  ' _ "$LAUNCHER" "$TEST_SKILL_DIR/lease-under-test" 2>/dev/null
}

@test "launcher: the lease schema admits a pwsh start token" {
  [ "$(_lease_verdict pwsh 639231441791462826)" = accept ]
}

@test "launcher: a pwsh lease whose token is not an integer is rejected, fail-closed" {
  # .NET Ticks is a bare integer. Anything else under that label is a lease this
  # side did not write, and a doubtful lease must never authorise a kill.
  [ "$(_lease_verdict pwsh 6392314.5)" = reject ]
  [ "$(_lease_verdict pwsh '')" = reject ]
}

@test "launcher: an unrecognised startsrc is rejected, fail-closed" {
  # wmic is here on purpose, not as an arbitrary bad value: WMIC's CreationDate
  # was the faster candidate and was deliberately NOT adopted, because a per-side
  # "WMIC, else PowerShell" order lets the writer and the reaper resolve different
  # sources for the same process whenever only one of them can reach wmic.exe.
  # Rejecting the label pins that decision, so reintroducing it fails loudly.
  [ "$(_lease_verdict wmic 20260824041348.411807+540)" = reject ]
  [ "$(_lease_verdict bogus 123)" = reject ]
}

@test "launcher: proc and ps leases still parse (start-token regression)" {
  [ "$(_lease_verdict proc 396341883)" = accept ]
  [ "$(_lease_verdict ps 'Sun Aug 24 04:00:00 2026')" = accept ]
  # ps stays exempt from the integer check (its token is a human date string
  # whose punctuation varies by platform); proc does not.
  [ "$(_lease_verdict proc abc)" = reject ]
}

_run_start_token() { # <pid> -> runs _start_token in a subshell
  run bash -c '
    eval "$(sed -n "/^_agmsg_is_windows() {/,/^}/p;/^_start_token() {/,/^}/p" "$1")"
    _start_token "$2"
  ' _ "$LAUNCHER" "$1"
}

@test "launcher: a live pid yields a proc or ps start token on POSIX" {
  skip_on_windows "Windows has its own source; see the windows-native case"
  _run_start_token $$
  [ "$status" -eq 0 ]
  local tab; tab=$(printf '\t')
  case "${output%%"$tab"*}" in proc|ps) ;; *) false ;; esac
  [ -n "${output#*"$tab"}" ]
}

@test "launcher: windows-native a live pid yields an integer pwsh start token" {
  skip_unless_windows "PowerShell and the Windows pid space are the point"
  # The pid must be the WINDOWS one. MSYS/Cygwin number processes in their own
  # space -- the same shell is MSYS pid 3994449 and winpid 19568 on our runner --
  # and Get-Process only knows the latter, which is also the pid
  # codex-bridge.js records as process.pid.
  local winpid; winpid="$(cat /proc/$$/winpid)"
  [ -n "$winpid" ]
  _run_start_token "$winpid"
  [ "$status" -eq 0 ]
  local tab; tab=$(printf '\t')
  [ "${output%%"$tab"*}" = pwsh ]
  local tok="${output#*"$tab"}"
  case "$tok" in ''|*[!0-9]*) false ;; esac
}
