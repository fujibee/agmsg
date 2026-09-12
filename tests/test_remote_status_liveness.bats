#!/usr/bin/env bats

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
  ENGINE_PIDS=""
}

teardown() {
  local pid
  for pid in $ENGINE_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  teardown_test_env
}

start_matching_engine() {
  local engine="$SCRIPTS/internal/remote-sync.mjs"
  printf '%s\n' '#!/usr/bin/env bash' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$engine"
  chmod +x "$engine"
  bash "$engine" run --team testteam &
  ENGINE_PID=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$ENGINE_PID"
  printf '%s\n' "$ENGINE_PID" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
}

# Fakes ONE question: what is this pid's argv. Everything else goes to the real
# ps.
#
# The `-o args=` guard is load-bearing. Without it the fixture answers every
# `ps -p <ENGINE_PID>` with the argv string, and liveness now asks a different
# question through the same command -- `_agmsg_pid_alive` consults
# `ps -o stat= -p` when kill(1) reports ESRCH, and reads any non-empty,
# non-zombie state as alive. A killed engine then reads as running, `sync start`
# no-ops, and the test that asserts a NEW pid fails on an assertion that names
# neither ps nor the fixture.
#
# So the fixture has to be as narrow as the thing it stands in for: a fake that
# answers questions it was never asked will answer one that matters.
write_matching_ps_fixture() {
  local fake_bin="$TEST_SKILL_DIR/fake-bin"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [[ \" \$* \" == *\" -p $ENGINE_PID \"* && \" \$* \" == *\" -o args= \"* ]]; then" \
    "  printf '%s\\n' 'bash $SCRIPTS/internal/remote-sync.mjs run --team testteam'" \
    '  exit 0' \
    'fi' \
    'exec /bin/ps "$@"' > "$fake_bin/ps"
  chmod +x "$fake_bin/ps"
  printf '%s\n' "$fake_bin"
}

write_fake_node() {
  local trailing_records="${1:-0}" fake_node="$TEST_SKILL_DIR/fake-node"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then' \
    '  echo v23.0.0' \
    '  exit 0' \
    'fi' \
    'echo "{\"event\":\"capabilities\",\"startup_nonce\":\"${AGMSG_SYNC_START_NONCE:-}\"}"' \
    "trailing_records=$trailing_records" \
    'awk -v count="$trailing_records" '\''BEGIN {' \
    '  padding = sprintf("%16384s", "")' \
    '  gsub(/ /, "x", padding)' \
    '  for (i = 0; i < count; i++) {' \
    '    print "{\"event\":\"capabilities\",\"startup_nonce\":\"other-generation\",\"padding\":\"" padding "\"}"' \
    '  }' \
    '}'\''' \
    '[ -z "${AGMSG_TEST_LOG_READY_FILE:-}" ] || : > "$AGMSG_TEST_LOG_READY_FILE"' \
    '[ -z "${AGMSG_TEST_CHILD_PID_FILE:-}" ] || printf '\''%s\\n'\'' "$$" > "$AGMSG_TEST_CHILD_PID_FILE"' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  printf '%s\n' "$fake_node"
}

write_fake_node_ps_fixture() {
  local fake_node="$1" foreign_pid="${2:-}" ready_file="${3:-}" \
    fake_bin="$TEST_SKILL_DIR/fake-node-bin"
  mkdir -p "$fake_bin"
  # Answers the argv question only. Anything else -- notably `-o stat=`, which
  # `_agmsg_pid_alive` consults when kill(1) reports ESRCH -- goes to the real
  # ps.
  #
  # Without that guard this fixture replies to EVERY ps call, for every pid,
  # with an argv string and exit 0. Liveness then reads that string as a process
  # state: non-empty and not starting with `Z`, so a killed engine reads as
  # alive, `sync start` reports "already running", and the assertion that fails
  # is the one about the new pid -- naming neither ps nor this fixture.
  printf '%s\n' '#!/usr/bin/env bash' \
    'pid=""; args=0' \
    'for a in "$@"; do' \
    '  case "$a" in -o) ;; args=) args=1 ;; esac' \
    'done' \
    'case " $* " in *" -o args= "*) args=1 ;; esac' \
    '[ "$args" = 1 ] || exec /bin/ps "$@"' \
    'set -- "$@"' \
    'while [ $# -gt 0 ]; do' \
    '  if [ "$1" = "-p" ]; then pid="$2"; shift 2; else shift; fi' \
    'done' \
    "if { [ -n '$ready_file' ] && [ ! -f '$ready_file' ]; } || [ \"\$pid\" = '$foreign_pid' ]; then" \
    "  printf '%s\\n' 'sleep 30'" \
    'else' \
    "  printf '%s\\n' 'bash $SCRIPTS/internal/remote-sync.mjs run --team testteam'" \
    'fi' > "$fake_bin/ps"
  chmod +x "$fake_bin/ps"
  printf '%s\n' "$fake_bin"
}

remember_engine_pid() {
  ENGINE_PID="$(cat "$TEST_SKILL_DIR/run/remote-sync.testteam.pid")"
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$ENGINE_PID"
}

# The Windows spelling, through the production entry. (#652)
#
# `write_matching_ps_fixture` answers with the POSIX path, which is the case
# that never broke. These two answer with what the reporting machine actually
# showed -- a drive-letter path -- and put a `cygpath` stub on PATH so the
# conversion the comparator relies on exists.
#
# The point is the WIRING, not the comparator: `tests/test_cmdline_path_match.bats`
# drives `agmsg_cmdline_names_path` alone, and every one of its cases stays green
# if `remote.sh` goes back to the old suffix match. These two go red.
write_windows_spelling_fixtures() {
  local fake_bin="$TEST_SKILL_DIR/fake-win-bin" engine_win="C:/w/scripts/internal/remote-sync.mjs"
  mkdir -p "$fake_bin"
  # ps: this pid's argv, spelled the way a native binary reports it.
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [[ \" \$* \" == *\" -p $ENGINE_PID \"* && \" \$* \" == *\" -o args= \"* ]]; then" \
    "  printf '%s\\n' '\"C:\\Program Files\\nodejs\\node.exe\" $engine_win run --team testteam'" \
    '  exit 0' \
    'fi' \
    'exec /bin/ps "$@"' > "$fake_bin/ps"
  # cygpath: only the one path this test is about. A stub that rewrote
  # everything would hide a comparator that converts the wrong operand.
  printf '%s\n' '#!/usr/bin/env bash' \
    "if [ \"\$2\" = \"$SCRIPTS/internal/remote-sync.mjs\" ]; then" \
    "  printf '%s' '$engine_win'" \
    '  exit 0' \
    'fi' \
    'printf %s "$2"' > "$fake_bin/cygpath"
  chmod +x "$fake_bin/ps" "$fake_bin/cygpath"
  printf '%s\n' "$fake_bin"
}

@test "status: a Windows-spelled argv still names this team's engine (#652)" {
  start_matching_engine
  local fake_bin; fake_bin="$(write_windows_spelling_fixtures)"
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  # `stale` is what the reporting machine got while the engine was running.
  refute grep -qi 'stale' <<<"$output"
  grep -qiE 'running|active' <<<"$output"
}

@test "disconnect: a Windows-spelled argv gets the engine stopped, not just forgotten (#652)" {
  # The third contract, and it is not reached by a `sync stop` -- there is no
  # such command. `_remote_sync_engine_stop` is what `unlock`, `disconnect`,
  # `forget` and `set-endpoint` all call, and it reaps ONLY when the state is
  # `running` while removing the pidfile either way. So a comparison that reads
  # `stale` makes `disconnect` erase the engine's whereabouts and leave it
  # polling a team whose binding was just torn off.
  start_matching_engine
  local fake_bin; fake_bin="$(write_windows_spelling_fixtures)"
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  refute test -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  # The engine itself -- the half that "forgotten" leaves behind, and the whole
  # reason the pidfile assertion above is not enough on its own.
  sleep 1
  refute kill -0 "$ENGINE_PID" 2>/dev/null
}

@test "status: a running engine that has never completed a cycle says so (#756)" {
  # `engine running` reports that a process is alive, which is true and is not
  # the question an operator has. In #744's report an engine failed every cycle
  # for an entire session while this line said `running` the whole time.
  start_matching_engine
  local fake_bin stamp
  fake_bin="$(write_matching_ps_fixture)"
  stamp="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"

  # Negative side first, on the state a just-started engine is actually in: no
  # record yet. Asserting only the populated case would pass for a line printed
  # unconditionally.
  [ ! -e "$stamp" ]
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected (engine running"
  printf '%s\n' "$output" | grep -q -F -- "cycles: no successful cycle recorded since this engine started"

  printf '%s\n' '{"type":"sync_cycle_stamp","first_success_at":"2026-08-11T20:00:00.000Z","last_success_at":"2026-08-11T20:34:56.000Z"}' > "$stamp"
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  # The LAST success, not the first: "it worked once at some point" is the claim
  # that made the original report hard to read.
  printf '%s\n' "$output" | grep -q -F -- "cycles: last successful sync 2026-08-11T20:34:56.000Z"
  refute grep -qF -- "no successful cycle recorded" <<<"$output"
}

@test "status: a stopped engine does not also report zero cycles (#756)" {
  # Two lines for one fault reads as two faults. The stopped line above already
  # says the useful thing and names the command that fixes it.
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected (engine stopped"
  refute grep -qF -- "cycles:" <<<"$output"
}

@test "stopping an engine takes its cycle record with it (#756)" {
  # Left behind, the NEXT engine's first `status` would report a predecessor's
  # success as its own -- the exact claim this record exists to prevent.
  start_matching_engine
  local stamp="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  printf '%s\n' '{"type":"sync_cycle_stamp","first_success_at":"2026-08-11T20:00:00.000Z","last_success_at":"2026-08-11T20:00:00.000Z"}' > "$stamp"
  [ -e "$stamp" ]

  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  [ ! -e "$stamp" ]
}

@test "status: a connected team that can name nobody says so (#743)" {
  # `connected (engine running)` and `0 member(s)` were both true at once and
  # nothing joined them, so the state read as a working team that happened to be
  # empty rather than as a machine still waiting for a roster it cannot produce
  # itself. This is the state a freshly pulled second machine is in.
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped

  # The negative control first, on the fixture as built: alice is registered
  # here, so the line must be absent. Asserting only its presence below would
  # pass just as well for a line printed unconditionally.
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  refute grep -qF -- "roster: no members known here yet" <<<"$output"

  escaped="$(sed "s/'/''/g" "$cfg")"
  sqlite_mem "SELECT json_set('$escaped', '\$.agents', json_object());" > "$cfg"
  # The premise, measured rather than assumed -- if this edit stopped emptying
  # the roster, the assertion below would be testing the populated case.
  [ "$(sqlite_mem "SELECT COUNT(*) FROM json_each(
      json_extract(readfile('$(rf "$cfg")'), '\$.agents'));")" -eq 0 ]

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected ("
  printf '%s\n' "$output" | grep -q -F -- "roster: no members known here yet"
}

@test "status: reports an active binding whose engine is stopped" {
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stopped"* ]]
  # The command carries its install path and quotes its team now (#667), so the
  # bare spelling is gone. `grep -q`, not `[[ ]]`: a failing `[[ ]]` mid-body is
  # not enforced on bash 3.2 (#670), and this assertion is one that just moved.
  printf '%s\n' "$output" | grep -q -F -- "remote.sh' sync start 'testteam'"

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stopped ]
  [ "$(sqlite_mem "SELECT json_type('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = null ]
}

@test "status: reports a live engine only when argv matches this team" {
  start_matching_engine
  local fake_bin
  fake_bin="$(write_matching_ps_fixture)"

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = running ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" -eq "$ENGINE_PID" ]
}

@test "status: a stale engine names the command that fixes it, like a stopped one does (#761)" {
  # A reboot leaves this state, and it was the one branch with no remedy in it.
  # `stopped` is reached by an operator who stopped the engine themselves and
  # already knows the command; `stale` is reached by someone who did nothing.
  printf '%s\n' 999999 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected (engine stale"
  printf '%s\n' "$output" | grep -q -F -- "sync start"

  # The other stale branch — a pidfile with nothing usable in it — is a separate
  # line in the source, so asserting one says nothing about the other.
  printf '%s\n' "not-a-pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "does not contain a valid process id"
  printf '%s\n' "$output" | grep -q -F -- "sync start"
}

@test "status: rejects a live foreign process behind a recycled pidfile" {
  sleep 30 &
  local foreign_pid=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]
  [[ "$output" == *"pidfile $foreign_pid points at a dead or foreign process"* ]]

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stale ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" -eq "$foreign_pid" ]
}

@test "status: reports a dead pidfile as stale without changing exit status" {
  printf '%s\n' 2147483647 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]
  [[ "$output" == *"pidfile 2147483647 points at a dead or foreign process"* ]]
}

@test "status: rejects a malformed pidfile without interpreting it as a process" {
  printf '%s\n' 0123 > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" status testteam --json
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_state');")" = stale ]
  [ "$(sqlite_mem "SELECT json_type('$(printf '%s' "$output" | sed "s/'/''/g")', '\$.engine_pid');")" = null ]
}

@test "sync start: starts a stopped engine and status reports it running" {
  local fake_node fake_bin first_pid
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sync engine started for 'testteam' (pid "* ]]
  remember_engine_pid
  kill -0 "$ENGINE_PID"

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]

  first_pid="$ENGINE_PID"
  kill "$first_pid"
  wait_for_pid_exit "$first_pid"
  run bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine stale"* ]]

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  remember_engine_pid
  [ "$ENGINE_PID" -ne "$first_pid" ]
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]
}

@test "sync start: is a no-op when the verified engine is already running" {
  local fake_node fake_bin original_pid
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"
  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  remember_engine_pid
  original_pid="$ENGINE_PID"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [ "$output" = "Sync engine already running (pid $original_pid)." ]
  [ "$(cat "$TEST_SKILL_DIR/run/remote-sync.testteam.pid")" = "$original_pid" ]
  kill -0 "$original_pid"
}

@test "sync start: a replaced engine does not inherit its predecessor's cycle record (#756)" {
  # The stop path clears the record, and that is not enough: an engine that
  # crashes, is killed, or leaves a stale pidfile never runs it. The replacement
  # would then find the old file on disk, and `status` would report a success
  # this engine has not had. Review caught this; the original change cleared the
  # record only where the pidfile was removed, which the crash path never reaches.
  local fake_node fake_bin foreign_pid stamp
  stamp="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  fake_node="$(write_fake_node)"
  sleep 30 &
  foreign_pid=$!
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "$foreign_pid")"
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  # A dead engine's leftovers: a pidfile pointing at something that is not ours,
  # and the record it wrote while it was alive.
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  printf '%s\n' '{"type":"sync_cycle_stamp","first_success_at":"2026-08-11T19:00:00.000Z","last_success_at":"2026-08-11T19:30:00.000Z"}' > "$stamp"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  remember_engine_pid

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected (engine running, pid $ENGINE_PID)"
  # The decisive assertion: the predecessor's timestamp must not appear at all.
  refute grep -qF -- "19:30:00" <<<"$output"
  printf '%s\n' "$output" | grep -q -F -- "cycles: no successful cycle recorded since this engine started"
}

@test "sync start: refusing over the cycle record does not kill the engine that is running (#756)" {
  # The refusal has to happen while the start is still free. Past the kill, a
  # refusal has taken down a working engine for a bookkeeping reason -- worse
  # than the misattribution it was avoiding, because syncing stops.
  start_matching_engine
  local fake_bin stamp
  fake_bin="$(write_matching_ps_fixture)"
  stamp="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  mkdir -p "$stamp"

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" sync start testteam
  # `sync start` against a verified running engine is a no-op that succeeds --
  # measured, and it is the better answer than the refusal this test was first
  # written to expect: there is nothing to replace, so the record's shape never
  # becomes a reason to touch a working engine at all.
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "already running"
  # The engine is untouched, and still the owner as far as status is concerned.
  # Both halves matter: alive but disowned would be an orphan.
  kill -0 "$ENGINE_PID"
  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected (engine running, pid $ENGINE_PID)"
}

@test "sync start: a symlink at the cycle record path is refused, dangling or not (#756)" {
  # `[ -e ]` follows the link and reports a dangling one ABSENT, so an -e-only
  # check lets it through. Leaving a link there is worse than leaving a stale
  # file: the engine writes THROUGH it, so the record becomes a write to
  # wherever it points.
  local fake_node fake_bin stamp
  stamp="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "")"
  ln -s "$TEST_SKILL_DIR/no-such-target.json" "$stamp"
  [ -L "$stamp" ]
  [ ! -e "$stamp" ]      # the property that makes an -e-only check wrong

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -q -F -- "not a plain file"
  [ ! -s "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  # And the link is left as it was found rather than followed.
  [ -L "$stamp" ]
  [ ! -e "$TEST_SKILL_DIR/no-such-target.json" ]
}

@test "sync start: refuses to start when the old cycle record cannot be removed (#756)" {
  # `rm -f` returns success for a file that was not there and failure for a path
  # it cannot remove at all. Measured: `rm -f <a directory>` exits 1 and leaves
  # it. Ignoring that would start the replacement with the predecessor's record
  # still on disk -- the misattribution, through the very path meant to close it.
  local fake_node fake_bin stamp
  stamp="$TEST_SKILL_DIR/run/remote-sync.testteam.cycles.json"
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "")"
  mkdir -p "$stamp"          # undeletable as a file: rm -f will not take it
  [ -d "$stamp" ]

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  # Either refusal is correct here — the precondition rejects the shape before
  # anything is signalled, and the post-kill removal check catches what gets
  # past it. What must hold is that the start refused and left nothing behind,
  # so this asserts the outcome rather than which of the two spoke.
  printf '%s\n' "$output" | grep -q -E -- "not a plain file|could not be removed"
  # No engine, and no ownership claim left behind: a start that refuses must not
  # look like one that owns this team.
  [ ! -s "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  refute grep -qF -- "engine running" <<<"$output"
}

@test "sync start: replaces stale ownership without signalling a foreign process" {
  local fake_node fake_bin foreign_pid
  fake_node="$(write_fake_node)"
  sleep 30 &
  foreign_pid=$!
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "$foreign_pid")"
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  kill -0 "$foreign_pid"
  remember_engine_pid
  [ "$ENGINE_PID" -ne "$foreign_pid" ]

  run env PATH="$fake_bin:$PATH" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"connected (engine running, pid $ENGINE_PID)"* ]]
}

@test "disconnect removes stale ownership without signalling a foreign process" {
  sleep 30 &
  local foreign_pid=$!
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$foreign_pid"
  printf '%s\n' "$foreign_pid" > "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"

  run bash "$SCRIPTS/remote.sh" disconnect testteam
  [ "$status" -eq 0 ]
  kill -0 "$foreign_pid"
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}

@test "the engine start holds the team lock across the spawn (#762)" {
  # `sync start` was the ONE caller of five that held the lock over its spawn;
  # pull, connect, unlock and set-endpoint did not, so two of them in the same
  # window both spawned and the pidfile named only the second. The first was
  # then invisible to `status` and unreachable by `stop` -- the orphan state
  # this file guards against elsewhere, produced by the guard's own gap.
  #
  # The lock is taken inside _remote_sync_engine_start now, so this holds for
  # every caller rather than for the one that remembered. Measured here by
  # holding the lock from outside and watching the start refuse rather than
  # race: a start that cannot serialise itself must not run unserialised.
  # Driven through `sync start`, which takes the lock ITSELF before calling the
  # helper: the assertion is that the helper does not deadlock against a lock
  # its own caller is holding. The lock is a mkdir and is not reentrant, so a
  # naive "always acquire" would spin to its timeout and refuse to start an
  # engine because of a lock the same process holds. That is the case this
  # fix's shape has to survive, and it is the one a test can drive here.
  local fake_node fake_bin lock
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"
  lock="$TEST_SKILL_DIR/teams/testteam/.config.lock"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" AGMSG_LOCK_TRIES=2 \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "Sync engine started"
  remember_engine_pid
  kill -0 "$ENGINE_PID"
  # And the lock is not left behind -- a start that keeps it would block every
  # later command on this team.
  [ ! -d "$lock" ]
}

@test "the engine start acquires the lock itself, and refuses when it cannot (#762)" {
  # The central contract of this change: a caller that does not hold the lock
  # gets the whole check-then-act serialised by the helper, not by remembering
  # to lock first. Until the sourceable seam existed this could not be driven --
  # holding the lock from outside stops every command at an earlier acquire of
  # its own -- so it went untested and was named as untested. It is testable now.
  #
  # `agmsg_lock_acquire` and the locked body are both replaced after sourcing:
  # one records that it was called and can be made to fail, the other records
  # whether the wrapper got that far. Nothing is re-implemented -- the wrapper
  # under test is the production one.
  run bash -c '
    set -uo pipefail
    export AGMSG_SYNC_CONNECTION_DIR='"$TEST_SKILL_DIR"'
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    log="$(mktemp)"
    agmsg_lock_acquire() { echo "acquire:$1" >> "$log"; return "${STUB_ACQUIRE_RC:-0}"; }
    agmsg_lock_release_one() { echo "release:$1" >> "$log"; }
    _remote_sync_engine_start_locked() { echo "locked" >> "$log"; return 0; }

    # 1. The caller holds nothing, so the wrapper must acquire.
    STUB_ACQUIRE_RC=0 _remote_sync_engine_start testteam >/dev/null 2>&1
    grep -q "^acquire:.*/teams/testteam$" "$log" || { echo "NO_ACQUIRE"; exit 1; }
    grep -q "^locked$" "$log" || { echo "NEVER_REACHED_BODY"; exit 1; }
    grep -q "^release:.*/teams/testteam$" "$log" || { echo "NOT_RELEASED"; exit 1; }

    # 2. The acquire fails: the body must not run, and the call must report it.
    : > "$log"
    STUB_ACQUIRE_RC=1 _remote_sync_engine_start testteam >/dev/null 2>&1 && { echo "REFUSAL_RETURNED_ZERO"; exit 1; }
    grep -q "^locked$" "$log" && { echo "BODY_RAN_UNSERIALISED"; exit 1; }
    grep -q "^release:" "$log" && { echo "RELEASED_A_LOCK_IT_NEVER_TOOK"; exit 1; }
    echo acquire-contract-ok
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "acquire-contract-ok"
}

@test "the engine start restores all three traps the acquire takes (#762)" {
  # Drives `_remote_sync_engine_start` itself. The previous version of this test
  # re-implemented the wrapper's save/acquire/release/replay in the test body and
  # asserted on the copy: it passed with the implementation reduced to EXIT-only,
  # which is the mutation it was written to catch. Review caught that; the fix is
  # to call the real function, which is why remote.sh is now sourceable.
  run bash -c '
    set -uo pipefail
    export AGMSG_SYNC_CONNECTION_DIR='"$TEST_SKILL_DIR"'
    . '"$SCRIPTS"'/remote.sh 2>/dev/null
    trap "echo CALLER_EXIT" EXIT
    trap "echo CALLER_INT; exit 130" INT
    trap "echo CALLER_TERM; exit 143" TERM
    # Make the start fail fast and INSIDE the locked section: a directory where
    # the pidfile goes. What is under test is the trap state it leaves behind,
    # not whether an engine appeared.
    mkdir -p "'"$TEST_SKILL_DIR"'/run/remote-sync.testteam.pid"
    _remote_sync_engine_start testteam >/dev/null 2>&1 || true
    rmdir "'"$TEST_SKILL_DIR"'/run/remote-sync.testteam.pid" 2>/dev/null || true
    # Captured into a variable, NOT piped. In bash 3.2 the left side of a
    # pipeline is a subshell with the traps reset, so `trap -p | grep` reports
    # nothing there and this assertion fails on a correct implementation --
    # measured: it passes under bash 5 and fails under 3.2, which is why it was
    # green here and red on the macOS CI leg. Command substitution is also a
    # subshell but reports the outer shell traps in both versions (70 bytes).
    installed="$(trap -p EXIT INT TERM)"
    for want in CALLER_EXIT CALLER_INT CALLER_TERM; do
      case "$installed" in *"$want"*) ;; *) echo "MISSING:$want"; exit 1 ;; esac
    done
    case "$installed" in *agmsg_lock_release*) echo "LIBRARY_HANDLER_LEFT"; exit 1 ;; esac
    echo wiring-ok
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "wiring-ok"
}

@test "releasing the engine's own lock leaves other held locks alone (#762)" {
  # `agmsg_lock_release` drops every lock the process holds, and the library's
  # contract is that a caller may hold several. The engine start acquires ONE,
  # so it must release one: releasing all of them takes locks away from an
  # operation that is still using them.
  run bash -c '
    set -euo pipefail
    . '"$SCRIPTS"'/lib/registry-lock.sh
    root="$(mktemp -d)"
    mkdir -p "$root/a" "$root/b"
    agmsg_lock_acquire "$root/a"
    agmsg_lock_acquire "$root/b"
    agmsg_lock_release_one "$root/a"
    [ ! -d "$root/a/.config.lock" ] || { echo "own lock not released"; exit 1; }
    [ -d "$root/b/.config.lock" ] || { echo "OTHER lock was released"; exit 1; }
    case "$AGMSG_HELD_LOCKS" in *"$root/b/.config.lock"*) ;; *) echo "bookkeeping lost the other lock"; exit 1 ;; esac
    case "$AGMSG_HELD_LOCKS" in *"$root/a/.config.lock"*) echo "bookkeeping kept the released lock"; exit 1 ;; esac
    echo ok
  '
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "ok"
}

@test "concurrent sync start serializes ownership to one engine" {
  local fake_node fake_bin first_out second_out first_status=0 second_status=0
  fake_node="$(write_fake_node)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"
  first_out="$(mktemp)"
  second_out="$(mktemp)"

  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam >"$first_out" 2>&1 &
  local first_start=$!
  env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" bash "$SCRIPTS/remote.sh" sync start testteam >"$second_out" 2>&1 &
  local second_start=$!
  wait "$first_start" || first_status=$?
  wait "$second_start" || second_status=$?
  [ "$first_status" -eq 0 ]
  [ "$second_status" -eq 0 ]
  [ "$(grep -h -c 'Sync engine started' "$first_out" "$second_out" | awk '{s += $1} END {print s}')" -eq 1 ]
  [ "$(grep -h -c 'Sync engine already running' "$first_out" "$second_out" | awk '{s += $1} END {print s}')" -eq 1 ]

  remember_engine_pid
  kill -0 "$ENGINE_PID"
  rm -f "$first_out" "$second_out"
}

@test "sync start reads a complete multi-megabyte handshake log without SIGPIPE" {
  local fake_node fake_bin ready_file="$TEST_SKILL_DIR/handshake-log.ready"
  fake_node="$(write_fake_node 512)"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node" "" "$ready_file")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    AGMSG_TEST_LOG_READY_FILE="$ready_file" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  [ -f "$ready_file" ]
  remember_engine_pid
  kill -0 "$ENGINE_PID"
}

@test "sync start reaps a ready-timeout child before releasing ownership" {
  local fake_node="$TEST_SKILL_DIR/fake-node-timeout" fake_bin lock child_pid_file child_pid
  child_pid_file="$TEST_SKILL_DIR/timeout-child.pid"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s\\n'\'' "$$" > "$AGMSG_TEST_CHILD_PID_FILE"' \
    'trap "" TERM' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  fake_bin="$(write_fake_node_ps_fixture "$fake_node")"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    AGMSG_TEST_CHILD_PID_FILE="$child_pid_file" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not become ready"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
  child_pid="$(cat "$child_pid_file")"
  refute kill -0 "$child_pid" 2>/dev/null
  lock="$TEST_SKILL_DIR/teams/testteam/.config.lock"
  [ ! -d "$lock" ]
}

@test "sync start: rejects a team whose binding is not active" {
  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem \
    "SELECT json_set('$escaped', '\$.remote_binding.disconnected_at', '2026-07-30T01:00:00Z');")"
  printf '%s\n' "$updated" > "$cfg"

  run bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"team 'testteam' is disconnected"* ]]
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.pid" ]
}

# A ps fixture that never confirms ownership: every argv query answers with
# something that is not this team's engine. `_remote_sync_engine_status` then
# reports the pid as not-running, so `_remote_sync_engine_reap_owned` returns
# without signalling -- by design, since it must never signal a pid it cannot
# prove it owns.
#
# That models what a sandbox does. Measured under Codex's: `kill -0` and
# `kill -TERM` on the engine this shell just started both return "Operation
# not permitted", while the same signal from outside is allowed. The engine
# survives, and ownership cannot be established from in there either.
write_unownable_ps_fixture() {
  local fake_bin="$TEST_SKILL_DIR/fake-ps-unownable"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' \
    'args=0' \
    'case " $* " in *" -o args= "*) args=1 ;; esac' \
    '[ "$args" = 1 ] || exec /bin/ps "$@"' \
    "printf '%s\\n' 'sleep 30'" > "$fake_bin/ps"
  chmod +x "$fake_bin/ps"
  printf '%s\n' "$fake_bin"
}

@test "sync start says a live engine was left behind when it cannot be reaped (#731)" {
  local fake_node="$TEST_SKILL_DIR/fake-node-unreapable" fake_bin child_pid_file child_pid
  child_pid_file="$TEST_SKILL_DIR/unreapable-child.pid"
  printf '%s\n' '#!/usr/bin/env bash' \
    'echo "$$" > "$AGMSG_TEST_CHILD_PID_FILE"' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"
  fake_bin="$(write_unownable_ps_fixture)"

  run env PATH="$fake_bin:$PATH" AGMSG_NODE="$fake_node" \
    AGMSG_TEST_CHILD_PID_FILE="$child_pid_file" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -ne 0 ]

  child_pid="$(cat "$child_pid_file")"
  # The premise: it really is still running. Without this the assertions below
  # would pass just as well against a message about a process that had died,
  # which is the thing the old wording could not distinguish.
  kill -0 "$child_pid"

  # What the operator is told. `grep -q`, not `[[ ]]`: a non-last `[[ ]]` is
  # not enforced on bash 3.2 (#670).
  printf '%s\n' "$output" | grep -q -F "did not become ready, and this command did not stop it"
  printf '%s\n' "$output" | grep -q -F "pid $child_pid is still running"
  printf '%s\n' "$output" | grep -q -F "keep retrying"
  # This test drives the ownership-unproven path, where no signal is ever sent.
  # The text must not claim signalling was refused -- that is the other branch,
  # and asserting a cause this run did not establish is the defect the wording
  # was changed for (review on #750).
  printf '%s\n' "$output" | grep -q -F "either could not confirm the process was ours or could not signal it"
  refute grep -q -F "was not allowed to signal it" <<<"$output"
  # That repeating the command accumulates them, and that the pidfile only
  # records the newest -- the part that turns one stuck engine into several.
  printf '%s\n' "$output" | grep -q -F "leaves another one behind"
  # And a way out that works from where the operator actually is.
  printf '%s\n' "$output" | grep -q -F "kill $child_pid"
  printf '%s\n' "$output" | grep -q -F "remote.sh disconnect 'testteam'"

  kill -9 "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
}

# --- the probe a minted pid is checked with (#652) -----------------------
#     Field report from the owner's Windows dogfood: `ps -W` found node 33872,
#     the pidfile held 33872, and status still said "engine stale — pidfile
#     points at a dead or foreign process". The pid was right; the thing asking
#     whether it was alive could not see it.
#
#     `remote.sh` mints every pid it checks — `$!` in this shell, or read back
#     from the pidfile this shell wrote it to — and a pidfile does not move a
#     number into another pid space. Under Git Bash those are MSYS pids, which
#     `tasklist` has no record of.

@test "the non-local probe cannot see a pid this shell minted, and the local one can (#652)" {
  # Windows modelled on this host: MSYSTEM set, and a `tasklist` that answers
  # nothing — which is exactly what the real one does when asked about an MSYS
  # pid. This reproduces the mechanism; it is not a Windows run.
  local fake_bin="$TEST_SKILL_DIR/fake-tasklist-blind"
  mkdir -p "$fake_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fake_bin/tasklist"
  chmod +x "$fake_bin/tasklist"

  sleep 30 &
  local minted=$!

  # The premise, checked rather than assumed: the process really is alive.
  run kill -0 "$minted"
  [ "$status" -eq 0 ]

  run env PATH="$fake_bin:$PATH" MSYSTEM=MINGW64 bash -c \
    'source "$1/lib/instance-id.sh"; _agmsg_pid_alive "$2" && echo ALIVE || echo DEAD' \
    _ "$SCRIPTS" "$minted"
  [ "$output" = "DEAD" ]   # the defect, reproduced

  run env PATH="$fake_bin:$PATH" MSYSTEM=MINGW64 bash -c \
    'source "$1/lib/instance-id.sh"; _agmsg_pid_alive_local "$2" && echo ALIVE || echo DEAD' \
    _ "$SCRIPTS" "$minted"
  [ "$output" = "ALIVE" ]  # the probe the minted pid is entitled to

  kill "$minted" 2>/dev/null || true
  wait "$minted" 2>/dev/null || true
}

@test "remote.sh checks every pid it minted with the local probe (#652)" {
  # The test above pins the DIFFERENCE between the probes; it says nothing
  # about which one `remote.sh` calls. This says that, and it is a count
  # because the failure it guards against is a new call site appearing rather
  # than an existing one changing.
  #
  # NOT `grep '_agmsg_pid_alive "'`. That pattern pins the CALL SITE'S SPELLING,
  # not the call: two spaces, a tab, an unquoted `$pid`, or a line continuation
  # after the name all slip past it, so a reverted call site could sit here
  # green (raised in review).
  #
  # Instead: strip whole-line comments, delete every `_agmsg_pid_alive_local`
  # token, and count what is left of the name. Nothing about the argument or
  # the spacing is assumed, because nothing after the name is looked at. The
  # helper is defined in instance-id.sh, so no definition is counted here.
  run bash -c "grep -v '^[[:space:]]*#' \"\$1\" | sed 's/_agmsg_pid_alive_local//g' | grep -c '_agmsg_pid_alive'" _ "$SCRIPTS/remote.sh"
  [ "$output" = "0" ]
}


# systemd-supervised engine detection for #894. The process itself is real;
# only systemctl is replaced, so these tests exercise the same argv/liveness
# checks used on a host while remaining independent of the test runner's user bus.
write_systemd_show_fixture() {
  local state="$1" pid="$2" sub=dead fake="$TEST_SKILL_DIR/fake-systemctl"
  [ "$state" = active ] && sub=running
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--user" ] && [ "${2:-}" = "show" ]; then' \
    "  printf '%s\n' 'LoadState=loaded' 'ActiveState=$state' 'SubState=$sub' 'MainPID=$pid'" \
    '  exit 0' \
    'fi' \
    'exit 1' > "$fake"
  chmod +x "$fake"
  printf '%s\n' "$fake"
}

@test "status: recognizes a verified systemd engine without a pidfile (#894)" {
  start_matching_engine
  rm -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  local fake_bin fake_systemctl
  fake_bin="$(write_matching_ps_fixture)"
  fake_systemctl="$(write_systemd_show_fixture active "$ENGINE_PID")"

  run env PATH="$fake_bin:$PATH" AGMSG_SYSTEMCTL="$fake_systemctl" \
    bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected (engine running, pid $ENGINE_PID)"
  refute grep -qi 'stale\|stopped' <<<"$output"
}

@test "sync start: does not duplicate an active systemd engine (#894)" {
  start_matching_engine
  rm -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  local fake_bin fake_systemctl
  fake_bin="$(write_matching_ps_fixture)"
  fake_systemctl="$(write_systemd_show_fixture active "$ENGINE_PID")"

  run env PATH="$fake_bin:$PATH" AGMSG_SYSTEMCTL="$fake_systemctl" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "already running (pid $ENGINE_PID)"
  [ "$(find "$TEST_SKILL_DIR/run" -maxdepth 1 -name 'remote-sync.testteam.pid' | wc -l)" -eq 0 ]
}

@test "sync start: refuses an active systemd unit with unverified identity (#894)" {
  sleep 30 &
  local foreign_pid=$!
  ENGINE_PIDS="$ENGINE_PIDS $foreign_pid"
  local fake_bin fake_systemctl
  fake_bin="$(write_matching_ps_fixture)"
  fake_systemctl="$(write_systemd_show_fixture active "$foreign_pid")"

  run env PATH="$fake_bin:$PATH" AGMSG_SYSTEMCTL="$fake_systemctl" \
    bash "$SCRIPTS/remote.sh" sync start testteam
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -q -F -- "systemd owns team 'testteam'"
  refute test -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
}


@test "status: reports an inactive systemd unit with restart guidance (#894)" {
  start_matching_engine
  rm -f "$TEST_SKILL_DIR/run/remote-sync.testteam.pid"
  local fake_systemctl
  fake_systemctl="$(write_systemd_show_fixture inactive 0)"

  run env AGMSG_SYSTEMCTL="$fake_systemctl" bash "$SCRIPTS/remote.sh" status testteam
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "engine inactive under systemd"
  printf '%s\n' "$output" | grep -q -F -- "systemctl --user restart agmsg-remote-sync-testteam.service"
}
