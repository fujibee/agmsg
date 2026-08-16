#!/usr/bin/env bats

# What a sync engine that cannot start is allowed to leave behind (#730).
#
# It used to leave nothing: no message, no exit code the operator saw, and a
# claim from the caller that the engine was running. `_remote_sync_engine_start`
# ended in `disown … || true`, so it always returned 0; the one caller that
# checked used `if ! …`, where `set -e` is suspended, so a failed pidfile write
# was stepped over and the command died later at `cat "$pidfile"` with nothing
# printed. Measured on a codex-like sandbox shape: the run dir was not writable,
# and `sync start` exited without a word of its own.
#
# These tests pin the three things that has to produce instead: a non-zero exit,
# a message naming the path and the way out, and NO half-started engine.

load test_helper

setup() {
  setup_test_env
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
}

teardown() {
  # Restore before the harness removes the tree, or the unwritable dir defeats
  # its own cleanup.
  chmod u+w "$TEST_SKILL_DIR/run" 2>/dev/null || true
  chmod u+w "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" 2>/dev/null || true
  chmod u+w "$TEST_SKILL_DIR" 2>/dev/null || true
  # The control case starts a real engine. cmd_sync_start reaps it when it does
  # not become ready, but a test file about leaked engines should not be the one
  # leaking them if that reap ever stops working.
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid" pid=""
  [ -f "$pidfile" ] && pid="$(cat "$pidfile" 2>/dev/null || true)"
  # 0 and 1 are never ours: `kill 0` signals the whole process group (measured:
  # it killed the bats run) and 1 is init.
  case "$pid" in
    ''|*[!0-9]*|0|1) ;;
    *) kill "$pid" 2>/dev/null || true ;;
  esac
  teardown_test_env
}

# Refuse to run as root: chmod is the whole mechanism here and root ignores it,
# so the tests would pass without ever reaching the branch they are about.
skip_if_root() {
  [ "$(id -u)" -ne 0 ] || skip "chmod does not restrict root, so the refusal path is unreachable"
}

@test "sync start: an unwritable run dir is refused out loud, not in silence (#730)" {
  skip_if_root
  chmod a-w "$TEST_SKILL_DIR/run"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  # The path, so the operator knows what to fix rather than what to suspect.
  grep -qF "remote-sync.testteam.pid" <<<"$output"
  # What is not happening, in the operator's terms rather than the engine's.
  grep -qF "Nothing is syncing for this team" <<<"$output"
  # And the way back. A refusal that names no next step leaves the operator to
  # invent one, which is how a tunnel got invented for #717.
  grep -qF "remote.sh sync start" <<<"$output"
}

@test "sync start: the refusal leaves no engine and no pidfile behind (#730)" {
  skip_if_root
  chmod a-w "$TEST_SKILL_DIR/run"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  # Companion, not the discriminator: the broken form ALSO leaves no pidfile —
  # that is exactly what its failed write produces. Measured against the
  # original body, this assertion stays green. It is here so a future change
  # cannot start writing a pidfile for a start that was refused; the test below
  # is the one that separates "refused" from "orphaned".
  refute test -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
}

# NOT COVERED, deliberately: "a refused start leaves no engine process".
#
# Proving the orphan-prevention half needs an input where the broken code
# spawns and then fails to record the pid. Two were tried and neither reaches
# it. Making the run dir unwritable kills the child at its own log redirection
# (`>> run/remote-sync.<team>.log`) before node starts. Making only the pidfile
# read-only lets the spawn happen, but the test could not observe a surviving
# engine either -- both were measured green against the original function body,
# which is the definition of a test that does not test its subject.
#
# So the guard that proves writability BEFORE the spawn is in the code without
# a test that would notice its removal. Said here rather than left implicit:
# the other four tests below and above cover the audible-failure half only.

@test "sync start: the command the refusal prints is the command that works (#730)" {
  skip_if_root
  # Not "the refusal mentions a real command" -- that is satisfied by any real
  # command. The remedy is LIFTED OUT of the refusal and run, so the two cannot
  # drift apart: change the printed string alone and this fails on whatever it
  # now prints. A printed route has to be run, not read.
  printf '%s\n' 2147483647 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  chmod a-w "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]

  # Captured before the next `run`, which overwrites $output.
  local remedy
  remedy="$(grep -oE 'remote\.sh [a-z].*' <<<"$output" | tail -1)"
  [ -n "$remedy" ]
  # Only the arguments are lifted: the leading path is whatever the operator's
  # install puts there, and the test has its own.
  local args="${remedy#remote.sh }"

  chmod u+w "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  rm -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  # Run through a shell, not by word-splitting. The remedy is written for a
  # person to paste into one, so the team name arrives shell-quoted by
  # agmsg_shq; splitting it here passes the quotes through as characters and the
  # command fails on a team literally named "'testteam'" -- measured, that is
  # what the first version of this test did. A printed route has to be run the
  # way it is meant to be run.
  run bash -c "bash '$SCRIPTS/remote.sh' $args"
  # "not refused" is not enough: a remedy that no longer parses is answered with
  # a usage line, which is also not a refusal. Measured -- changing only the
  # printed verb (start -> begin) left this test green until the two assertions
  # below were added. What has to be true is that the lifted command REACHED the
  # engine-start path, so it must say what became of the engine.
  refute grep -q "^Usage:" <<<"$output"
  grep -qE "Sync engine (already running|started)|did not become ready" <<<"$output"
}

@test "sync start: a run dir that cannot be created is refused the same way (#730)" {
  skip_if_root
  # The other half. `mkdir -p … || true` tolerated this and left the failure to
  # the unguarded write below it, which could not explain itself.
  rmdir "$TEST_SKILL_DIR/run"
  chmod a-w "$TEST_SKILL_DIR"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  grep -qF "could not start the sync engine" <<<"$output"
  grep -qF "run" <<<"$output"
}

@test "sync start: a writable run dir still starts an engine (#730)" {
  # The control. Without it, every assertion above is satisfied by a
  # `sync start` that refuses unconditionally.
  run bash "$SCRIPTS/remote.sh" sync start testteam
  # The engine is real here and will fail to reach https://remote.example, so
  # this does not assert success -- only that the refusal above is not what
  # happened, and that the pidfile path was reachable.
  refute grep -qF "Nothing is syncing for this team" <<<"$output"
  refute grep -qF "could not start the sync engine" <<<"$output"
}

@test "sync start: the registry lock is free while readiness is still polled (#817)" {
  # THE FIELD DEFECT, OBSERVED FROM OUTSIDE THE COMMAND.
  #
  # `cmd_sync_start` took the team's registry lock, started the engine, and then
  # polled for a readiness marker while still holding it.
  #
  # The engine emits that marker BEFORE it asks for the same lock, so the order
  # was never the problem -- an earlier version of this comment said it was. On
  # the reporting machine the loop never reached the marker check:
  # `_remote_sync_engine_status` answered `stale` for a pid this shell had just
  # started (#652), so the condition short-circuited, and the ceiling it then ran
  # to is counted in iterations rather than time (#779). The lock was held for
  # all of it.
  #
  # #812 removed that direct cause. What this case pins is the contract, not the
  # cure: the lock covers deciding whether to start and starting, and nothing
  # after -- so a marker that is late or missing for any reason costs this caller
  # its own wait and not the rest of the machine.
  #
  # So this asserts the property from outside: while the starter is STILL
  # polling, the lock must not be held. Nothing here inspects the loop.
  local lock="$TEST_SKILL_DIR/teams/testteam/.config.lock"
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  local starter i=0 j=0 freed=0

  bash "$SCRIPTS/remote.sh" sync start testteam >/dev/null 2>&1 &
  starter=$!

  # The engine existing is what says the START is over and the WAIT has begun.
  while [ ! -f "$pidfile" ] && [ "$i" -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
  [ -f "$pidfile" ]

  # Both halves in one condition, deliberately: a free lock AFTER the starter
  # has returned proves nothing -- that is the old behaviour too. What has to
  # hold is free WHILE it is still in there.
  while [ "$j" -lt 60 ]; do
    if [ ! -d "$lock" ] && kill -0 "$starter" 2>/dev/null; then freed=1; break; fi
    j=$((j + 1)); sleep 0.05
  done
  [ "$freed" -eq 1 ]

  kill "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null || true
  wait "$starter" 2>/dev/null || true
}

@test "sync start: two at once leave exactly one engine, on the blind probe (#817, #652)" {
  # THE INVARIANT THE EARLY RELEASE RESTS ON, DRIVEN ON THE PLATFORM THAT BREAKS IT.
  #
  # Letting go of the lock before the readiness wait is only safe because a
  # second `sync start` reads `running` from `_remote_sync_engine_status` and
  # returns without starting anything. That reading asks whether the pid is
  # alive -- and on Windows the non-local probe cannot see a pid this shell
  # minted (#652), so it answers `stale`, the second caller does NOT stop, and
  # two engines end up running for one team.
  #
  # I asserted that invariant from reading the code and did not measure it on the
  # platform that breaks it. Review caught that. So it is driven here rather than
  # argued: `MSYSTEM` plus a `tasklist` that answers nothing is the condition
  # #652 reproduces, and it runs on any host.
  #
  # A TEAM NAME NOBODY ELSE USES, because this test counts processes.
  #
  # It first counted with `pgrep -f "... --team testteam"`, which is machine-wide
  # and names a team half this suite also uses: it counted -- and KILLED --
  # engines belonging to other cases, other files and other shards. Scoping by
  # `$TEST_SKILL_DIR` would not help either, since the store is passed in the
  # environment and never appears in argv. The team name IS in argv, so making it
  # unique makes every match this test's own (raised in review).
  local team="lockrace817"
  bash "$SCRIPTS/join.sh" "$team" alice claude-code /tmp/project-lockrace >/dev/null

  local cfg="$TEST_SKILL_DIR/teams/$team/config.json" escaped updated
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

  local pattern="remote-sync.mjs run --team $team"
  # Nothing of this name may exist yet; if it does, the isolation is not real
  # and every count below would be meaningless.
  [ -z "$(pgrep -f "$pattern")" ]

  local blind="$TEST_SKILL_DIR/blind-probe"
  mkdir -p "$blind"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$blind/tasklist"
  chmod +x "$blind/tasklist"

  local pidfile="$TEST_SKILL_DIR/run/remote-sync.$team.pid"
  local one two i=0 k=0 running=0

  env PATH="$blind:$PATH" MSYSTEM=MINGW64 bash "$SCRIPTS/remote.sh" sync start "$team" >/dev/null 2>&1 &
  one=$!
  while [ ! -f "$pidfile" ] && [ "$i" -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
  [ -f "$pidfile" ]
  env PATH="$blind:$PATH" MSYSTEM=MINGW64 bash "$SCRIPTS/remote.sh" sync start "$team" >/dev/null 2>&1 &
  two=$!

  # NOT waiting for either starter to return, deliberately. With the blind probe
  # the readiness marker can never be satisfied, so each starter runs its whole
  # 1600-turn loop -- minutes here, and the thing being measured is over long
  # before that. A second engine, if it is going to exist, exists as soon as the
  # second caller has decided; that decision is what this watches.
  while [ "$k" -lt 60 ]; do
    running="$(pgrep -f "$pattern" | wc -l | tr -d ' ')"
    [ "$running" -gt 1 ] && break        # fail fast: the defect has happened
    kill -0 "$two" 2>/dev/null || break  # the second caller is done deciding
    k=$((k + 1)); sleep 0.05
  done
  running="$(pgrep -f "$pattern" | wc -l | tr -d ' ')"

  # Counted by what is actually running rather than by what the pidfile says --
  # the pidfile only ever names the most recent, which is how a second engine
  # hides from anyone who asks the file. Everything torn down here carries this
  # test's own team name, so nothing else on the machine is touched.
  pkill -f "$pattern" 2>/dev/null || true
  kill "$one" "$two" 2>/dev/null || true
  wait "$one" "$two" 2>/dev/null || true

  [ "$running" -le 1 ]
}

@test "sync start: a timed-out starter does not clear another engine's records (#817)" {
  # THE CLEANUP AFTER THE WAIT WRITES SHARED STATE, and the early release means
  # it can arrive to find that state belonging to somebody else.
  #
  # The pidfile and the cycle stamp are per team, not per caller. While this
  # starter polls, another `sync start` may complete and record its own engine --
  # and that pidfile is the only thing naming it.
  #
  # ORDER MATTERS HERE, and the first version got it wrong. It wrote the foreign
  # pid while this starter's own engine was still alive, so
  # `_remote_sync_engine_reap_owned` saw a record it could not prove was ours and
  # returned non-zero -- the branch holding the removal was never entered, and
  # the case passed with the guard removed too. Ending our own engine FIRST makes
  # the reap succeed on its "already gone" path, which is the only way into the
  # removal (raised in review).
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  local cycles="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  local starter engine foreign i=0

  bash "$SCRIPTS/remote.sh" sync start testteam >/dev/null 2>&1 &
  starter=$!
  while [ ! -f "$pidfile" ] && [ "$i" -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
  [ -f "$pidfile" ]
  engine="$(cat "$pidfile")"

  # Our own engine ends first, so the reap reaches its success path.
  kill "$engine" 2>/dev/null || true
  i=0
  while kill -0 "$engine" 2>/dev/null && [ "$i" -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
  refute kill -0 "$engine" 2>/dev/null

  # Somebody else's engine, recorded while this starter is still polling. BOTH
  # files, because the cleanup removes them on two separate lines and a control
  # that watches one does not protect the other (raised in review).
  sleep 300 &
  foreign=$!
  printf '%s\n' "$foreign" > "$pidfile"
  printf '%s\n' "REPLACEMENT-CYCLE-STATE" > "$cycles"

  wait "$starter" 2>/dev/null || true

  # The record survives, and still names the other engine.
  [ -f "$pidfile" ]
  [ "$(cat "$pidfile")" = "$foreign" ]
  # And so does the other half of it, byte for byte.
  [ -f "$cycles" ]
  [ "$(cat "$cycles")" = "REPLACEMENT-CYCLE-STATE" ]

  kill "$foreign" 2>/dev/null || true
  wait "$foreign" 2>/dev/null || true
}

@test "sync start: a cleanup that cannot retake the lock says so and keeps the record (#817)" {
  # THE RETAKE, OBSERVED WHERE IT DIFFERS FROM NOT RETAKING.
  #
  # After the early release the timeout cleanup writes shared state, so it takes
  # the lock back first. That is only distinguishable from not taking it when
  # somebody else is holding it -- so a helper holds this team's lock for the
  # whole window, and the starter has to arrive at its cleanup and find it taken.
  #
  # Our own engine is ended first for the same reason as the case above: it is
  # the only way `_remote_sync_engine_reap_owned` reaches its success path, and
  # therefore the only way the cleanup gets as far as the records.
  local pidfile="$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  local lock="$TEST_SKILL_DIR/teams/testteam/.config.lock"
  local cycles="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  local starter engine i=0 err="$TEST_SKILL_DIR/retake.err"

  bash "$SCRIPTS/remote.sh" sync start testteam >"$err" 2>&1 &
  starter=$!
  while [ ! -f "$pidfile" ] && [ "$i" -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
  [ -f "$pidfile" ]
  engine="$(cat "$pidfile")"

  # Somebody else takes the lock and keeps it. Held with mkdir directly, the way
  # the library takes it, so no helper of ours has to survive the wait.
  mkdir "$lock"
  printf '%s\n' "KEPT-CYCLE-STATE" > "$cycles"

  kill "$engine" 2>/dev/null || true
  i=0
  while kill -0 "$engine" 2>/dev/null && [ "$i" -lt 200 ]; do i=$((i + 1)); sleep 0.05; done

  wait "$starter" 2>/dev/null || true

  # 1. it said it could not retake, rather than clearing the records blind
  grep -q 'could not retake the registry lock' "$err"
  # 2. and BOTH records are still there. Two separate removals, two assertions:
  # watching only the pidfile leaves the cycle line unguarded (raised in review).
  [ -f "$pidfile" ]
  [ -f "$cycles" ]
  [ "$(cat "$cycles")" = "KEPT-CYCLE-STATE" ]

  rmdir "$lock" 2>/dev/null || true
}
