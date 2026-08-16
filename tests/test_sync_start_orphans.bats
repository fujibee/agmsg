#!/usr/bin/env bats

# `sync start` must not walk away from a process it started (#831).
#
# Reported from the field: repeated `sync start` attempts left engines running
# that nothing pointed at. Three invocations, three live engines, and `status`
# reporting stopped for all of them.
#
# The mechanism is in the give-up path. When the engine never becomes ready the
# starter reaps it and clears its records -- and the reap answered "reaped" for a
# pid it had merely READ as gone, without signalling anything. On Windows a live
# engine reads as dead (#652, #505: a DWORD pid above the POSIX ceiling is not a
# number `kill` will parse), so the records of a RUNNING engine were deleted. The
# pidfile is the only thing that names it, so after that no `status` could see it
# and no `stop` could reach it -- while it kept retrying on a backoff.
#
# The separation these cases hold is between an act and a reading:
#
#   0   this call signalled the engine and the engine went
#   2   the engine read as gone; nothing was signalled
#
# and the records are cleared on 0 only. #832 fixed the probe that misread; this
# does not depend on that fix, because the harm does not depend on WHICH
# misreading happens. A record deleted for a live process cannot be recovered by
# the operator. A record left for a dead one is exactly what `status` describes.
#
# WHAT THIS FILE DOES NOT COVER. #831 names two independent directions and this
# is the first of them. The second -- every engine appending to one shared log,
# so lines tear into each other and every tool that reads that log, including the
# readiness poll, reads fragments -- is untouched here, and no case below says
# anything about it. Nothing here reduces the number of engines that CAN exist
# either: two `sync start` calls that both misread still start two. What it
# stops is the second half, where the record of one is deleted and nothing can
# name it afterwards.

load test_helper

# A team name of this file's own, because these cases COUNT AND KILL processes
# by their `--team` argument, which is the only part of an engine's argv that is
# not shared (the store is passed in the environment). Scoping to $TEST_SKILL_DIR
# would not work; a name nobody else uses does.
TEAM=orphan831

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" "$TEAM" alice claude-code /tmp/project-orphan831 >/dev/null

  local cfg="$TEST_SKILL_DIR/teams/$TEAM/config.json" escaped updated
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

  PIDFILE="$TEST_SKILL_DIR/run/remote-sync.$TEAM.pid"
  PATTERN="remote-sync.mjs run --team $TEAM"
  # Nothing of this name may exist yet, or every count below means nothing.
  [ -z "$(pgrep -f "$PATTERN")" ]
}

teardown() {
  # This file's cases exist BECAUSE an engine can be left running, so it cannot
  # rely on the code under test to clean up after them.
  pkill -f "$PATTERN" 2>/dev/null || true
  teardown_test_env
}

# Drives the real `cmd_sync_start` with the local liveness probe made to answer
# "gone" for everything -- the reading Windows produces for a live engine.
#
# A driver script and not `run bash -c`, so the override is written once and the
# only difference between the two callers below is its presence.
write_driver() {
  DRIVER="$TEST_SKILL_DIR/drive-sync-start.sh"
  cat > "$DRIVER" <<'EOF_DRIVER'
#!/usr/bin/env bash
# $1 = team, $2 = "blind" to make the local liveness probe read every pid as gone
. "$SCRIPTS/remote.sh"
if [ "$2" = "blind" ]; then
  _agmsg_pid_alive_local() { return 1; }
fi
rc=0
cmd_sync_start "$1" || rc=$?
echo "driver: cmd_sync_start rc=$rc"
EOF_DRIVER
  chmod +x "$DRIVER"
}

@test "reap: a pid that only READS as gone is answered 2, and nothing is signalled (#831)" {
  # 2 is the whole distinction. A dead pid gives the same reading a live engine
  # gives on Windows, and the answer must not be the one that means "I stopped
  # it" -- the caller clears records on that answer.
  local dead
  bash -c 'exit 0' & dead=$!
  wait "$dead" 2>/dev/null || true

  cat > "$TEST_SKILL_DIR/reap.sh" <<'EOF_REAP'
#!/usr/bin/env bash
. "$SCRIPTS/remote.sh"
rc=0
_remote_sync_engine_reap_owned "$1" "$2" || rc=$?
echo "reap rc=$rc"
EOF_REAP

  run bash "$TEST_SKILL_DIR/reap.sh" "$TEAM" "$dead"
  [ "$status" -eq 0 ]
  grep -qF 'reap rc=2' <<<"$output"
}

@test "reap: a pid it actually signals is answered 0 (#831)" {
  # THE NEGATIVE CONTROL. Without it "always answer 2" satisfies the case above,
  # and no record would ever be cleared again.
  local live
  sleep 30 & live=$!

  # The reap refuses a pid it cannot prove is this team's, so the records have to
  # name it -- which is also the state the real give-up path is in.
  printf '%s\n' "$live" > "$PIDFILE"
  cat > "$TEST_SKILL_DIR/reap0.sh" <<'EOF_REAP0'
#!/usr/bin/env bash
. "$SCRIPTS/remote.sh"
# The engine here is a `sleep`, not the real script, so the cmdline half of the
# status probe cannot match. Ownership is what this case is not about; the
# liveness probe underneath is the real one, and it is what says the kill landed.
LIVE="$2"
_remote_sync_engine_status() { printf 'running\t%s\n' "$LIVE"; }
rc=0
_remote_sync_engine_reap_owned "$1" "$LIVE" || rc=$?
echo "reap rc=$rc"
EOF_REAP0

  run bash "$TEST_SKILL_DIR/reap0.sh" "$TEAM" "$live"
  [ "$status" -eq 0 ]
  grep -qF 'reap rc=0' <<<"$output"
  # It really went: 0 is an act, and the act has to have happened.
  run kill -0 "$live"
  [ "$status" -ne 0 ]
}

@test "sync start: a blind liveness probe leaves the engine RECORDED, not orphaned (#831)" {
  # THE DEFECT ITSELF, end to end. The engine is real, the give-up path is real;
  # only the liveness reading is forced, to the value Windows produces.
  write_driver
  run env SCRIPTS="$SCRIPTS" bash "$DRIVER" "$TEAM" blind

  # It failed to become ready, which is the path under test.
  grep -qF 'driver: cmd_sync_start rc=1' <<<"$output"

  # The engine is still running -- the reap never signalled it, because it read
  # it as gone.
  local running
  running="$(pgrep -f "$PATTERN" | wc -l | tr -d ' ')"
  [ "$running" -eq 1 ]

  # AND IT IS STILL REACHABLE. This is the assertion the issue is about: the
  # pidfile is the only thing that names that process, so it has to survive.
  [ -f "$PIDFILE" ]
  local recorded
  recorded="$(cat "$PIDFILE")"
  pgrep -f "$PATTERN" | grep -qxF "$recorded"
}

@test "sync start: it says the engine read as gone and was not signalled (#831)" {
  # A record left behind with no explanation reads as a bug. The operator has to
  # be told which of the two situations they are in, because the actions differ.
  write_driver
  run env SCRIPTS="$SCRIPTS" bash "$DRIVER" "$TEAM" blind

  grep -qF 'read as already gone, so nothing was signalled' <<<"$output"
  grep -qF "remote.sh status" <<<"$output"
}

@test "sync start: with an honest probe the engine IS stopped and its records cleared (#831)" {
  # THE NEGATIVE CONTROL FOR THE CASE ABOVE. Without it, "never clear anything"
  # passes both, and every failed start would leave a pidfile naming nothing --
  # which is the state `status` then reports as stale forever.
  write_driver
  run env SCRIPTS="$SCRIPTS" bash "$DRIVER" "$TEAM" honest

  grep -qF 'driver: cmd_sync_start rc=1' <<<"$output"
  local running
  running="$(pgrep -f "$PATTERN" | wc -l | tr -d ' ')"
  [ "$running" -eq 0 ]
  [ ! -f "$PIDFILE" ]
}

@test "sync start: a jammed lock on the blind path does not claim the engine stopped (#831)" {
  # THE ONE MESSAGE THAT IS NOT ABOUT A FILE, AND THE ONLY THING THE OPERATOR GETS.
  #
  # Two conditions have to hold at once: the cleanup cannot retake the lock, and
  # the reap only READ the engine as gone. The line printed there used to say
  # "the engine is stopped" unconditionally, which on this path is the one thing
  # nothing established -- nothing was signalled.
  #
  # The lock is taken the way the library takes it, after the engine exists, so
  # the starter has already let go of it and finds it held on the way back.
  write_driver
  local lock="$TEST_SKILL_DIR/teams/$TEAM/.config.lock"
  local err="$TEST_SKILL_DIR/jammed.err"
  local driver_pid i=0

  env SCRIPTS="$SCRIPTS" bash "$DRIVER" "$TEAM" blind >"$err" 2>&1 &
  driver_pid=$!
  while [ ! -f "$PIDFILE" ] && [ "$i" -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
  [ -f "$PIDFILE" ]
  mkdir "$lock"

  wait "$driver_pid" 2>/dev/null || true

  grep -qF 'could not retake the registry lock' "$err"
  grep -qF 'the only thing naming that pid' "$err"
  # And it does NOT say the thing it cannot know. Asserted separately, because a
  # message can gain a true sentence and keep the false one.
  ! grep -qF 'the engine is stopped' "$err"
  [ -f "$PIDFILE" ]

  rmdir "$lock" 2>/dev/null || true
}
