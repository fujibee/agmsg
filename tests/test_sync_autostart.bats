#!/usr/bin/env bats

load test_helper

# Starting a connected team's engine when an agent turns up (#774).
#
# The case this exists for is SEVERAL SESSIONS AT ONCE on one machine, in one
# team. They race for the per-team lock `cmd_sync_start` takes; one starts the
# engine and the rest are told `already running` and carry on. That behaviour
# belongs to the command, and these tests pin that the auto-start path inherits
# it rather than reproducing it — a second answer to "is it running?" diverges
# exactly under this race.

setup() {
  setup_test_env
  # The trigger tests below run the real scripts, which read these two.
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped', '\$.remote_binding', json_object(
      'endpoint', 'https://remote.example',
      'server_instance_id', '018f0000-0000-7000-8000-000000000001',
      'remote_team_id', '018f0000-0000-7000-8000-000000000002',
      'protocol_version', 1,
      'capabilities', json_object('write_allowed_ciphers', json_array('none')),
      'connected_at', '2026-07-30T00:00:00Z',
      'disconnected_at', null
    ));")"
  printf '%s\n' "$updated" > "$cfg"
  mkdir -p "$TEST_SKILL_DIR/run"
  ENGINE_PIDS=""
}

teardown() {
  local pid
  for pid in $ENGINE_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  # The "does not wait" cases leave a `sync start` child running ON PURPOSE —
  # that is the behaviour under test. It must not outlive the test: a CI shard
  # runs many files in one process tree, and a fake that loops forever would
  # then be somebody else's flake (raised in review).
  # BY THE PATH THEY ACTUALLY RUN UNDER. The hanging fake is COPIED over
  # `$SCRIPTS/remote.sh`, so matching the name it was written as reaps nothing
  # and the child outlives the whole file — which is how this suite stopped
  # exiting even with every case green. Both paths are inside the test's own
  # skill dir, so the pattern cannot reach anything else.
  pkill -f "$TEST_SKILL_DIR/" 2>/dev/null || true
  teardown_test_env
}

# A node that becomes READY and then stays up.
#
# `cmd_sync_start` does not return when the process exists — it waits for the
# engine's `startup_nonce` to appear in the logfile, so a fake that only sleeps
# makes the command spin until its own timeout. Same shape as
# test_remote_status_liveness.bats's fake node, which is where this came from.
write_fake_node() {
  local fake_node="$TEST_SKILL_DIR/fake-node"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then' \
    '  echo v23.0.0' \
    '  exit 0' \
    'fi' \
    'echo "{\"event\":\"capabilities\",\"startup_nonce\":\"${AGMSG_SYNC_START_NONCE:-}\"}"' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  printf '%s\n' "$fake_node"
}

# A node that fails to start at all.
write_failing_node() {
  local fake_node="$TEST_SKILL_DIR/fake-node-bad"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then echo v23.0.0; exit 0; fi' \
    'echo "engine exploded" >&2' \
    'exit 1' > "$fake_node"
  chmod +x "$fake_node"
  printf '%s\n' "$fake_node"
}

# Register a (team, agent) pair for the test project, as the actas tests do.
fake_register() {
  local team="$1" agent="$2" proj="${3:-/tmp/p1}"
  bash "$SCRIPTS/join.sh" "$team" "$agent" claude-code "$proj" >/dev/null 2>&1 || true
}

# Wait briefly for a call to be RECORDED.
#
# The "does not wait" cases give the helper a 1s budget, so it returns while the
# child is still running — and the child records the team name as its first act.
# Grepping immediately is therefore a race with a process the test deliberately
# did not wait for: it passed on an idle machine and went red under load, which
# is a flaky assertion dressed as a strict one. The bound here is generous
# because it is not measuring speed; the SESSION's bound is measured separately,
# from the outside, in the same test.
wait_for_call() {
  local file="$1" needle="$2" i=0
  while [ "$i" -lt 100 ]; do
    grep -q "^$needle\$" "$file" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# A `remote.sh` that answers instantly, for the cases where the SUBJECT is what
# the helper does with an answer — not how long the real command takes.
#
# The real command is kept for the race case below, which is about inheriting
# its lock. Everywhere else it only made the suite slow and timing-coupled:
# raising the budget so a case could not be cut short is the same admission,
# with a worse failure mode (a 60s case that goes red when the machine is busy).
write_answering_remote() {
  local answer="$1" fake="$TEST_SKILL_DIR/fake-remote-answer.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '[ "${1:-}" = "sync" ] || exit 0'
    case "$answer" in
      started)  printf '%s\n' 'echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0' ;;
      running)  printf '%s\n' 'echo "Sync engine already running (pid 4242)."; exit 0' ;;
      refused)  printf '%s\n' 'echo "agmsg: team '"'"'$3'"'"' is disconnected; connect or pull it before starting sync" >&2; exit 1' ;;
      broken)   printf '%s\n' 'echo "engine exploded" >&2; exit 1' ;;
    esac
  } > "$fake"
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

collect_engine_pids() {
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  [ -f "$pidfile" ] && ENGINE_PIDS="$ENGINE_PIDS $(cat "$pidfile")"
  return 0
}

@test "starts an engine for a connected team that has none" {
  # THE REAL COMMAND, because this case asserts on the artifact it leaves: a
  # pidfile naming a live process. The sentence is not the evidence.
  export AGMSG_SYNC_AUTOSTART_TIMEOUT_S=60
  export AGMSG_NODE="$(write_fake_node)"
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam
  collect_engine_pids
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'started one for'
  printf '%s' "$output" | grep -q 'testteam'
  [ -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  # Liveness through the shipped helper, not a bare kill -0 (a repo-wide check
  # forbids the latter, and it caught this branch once already).
  run bash -c 'source "'"$SCRIPTS"'/lib/instance-id.sh"; _agmsg_pid_alive "$(cat "'"$TEST_SKILL_DIR"'/run/remote-sync.testteam.pid")"'
  [ "$status" -eq 0 ]
}

@test "says nothing at all when the engine is already running" {
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$(write_answering_remote running)" testteam
  [ "$status" -eq 0 ]
  # Starting is a side effect nobody asked for in this moment; "nothing
  # changed" is not news, and a line here would appear on every session start
  # for the rest of the machine's life.
  [ -z "$output" ]
}

@test "several sessions at once leave exactly one engine, and none of them fails" {
  # THE CASE THIS FEATURE IS FOR. Five callers race for the per-team lock.
  export AGMSG_NODE="$(write_fake_node)"
  source "$SCRIPTS/lib/sync-autostart.sh"

  local i outdir="$TEST_SKILL_DIR/race"
  mkdir -p "$outdir"
  for i in 1 2 3 4 5; do
    (
      agmsg_sync_autostart "$SCRIPTS/remote.sh" testteam > "$outdir/$i.out" 2>&1
      printf '%s\n' "$?" > "$outdir/$i.rc"
    ) &
  done
  wait
  collect_engine_pids

  # Every caller succeeded — the losers of the race are not failures.
  for i in 1 2 3 4 5; do
    [ "$(cat "$outdir/$i.rc")" = "0" ]
  done

  # Exactly one of them reports having started it. The rest say nothing, which
  # is what `already running` produces.
  local started=0 quiet=0
  for i in 1 2 3 4 5; do
    if grep -q "started one for" "$outdir/$i.out"; then
      started=$((started + 1))
    elif [ ! -s "$outdir/$i.out" ]; then
      quiet=$((quiet + 1))
    fi
  done
  [ "$started" -eq 1 ]
  [ "$quiet" -eq 4 ]

  # And one engine exists, not five. Counted from the process table rather than
  # from the pidfile: the pidfile can only ever name one, so asking it would be
  # asking the wrong witness.
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  [ -f "$pidfile" ]
  kill -0 "$(cat "$pidfile")"
  # COUNTED IN THIS TEST'S OWN TREE. `fake-node` as a bare name matches any
  # leftover from another run in the same process tree — a CI shard runs many
  # files in one — so the count would include somebody else's engine and this
  # assertion would fail for their leak rather than a second engine here.
  # Measured: with two strays present on the machine it read 3 and went red,
  # green on the run before, which is what a global pattern looks like from
  # the inside.
  local live
  live="$(pgrep -f "$TEST_SKILL_DIR/fake-node" 2>/dev/null | wc -l | tr -d ' ')"
  [ "$live" = "1" ]
}

@test "a refusal from the command is repeated, not replaced" {
  # THE SUBJECT IS THE HELPER'S HANDLING of a refusal, so the refusal is given
  # to it directly. Driving the real command here made the case depend on how
  # busy the machine was — it went green alone and red in the full file — and
  # raising the budget only made it slow instead of wrong.
  #
  # The binding check itself belongs to `cmd_sync_start` and is tested where it
  # lives; what is asserted here is that its sentence survives.
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$(write_answering_remote refused)" testteam
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'disconnected'
  printf '%s' "$output" | grep -q 'connected, but not syncing'
}

@test "a start that fails does not fail the caller, and says what the command said" {
  # An agent that will not open because a sync engine refused is worse than a
  # sync engine that is down.
  #
  # The budget is raised for this case on purpose. `cmd_sync_start` does not
  # notice a dead engine immediately — it waits out its readiness loop — so
  # under the default 5s this failure is reported as "still in flight", which
  # is TRUE and is a different sentence. The two outcomes are tested
  # separately rather than folded together: "it failed" and "it has not
  # answered yet" are different facts and the tool says different things.
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$(write_answering_remote broken)" testteam
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'connected, but not syncing'
  printf '%s' "$output" | grep -q 'The session continues.'
  # The runnable remedy survives from #765 — the person now also knows it was
  # tried.
  printf '%s' "$output" | grep -q 'sync start'
}

@test "no teams, no output, no failure" {
  source "$SCRIPTS/lib/sync-autostart.sh"
  run agmsg_sync_autostart "$SCRIPTS/remote.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── the two production triggers, driven for real ─────────────────────────────
#
# Everything above drives `agmsg_sync_autostart` directly, and deleting the
# wiring from either trigger leaves all of it green (raised in review). The
# wiring is the PR's whole point and it is different on each side:
# session-start awks `remote.sh status` for connected teams, actas-claim
# array-ifies `$TEAMS` after the claim. Neither follows from the helper being
# right.

# A `remote.sh` this test controls, standing in for the real one so a trigger
# can be driven without a server. It records every call it was given.
write_fake_remote() {
  local behaviour="$1" fake="$TEST_SKILL_DIR/fake-remote.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'calls="$AGMSG_FAKE_REMOTE_CALLS"'
    printf '%s\n' 'if [ "${1:-}" = "status" ]; then'
    printf '%s\n' '  printf "%s\tconnected (engine stopped — run: x) since 2026-07-30T00:00:00Z\n" testteam'
    printf '%s\n' '  printf "%s\tdisconnected (was connected until 2026-08-01T00:00:00Z)\n" otherteam'
    printf '%s\n' '  exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [ "${1:-}" = "sync" ] && [ "${2:-}" = "start" ]; then'
    printf '%s\n' '  printf "%s\n" "$3" >> "$calls"'
    case "$behaviour" in
      starts) printf '%s\n' '  echo "Sync engine started for '"'"'$3'"'"' (pid 4242)."; exit 0' ;;
      hangs)  printf '%s\n' '  while :; do sleep 1; done' ;;
    esac
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } > "$fake"
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

@test "session-start starts the engine for a connected team, and still emits the directive" {
  local fake calls="$TEST_SKILL_DIR/calls.txt"
  fake="$(write_fake_remote starts)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice
  echo "sid-current" > "$RUN_DIR/cc-instance.$$"

  run env AGMSG_FAKE_REMOTE_CALLS="$calls" bash -c \
    'printf "{\"session_id\":\"sid-current\"}" | bash "$1" claude-code /tmp/p1' _ \
    "$SCRIPTS/session-start.sh"

  # The connected team was started...
  grep -q '^testteam$' "$calls"
  # ...and the disconnected one was never offered to the command.
  #
  # `refute`, not `! grep`. A leading `!` does not trip errexit on either
  # interpreter, so in a non-last position it reports ok whatever it finds —
  # I removed five of those from this file and introduced this one in the same
  # head (raised in review).
  refute grep -q '^otherteam$' "$calls"
  # ...and the thing the session actually needs still came out.
  printf '%s' "$output" | grep -q 'AGMSG'
  [ "$status" -eq 0 ]
}

@test "session-start does not wait for a start that hangs" {
  local fake calls="$TEST_SKILL_DIR/calls.txt" began ended
  fake="$(write_fake_remote hangs)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice
  echo "sid-current" > "$RUN_DIR/cc-instance.$$"

  began=$SECONDS
  run env AGMSG_FAKE_REMOTE_CALLS="$calls" AGMSG_SYNC_AUTOSTART_TIMEOUT_S=1 bash -c \
    'printf "{\"session_id\":\"sid-current\"}" | bash "$1" claude-code /tmp/p1' _ \
    "$SCRIPTS/session-start.sh"
  ended=$SECONDS

  # THAT IT WAS TRIED. Without this the case passes when the invocation is
  # DELETED — nothing to wait for is also fast — so it would be measuring the
  # absence of the feature and calling it a bound (found by the deletion
  # mutation; the actas twin below had the same hole).
  wait_for_call "$calls" testteam
  # The bound, from the outside: a session that waits on a hung child is the
  # release-blocker fix blocking a release.
  [ $((ended - began)) -lt 10 ]
  # It said a start is in flight rather than pretending nothing happened.
  printf '%s' "$output" | grep -q 'still in flight'
  [ "$status" -eq 0 ]
}

@test "actas-claim starts the engine and still prints status=ok" {
  local fake calls="$TEST_SKILL_DIR/calls.txt"
  fake="$(write_fake_remote starts)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice

  run env AGMSG_FAKE_REMOTE_CALLS="$calls" bash "$SCRIPTS/actas-claim.sh" \
    /tmp/project-a claude-code alice sid-actas
  # The claim is what the caller is waiting on, and it still arrives.
  printf '%s' "$output" | grep -q 'status=ok'
  grep -q '^testteam$' "$calls"
  [ "$status" -eq 0 ]
}

@test "actas-claim does not wait for a start that hangs" {
  local fake calls="$TEST_SKILL_DIR/calls.txt" began ended
  fake="$(write_fake_remote hangs)"
  cp "$fake" "$SCRIPTS/remote.sh"
  : > "$calls"
  fake_register testteam alice

  began=$SECONDS
  run env AGMSG_FAKE_REMOTE_CALLS="$calls" AGMSG_SYNC_AUTOSTART_TIMEOUT_S=1 \
    bash "$SCRIPTS/actas-claim.sh" /tmp/project-a claude-code alice sid-actas
  ended=$SECONDS

  # THAT IT WAS TRIED — see the session-start twin. Deleting the invocation
  # made this case pass, which is the check measuring its own absence.
  wait_for_call "$calls" testteam
  [ $((ended - began)) -lt 10 ]
  printf '%s' "$output" | grep -q 'status=ok'
  [ "$status" -eq 0 ]
}

# --- #773: why there is no refusal check here ------------------------------
#
# An earlier version of this suite had three cases asserting that a team whose
# server had refused was never offered to `sync start`, plus two more bounding
# and reaping the lookup that made that possible.
#
# They are gone with the mechanism. The refusal check existed to stop a restart
# loop — the engine used to EXIT on a refusal — and #792 ended that: the engine
# records the refusal, backs off to its longest interval and keeps looping. A
# refused team costs one quiet process that reports the reason through
# `status`, so there is nothing here to prevent, and nothing to test.
#
# Recorded rather than silently dropped, because "there used to be a check"
# reads as an oversight to whoever finds this next.

@test "a team whose temp file cannot be made is reported, and the rest are still tried (#810)" {
  # `mktemp` failing is a start that did not happen, and #761/#765 exist so
  # that a start that did not happen is never silent. Before this, the function
  # returned early: no engine, NO OUTPUT — the started/slow/failed blocks are
  # built after the loop — and every team after this one abandoned untried.
  #
  # Driven by putting `mktemp` on PATH as a command that fails, which is what
  # a full or unwritable temp filesystem looks like from inside this function.
  source "$SCRIPTS/lib/sync-autostart.sh"
  local bindir="$TEST_SKILL_DIR/failing-bin"
  mkdir -p "$bindir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$bindir/mktemp"
  chmod +x "$bindir/mktemp"

  local fake; fake="$(write_answering_remote started)"
  PATH="$bindir:$PATH" run agmsg_sync_autostart "$fake" teamone teamtwo
  [ "$status" -eq 0 ]

  # Said, in the #765 block, with its runnable remedy.
  printf '%s' "$output" | grep -q 'connected, but not syncing'
  printf '%s' "$output" | grep -q 'temporary file'
  # BOTH teams: the second must not be abandoned because the first could not
  # allocate. That is what `return` did and `continue` does not.
  printf '%s' "$output" | grep -q 'teamone'
  printf '%s' "$output" | grep -q 'teamtwo'
  # The remedy is per team and runnable, unchanged from #765.
  printf '%s' "$output" | grep -q 'sync start'
}
