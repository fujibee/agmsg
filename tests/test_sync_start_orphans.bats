#!/usr/bin/env bats

# `sync start` must not walk away from a process it started (#831).
#
# Measured on Windows 11: readiness could not be confirmed, `sync start` reported
# failure, deleted the pidfile and left. The engine kept running and kept pulling.
# Three invocations left three live engines; a follow-up reproduction reached six.
# `status` reported stopped for all of them, and the pidfile was the only thing
# that had ever named them.
#
# TWO PROBES DISAGREE ON WINDOWS, AND THE CODE BELIEVED THE WRONG ONE. `kill -0`
# cannot see a live engine there (#652), so `_remote_sync_engine_status` answered
# `stale`, the reap refused to signal a pid it could not confirm, and the caller
# deleted the record anyway.
#
# The asymmetry is the whole design. A probe that wrongly says ALIVE costs one
# signal aimed at a process whose cmdline still names this team's engine. A probe
# that wrongly says GONE leaves that engine running with nobody to stop it. So
# "gone" now requires every probe to agree (`compat_pid_gone`), and the signal
# goes through whatever the host uses to end a tree (`compat_signal_pid_tree`) --
# on Windows `taskkill /PID <winpid> /T`, because an MSYS kill reaches the shell
# and not the node process under it.
#
# OWNERSHIP IS STILL THE CMDLINE, NOT THE NUMBER. A pid stops being an identity
# token the moment its process exits, and `taskkill /T` on a reused number ends
# somebody else's tree. Every pass re-reads `_remote_sync_engine_status`, which
# answers `running` only while the cmdline names this team's engine.
#
# WHAT THIS FILE DOES NOT COVER. #831 names two independent directions and this
# is the first. The second -- every engine appending to one shared log, so the
# lines tear into each other and every tool that reads that log, including the
# readiness poll, reads fragments -- is untouched, and no case below says
# anything about it.
#
# AND WHAT THE WINDOWS CASES ARE WORTH. They drive the Windows ROUTE on this
# host: `MSYSTEM` set, and a `ps`/`tasklist`/`taskkill` on PATH that speak the
# shapes Git Bash speaks. That measures that the route is chosen and that the
# process dies through it. It is not a measurement of native `node.exe` dying on
# real Windows; only the Windows machine closes that, and it is asked to.

load test_helper

# A team name of this file's own, because these cases COUNT AND KILL processes by
# their `--team` argument -- the only part of an engine's argv that is not shared
# (the store is passed in the environment, and never appears there).
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
  # A run that was interrupted leaves one of these behind -- this file's cases
  # are ABOUT a process outliving its command, so that is not hypothetical. The
  # name is this file's own, so anything answering to it is ours to end.
  pkill -f "$PATTERN" 2>/dev/null || true
  # Then assert, because every count below is meaningless if one survived.
  [ -z "$(pgrep -f "$PATTERN")" ]
}

teardown() {
  # This file exists BECAUSE an engine can be left running, so it cannot rely on
  # the code under test to clean up after its own cases.
  pkill -f "$PATTERN" 2>/dev/null || true
  teardown_test_env
}

# A Git-Bash-shaped Windows side, on this host.
#
#   ps -l -p <pid>   a WINPID column, as MSYS2's ps prints one. The number is
#                    derived from the pid so each process has its own.
#   tasklist         answers ALIVE for any WINPID whose marker file exists --
#                    this is the probe that has to override the POSIX one.
#   taskkill         records the arguments it was called with, then ends the
#                    process for real, which is what Windows would do.
#
# `stub_windows blind` additionally makes the POSIX liveness probe answer "gone"
# for everything, which is the #652 reading the whole defect rests on.
stub_windows() {
  WINSTUB="$TEST_SKILL_DIR/winstub"
  # taskkill ALONE, for the negative control: reachable on PATH, with the host
  # still answering what it really is. Kept in its own directory because the
  # `uname` stub below is what makes the msys branch run, and a control that
  # shares a directory with it is not a control (measured: the off-Windows case
  # called taskkill, because $WINSTUB put a Windows `uname` on its PATH too).
  WINSTUB_POSIX="$TEST_SKILL_DIR/winstub-posix"
  TASKKILL_LOG="$TEST_SKILL_DIR/taskkill.log"
  ALIVE_DIR="$TEST_SKILL_DIR/winalive"
  mkdir -p "$WINSTUB" "$WINSTUB_POSIX" "$ALIVE_DIR"

  # `MSYSTEM` alone is not the switch. `_agmsg_detect_platform` asks `uname -s`,
  # so a host that answers Darwin takes the POSIX branch however MSYSTEM is set --
  # measured while writing this, on a run where every Windows assertion passed
  # vacuously because the branch under test never executed. Both are set below.
  cat > "$WINSTUB/uname" <<'EOF_UN'
#!/usr/bin/env bash
if [ "$1" = "-s" ]; then printf 'MINGW64_NT-10.0-22631\n'; exit 0; fi
exec /usr/bin/uname "$@"
EOF_UN

  cat > "$WINSTUB/ps" <<'EOF_PS'
#!/usr/bin/env bash
# Only the `-l -p <pid>` form is used here; anything else falls through to the
# real ps, so nothing outside this stub's purpose is affected.
if [ "$1" = "-l" ] && [ "$2" = "-p" ]; then
  printf 'PID WINPID PPID STATE\n'
  printf '%s %s 1 S\n' "$3" "$((900000 + $3))"
  exit 0
fi
exec /bin/ps "$@"
EOF_PS

  cat > "$WINSTUB/tasklist" <<EOF_TL
#!/usr/bin/env bash
# tasklist /FI "PID eq <winpid>". The filter is ONE argument, so the number is
# the last word of THAT argument. Not \${*##* }: that form applies the pattern to
# each positional separately and joins them, which yields "/FI <winpid>" and
# matches nothing -- it read as "the process is gone", the answer this stub
# exists to contradict.
winpid=""
for a in "\$@"; do case "\$a" in *' eq '*) winpid="\${a##* }" ;; esac; done
if [ -e "$ALIVE_DIR/\$winpid" ]; then
  printf 'node.exe %s Console 1 100 K\n' "\$winpid"
fi
exit 0
EOF_TL

  cat > "$WINSTUB/taskkill" <<EOF_TK
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TASKKILL_LOG"
winpid=""
while [ \$# -gt 0 ]; do
  case "\$1" in /PID) winpid="\$2"; shift 2 ;; *) shift ;; esac
done
case "\$winpid" in ''|*[!0-9]*) exit 1 ;; esac
rm -f "$ALIVE_DIR/\$winpid"
kill -KILL "\$((winpid - 900000))" 2>/dev/null || true
exit 0
EOF_TK

  # The cmdline, which is how ownership is proven. Under Git Bash there is no
  # /proc for a native process, so compat_get_cmdline asks Windows through CIM;
  # this answers that question for the WINPID, from the real process, so the
  # ownership check the reap performs is the real one and not a stubbed yes.
  cat > "$WINSTUB/powershell.exe" <<'EOF_PWSH'
#!/usr/bin/env bash
args="$*"
winpid="${args##*ProcessId=}"
winpid="${winpid%%\"*}"
case "$winpid" in ''|*[!0-9]*) exit 0 ;; esac
/bin/ps -o args= -p "$((winpid - 900000))" 2>/dev/null
EOF_PWSH

  # `ps` comes WITH it. Without a WINPID column the platform check is not the
  # thing keeping taskkill away -- there is simply no number to pass it, and the
  # control passes for the wrong reason. Measured: dropping the msys guard
  # entirely left all ten cases green, because macOS `ps -l` has no such column.
  cp "$WINSTUB/ps" "$WINSTUB_POSIX/ps"
  cp "$WINSTUB/taskkill" "$WINSTUB_POSIX/taskkill"
  chmod +x "$WINSTUB/uname" "$WINSTUB/ps" "$WINSTUB/tasklist" "$WINSTUB/taskkill" \
           "$WINSTUB/powershell.exe" "$WINSTUB_POSIX/ps" "$WINSTUB_POSIX/taskkill"
}

# Marks a pid alive to the stubbed Windows side.
win_mark_alive() { : > "$ALIVE_DIR/$((900000 + $1))"; }

# The driver: sources remote.sh and calls the real `cmd_sync_start`.
#
# A file rather than `bash -c`, so the only difference between the callers below
# is the mode argument.
write_driver() {
  DRIVER="$TEST_SKILL_DIR/drive-sync-start.sh"
  cat > "$DRIVER" <<'EOF_DRIVER'
#!/usr/bin/env bash
# $1 = team, $2 = mode
#   honest  nothing overridden
#   blind   the POSIX liveness probe reads every pid as gone -- the #652 reading
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

# Runs the driver under the stubbed Windows side, having marked the engine alive
# there once it exists. The marking has to happen after the fork, so the driver
# runs in the background and this waits for it.
run_windows_driver() {
  local mode="$1" out="$TEST_SKILL_DIR/win-$mode.out" p i=0
  env SCRIPTS="$SCRIPTS" PATH="$WINSTUB:$PATH" MSYSTEM=MINGW64 \
      AGMSG_TEST_SYNC_READY_TURNS=40 \
      bash "$DRIVER" "$TEAM" "$mode" >"$out" 2>&1 &
  p=$!
  while [ ! -f "$PIDFILE" ] && [ "$i" -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
  [ -f "$PIDFILE" ]
  ENGINE="$(cat "$PIDFILE")"
  win_mark_alive "$ENGINE"
  wait "$p" 2>/dev/null || true
  OUT="$(cat "$out")"
}

@test "sync start: a blind POSIX probe no longer hides the engine from the reap (#831)" {
  # THE DEFECT ITSELF. `kill -0` says gone -- the Windows reading -- and the
  # engine is running. It has to be stopped anyway, and no orphan may remain.
  stub_windows
  write_driver
  run_windows_driver blind

  grep -qF 'driver: cmd_sync_start rc=1' <<<"$OUT"

  # Nothing of this team is left running. Counted by what is on the machine, not
  # by what the pidfile says -- the pidfile only ever names the most recent.
  local running
  running="$(pgrep -f "$PATTERN" | wc -l | tr -d ' ')"
  [ "$running" -eq 0 ]
  # And its records are gone with it, so the next `sync start` starts one engine.
  [ ! -f "$PIDFILE" ]
}

@test "sync start: it is the Windows route that ended it, named by WINPID (#831)" {
  # Asserted separately from the case above, because "the process died" does not
  # say WHAT killed it -- on this host the POSIX kill would do it on its own, and
  # that is precisely the thing that does not work on Windows.
  stub_windows
  write_driver
  run_windows_driver blind

  [ -f "$TASKKILL_LOG" ]
  # The tree, by the WINPID the ps stub derived for this engine -- not the pid.
  grep -qF "/PID $((900000 + ENGINE)) /T" "$TASKKILL_LOG"
}

@test "compat_signal_pid_tree: off Windows it does not reach for taskkill (#831)" {
  # THE NEGATIVE CONTROL FOR THE ROUTE. Without it, "always call taskkill"
  # satisfies the case above, and every POSIX host would depend on a Windows
  # binary being on PATH.
  stub_windows
  local live
  sleep 30 & live=$!
  win_mark_alive "$live"

  cat > "$TEST_SKILL_DIR/sig.sh" <<'EOF_SIG'
#!/usr/bin/env bash
. "$SCRIPTS/lib/compat.sh"
compat_signal_pid_tree "$1" TERM
EOF_SIG
  # No MSYSTEM, and the real uname, so the msys branch must not run -- while both
  # taskkill AND a ps that yields a WINPID are on PATH, so "it was not called" is
  # a decision this code made and not something the environment prevented.
  run env SCRIPTS="$SCRIPTS" PATH="$WINSTUB_POSIX:$PATH" bash "$TEST_SKILL_DIR/sig.sh" "$live"
  [ "$status" -eq 0 ]
  [ ! -f "$TASKKILL_LOG" ]
  # It still signalled, through the route this platform has.
  local i=0
  while kill -0 "$live" 2>/dev/null && [ "$i" -lt 100 ]; do i=$((i + 1)); sleep 0.01; done
  run kill -0 "$live"
  [ "$status" -ne 0 ]
}

@test "compat_pid_gone: one probe saying gone is not enough (#831)" {
  # The property the rest of it stands on, on its own. The POSIX probe says gone;
  # the Windows side says alive; the answer must be "not gone".
  stub_windows
  local pid=4242
  win_mark_alive "$pid"

  cat > "$TEST_SKILL_DIR/gone.sh" <<'EOF_GONE'
#!/usr/bin/env bash
. "$SCRIPTS/lib/instance-id.sh"
. "$SCRIPTS/lib/compat.sh"
_agmsg_pid_alive_local() { return 1; }     # the #652 reading
rc=0
compat_pid_gone "$1" || rc=$?
echo "gone rc=$rc"
EOF_GONE
  run env SCRIPTS="$SCRIPTS" PATH="$WINSTUB:$PATH" MSYSTEM=MINGW64 \
      bash "$TEST_SKILL_DIR/gone.sh" "$pid"
  grep -qF 'gone rc=1' <<<"$output"

  # NEGATIVE CONTROL, in the same case: with the Windows side also saying gone,
  # the answer flips. Otherwise "never gone" would pass the assertion above.
  rm -f "$ALIVE_DIR/$((900000 + pid))"
  run env SCRIPTS="$SCRIPTS" PATH="$WINSTUB:$PATH" MSYSTEM=MINGW64 \
      bash "$TEST_SKILL_DIR/gone.sh" "$pid"
  grep -qF 'gone rc=0' <<<"$output"
}

@test "compat_pid_gone: without instance-id.sh it refuses rather than answering gone (#831)" {
  # A missing dependency exits 127, which is not 0, which fell straight through
  # to "gone" -- the one answer this function exists to make hard to reach.
  cat > "$TEST_SKILL_DIR/nodep.sh" <<'EOF_NODEP'
#!/usr/bin/env bash
. "$SCRIPTS/lib/compat.sh"
rc=0
compat_pid_gone 4242 || rc=$?
echo "gone rc=$rc"
EOF_NODEP
  run env SCRIPTS="$SCRIPTS" bash "$TEST_SKILL_DIR/nodep.sh"
  grep -qF 'gone rc=1' <<<"$output"
  grep -qF 'needs lib/instance-id.sh sourced' <<<"$output"
}

@test "sync start: with an honest probe the engine is stopped and its records cleared (#831)" {
  # The ordinary path, unstubbed, so the Windows work above cannot have broken
  # the thing that already worked.
  #
  # AND THE ONLY CASE THAT LEAVES THE READINESS CEILING ALONE. The others set
  # AGMSG_TEST_SYNC_READY_TURNS, because reaching the give-up path costs the full
  # 1600 turns and none of them are about that number. This one pays it, so the
  # shipped default is on the path of something.
  write_driver
  local began ended
  began="$(date +%s)"
  run env SCRIPTS="$SCRIPTS" bash "$DRIVER" "$TEAM" honest
  ended="$(date +%s)"

  grep -qF 'driver: cmd_sync_start rc=1' <<<"$output"
  # AND THE SHIPPED CEILING IS STILL THE SHIPPED ONE. The seam defaults to 1600
  # turns of a 0.01s sleep, so this path cannot return in under sixteen seconds.
  # Asserted on the floor the sleep puts there, not on how long the forks take.
  # Without this, the seam's default could be lowered and nothing would notice.
  [ "$((ended - began))" -ge 15 ]
  local running
  running="$(pgrep -f "$PATTERN" | wc -l | tr -d ' ')"
  [ "$running" -eq 0 ]
  [ ! -f "$PIDFILE" ]
}

@test "sync start: when it cannot stop it, it keeps the record and says so (#831)" {
  # THE OTHER HALF. A reap that fails means an orphan exists, and the record is
  # the only thing that names it -- so the failure path must not clear it, and
  # must not be silent about which situation the operator is in.
  #
  # Driven by making the engine unkillable from the driver: the signal helper is
  # replaced with one that does nothing, which is what a sandbox that refuses to
  # signal looks like from in here (#730 measured that on Codex).
  DRIVER="$TEST_SKILL_DIR/drive-unkillable.sh"
  cat > "$DRIVER" <<'EOF_UNKILL'
#!/usr/bin/env bash
. "$SCRIPTS/remote.sh"
compat_signal_pid_tree() { return 0; }     # every signal silently goes nowhere
rc=0
cmd_sync_start "$1" || rc=$?
echo "driver: cmd_sync_start rc=$rc"
EOF_UNKILL
  chmod +x "$DRIVER"

  run env SCRIPTS="$SCRIPTS" AGMSG_TEST_SYNC_READY_TURNS=40 bash "$DRIVER" "$TEAM"
  grep -qF 'driver: cmd_sync_start rc=1' <<<"$output"

  # It is still running, and it still has a name.
  local running
  running="$(pgrep -f "$PATTERN" | wc -l | tr -d ' ')"
  [ "$running" -eq 1 ]
  [ -f "$PIDFILE" ]
  pgrep -f "$PATTERN" | grep -qxF "$(cat "$PIDFILE")"
  grep -qF 'did not stop it' <<<"$output"
}

@test "sync start: the give-up message does not name a cause it did not measure (#831)" {
  # It used to say the engine could not reach the server and that nothing was
  # syncing for the team. The engines this text was written for were reaching the
  # server and pulling the whole time. `refute` and not `! grep`: a negated
  # command cannot fail a bats test at all (#670).
  DRIVER="$TEST_SKILL_DIR/drive-unkillable.sh"
  cat > "$DRIVER" <<'EOF_UNKILL2'
#!/usr/bin/env bash
. "$SCRIPTS/remote.sh"
compat_signal_pid_tree() { return 0; }
rc=0
cmd_sync_start "$1" || rc=$?
echo "driver: cmd_sync_start rc=$rc"
EOF_UNKILL2
  chmod +x "$DRIVER"

  run env SCRIPTS="$SCRIPTS" AGMSG_TEST_SYNC_READY_TURNS=40 bash "$DRIVER" "$TEAM"
  refute grep -qF 'It cannot reach the server' <<<"$output"
  refute grep -qF 'Nothing is syncing' <<<"$output"
}

@test "sync start: on Windows the way out it prints is not the one that fails there (#831)" {
  # `kill <pid>` was the only manual stop offered, and #831 measured that it does
  # not end the native node under the MSYS shell. Offering it as the way out
  # sends the operator to do the thing that already did not work.
  stub_windows
  DRIVER="$TEST_SKILL_DIR/drive-unkillable-win.sh"
  cat > "$DRIVER" <<'EOF_UNKILL3'
#!/usr/bin/env bash
. "$SCRIPTS/remote.sh"
compat_signal_pid_tree() { return 0; }
rc=0
cmd_sync_start "$1" || rc=$?
echo "driver: cmd_sync_start rc=$rc"
EOF_UNKILL3
  chmod +x "$DRIVER"

  local out="$TEST_SKILL_DIR/winmsg.out" p i=0
  env SCRIPTS="$SCRIPTS" PATH="$WINSTUB:$PATH" MSYSTEM=MINGW64 \
      AGMSG_TEST_SYNC_READY_TURNS=40 \
      bash "$DRIVER" "$TEAM" >"$out" 2>&1 &
  p=$!
  while [ ! -f "$PIDFILE" ] && [ "$i" -lt 400 ]; do i=$((i + 1)); sleep 0.05; done
  [ -f "$PIDFILE" ]
  ENGINE="$(cat "$PIDFILE")"
  win_mark_alive "$ENGINE"
  wait "$p" 2>/dev/null || true

  grep -qF "taskkill /PID $((900000 + ENGINE)) /T /F" "$out"
  # And it names why, so the next reader does not put `kill` back.
  grep -qF 'not the node process under it' "$out"
}

@test "reap: a live pid whose cmdline is another process is never signalled (#831)" {
  # THE OTHER HALF OF THE ASYMMETRY, and the one that stops it from becoming a
  # new defect. Overriding "gone" with a second probe means more pids now reach
  # the signalling code -- so what proves the pid is OURS has to be the thing
  # that survives reuse, and a number does not. The moment a process exits its
  # pid is reusable, and `taskkill /T` on a reused number ends a stranger's tree.
  #
  # Here the pidfile names a process that is alive on both probes and is not the
  # engine. Nothing may be sent to it, by either route (raised in review on #840).
  stub_windows
  local other
  sleep 30 & other=$!
  win_mark_alive "$other"
  printf '%s\n' "$other" > "$PIDFILE"

  cat > "$TEST_SKILL_DIR/reap-foreign.sh" <<'EOF_FOREIGN'
#!/usr/bin/env bash
. "$SCRIPTS/remote.sh"
rc=0
_remote_sync_engine_reap_owned "$1" "$2" || rc=$?
echo "reap rc=$rc"
EOF_FOREIGN

  run env SCRIPTS="$SCRIPTS" PATH="$WINSTUB:$PATH" MSYSTEM=MINGW64 \
      bash "$TEST_SKILL_DIR/reap-foreign.sh" "$TEAM" "$other"

  # 1 = ownership not proven. Not 0, which would say this call stopped it, and
  # not 2, which would say it is gone.
  grep -qF 'reap rc=1' <<<"$output"
  # Nothing was sent down the Windows route...
  [ ! -f "$TASKKILL_LOG" ]
  # ...and nothing down the POSIX one either: it is still running.
  kill -0 "$other"
  # And the record it could not act on is still there for `status` to describe.
  [ -f "$PIDFILE" ]

  kill "$other" 2>/dev/null || true
}
