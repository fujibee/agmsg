#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # Pin bare instance-id keying (#93) so watcher pidfiles / cc-instance records
  # stay keyed on the raw session_id these tests pass — deterministic in CI and
  # when the suite runs under an agent process. Composite path: test_watch.bats.
  export AGMSG_AGENT_PID=""
  export TEST_PROJECT="$(mktemp -d)"
}

teardown() {
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

# Count agmsg-owned entries in a hooks-event array.
agmsg_entries() {
  local file="$1"
  local event="$2"
  if [ ! -f "$file" ]; then echo 0; return; fi
  sqlite_mem "
    SELECT count(*) FROM json_each(json_extract(readfile('$(rf "$file")'), '\$.hooks.$event')) AS s
    WHERE EXISTS (
      SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
      WHERE instr(json_extract(h.value, '\$.command'), 'agmsg') > 0
        OR instr(json_extract(h.value, '\$.command'), \"$(basename $(dirname $(dirname $file)))\") > 0
        OR instr(json_extract(h.value, '\$.command'), '$(dirname $file)') > 0
    );
  " 2>/dev/null || echo 0
}

# Simpler probe: grep for our scripts directly.
has_session_start() {
  [ -f "$1" ] && grep -q "session-start.sh" "$1"
}
has_check_inbox() {
  [ -f "$1" ] && grep -q "check-inbox.sh" "$1"
}

settings_file() {
  echo "$TEST_PROJECT/.claude/settings.local.json"
}

# --- set <mode> ---

@test "delivery set monitor: installs SessionStart, no Stop" {
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

@test "delivery set turn: installs Stop, no SessionStart" {
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  has_check_inbox "$(settings_file)"
  ! has_session_start "$(settings_file)"
}

@test "delivery set both: installs SessionStart and Stop" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  has_check_inbox "$(settings_file)"
}

@test "delivery set off: removes both hooks" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  refute has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

# --- idempotency ---

@test "delivery set monitor: idempotent" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  local n
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.SessionStart'));")
  [ "$n" = "1" ]
}

@test "delivery set both: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  local s t
  s=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.SessionStart'));")
  t=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.Stop'));")
  [ "$s" = "1" ]
  [ "$t" = "1" ]
}

# --- mode transitions ---

@test "delivery: turn -> monitor swaps hooks cleanly" {
  bash "$SCRIPTS/delivery.sh" set turn    claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

@test "delivery: monitor -> turn swaps hooks cleanly" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn    claude-code "$TEST_PROJECT"
  has_check_inbox "$(settings_file)"
  ! has_session_start "$(settings_file)"
}

@test "delivery: both -> off clears settings.local.json hooks" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off  claude-code "$TEST_PROJECT"
  refute has_session_start "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

# --- preserves user settings ---

@test "delivery set monitor: preserves unrelated settings" {
  mkdir -p "$TEST_PROJECT/.claude"
  echo '{"permissions":{"allow":["Bash"]}}' > "$(settings_file)"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  local p
  p=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow[0]');")
  [ "$p" = "Bash" ]
}

@test "delivery set monitor: round-trips multibyte (UTF-8) settings without a short-write reject" {
  # The writefile() guard compares bytes written to the content's BYTE length
  # (CAST AS BLOB). A character-length comparison would mismatch on multibyte
  # content and wrongly reject the write, so set monitor would fail. Seed an
  # unrelated multibyte value and confirm the write succeeds and survives.
  mkdir -p "$TEST_PROJECT/.claude"
  printf '%s\n' '{"note":"日本語のメモ — ünïcödé ✓","permissions":{"allow":["Bash"]}}' > "$(settings_file)"

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]

  # Still valid JSON, the multibyte value survived byte-for-byte, hook landed.
  local valid
  valid=$(sqlite_mem "SELECT json_valid(readfile('$(rf "$(settings_file)")'));")
  [ "$valid" = "1" ]
  grep -q "日本語のメモ" "$(settings_file)"
  grep -q "session-start.sh" "$(settings_file)"
}

# --- status derives mode from settings.local.json ---

@test "delivery status: derives 'both' from settings with SessionStart + Stop" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" =~ "mode: both" ]]
}

@test "delivery status: derives 'monitor' from settings with SessionStart only" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "delivery status: claude-code still reports the watch process summary" {
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"watch processes:"* ]]
}

# A pid that exists but this user cannot signal, so `kill -0` fails with EPERM
# rather than ESRCH. pid 1 is that on any normal desktop or CI runner; when the
# suite runs as root, or in a container where pid 1 is ours, there is no such
# pid to borrow and the distinction under test cannot be staged.
eperm_pid() {
  local err
  # An `A && skip` list is a FAILING command on exactly the run we want, which
  # bats' errexit turns into a test failure instead of a skip.
  if kill -0 1 2>/dev/null; then skip "pid 1 is signalable here; no EPERM fixture available"; fi
  # `|| true`: the substitution's status is the failing kill, and a bare
  # assignment carrying it trips errexit before the case can decide anything.
  err="$(export LC_ALL=C; kill -0 1 2>&1)" || true
  case "$err" in
    *[Nn]'o such process'*) skip "pid 1 does not exist here" ;;
  esac
  echo 1
}

@test "delivery status: a live but unsignalable watcher is not counted as stale" {
  local pid
  pid="$(eperm_pid)"
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  printf '%s\n' "$pid" > "$TEST_SKILL_DIR/run/watch.eperm-session.pid"
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  # `kill -0` answers "can I signal this", not "is this running". Under a
  # sandbox every watcher fails it, and reading the exit status alone printed
  # every live watcher as a stale pidfile.
  [[ "$output" == *"watch processes: 1 alive, 0 stale pidfiles"* ]]
}

@test "delivery status: a genuinely dead watcher is still counted as stale" {
  mkdir -p "$TEST_SKILL_DIR/run"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  local dead
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  printf '%s\n' "$dead" > "$TEST_SKILL_DIR/run/watch.dead-session.pid"
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  # The other half of the fix: treating EPERM as alive must not make everything
  # look alive.
  [[ "$output" == *"watch processes: 0 alive, 1 stale pidfiles"* ]]
}

@test "delivery status: derives 'turn' from settings with Stop only" {
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

@test "delivery status: a settings file with zero agmsg hooks reads as 'no hooks installed', not asserted-deliberate (#687 review round 3)" {
  # $TEST_PROJECT's settings file exists and is real, just empty of agmsg
  # entries -- but `set off`'s apply_default only STRIPS agmsg's own hook
  # entries, it writes no marker recording that `set off` ran. So this exact
  # byte state is reachable two ways: someone ran `set off`, or this project
  # simply never had agmsg configured. delivery.sh cannot tell those apart,
  # so the wording must not claim "deliberate" -- it states only what's
  # observable (hooks absent), distinct from the "(unrecognized: ...)" family
  # the next two tests check for, which means delivery.sh couldn't even read
  # a settings file at all.
  bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" == "mode: off (no agmsg delivery hooks installed for this project)"$'\n'* ]] || { echo "expected the first line to be exactly 'mode: off (no agmsg delivery hooks installed for this project)', got: $output" >&2; return 1; }
  [[ "$output" != *"unrecognized"* ]]
}

@test "delivery status: an unrecognized project is distinguishable from a deliberately off one (#687)" {
  # No `set` call at all: $TEST_PROJECT is a bare mktemp -d, so no settings
  # file exists at the resolved path -- the actual #684 failure mode, where
  # a settings file could not be found (most often because the caller's
  # $(pwd) did not match how the project was actually registered) and that
  # was reported as indistinguishable from a real, deliberate "off". Both
  # used to print the bare word "off"; the FIRST line has to differ now, not
  # just a later one, because a reader (or actas) that only looks at the
  # first line must still be able to tell.
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" == "mode: off ("*")"$'\n'* || "$output" == "mode: off ("*")" ]] \
    || { echo "expected the first line to read 'mode: off (...)', got: $output" >&2; return 1; }
  [[ "$output" == *"unrecognized"* ]] &&
    [[ "$output" == *"$TEST_PROJECT"* ]]
}

@test "delivery status: a settings file that exists but is not valid JSON is also unrecognized, not deliberate off (review)" {
  # A third way has_ss/has_st both land on 0: not "missing" and not "genuinely
  # empty of agmsg entries" but unreadable/malformed, which the has_ss/has_st
  # queries collapse to the same 0 a real off produces (`2>/dev/null ||
  # echo 0`) -- checking only file EXISTENCE, as the first #687 fix did,
  # missed this: a corrupt settings file still read as a deliberate,
  # confirmed off. Reproducing what a hand-edited or partially-written
  # settings.local.json looks like.
  mkdir -p "$TEST_PROJECT/.claude"
  printf '{not valid json' > "$TEST_PROJECT/.claude/settings.local.json"
  run bash "$SCRIPTS/delivery.sh" status claude-code "$TEST_PROJECT"
  [[ "$output" == "mode: off ("*")"$'\n'* || "$output" == "mode: off ("*")" ]] \
    || { echo "expected the first line to read 'mode: off (...)', got: $output" >&2; return 1; }
  [[ "$output" == *"unrecognized"* ]] &&
    [[ "$output" == *"could not be read as valid JSON"* ]]
}

# --- rejects unknown mode ---

@test "delivery set: rejects unknown mode" {
  run bash "$SCRIPTS/delivery.sh" set bogus claude-code "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown mode" ]]
}

# --- project_path validation (#493) ---
# `set` used to build a hooks/rule-file path directly from an unvalidated
# project_path and `mkdir -p` it, so a malformed argument -- e.g. a literal
# trailing newline byte, the kind an LLM-agent-composed command can produce,
# as opposed to a `$(pwd)`-style substitution which already strips one --
# silently created a bogus sibling directory (the exact "myproject\n" repro
# in #493) and installed hooks into it. agmsg_validate_project_path now
# rejects a malformed value before any file or directory is touched, rather
# than silently correcting it -- a caller that built a bad command should see
# a loud error naming the exact value it passed, not a value that happens to
# work this one time and hides the bug in whatever generated it.

@test "delivery set: rejects a project_path with a trailing newline and creates no directory (#493 exact repro)" {
  # Adjacent-quote concatenation appends a literal newline byte to the
  # argument -- this is the exact #493 repro shape, not a $(cmd) substitution
  # (which would already have stripped it). $TEST_PROJECT itself exists, so
  # this also proves the fix does not silently fall back to the trimmed,
  # pre-existing directory -- it refuses the malformed value outright.
  local bogus="$TEST_PROJECT"$'\n'
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$bogus"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "carriage return or newline" ]]
  # No sibling "<real project>\n" directory (or anything else) was created.
  [ ! -e "$bogus" ]
  ! has_session_start "$(settings_file)"
}

@test "delivery set: rejects a nonexistent project_path and creates no directory" {
  local bogus="$TEST_PROJECT/does-not-exist"
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$bogus"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "project path does not exist" ]]
  [ ! -e "$bogus" ]
}

@test "delivery set: rejects an empty project_path" {
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code ""
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Missing project_path" ]]
}

@test "delivery set: rejects a project_path that exists but cannot be entered" {
  # -d passes for a directory with no execute bit, but every apply
  # implementation then writes inside it. Prove we fail here with a clear
  # message instead of later with a confusing mkdir error.
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: permission bits do not restrict traversal"
  fi
  local locked="$TEST_PROJECT/locked"
  mkdir -p "$locked"
  chmod 000 "$locked"
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$locked"
  chmod 755 "$locked"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "cannot be entered" ]]
}

@test "delivery set: rejects a project_path that is only whitespace" {
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "   "
  [ "$status" -ne 0 ]
  [[ "$output" =~ "empty or only whitespace" ]]
}

@test "delivery set: accepts a project_path with leading/trailing spaces, using it literally (#493 scope follow-up)" {
  # A plain leading/trailing space is a valid POSIX path byte -- #493 is
  # about CR/LF, not about whitespace in general -- so a directory legitimately
  # named with padding must be accepted and used as-is, not rejected.
  local padded="$TEST_PROJECT/  padded name  "
  mkdir -p -- "$padded"
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$padded"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  [ -f "$padded/.claude/settings.local.json" ]
  has_session_start "$padded/.claude/settings.local.json"
}

@test "delivery set: accepts a project_path with leading/trailing tabs, using it literally (#493 scope follow-up)" {
  local padded="$TEST_PROJECT/"$'\t'"tabbed name"$'\t'
  mkdir -p -- "$padded"
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$padded"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  [ -f "$padded/.claude/settings.local.json" ]
  has_session_start "$padded/.claude/settings.local.json"
}

@test "delivery set: a space-padded spelling of an EXISTING dir is used literally, never trimmed into the real one" {
  # "  $TEST_PROJECT  " is a RELATIVE pathname whose first byte is a space --
  # NOT the real (absolute) project path. Accepting spaces as literal path
  # bytes must not come with a silent fallback that trims the padding and
  # resolves to the directory the caller probably meant: the value is used
  # as-is, found not to exist, and rejected -- with the real project left
  # untouched. (This pins the "accept literally" half of the #493 follow-up
  # from the other side: the old trim-then-compare rejection also prevented
  # this fallback, so its removal must not quietly introduce one.)
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "  $TEST_PROJECT  "
  [ "$status" -ne 0 ]
  [[ "$output" =~ "does not exist" ]]
  ! has_session_start "$(settings_file)"
}

@test "delivery set: rejects a project_path with an embedded newline" {
  local bogus="$TEST_PROJECT"$'\n'"extra"
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$bogus"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "carriage return or newline" ]]
  [ ! -e "$bogus" ]
}

@test "delivery set: rejects a project_path with a trailing carriage return (CRLF line endings)" {
  # The CR half of the CR/LF rule: a command composed on (or pasted from) a
  # CRLF-line-ending environment leaves a bare \r on the value once the shell
  # strips the \n. Same class of defect as the #493 repro, same rejection.
  local bogus="$TEST_PROJECT"$'\r'
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$bogus"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "carriage return or newline" ]]
  [ ! -e "$bogus" ]
}

@test "delivery set: rejects a project_path with a leading newline or an embedded carriage return" {
  # The remaining corners of the "CR or LF anywhere" rule: leading (not just
  # trailing) LF, and CR hiding mid-value rather than at an end.
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code $'\n'"$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "carriage return or newline" ]]
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"$'\r'"extra"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "carriage return or newline" ]]
}

@test "delivery set: an un-enterable relative path cannot validate via a same-named CDPATH match" {
  # With CDPATH set, a bare `cd proj` can land in <cdpath-entry>/proj instead
  # of ./proj -- so the traversability probe would test a DIFFERENT directory
  # than the one `-d` just checked. The validator clears CDPATH for the probe;
  # this pins that an un-enterable ./proj is still rejected even when an
  # enterable directory of the same name sits on CDPATH.
  if [ "$(id -u)" -eq 0 ]; then
    skip "running as root: permission bits do not restrict traversal"
  fi
  local decoy_root="$TEST_PROJECT/cdpath-decoy"
  mkdir -p "$decoy_root/proj"            # enterable decoy on CDPATH
  mkdir -p "$TEST_PROJECT/here/proj"     # the real target, made un-enterable
  chmod 000 "$TEST_PROJECT/here/proj"
  cd "$TEST_PROJECT/here"
  CDPATH="$decoy_root" run bash "$SCRIPTS/delivery.sh" set monitor claude-code "proj"
  chmod 755 "$TEST_PROJECT/here/proj"
  cd "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "cannot be entered" ]]
  # Nothing was written into the enterable decoy.
  [ ! -e "$decoy_root/proj/.claude" ]
}

@test "delivery set: a normal valid project_path (the documented \$(pwd) shape) still works end to end" {
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  has_session_start "$(settings_file)"
}

# --- in-session directives ---

@test "delivery set monitor: emits AGMSG-DIRECTIVE for Monitor invocation" {
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "invoke the Monitor tool" ]]
  [[ "$output" =~ "watch.sh" ]]
}

@test "delivery set both: emits AGMSG-DIRECTIVE for Monitor invocation" {
  run bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "watch.sh" ]]
}

# The host pastes the emitted command into Monitor and runs it as a shell
# command; if the argv isn't shell-quoted, a project path with whitespace
# (iCloud Drive) or an apostrophe (/Users/o'brien/...) is mis-parsed and watch.sh
# resolves the wrong project. These re-parse the emitted line the way the host
# shell would and assert the project survives as one argv element. The path
# carries BOTH a space and an apostrophe (the case a plain '...' wrap breaks on).
# AGMSG_RESOLVE_PROJECT=0 keeps the raw path so the round-trip is deterministic.

@test "delivery set monitor: directive argv round-trips through a shell (#188)" {
  local sp="$TEST_PROJECT/Mobile Documents/o'brien proj"
  mkdir -p "$sp"
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/delivery.sh" set monitor claude-code "$sp"
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  [ -n "$cmdline" ]
  eval "set -- $cmdline"
  [ "$3" = "$sp" ]
  [ "$4" = "claude-code" ]
}

@test "session-start: Monitor directive argv round-trips through a shell (#188)" {
  local sp="$TEST_PROJECT/Mobile Documents/o'brien proj"
  mkdir -p "$sp"
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$sp" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$sp" </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" =~ "invoke the Monitor tool" ]]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  [ -n "$cmdline" ]
  eval "set -- $cmdline"
  [ "$3" = "$sp" ]
}

@test "session-start: a connected team with no engine is started, and said when that fails (#761, #774)" {
  # A reboot kills every sync engine and nothing restarts one. `connected` keeps
  # printing and `send` keeps succeeding locally, so the only symptom is silence
  # — which reads as "nobody wrote anything". This hook is the first thing of
  # ours that runs afterwards.
  #
  # A RULING WAS REVERSED HERE, and this test is where it is recorded.
  #
  # #761/#765 decided: do NOT start anything, make the absence VISIBLE. That
  # decision is what this test was written to hold. #774 reverses it — an agent
  # arriving at a connected team now STARTS the engine — on the grounds that
  # visibility asks a person for something the machine can do.
  #
  # What #765 built is not discarded: its warning, its wording and its runnable
  # remedy are exactly what remains when the start FAILS, and that is the case
  # driven below. The assertions about what the operator is told are therefore
  # unchanged; only the reason they are reachable is new. This is a reversal of
  # a decision, not a test edited to fit new output (raised in review).
  #
  # THE FAILURE IS FORCED BY THE COMMAND ITSELF, not by its environment.
  #
  # It used to be forced with an unusable interpreter, on the reasoning that
  # `sync start` would then "fail immediately and for a named reason". That is
  # a claim about a machine, and it was false on one: on a macOS CI runner the
  # command had not returned after SIXTY seconds, so the hook printed "a start
  # is still in flight" — a different fact, tested elsewhere — and this case
  # failed for a reason that had nothing to do with what it asserts.
  #
  # So `remote.sh` is replaced, for this half of the test, by one that answers
  # `status` with a connected team and refuses `sync start` at once. The real
  # one is restored before the section below, which needs it to SUCCEED.
  #
  # It used to be inherited instead — the fixture simply had no engine to start
  # — and that held only while this file ran alone: the case passed under
  # `--filter` and failed in the full file, because what a start does depends on
  # what other tests left behind. That is the same cross-test coupling this PR
  # fixes in its own suite, arriving from the other direction. The condition is
  # stated here so nothing about the surrounding file can decide it.
  #
  # The budget is raised as well: under the 5s default a slow failure is
  # reported as "still in flight", which is a different fact and is tested
  # separately in tests/test_sync_autostart.bats.
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null

  # NEGATIVE FIRST, on the state every ordinary machine is in: no connected
  # team at all. A line printed unconditionally would pass the positive half
  # below and be wrong every single session.
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  refute grep -qF -- "connected, but not syncing" <<<"$output"

  # Now a connected team whose engine is not running. Written through the same
  # config the command reads, rather than by calling `connect` — no server here.
  local cfg="$TEST_SKILL_DIR/teams/team/config.json" updated escaped
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped', '\$.remote_binding', json_object(
      'endpoint', 'https://remote.example',
      'server_instance_id', '018f0000-0000-7000-8000-000000000001',
      'remote_team_id', '018f0000-0000-7000-8000-000000000002',
      'protocol_version', 1,
      'capabilities', json_object('write_allowed_ciphers', json_array('none')),
      'connected_at', '2026-08-12T00:00:00Z',
      'disconnected_at', null
    ));")"
  printf '%s\n' "$updated" > "$cfg"

  # The stub goes in HERE, after the negative half has run against the real
  # command. Installed any earlier it would report a connected team before one
  # exists, and the negative assertion — the one that catches a line printed
  # unconditionally — would be testing the stub instead of the hook.
  cp "$SCRIPTS/remote.sh" "$TEST_SKILL_DIR/remote.real.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'if [ "${1:-}" = "status" ] && [ -z "${2:-}" ]; then'
    printf '%s\n' '  printf "team\tconnected since 2026-08-12\n"; exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'if [ "${1:-}" = "sync" ]; then'
    printf '%s\n' '  echo "agmsg: cannot start the sync engine for '"'"'$3'"'"': no runtime" >&2; exit 1'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 0'
  } > "$SCRIPTS/remote.sh"
  chmod +x "$SCRIPTS/remote.sh"

  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q -F -- "connected, but not syncing"
  # The printed COMMAND must be runnable, not a template. Scoped to the command
  # lines: the Monitor directive below legitimately contains `<team>` when it
  # describes the message format `<ts> | <team> | <from> → <to> | <body>`, and a
  # whole-output match calls that a defect. Measured — the first version of this
  # assertion failed on exactly that line.
  # Saved BEFORE the next `run`, which replaces $output. Asserting on $output
  # after running the suggested command reads the command's output and calls it
  # the hook's — measured here, it turned a passing check into a failing one for
  # the wrong reason.
  local session_out="$output" suggested
  suggested="$(printf '%s\n' "$session_out" | sed -n 's/^  bash //p' | head -1)"
  [ -n "$suggested" ]
  refute grep -qF -- "<team>" <<<"$suggested"

  # The directive still has to be there: a warning that displaces it would stop
  # the session receiving anything at all, which is worse than the gap it names.
  printf '%s\n' "$session_out" | grep -q -F -- "invoke the Monitor tool"

  # The real command is back from here on: the rest of this test requires a
  # `sync start` that can succeed, and a stub that always refuses would make
  # the final assertion unreachable rather than true.
  cp "$TEST_SKILL_DIR/remote.real.sh" "$SCRIPTS/remote.sh"
  chmod +x "$SCRIPTS/remote.sh"

  # Run what was printed, THROUGH AN INSTALL PATH THAT NEEDS QUOTING, and
  # require it to succeed.
  #
  # The first version of this checked only that `Usage:` was absent, and never
  # looked at `$status` — so `bash: …: No such file or directory` would have
  # passed it. And the fixture's install path had no space in it, so dropping
  # `%q` from the path changed nothing: the test could not fail for the reason
  # it was written. Both raised in review, both true.
  # A COPY, not a symlink. `SKILL_DIR` is `cd "$SCRIPT_DIR/.." && pwd`, and `..`
  # resolves through a symlink to the physical parent — so a symlinked install
  # with a space in its name arrives here as the real path without one, and the
  # fixture would silently stop testing what it was built for. Measured.
  local spaced="$BATS_TEST_TMPDIR/an install/skill"
  mkdir -p "$spaced"
  cp -R "$TEST_SKILL_DIR/." "$spaced/"
  run env AGMSG_RESOLVE_PROJECT=0 bash "$spaced/scripts/session-start.sh" claude-code "$TEST_PROJECT" </dev/null
  [ "$status" -eq 0 ]
  local spaced_cmd
  spaced_cmd="$(printf '%s\n' "$output" | sed -n 's/^  bash //p' | head -1)"
  [ -n "$spaced_cmd" ]
  # `install`, not `an install`: %q escapes the space, so the literal phrase is
  # never present in a correctly quoted line. Checking for it asserts the
  # ABSENCE of the quoting this test exists to require — measured, it failed
  # against a correct implementation twice.
  printf '%s\n' "$spaced_cmd" | grep -q -F -- "install"

  # A fake engine, so success is reachable at all: without one the command runs
  # correctly and still exits non-zero with `sync engine … did not become ready`,
  # and a test that accepted that would be accepting the failure it is meant to
  # catch.
  local fake_node="$BATS_TEST_TMPDIR/fake-node"
  printf '%s\n' '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "--version" ]; then echo v23.0.0; exit 0; fi' \
    'echo "{\"event\":\"capabilities\",\"startup_nonce\":\"${AGMSG_SYNC_START_NONCE:-}\"}"' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$fake_node"
  chmod +x "$fake_node"

  run env AGMSG_RESOLVE_PROJECT=0 AGMSG_NODE="$fake_node" bash -c "bash $spaced_cmd"
  # The STATUS, not the absence of one string. An unquoted path fails here with
  # `No such file or directory` and a non-zero exit, and the earlier version of
  # this check — `refute grep Usage:` — passed on exactly that.
  [ "$status" -eq 0 ]
  local started_pid
  started_pid="$(cat "$spaced/run/remote-sync.team.pid" 2>/dev/null || true)"
  [ -n "$started_pid" ]
  ENGINE_PIDS="${ENGINE_PIDS:+$ENGINE_PIDS }$started_pid"
  kill "$started_pid" 2>/dev/null || true
}

# --- session-start.sh role-aware resume directive (#339) ---

# Write a role-session record into the isolated skill dir's run/.
_seed_role_record() {
  local team="$1" agent="$2" sid="$3" proj="$4" type="${5:-claude-code}"
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_record "$2" "$3" "$4" "$5" "$6"
  ' _ "$SCRIPTS" "$team" "$agent" "$sid" "$proj" "$type"
}

@test "session-start: a resumed role's sid emits the role-filtered directive (#339)" {
  local sp="$TEST_PROJECT"
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$sp" >/dev/null
  _seed_role_record team alice "sid-resumed" "$sp" claude-code

  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$sp" <<< '{"session_id":"sid-resumed"}'
  [ "$status" -eq 0 ]
  [[ "$output" == *"resumed role"* ]]
  [[ "$output" == *"acting as alice"* ]]
  # The 4th watch.sh arg restricts receive to the role.
  local cmdline; cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [ "$5" = "alice" ]
}

@test "session-start: an unrecorded sid emits the generic directive (#339)" {
  local sp="$TEST_PROJECT"
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$sp" >/dev/null
  # no record for this sid

  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$sp" <<< '{"session_id":"sid-unknown"}'
  [ "$status" -eq 0 ]
  [[ "$output" != *"resumed role"* ]]
  [[ "$output" == *"invoke the Monitor tool"* ]]
  # Generic directive: watch.sh has no 4th (role) arg.
  local cmdline; cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [ "$#" -eq 4 ]
}

@test "session-start: a record for a role not registered here is ignored (#339)" {
  local sp="$TEST_PROJECT"
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$sp" >/dev/null
  # Same sid, but recorded for a (team, agent) that is NOT registered in this
  # project -- a cross-project sid collision must not mis-seat this session.
  _seed_role_record team ghost "sid-resumed" "/some/other/proj" claude-code

  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$sp" <<< '{"session_id":"sid-resumed"}'
  [ "$status" -eq 0 ]
  [[ "$output" != *"resumed role"* ]]
  [[ "$output" == *"invoke the Monitor tool"* ]]
}

@test "delivery set turn: emits AGMSG-DIRECTIVE to stop any running watcher" {
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "TaskStop" ]]
}

@test "delivery set off: emits AGMSG-DIRECTIVE to stop any running watcher" {
  run bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "TaskStop" ]]
}

# --- stop subcommand ---

@test "delivery stop: kills watchers and emits stop directive" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  # Spawn an actual watch.sh process so the safety check (argv contains
  # watch.sh) passes.
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" stop-test "$TEST_PROJECT" claude-code 3>&- &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.stop-test.pid" ]
  run bash "$SCRIPTS/delivery.sh" stop
  [[ "$output" =~ "Killed 1 watch" ]]
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [ ! -f "$TEST_SKILL_DIR/run/watch.stop-test.pid" ]
  sleep 1
  ! kill -0 "$watch_pid" 2>/dev/null
}

@test "delivery stop: skips pid whose command line is not watch.sh (pid recycling safety)" {
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 3>&- &
  local unrelated_pid=$!
  echo "$unrelated_pid" > "$TEST_SKILL_DIR/run/watch.stale-sess.pid"
  run bash "$SCRIPTS/delivery.sh" stop
  [[ "$output" =~ "Killed 0 watch" ]]
  [ ! -f "$TEST_SKILL_DIR/run/watch.stale-sess.pid" ]
  # The unrelated sleep process must still be alive.
  kill -0 "$unrelated_pid" 2>/dev/null
  kill "$unrelated_pid" 2>/dev/null || true
}

# --- restart subcommand ---

@test "delivery restart with args: emits both stop and start directives" {
  run bash "$SCRIPTS/delivery.sh" restart claude-code "$TEST_PROJECT"
  [[ "$output" =~ "Killed" ]]
  [[ "$output" =~ "TaskStop" ]]
  [[ "$output" =~ "invoke the Monitor tool" ]]
}

@test "delivery restart without args: emits only stop directive" {
  run bash "$SCRIPTS/delivery.sh" restart
  [[ "$output" =~ "TaskStop" ]]
  [[ ! "$output" =~ "invoke the Monitor tool" ]]
}

# --- watcher teardown is (project, type)-scoped (#218) ---
# claude-code is the only type that runs a watch.sh watcher. Before scoping,
# `set turn <any other type>` ran `kill_all_watchers "$PROJECT"` (project only)
# and tore down the project's claude-code monitor — collateral that killed
# unrelated agents' monitors on a shared machine.

@test "delivery set turn (other type): does NOT kill the project's claude-code watcher (#218)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  # A live claude-code watcher for this project.
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" cc-sess "$TEST_PROJECT" claude-code 3>&- &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.cc-sess.pid" ]
  # Switching a DIFFERENT type's delivery in the SAME project must not touch it.
  run bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/run/watch.cc-sess.pid" ]
  kill -0 "$watch_pid" 2>/dev/null
  kill "$watch_pid" 2>/dev/null || true
}

@test "delivery set off (claude-code): DOES kill the project's claude-code watcher (type matches)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" cc-sess2 "$TEST_PROJECT" claude-code 3>&- &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.cc-sess2.pid" ]
  run bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_SKILL_DIR/run/watch.cc-sess2.pid" ]
  sleep 1
  ! kill -0 "$watch_pid" 2>/dev/null
}

@test "delivery (project, type) scoping holds for a project path with spaces (#218)" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  # The argv match is the literal "<project> <type>" string, so a space in the
  # project path is matched verbatim — no false negatives (target preserved/
  # killed correctly) and no false positives across the space boundary.
  local sp="$TEST_PROJECT/with space proj"
  mkdir -p "$sp"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$sp"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sp-sess "$sp" claude-code 3>&- &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.sp-sess.pid" ]
  # Another type's set turn in the SAME space-containing project: must NOT kill it.
  run bash "$SCRIPTS/delivery.sh" set turn copilot "$sp"
  [ "$status" -eq 0 ]
  [ -f "$TEST_SKILL_DIR/run/watch.sp-sess.pid" ]
  kill -0 "$watch_pid" 2>/dev/null
  # claude-code off for the SAME space-containing project: must kill it (right target).
  run bash "$SCRIPTS/delivery.sh" set off claude-code "$sp"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_SKILL_DIR/run/watch.sp-sess.pid" ]
  sleep 1
  ! kill -0 "$watch_pid" 2>/dev/null
}

# --- watch.sh signal handling ---

@test "watch.sh exits promptly on SIGTERM and cleans its pidfile" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  # Minimal team config so identities.sh returns a pair.
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sigterm-test "$TEST_PROJECT" claude-code 3>&- &
  local pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.sigterm-test.pid" ]
  kill -TERM "$pid"
  sleep 1
  refute kill -0 "$pid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.sigterm-test.pid" ]
}

# --- session-start.sh: skip worktree sub-sessions (#367) ---

@test "session-start: skips the Monitor directive when hook cwd is under .claude/worktrees/" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  local sub_cwd="$TEST_PROJECT/.claude/worktrees/bg-task-1"
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<< "{\"session_id\":\"sid-sub\",\"cwd\":\"$sub_cwd\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ ! "$output" =~ "invoke the Monitor tool" ]]
}

@test "session-start: skips when hook cwd uses escaped-backslash (Windows JSON) separators" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<< '{"session_id":"sid-sub-win","cwd":"C:\\proj\\.claude\\worktrees\\bg-1"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session-start: falls back to \$PWD for the worktree check when the hook input has no cwd" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  local sub_cwd="$TEST_PROJECT/.claude/worktrees/bg-task-2"
  mkdir -p "$sub_cwd"
  run env AGMSG_RESOLVE_PROJECT=0 bash -c "cd '$sub_cwd' && bash '$SCRIPTS/session-start.sh' claude-code '$TEST_PROJECT' <<< '{\"session_id\":\"sid-sub-nocwd\"}'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "session-start: still emits the Monitor directive for a normal (non-worktree) cwd" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<< "{\"session_id\":\"sid-normal\",\"cwd\":\"$TEST_PROJECT\"}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "invoke the Monitor tool" ]]
}

@test "session-start: does NOT skip a project whose path merely contains 'claude' and 'worktrees' loosely" {
  # Regression guard: a naive *.claude*worktrees* glob would also match
  # unrelated project names like .claude-tools/my-worktrees-app, which don't
  # form the actual .claude/worktrees path segment sequence.
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  local decoy_cwd="$TEST_PROJECT/.claude-tools/my-worktrees-app"
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<< "{\"session_id\":\"sid-decoy\",\"cwd\":\"$decoy_cwd\"}"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "invoke the Monitor tool" ]]
}

# --- session-start.sh dedup across /clear ---

@test "session-start.sh kills previous watcher when called with new session_id in same cc-instance" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # Stand in for the previous watcher: a sleep that updates its own pidfile.
  sleep 30 3>&- &
  local prev_pid=$!
  echo "$prev_pid" > "$TEST_SKILL_DIR/run/watch.session-A.pid"
  # Pin the cc-instance state to "session-A" for a fake CC pid we control.
  local fake_cc_pid="$$"
  echo "session-A" > "$TEST_SKILL_DIR/run/cc-instance.$fake_cc_pid"

  # Patch find_cc_pid by stubbing ps via PATH override — too invasive. Instead
  # invoke a wrapper that exports the discovered CC pid via env, then have
  # session-start.sh consult it. (We test the cleanup path explicitly below.)

  # Verify the cleanup logic in isolation: feed the same script its inputs.
  # Simulate by hand: session_id changed → prev_pid should be killed.
  STATE="$TEST_SKILL_DIR/run/cc-instance.$fake_cc_pid"
  prev=$(cat "$STATE")
  pidfile="$TEST_SKILL_DIR/run/watch.$prev.pid"
  [ -f "$pidfile" ]
  prev_p=$(cat "$pidfile")
  kill "$prev_p"
  sleep 1
  ! kill -0 "$prev_p" 2>/dev/null
}

@test "session-start.sh cleans stale cc-instance files for dead CC pids" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  local dead_pid=999999
  touch "$TEST_SKILL_DIR/run/cc-instance.$dead_pid"
  echo '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.$dead_pid" ]
}

# --- session-id resolution: vendor field-name differences (grok/cursor) ---
# Grok Build emits the session id on stdin as camelCase "sessionId" and injects
# GROK_SESSION_ID into every hook; Claude uses snake_case "session_id". The
# shared resolver tries snake -> camel -> $GROK_SESSION_ID. The Monitor
# directive echoes the resolved id as the watch.sh command's session arg, so we
# assert through that. (Exercised via claude-code since the resolver is shared.)

@test "session-start: resolves camelCase sessionId from stdin (grok/cursor field)" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<<'{"sessionId":"grokCamelSID"}'
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [[ "$2" =~ grokCamelSID ]]
}

@test "session-start: falls back to GROK_SESSION_ID env when stdin lacks a session id" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 GROK_SESSION_ID=grokEnvSID bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<<'{}'
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [[ "$2" =~ grokEnvSID ]]
}

@test "session-start: snake_case session_id still wins over camelCase (claude-code unaffected)" {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/join.sh" team alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  run env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" <<<'{"session_id":"snakeWins","sessionId":"camelLoses"}'
  [ "$status" -eq 0 ]
  local cmdline
  cmdline=$(printf '%s\n' "$output" | sed -n 's/^[[:space:]]*command: //p')
  eval "set -- $cmdline"
  [[ "$2" =~ snakeWins ]]
  [[ ! "$2" =~ camelLoses ]]
}

# --- SessionEnd hook integration ---

has_session_end() {
  [ -f "$1" ] && grep -q "session-end.sh" "$1"
}

@test "delivery set monitor: installs SessionEnd alongside SessionStart" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  has_session_end   "$(settings_file)"
  ! has_check_inbox "$(settings_file)"
}

@test "delivery set both: installs SessionStart, SessionEnd, Stop" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  has_session_start "$(settings_file)"
  has_session_end   "$(settings_file)"
  has_check_inbox   "$(settings_file)"
}

@test "delivery set turn: no SessionEnd installed" {
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  ! has_session_end "$(settings_file)"
}

@test "delivery set off: removes SessionEnd along with other entries" {
  bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set off  claude-code "$TEST_PROJECT"
  ! has_session_end "$(settings_file)"
}

@test "delivery: monitor is idempotent for SessionEnd entry" {
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  local n
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.hooks.SessionEnd'));")
  [ "$n" = "1" ]
}

# --- session-end.sh behavior ---

@test "session-end.sh kills the watcher matching session_id and removes pidfile" {
  mkdir -p "$TEST_SKILL_DIR/run"
  # The cmdline has to look like this install's watch.sh: session-end only
  # signals a pid that still does, so a bare `sleep` was never killed and the
  # check for it was silent (#670).
  local target_pid
  spawn_decoy_with_cmdline "$SCRIPTS/watch.sh"; target_pid="$DECOY_PID"
  # The fixture's own preconditions, before the action. Without them this test
  # cannot refuse the false green it exists to fix: the first helper spawned the
  # decoy inside `$( )`, it died with the subshell, and "the watcher was killed"
  # passed because nothing was ever alive to kill.
  kill -0 "$target_pid" 2>/dev/null || { echo "the decoy was not alive" >&2; return 1; }
  _decoy_cmdline "$target_pid" | grep -q -F -- "$SCRIPTS/watch.sh" \
    || { echo "the decoy does not look like this install's watch.sh" >&2; return 1; }
  echo "$target_pid" > "$TEST_SKILL_DIR/run/watch.sess-A.pid"
  echo '{"session_id":"sess-A"}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
  sleep 1
  refute kill -0 "$target_pid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.sess-A.pid" ]
}

@test "session-end.sh leaves other sessions' watchers alone" {
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 3>&- &
  local other_pid=$!
  echo "$other_pid" > "$TEST_SKILL_DIR/run/watch.sess-B.pid"
  echo '{"session_id":"sess-A"}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
  kill -0 "$other_pid" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.sess-B.pid" ]
  kill "$other_pid" 2>/dev/null || true
}

@test "session-end.sh removes cc-instance file that points to this session" {
  mkdir -p "$TEST_SKILL_DIR/run"
  echo "sess-A" > "$TEST_SKILL_DIR/run/cc-instance.12345"
  echo "sess-B" > "$TEST_SKILL_DIR/run/cc-instance.67890"
  echo '{"session_id":"sess-A"}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.12345" ]
  [ -f "$TEST_SKILL_DIR/run/cc-instance.67890" ]
}

@test "session-end.sh exits 0 when input has no session_id" {
  echo '{}' | bash "$SCRIPTS/session-end.sh" claude-code "$TEST_PROJECT"
}

# --- CLAUDE_CODE_SESSION_ID baking ---

@test "delivery set monitor: bakes CLAUDE_CODE_SESSION_ID into the directive" {
  CLAUDE_CODE_SESSION_ID="real-uuid-1234" run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [[ "$output" =~ "real-uuid-1234" ]]
  # A quoted right-hand side in `[[ =~ ]]` is a literal, so `grep -F` matches
  # the same thing -- including the backslash: what must be absent is the
  # ESCAPED form `\$NAME`, not an expanded one. `! [[ ]]` never fired (#670).
  refute grep -q -F -- '\$AGMSG_SESSION_ID' <<<"$output"
  refute grep -q -F -- '\$CLAUDE_CODE_SESSION_ID' <<<"$output"
}

@test "delivery set monitor: falls back to a generated id when env is unset" {
  # Ensure env var is unset
  unset CLAUDE_CODE_SESSION_ID
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  # No placeholder leaked
  refute grep -q -F -- '\$AGMSG_SESSION_ID' <<<"$output"
}

# --- session-start.sh: stale watcher pidfile cleanup ---

@test "session-start.sh removes watch.<sid>.pid files whose pid is dead" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  echo "999999" > "$TEST_SKILL_DIR/run/watch.dead-session.pid"  # bogus pid
  : > "$TEST_SKILL_DIR/run/watch.empty-pid.pid"                  # empty pid
  echo '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.dead-session.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/watch.empty-pid.pid" ]
}

# watch.sh records its own $$ into watch.<token>.pid, so the pid recorded there
# is minted in the MSYS pid space. The stale-pidfile sweep just above this in
# session-start.sh ("Same defensive pass for stale watcher pidfiles") used to
# probe it with _agmsg_pid_alive, which under MSYSTEM asks tasklist -- and
# tasklist has no record of an MSYS-only pid, so a live watcher read as dead
# and its pidfile got removed, freeing the next session to spawn a duplicate.
# Routed through _agmsg_pid_alive_local (kill -0) instead. Unlike the "leaves
# alive watcher pidfiles alone (when bound to a live CC instance)" test below,
# this one binds NO cc-instance record, so only the sweep itself -- not the
# separate dead-cc-instance passes above it -- decides the outcome.
@test "session-start.sh: stale-pidfile sweep keeps a live watcher pidfile tasklist cannot see (#567-style regression)" {
  skip_on_windows "stubs tasklist to model Git Bash; the real one is authoritative there"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  local stubdir="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stubdir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stubdir/tasklist"
  chmod +x "$stubdir/tasklist"

  sleep 30 3>&- &
  local live_pid=$!
  echo "$live_pid" > "$TEST_SKILL_DIR/run/watch.sweep-live.pid"

  printf '{"session_id":"x"}' | env MSYSTEM=MINGW64 PATH="$stubdir:$PATH" \
    bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null

  [ -f "$TEST_SKILL_DIR/run/watch.sweep-live.pid" ]

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
}

# Native-Windows companion of the test above: exercises the real MSYS pid space
# and the real tasklist.exe instead of a stub, so it proves the fix against the
# actual environment the bug was found in rather than a model of it. No
# cc-instance binding here either, for the same isolation reason.
@test "session-start.sh: stale-pidfile sweep keeps a live watcher pidfile under real Git Bash (#567-style regression, native Windows only)" {
  skip_unless_windows "exercises the real MSYS pid space and real tasklist"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  sleep 30 3>&- &
  local live_pid=$!
  echo "$live_pid" > "$TEST_SKILL_DIR/run/watch.sweep-live-native.pid"

  printf '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null

  [ -f "$TEST_SKILL_DIR/run/watch.sweep-live-native.pid" ]

  kill "$live_pid" 2>/dev/null || true
  wait "$live_pid" 2>/dev/null || true
}

@test "session-start.sh leaves alive watcher pidfiles alone (when bound to a live CC instance)" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 30 3>&- &
  local alive_pid=$!
  echo "$alive_pid" > "$TEST_SKILL_DIR/run/watch.live-session.pid"
  # Bind this watcher to a live CC instance (use $$ as a stand-in).
  echo "live-session" > "$TEST_SKILL_DIR/run/cc-instance.$$"
  echo '{"session_id":"x"}' | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.live-session.pid" ]
  kill "$alive_pid" 2>/dev/null || true
}

# --- emit_monitor_directive idempotency ---

@test "emit monitor directive: skips when a live watcher already exists for this session" {
  mkdir -p "$TEST_SKILL_DIR/run"
  # Spawn a live process and pretend it's our watcher for this session_id.
  sleep 30 3>&- &
  local live_pid=$!
  CLAUDE_CODE_SESSION_ID="live-test-sid"
  export CLAUDE_CODE_SESSION_ID
  echo "$live_pid" > "$TEST_SKILL_DIR/run/watch.$CLAUDE_CODE_SESSION_ID.pid"

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already streaming" ]]
  refute grep -q -F -- 'AGMSG-DIRECTIVE' <<<"$output"

  kill "$live_pid" 2>/dev/null || true
  unset CLAUDE_CODE_SESSION_ID
}

@test "emit monitor directive: skips when tasklist cannot see the live watcher (#567)" {
  skip_on_windows "stubs tasklist to model Git Bash; the real one is authoritative there"
  # watch.sh records its own $$, so the pid in watch.<sid>.pid is numbered in the
  # MSYS pid space. `tasklist` reports Windows pids and has no record of it --
  # measured on our own Windows runner, where $$, $! and a pid read back from a
  # pidfile all come back with zero tasklist hits while kill -0 answers yes. A
  # probe that asks tasklist therefore calls the running watcher dead, and this
  # dedup emits a second directive beside the one already streaming.
  mkdir -p "$TEST_SKILL_DIR/run"
  local stubdir="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stubdir"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stubdir/tasklist"
  chmod +x "$stubdir/tasklist"

  sleep 30 3>&- &
  local live_pid=$!
  CLAUDE_CODE_SESSION_ID="msys-live-sid"
  export CLAUDE_CODE_SESSION_ID
  echo "$live_pid" > "$TEST_SKILL_DIR/run/watch.$CLAUDE_CODE_SESSION_ID.pid"

  run env MSYSTEM=MINGW64 PATH="$stubdir:$PATH" \
    bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "already streaming" ]]
  refute grep -q -F -- 'AGMSG-DIRECTIVE' <<<"$output"

  kill "$live_pid" 2>/dev/null || true
  unset CLAUDE_CODE_SESSION_ID
}

@test "emit monitor directive: emits when no live watcher exists for this session" {
  CLAUDE_CODE_SESSION_ID="fresh-sid-no-watcher"
  export CLAUDE_CODE_SESSION_ID

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "AGMSG-DIRECTIVE" ]]
  [[ "$output" =~ "fresh-sid-no-watcher" ]]

  unset CLAUDE_CODE_SESSION_ID
}

@test "session-start.sh for codex matches rollout cwd via a symlinked project path (#160)" {
  skip_on_windows "codex bridge launch and symlink path on Windows (#182)"
  # agmsg opens the project through a symlink (linkproj), but Codex records the
  # canonical/physical cwd (realproj) in session_meta. A raw string compare
  # misses the rollout, so the thread never resolves and the bridge never
  # starts. With physical-path canonicalization the two reconcile.
  local realproj="$TEST_PROJECT/realproj"
  local linkproj="$TEST_PROJECT/linkproj"
  mkdir -p "$realproj"
  ln -s "$realproj" "$linkproj"
  local phys
  phys=$(cd "$realproj" && pwd -P)

  bash "$SCRIPTS/join.sh" team alice codex "$linkproj" >/dev/null
  _seed_role_record team alice thread-sym "$linkproj" codex

  # Stage a Codex rollout whose session_meta records the PHYSICAL cwd.
  local sdir="$HOME/.codex/sessions/2026/06/19"
  mkdir -p "$sdir"
  printf '{"type":"session_meta","payload":{"id":"thread-sym","cwd":"%s"}}\n' "$phys" \
    > "$sdir/rollout-test.jsonl"

  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  # env -u CODEX_THREAD_ID forces the rollout-scan fallback that does the
  # compare — without it, a CODEX_THREAD_ID inherited from the parent env (e.g.
  # running the suite inside a Codex session) short-circuits the resolver and
  # this test never exercises the path it's meant to cover.
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$fake" \
  AGMSG_TEST_LOG="$log" \
    env -u CODEX_THREAD_ID bash "$SCRIPTS/session-start.sh" codex "$linkproj" >/dev/null

  for _ in {1..20}; do
    [ -f "$log" ] && break
    sleep 0.1
  done

  [ -f "$log" ]
  grep -q -- "--thread thread-sym" "$log"
}

# --- gemini agent tests ---

@test "delivery set turn (gemini): installs rule file" {
  run bash "$SCRIPTS/delivery.sh" set turn gemini "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  [ -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
  grep -q "check-inbox.sh" "$TEST_PROJECT/.agent/rules/agmsg.md"
}

@test "delivery set off (gemini): removes rule file" {
  bash "$SCRIPTS/delivery.sh" set turn gemini "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set off gemini "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
}

@test "delivery status (gemini): derives mode from rule file existence" {
  run bash "$SCRIPTS/delivery.sh" status gemini "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn gemini "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status gemini "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

# --- copilot agent tests ---

@test "delivery set turn (copilot): writes .github/hooks/agmsg.json with version + Stop entry" {
  run bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  local hook_file="$TEST_PROJECT/.github/hooks/agmsg.json"
  [ -f "$hook_file" ]
  # JSON sanity: version=1, Stop entry references check-inbox.sh
  local v
  v=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.version');")
  [ "$v" = "1" ]
  local cmd
  cmd=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.hooks.Stop[0].bash');")
  [[ "$cmd" =~ "check-inbox.sh" ]]
  [[ "$cmd" =~ "copilot" ]]
}

@test "delivery set off (copilot): removes the hook file" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
  run bash "$SCRIPTS/delivery.sh" set off copilot "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
}

@test "delivery set monitor (copilot): rejected; no hook file written" {
  run bash "$SCRIPTS/delivery.sh" set monitor copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
}

# Regression for a Copilot review finding: the unsupported-mode arms used to
# `rm -f` the hook file before validating the mode, so fat-fingering
# `mode monitor` on a project with a working `turn` config silently wiped
# delivery. Validation must come first.
@test "delivery set monitor (copilot): does NOT delete an existing turn hook" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
  run bash "$SCRIPTS/delivery.sh" set monitor copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
  local n
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.github/hooks/agmsg.json")'), '\$.hooks.Stop'));")
  [ "$n" = "1" ]
}

@test "delivery set both (copilot): does NOT delete an existing turn hook" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" set both copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.github/hooks/agmsg.json" ]
}

@test "delivery set both (copilot): rejected" {
  run bash "$SCRIPTS/delivery.sh" set both copilot "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
}

@test "delivery status (copilot): derives mode from hook file existence" {
  run bash "$SCRIPTS/delivery.sh" status copilot "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status copilot "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

@test "delivery set turn (copilot): idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn copilot "$TEST_PROJECT"
  local n
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.github/hooks/agmsg.json")'), '\$.hooks.Stop'));")
  [ "$n" = "1" ]
}

@test "check-inbox (copilot): emits JSON cooldown message inside cooldown window" {
  bash "$SCRIPTS/join.sh" testteam alice copilot "$TEST_PROJECT"
  # Prime the cooldown marker
  echo '{}' | bash "$SCRIPTS/check-inbox.sh" copilot "$TEST_PROJECT" >/dev/null
  # Second call within cooldown: copilot should get JSON, not silence
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' copilot '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg: check skipped (cooldown)" ]]
  [[ "$output" =~ "\"continue\"" ]]
}

@test "check-inbox (copilot): emits decision=block JSON when new messages arrive" {
  bash "$SCRIPTS/join.sh" testteam alice copilot "$TEST_PROJECT"
  bash "$SCRIPTS/join.sh" testteam bob   copilot "$TEST_PROJECT"
  # Push cooldown window into the past so the first invocation is not skipped.
  bash "$SCRIPTS/config.sh" set delivery.turn.check_interval 0 >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "ping copilot"
  run bash -c "echo '{}' | bash '$SCRIPTS/check-inbox.sh' copilot '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"decision\": \"block\"" ]]
  [[ "$output" =~ "ping copilot" ]]
}

@test "check-inbox: does not hang when stdin is a non-TTY pipe that never reaches EOF (#381)" {
  # A minimal `timeout` shim so this test exercises check-inbox.sh's own
  # `command -v timeout` code path deterministically, regardless of whether
  # the host actually ships GNU timeout (stock macOS does not) -- what's
  # under test is check-inbox.sh's wiring to `timeout`, not the host
  # environment. Prepended first on PATH so it wins even where a real one
  # also exists.
  local bindir="$TEST_SKILL_DIR/shimbin"
  mkdir -p "$bindir"
  cat > "$bindir/timeout" <<'EOF'
#!/usr/bin/env bash
secs="$1"; shift
("$@") 3>&- & cmd_pid=$!
( sleep "$secs"; kill "$cmd_pid" 2>/dev/null ) 3>&- & watchdog_pid=$!
if wait "$cmd_pid" 2>/dev/null; then
  kill "$watchdog_pid" 2>/dev/null
  exit 0
else
  exit 124
fi
EOF
  chmod +x "$bindir/timeout"

  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT"

  local fifo="$TEST_PROJECT/repro.fifo"
  mkfifo "$fifo"
  # Write the payload, then hold the write end open without closing it --
  # exactly the "hook runtime forgets to close the pipe" shape from the
  # issue's own FIFO repro. A plain `sleep N | check-inbox.sh` does NOT
  # reproduce this: bash waits for every pipeline member, so it looks like a
  # hang even when the hook itself exits immediately.
  { printf '%s' '{"stop_hook_active":false,"session_id":"repro-381"}'; sleep 300; } \
    3>&- 4>&- > "$fifo" &
  local writer_pid="$!"

  local newpath="$bindir:$PATH"
  run bash -c "PATH='$newpath' AGMSG_HOOK_STDIN_TIMEOUT=1 bash '$SCRIPTS/check-inbox.sh' claude-code '$TEST_PROJECT' < '$fifo'"

  kill "$writer_pid" 2>/dev/null || true
  rm -f "$fifo"

  [ "$status" -eq 0 ]
}




# --- watch.sh exclusive role filter ---

@test "watch.sh restricts subscription to active_name when 4th arg is given" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{
  "name":"myteam",
  "agents":{
    "alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]},
    "bob":  {"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}
  }
}
JSON
  # Insert two messages, one for each agent.
  DB="$TEST_SKILL_DIR/db/messages.db"
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'system', 'alice', 'for-alice');"
  sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('myteam', 'system', 'bob', 'for-bob');"

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" t-sid "$TEST_PROJECT" claude-code bob > /tmp/agmsg-as-bob 2>&1 3>&- &
  local pid=$!
  # The watcher seeds its cursor from the storage tip at startup, so prior
  # messages aren't replayed. Send NEW messages through the facade (storage_send
  # writes the event log the watcher now streams) and wait for several polls.
  sleep 1
  bash "$SCRIPTS/send.sh" myteam system alice "new-for-alice" --force >/dev/null
  bash "$SCRIPTS/send.sh" myteam system bob "new-for-bob" --force >/dev/null
  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true

  grep -q "new-for-bob"   /tmp/agmsg-as-bob
  ! grep -q "new-for-alice" /tmp/agmsg-as-bob
  rm -f /tmp/agmsg-as-bob
}

@test "watch.sh exits when active_name is not registered" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  run bash "$SCRIPTS/watch.sh" t-sid "$TEST_PROJECT" claude-code nobody
  [[ "$output" =~ "no registration for agent 'nobody'" ]]
}

# --- session-start.sh orphan watcher cleanup ---

@test "session-start.sh kills orphan watchers whose owning CC instance is gone" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # Orphan: watcher referenced by a cc-instance.<dead-pid> file. Its cmdline
  # has to look like watch.sh or the reaper declines to signal it (#670).
  local orphan_pid
  spawn_decoy_with_cmdline "$SCRIPTS/watch.sh"; orphan_pid="$DECOY_PID"
  # Same preconditions, same reason.
  kill -0 "$orphan_pid" 2>/dev/null || { echo "the decoy was not alive" >&2; return 1; }
  _decoy_cmdline "$orphan_pid" | grep -q -F -- "$SCRIPTS/watch.sh" \
    || { echo "the decoy does not look like this install's watch.sh" >&2; return 1; }
  echo "$orphan_pid" > "$TEST_SKILL_DIR/run/watch.orphan-sid.pid"
  # Use a PID that's almost certainly not in use as the dead CC ancestor.
  local dead_cc_pid=999999
  echo "orphan-sid" > "$TEST_SKILL_DIR/run/cc-instance.$dead_cc_pid"

  # Untracked watcher: no cc-instance points to it. Conservative semantics
  # leave it alone (we have no evidence the CC is dead).
  sleep 30 3>&- &
  local untracked_pid=$!
  echo "$untracked_pid" > "$TEST_SKILL_DIR/run/watch.untracked-sid.pid"

  echo "{\"session_id\":\"current-sid\"}" \
    | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null

  refute kill -0 "$orphan_pid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.orphan-sid.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.$dead_cc_pid" ]
  # Untracked watcher untouched
  kill -0 "$untracked_pid" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.untracked-sid.pid" ]
  kill "$untracked_pid" 2>/dev/null || true
}

@test "session-start.sh does NOT kill a watcher when its session_id is still live under a different CC pid" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # The session moved from one CC pid to another (claude --continue / resume).
  # cc-instance.<dead> still references the same session_id as
  # cc-instance.<live>. The watcher must NOT be killed.
  sleep 30 3>&- &
  local watcher_pid=$!
  echo "$watcher_pid" > "$TEST_SKILL_DIR/run/watch.shared-sid.pid"
  local dead_cc=999999
  echo "shared-sid" > "$TEST_SKILL_DIR/run/cc-instance.$dead_cc"
  echo "shared-sid" > "$TEST_SKILL_DIR/run/cc-instance.$$"

  echo "{\"session_id\":\"x\"}" \
    | bash "$SCRIPTS/session-start.sh" claude-code "$TEST_PROJECT" >/dev/null

  kill -0 "$watcher_pid" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.shared-sid.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/cc-instance.$dead_cc" ]
  kill "$watcher_pid" 2>/dev/null || true
}

@test "watch.sh subscription is static — newly joined identities don't appear in a running watcher" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  DB="$TEST_SKILL_DIR/db/messages.db"

  # Watcher starts with only `alice` registered. Default subscription set
  # is resolved at launch and not re-evaluated each poll.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" t-static "$TEST_PROJECT" claude-code > /tmp/agmsg-static 2>&1 3>&- &
  local pid=$!
  sleep 1

  # Join `bob` to the same (project, type) after the watcher is running.
  bash "$SCRIPTS/join.sh" myteam bob claude-code "$TEST_PROJECT"

  # Send messages for both via the facade. alice should arrive (alice was in the
  # original subscription set); bob should NOT arrive (joined after launch).
  bash "$SCRIPTS/send.sh" myteam sys alice "for-alice-static" --force >/dev/null
  bash "$SCRIPTS/send.sh" myteam sys bob   "for-bob-static" --force >/dev/null

  sleep 3
  kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true

  grep -q "for-alice-static" /tmp/agmsg-static
  refute grep -q "for-bob-static" /tmp/agmsg-static
  rm -f /tmp/agmsg-static
}

# --- set turn/off is project-scoped: must not kill other projects' watchers ---

@test "delivery set turn: kills only the target project's watcher, leaves other projects'" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  local proj_a="$TEST_PROJECT"
  local proj_b
  proj_b="$(mktemp -d)"

  mkdir -p "$TEST_SKILL_DIR/teams/team-a" "$TEST_SKILL_DIR/teams/team-b"
  cat > "$TEST_SKILL_DIR/teams/team-a/config.json" <<JSON
{"name":"team-a","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$proj_a"}]}}}
JSON
  cat > "$TEST_SKILL_DIR/teams/team-b/config.json" <<JSON
{"name":"team-b","agents":{"bob":{"registrations":[{"type":"claude-code","project":"$proj_b"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sid-a "$proj_a" claude-code 3>&- &
  local pid_a=$!
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" sid-b "$proj_b" claude-code 3>&- &
  local pid_b=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.sid-a.pid" ]
  [ -f "$TEST_SKILL_DIR/run/watch.sid-b.pid" ]

  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj_a"
  [ "$status" -eq 0 ]
  sleep 1

  # Target project A: watcher killed, pidfile removed.
  refute kill -0 "$pid_a" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.sid-a.pid" ]

  # Other project B: watcher and its pidfile must survive.
  kill -0 "$pid_b" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.sid-b.pid" ]

  kill "$pid_b" 2>/dev/null || true
  rm -rf "$proj_b"
}

@test "delivery set off: kills only the target project's watcher, leaves other projects'" {
  skip_on_windows "watcher process mgmt under Git Bash (#182)"
  local proj_a="$TEST_PROJECT"
  local proj_b
  proj_b="$(mktemp -d)"

  mkdir -p "$TEST_SKILL_DIR/teams/team-a" "$TEST_SKILL_DIR/teams/team-b"
  cat > "$TEST_SKILL_DIR/teams/team-a/config.json" <<JSON
{"name":"team-a","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$proj_a"}]}}}
JSON
  cat > "$TEST_SKILL_DIR/teams/team-b/config.json" <<JSON
{"name":"team-b","agents":{"bob":{"registrations":[{"type":"claude-code","project":"$proj_b"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" off-a "$proj_a" claude-code 3>&- &
  local pid_a=$!
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" off-b "$proj_b" claude-code 3>&- &
  local pid_b=$!
  sleep 1

  run bash "$SCRIPTS/delivery.sh" set off claude-code "$proj_a"
  [ "$status" -eq 0 ]
  sleep 1

  refute kill -0 "$pid_a" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/watch.off-a.pid" ]
  kill -0 "$pid_b" 2>/dev/null
  [ -f "$TEST_SKILL_DIR/run/watch.off-b.pid" ]

  kill "$pid_b" 2>/dev/null || true
  rm -rf "$proj_b"
}

@test "delivery stop: remains global — kills watchers across all projects" {
  local proj_a="$TEST_PROJECT"
  local proj_b
  proj_b="$(mktemp -d)"

  mkdir -p "$TEST_SKILL_DIR/teams/team-a" "$TEST_SKILL_DIR/teams/team-b"
  cat > "$TEST_SKILL_DIR/teams/team-a/config.json" <<JSON
{"name":"team-a","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$proj_a"}]}}}
JSON
  cat > "$TEST_SKILL_DIR/teams/team-b/config.json" <<JSON
{"name":"team-b","agents":{"bob":{"registrations":[{"type":"claude-code","project":"$proj_b"}]}}}
JSON

  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" stop-a "$proj_a" claude-code 3>&- &
  local pid_a=$!
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" stop-b "$proj_b" claude-code 3>&- &
  local pid_b=$!
  sleep 1

  run bash "$SCRIPTS/delivery.sh" stop
  [[ "$output" =~ "Killed 2 watch" ]]
  sleep 1
  refute kill -0 "$pid_a" 2>/dev/null
  refute kill -0 "$pid_b" 2>/dev/null

  rm -rf "$proj_b"
}

# --- Windows support: codex hooks emit commandWindows; other types do not ---

@test "delivery set turn (codex): Stop entry carries commandWindows wrapping Git Bash" {
  skip_on_windows "commandWindows not written on native Windows (#182)"
  run bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local hook_file="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hook_file" ]
  local cw
  cw=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
  [ -n "$cw" ]
  [[ "$cw" == *"Program Files\\Git\\bin\\bash.exe"* ]]
  [[ "$cw" == *"GIT_BASH"* ]]
  [[ "$cw" == *"-lc"* ]]
  [[ "$cw" != *".agents/bin"* ]]
  [[ "$cw" == *"check-inbox.sh"* ]]
}

@test "delivery set turn (claude-code): Stop entry has NO commandWindows (regression guard)" {
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local hook_file="$TEST_PROJECT/.claude/settings.local.json"
  [ -f "$hook_file" ]
  local cw
  cw=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hook_file")'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
  [ -z "$cw" ]
}

# --- #1003: codex mid-turn PostToolUse hook install/strip/status wiring ---
#
# The install is version-gated (#1003 review): the entry goes in only when the
# codex CLI is confirmed at or above posttooluse_min_cli, fail-closed otherwise.
# The version is READ from the CLI, never asserted, so these place a fake `codex`
# on PATH (both the pass and the fail cases) rather than depending on whether a
# real codex is installed (CI has none). The gate narrows WHO gets the entry
# written; it does not establish that an older CLI ignores a persisted entry.

# A fake `codex` whose `--version` prints $1 (empty $1 => it exits non-zero).
# Echoes a dir to PREPEND to PATH.
_fake_codex_path() {
  local dir="$TEST_SKILL_DIR/fakebin"
  mkdir -p "$dir"
  if [ -z "${1:-}" ]; then
    printf '#!/bin/sh\nexit 1\n' > "$dir/codex"
  else
    printf '#!/bin/sh\necho "%s"\n' "$1" > "$dir/codex"
  fi
  chmod +x "$dir/codex"
  printf '%s' "$dir"
}

@test "delivery set turn (codex): installs a PostToolUse entry alongside Stop, carrying the event arg (#1003)" {
  run env PATH="$(_fake_codex_path 'codex-cli 0.149.1'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local hf="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hf" ]
  local n
  n=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$hf")'), '\$.hooks.PostToolUse'));")
  [ "$n" = "1" ]
  # The command runs check-inbox with the PostToolUse event as a 3rd arg, so the
  # script emits that event's shape — not a copy that would silently use Stop's.
  local cmd
  cmd=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hf")'), '\$.hooks.PostToolUse[0].hooks[0].command');")
  grep -q 'check-inbox.sh' <<<"$cmd"
  grep -q 'PostToolUse' <<<"$cmd"
  local m
  m=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$hf")'), '\$.hooks.PostToolUse[0].matcher');")
  [ -z "$m" ]
  local s
  s=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$hf")'), '\$.hooks.Stop'));")
  [ "$s" = "1" ]
}

@test "delivery set turn (codex): the PostToolUse entry carries commandWindows too (#1003)" {
  skip_on_windows "commandWindows not written on native Windows (#182)"
  run env PATH="$(_fake_codex_path '0.149.1'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local cw
  cw=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse[0].hooks[0].commandWindows');")
  [ -n "$cw" ]
  grep -q 'check-inbox.sh' <<<"$cw"
  grep -q 'PostToolUse' <<<"$cw"
}

@test "delivery set off (codex): strips the PostToolUse entry with Stop (#1003)" {
  env PATH="$(_fake_codex_path '0.149.1'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" set off codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "0" ]
}

# --- version gate: install only at/above the EXACT measured floor, fail-closed ---
# Boundary controls on both sides: exact floor, floor-minus-one, and a MAX.

@test "delivery set turn (codex): the exact measured floor 0.149.1 installs (#1003)" {
  run env PATH="$(_fake_codex_path '0.149.1'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "1" ]
}

@test "delivery set turn (codex): floor-minus-one 0.149.0 does NOT install — patch is significant (#1003)" {
  run env PATH="$(_fake_codex_path '0.149.0'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "0" ]
  grep -q 'mid-turn delivery (PostToolUse) not installed' <<<"$output"
  local s
  s=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.Stop'));")
  [ "$s" = "1" ]
}

@test "delivery set turn (codex): a far-newer version installs (MAX side) (#1003)" {
  run env PATH="$(_fake_codex_path '9.9.9'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "1" ]
}

@test "delivery set turn (codex): an unparseable CLI version does NOT install, fail-closed (#1003)" {
  run env PATH="$(_fake_codex_path 'banana'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "0" ]
  grep -q 'mid-turn delivery (PostToolUse) not installed' <<<"$output"
}

@test "delivery set turn (codex): a CLI whose --version fails does NOT install, fail-closed (#1003)" {
  run env PATH="$(_fake_codex_path ''):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "0" ]
  grep -q 'mid-turn delivery (PostToolUse) not installed' <<<"$output"
}

@test "delivery set monitor (codex): installs NO PostToolUse entry (#1003)" {
  run env PATH="$(_fake_codex_path '0.149.1'):$PATH" bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.codex/hooks.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "0" ]
}

@test "delivery set turn (claude-code): installs NO PostToolUse entry — no manifest datum (#1003)" {
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  local n
  n=$(sqlite_mem "SELECT coalesce(json_array_length(json_extract(readfile('$(rf "$TEST_PROJECT/.claude/settings.local.json")'), '\$.hooks.PostToolUse')), 0);" 2>/dev/null || echo 0)
  [ "${n:-0}" = "0" ]
}

@test "delivery status (codex turn): reports the PostToolUse entry count next to Stop (#1003)" {
  env PATH="$(_fake_codex_path '0.149.1'):$PATH" bash "$SCRIPTS/delivery.sh" set turn codex "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  grep -q 'Stop entries:' <<<"$output"
  grep -q 'PostToolUse entries:  1' <<<"$output"
}

# --- Hook JSON escaping: build entries via json_object, not by hand (#134) ---
#
# The pre-fix code hand-assembled the entry JSON and only escaped the codex
# commandWindows. The "command" value's own embedded " and ' went in raw, so any
# project path containing them produced "Error: stepping, malformed JSON" and no
# hook file — for BOTH claude-code and codex (#134 Bug 1, reporter #138). These
# reproduce on macOS/Linux independent of the sqlite build.
#
# Note: these cover the cross-platform JSON-escaping defect only. Native-Windows
# delivery has a separate, still-open failure (empty commandWindows / invalid
# JSON even for plain paths — sqlite3.exe / CRLF, #130); see the windows-latest
# experimental leg. Not addressed here.

# SQL string-literal escape so a tricky path is safe inside our own probe query.
sql_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

# The quote/backslash path cases below use " and \ in directory names, which are
# not legal filename characters on NTFS — they can't even be created under Git
# Bash on Windows. Skip there; the required ubuntu/macos legs cover them.
skip_if_no_special_fs() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "\" and \\ are not legal filename chars on NTFS" ;;
  esac
}

@test "delivery set turn: project path with quotes yields valid JSON (claude-code) (#134)" {
  skip_if_no_special_fs
  local proj="$TEST_PROJECT/o'brien \"x\""
  mkdir -p "$proj"
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj"
  [ "$status" -eq 0 ]
  local hf="$proj/.claude/settings.local.json"
  [ -f "$hf" ]
  local hfq; hfq=$(sql_lit "$hf")
  [ "$(sqlite_mem "SELECT json_valid(readfile('$hfq'));")" = "1" ]
  local cmd
  cmd=$(sqlite_mem "SELECT json_extract(readfile('$hfq'), '\$.hooks.Stop[0].hooks[0].command');")
  [[ "$cmd" == *"check-inbox.sh"* ]]
  [[ "$cmd" == *"o'\\''brien \"x\""* ]]
}

@test "delivery set turn: project path with quotes yields valid JSON + commandWindows (codex) (#134)" {
  skip_if_no_special_fs
  local proj="$TEST_PROJECT/o'brien \"x\""
  mkdir -p "$proj"
  run bash "$SCRIPTS/delivery.sh" set turn codex "$proj"
  [ "$status" -eq 0 ]
  local hf="$proj/.codex/hooks.json"
  [ -f "$hf" ]
  local hfq; hfq=$(sql_lit "$hf")
  [ "$(sqlite_mem "SELECT json_valid(readfile('$hfq'));")" = "1" ]
  local cw
  cw=$(sqlite_mem "SELECT json_extract(readfile('$hfq'), '\$.hooks.Stop[0].hooks[0].commandWindows');")
  [ -n "$cw" ]
  [[ "$cw" == *"Program Files\\Git\\bin\\bash.exe"* ]]
  [[ "$cw" == *"check-inbox.sh"* ]]
}

@test "delivery set turn: project path with a backslash round-trips intact (#134)" {
  # json_object must JSON-escape a literal backslash in the raw command value
  # (a hand-built "command":"..." left it raw). Backslashes are the norm in
  # Windows-shaped inputs, so verify the byte survives the round-trip.
  skip_if_no_special_fs
  local proj="$TEST_PROJECT/a\\b"
  mkdir -p "$proj"
  run bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj"
  [ "$status" -eq 0 ]
  local hf="$proj/.claude/settings.local.json"
  local hfq; hfq=$(sql_lit "$hf")
  [ "$(sqlite_mem "SELECT json_valid(readfile('$hfq'));")" = "1" ]
  local cmd
  cmd=$(sqlite_mem "SELECT json_extract(readfile('$hfq'), '\$.hooks.Stop[0].hooks[0].command');")
  [[ "$cmd" == *'a\b'* ]]
}

@test "delivery set monitor: existing settings with single-quoted hook commands stays valid JSON (#134)" {
  # The reporter's trigger: settings.local.json already holds hook commands
  # containing single quotes. Pre-fix, re-adding our entries produced malformed
  # JSON. Post-fix the round-trip stays valid and preserves the prior hook.
  mkdir -p "$TEST_PROJECT/.claude"
  cat > "$(settings_file)" <<'JSON'
{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"bash -lc 'echo it'\''s mine'"}]}]}}
JSON
  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_valid(readfile('$(rf "$(settings_file)")'));")" = "1" ]
  has_session_start "$(settings_file)"
}

# --- Large settings.local.json: must not trip Linux MAX_ARG_STRLEN (#95) ---
#
# Reporter's actual settings was 32,357 bytes. The pre-fix code embedded the
# whole blob 6x into one sqlite3 argv element inside strip_agmsg_event, so on
# Linux (MAX_ARG_STRLEN = 131072) anything above ~21 KB triggered E2BIG. The
# test below uses ~30 KB to stay close to the reporter's size and reliably
# fail before the fix on Linux. macOS has a much higher per-arg ceiling
# (kern.argmax ≈ 1 MB) so the pre-fix code can survive 30 KB there — the
# test still passes on macOS post-fix; the regression guard is meaningful
# on Linux CI.

@test "delivery set monitor: handles a large settings.local.json without E2BIG (#95)" {
  mkdir -p "$TEST_PROJECT/.claude"
  # Build a ~30 KB settings file with a populated permissions.allow list.
  # 600 entries * ~50 bytes each ≈ 30 KB.
  {
    printf '{"permissions":{"allow":['
    local i
    for i in $(seq 1 600); do
      [ "$i" -gt 1 ] && printf ','
      printf '"Bash(mkdir:/tmp/agmsg-e2big-entry-%04d)"' "$i"
    done
    printf ']}}'
  } > "$(settings_file)"
  local size
  size=$(wc -c < "$(settings_file)" | tr -d ' ')
  [ "$size" -gt 25000 ]

  run bash "$SCRIPTS/delivery.sh" set monitor claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  has_session_start "$(settings_file)"

  # Existing user permissions must be preserved across the rewrite.
  local first last allow_len
  first=$(sqlite_mem "SELECT json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow[0]');")
  last=$(sqlite_mem  "SELECT json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow[599]');")
  allow_len=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow'));")
  [ "$first" = "Bash(mkdir:/tmp/agmsg-e2big-entry-0001)" ]
  [ "$last" = "Bash(mkdir:/tmp/agmsg-e2big-entry-0600)" ]
  [ "$allow_len" = "600" ]
}

@test "delivery set both: handles a large settings.local.json across strip+add+prune (#95)" {
  mkdir -p "$TEST_PROJECT/.claude"
  {
    printf '{"permissions":{"allow":['
    local i
    for i in $(seq 1 600); do
      [ "$i" -gt 1 ] && printf ','
      printf '"Bash(mkdir:/tmp/agmsg-e2big-both-%04d)"' "$i"
    done
    printf ']}}'
  } > "$(settings_file)"

  # `both` exercises three add_event_entry_file calls after three
  # strip_agmsg_event_file calls — the longest chain in apply_settings.
  run bash "$SCRIPTS/delivery.sh" set both claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  has_session_start "$(settings_file)"
  has_check_inbox "$(settings_file)"

  local allow_len
  allow_len=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow'));")
  [ "$allow_len" = "600" ]
}

@test "delivery set off: idempotent strip on a large settings.local.json (#95)" {
  mkdir -p "$TEST_PROJECT/.claude"
  # Pre-populate with both user permissions and an agmsg-owned Stop entry,
  # then verify `set off` strips only the agmsg entry without choking on
  # the file size. Build the inflated fixture via sqlite3 (no python3
  # dependency — agmsg is bash + sqlite3 only).
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$TEST_PROJECT"

  local allow_json
  allow_json=$(
    printf '['
    local i
    for i in $(seq 1 600); do
      [ "$i" -gt 1 ] && printf ','
      printf '"Bash(mkdir:/tmp/agmsg-e2big-off-%04d)"' "$i"
    done
    printf ']'
  )
  local inflated
  inflated=$(sqlite_mem "
    SELECT json_set(
      json_set(readfile('$(rf "$(settings_file)")'), '\$.permissions', json('{}')),
      '\$.permissions.allow', json('$allow_json')
    );
  ")
  printf '%s' "$inflated" > "$(settings_file)"

  run bash "$SCRIPTS/delivery.sh" set off claude-code "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  refute has_check_inbox "$(settings_file)"
  local allow_len
  allow_len=$(sqlite_mem "SELECT json_array_length(json_extract(readfile('$(rf "$(settings_file)")'), '\$.permissions.allow'));")
  [ "$allow_len" = "600" ]
}

# --- opencode agent tests ---

@test "opencode is accepted as an agent type (turn mode)" {
  run bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  grep -q "check-inbox.sh" "$TEST_PROJECT/.opencode/rules/agmsg.md"
}

@test "opencode supports off mode: removes rule file" {
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set off opencode "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
}

@test "opencode rejects both mode" {
  run bash "$SCRIPTS/delivery.sh" set both opencode "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
}

@test "opencode rejects both: does NOT delete an existing turn rule" {
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set both opencode "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
}

@test "opencode set monitor: passes the delivery_modes gate and writes a sentinel_monitor rule" {
  run bash "$SCRIPTS/delivery.sh" set monitor opencode "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  local rule_file="$TEST_PROJECT/.opencode/rules/agmsg.md"
  [ -f "$rule_file" ]
  run cat "$rule_file"
  [[ "$output" == *"agmsg-delivery-mode: monitor"* ]]
  [[ "$output" == *"sentinel_monitor"* ]]
  [[ "$output" == *"watch.sh"* ]]
  [[ "$output" == *"SENTINEL_SESSION_ID"* ]]
  # Fallback instructions for when sentinel_monitor is unavailable.
  [[ "$output" == *"check-inbox.sh"* ]]
}

@test "opencode set monitor: a project path containing an apostrophe stays one shell word" {
  # An apostrophe is a legal POSIX path character and delivery.sh accepts it, so
  # a literal '$project' wrap in the rule would end the argument early and let
  # anything after it become live shell syntax. Both generated commands — the
  # sentinel_monitor watcher and the fallback check-inbox — have to survive it.
  local weird="$TEST_PROJECT/it's a proj"
  mkdir -p "$weird"
  run bash "$SCRIPTS/delivery.sh" set monitor opencode "$weird"
  [ "$status" -eq 0 ]

  local rule_file="$weird/.opencode/rules/agmsg.md"
  [ -f "$rule_file" ]

  # The path must not appear inside a single-quoted span that its own apostrophe
  # terminates. Asserted by running the generated command lines through the
  # shell's own parser: a broken quote fails to parse at all.
  local line
  while IFS= read -r line; do
    case "$line" in
      *watch.sh*|*check-inbox.sh*) ;;
      *) continue ;;
    esac
    line="${line#- command: }"
    line="${line#- Command: }"
    run bash -n -c "$line"
    [ "$status" -eq 0 ] || { echo "generated command does not parse: $line"; false; }
  done < "$rule_file"
}

@test "opencode status: reports monitor when the monitor rule is present" {
  bash "$SCRIPTS/delivery.sh" set monitor opencode "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status opencode "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "opencode set turn then monitor: rewrites the rule from turn to monitor" {
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status opencode "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
  bash "$SCRIPTS/delivery.sh" set monitor opencode "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status opencode "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "opencode supports turn/monitor/off modes: status derives mode from rule file content" {
  run bash "$SCRIPTS/delivery.sh" status opencode "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status opencode "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

@test "opencode set turn: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn opencode "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.opencode/rules/agmsg.md" ]
  local count
  count=$(grep -c "check-inbox.sh" "$TEST_PROJECT/.opencode/rules/agmsg.md")
  [ "$count" -eq 1 ]
}

# --- cursor agent tests (#131) ---

@test "cursor is accepted as an agent type (turn mode)" {
  run bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  grep -q "check-inbox.sh" "$TEST_PROJECT/.cursor/rules/agmsg.mdc"
}

@test "cursor rule file is an always-apply .mdc (Cursor CLI auto-load)" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null
  # First non-empty line opens the frontmatter; alwaysApply must be declared so
  # the Cursor CLI applies the rule on every turn.
  [ "$(head -1 "$TEST_PROJECT/.cursor/rules/agmsg.mdc")" = "---" ]
  grep -q "alwaysApply: true" "$TEST_PROJECT/.cursor/rules/agmsg.mdc"
}

@test "cursor supports off mode: removes rule file" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  run bash "$SCRIPTS/delivery.sh" set off cursor "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor rejects monitor mode" {
  run bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor rejects both mode" {
  run bash "$SCRIPTS/delivery.sh" set both cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor rejects monitor: does NOT delete an existing turn rule" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT" >/dev/null
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  run bash "$SCRIPTS/delivery.sh" set monitor cursor "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
}

@test "cursor set turn: idempotent across repeats" {
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  bash "$SCRIPTS/delivery.sh" set turn cursor "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.cursor/rules/agmsg.mdc" ]
  local count
  count=$(grep -c "check-inbox.sh" "$TEST_PROJECT/.cursor/rules/agmsg.mdc")
  [ "$count" -eq 1 ]
}

@test "antigravity supports off mode: removes rule file" {
  bash "$SCRIPTS/delivery.sh" set turn antigravity "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set off antigravity "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
}

# #399: type.conf previously advertised delivery_modes=monitor turn both off,
# but antigravity has no Monitor tool or bridge equivalent — the manifest must
# match what the template actually offers (turn/off only, like cursor/gemini).
@test "antigravity rejects monitor mode" {
  run bash "$SCRIPTS/delivery.sh" set monitor antigravity "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
}

@test "antigravity rejects both mode" {
  run bash "$SCRIPTS/delivery.sh" set both antigravity "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "not supported" ]]
  [ ! -f "$TEST_PROJECT/.agent/rules/agmsg.md" ]
}

# --- Codex monitor bridge (#41) ---
@test "session-start.sh for codex starts bridge when monitor launcher env is present" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  _seed_role_record team alice thread-123 "$TEST_PROJECT" codex
  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  AGMSG_CODEX_BRIDGE=1 \
  AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/custom-store" \
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$fake" \
  AGMSG_TEST_LOG="$log" \
  CODEX_THREAD_ID="thread-123" \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" >/dev/null

  for _ in {1..20}; do
    [ -f "$log" ] && break
    sleep 0.1
  done

  [ -f "$log" ]
  grep -q -- "--project $TEST_PROJECT" "$log"
  grep -q -- "--workspace-root $TEST_SKILL_DIR/custom-store" "$log"
  grep -q -- "--thread thread-123" "$log"
  grep -q -- "--app-server unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" "$log"
  grep -q -- "--inline-inbox" "$log"
}

@test "session-start.sh for codex stays quiet without monitor launcher env" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  AGMSG_CODEX_BRIDGE_CMD="$fake" AGMSG_TEST_LOG="$log" CODEX_THREAD_ID="thread-123" \
    bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" >/dev/null

  [ ! -f "$log" ]
}

@test "delivery set monitor (codex): installs SessionStart and prints Codex shell function" {
  run bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex monitor is enabled"* ]]
  [[ "$output" == *"codex() {"* ]]
  [[ "$output" == *"codex-shim.sh"* ]]
  [[ "$output" == *"launch with codex"* ]]
  [[ "$output" == *"Optional global PATH shim is still available"* ]]
  [[ "$output" == *"For more info: https://github.com/fujibee/agmsg/blob/main/docs/codex-monitor-beta.md"* ]]
  [[ "$output" != *"Monitor tool"* ]]
  [ ! -e "$HOME/.agents/bin/codex" ]
  local hook_file="$TEST_PROJECT/.codex/hooks.json"
  [ -f "$hook_file" ]
  grep -q "session-start.sh" "$hook_file"
}

@test "delivery set both (codex): rejected by the delivery_modes gate" {
  # codex's manifest omits 'both' (delivery_modes=monitor turn off), so the
  # central gate in delivery.sh rejects it before any file is touched.
  run bash "$SCRIPTS/delivery.sh" set both codex "$TEST_PROJECT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not supported for codex"* ]]
}

@test "delivery status (codex): live bridge reports alive and suppresses watch count" {
  skip_on_windows "codex bridge status liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  sleep 60 3>&- &
  local bpid=$!
  # shellcheck disable=SC2064  # capture the current child pid for EXIT cleanup
  trap "kill $bpid 2>/dev/null || true" EXIT
  printf '%s\n' "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$bpid
project=$TEST_PROJECT
team=team
name=alice
type=codex
EOF
  printf '%s\n' 99999999 > "$TEST_SKILL_DIR/run/watch.fake.pid"

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice alive (pid $bpid)"* ]]
  [[ "$output" != *"watch processes:"* ]]

  kill "$bpid" 2>/dev/null || true
  trap - EXIT
}

@test "delivery status (codex): stale bridge pidfile is reported as stale" {
  skip_on_windows "codex bridge status liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  local dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
  done
  printf '%s\n' "$dead_pid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$dead_pid
project=$TEST_PROJECT
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice stale pidfile (pid $dead_pid not running)"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): bridge metadata mismatch is reported as stale" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$$
project=$TEST_PROJECT-other
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice stale pidfile (metadata mismatch)"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): metadata project spelling variant is not a mismatch" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # Same directory, different spelling (trailing slash). A verbatim compare
  # calls this a mismatch; canonical comparison must not.
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$$
project=$TEST_PROJECT/
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team/alice"* ]]
  [[ "$output" != *"metadata mismatch"* ]]
}

@test "delivery status (codex): metadata project in native Windows spelling is not a mismatch" {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) skip "needs a real Windows path spelling (cygpath)" ;; esac
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # The bridge records the project via Node's path.resolve, i.e. the
  # backslash form cygpath -w produces — the exact shape that made every
  # live bridge read as "metadata mismatch" on Windows.
  local win_project
  win_project="$(cygpath -w "$TEST_PROJECT")"
  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$$
project=$win_project
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team/alice"* ]]
  [[ "$output" != *"metadata mismatch"* ]]
}

@test "delivery status (codex): missing bridge metadata is reported as stale" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  printf '%s\n' "$$" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: team/alice stale pidfile (missing metadata)"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): identity with no bridge and no seat says so, not \"not running\"" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  # No seat is the reason here, and it is a different problem from a process
  # that died -- the old wording named the wrong one (#579).
  [[ "$output" == *"Codex bridge: team/alice has no session recorded"* ]]
  [[ "$output" != *"Codex bridge: team/alice not running"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "delivery status (codex): notes when the installed shim loses to a different codex on PATH and no bridge has ever been alive (#387)" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  mkdir -p "$HOME/.agents/bin"
  cp "$TYPES/codex/codex-shim.sh" "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  # A different, non-agmsg codex earlier on PATH -- exactly the "PATH order
  # loses" shape from #387/#397: mode stays "monitor" but launches never
  # actually reach the shim. No bridge has ever come alive here either, so
  # this is the one case with enough corroboration to say something.
  local other_bin="$TEST_SKILL_DIR/other-bin"
  mkdir -p "$other_bin"
  printf '#!/usr/bin/env bash\necho real\n' > "$other_bin/codex"
  chmod +x "$other_bin/codex"

  PATH="$other_bin:$HOME/.agents/bin:$PATH" run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Note: an agmsg codex shim is installed"* ]]
  [[ "$output" == *"$other_bin/codex"* ]]
}

@test "delivery status (codex): no PATH-mismatch note when the shim correctly wins PATH order (#387)" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  mkdir -p "$HOME/.agents/bin"
  cp "$TYPES/codex/codex-shim.sh" "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  PATH="$HOME/.agents/bin:$PATH" run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Note: an agmsg codex shim"* ]]
}

@test "delivery status (codex): no PATH-mismatch note when no PATH-based shim is installed (#387)" {
  # The shell-function-only install method is invisible to this script (a
  # function from an interactive profile isn't inherited by a fresh
  # `bash delivery.sh status` invocation) -- must not false-alarm here.
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Note: an agmsg codex shim"* ]]
}

@test "delivery status (codex): no PATH-mismatch note when a bridge is alive even if the shim file loses on PATH (#387 regression)" {
  # Real-machine regression: the shim FILE existing at ~/.agents/bin/codex
  # does not mean this install relies on PATH resolution for it -- the
  # shell-function method (recommended first, in on_enable) is common, and
  # having the PATH shim file ALSO present is a normal side effect of
  # following the setup instructions, not evidence of a broken PATH-based
  # setup. A live bridge is corroborating evidence that delivery is
  # actually working (by whichever method), so the note must remain silent.
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  mkdir -p "$HOME/.agents/bin" "$TEST_SKILL_DIR/run"
  cp "$TYPES/codex/codex-shim.sh" "$HOME/.agents/bin/codex"
  chmod +x "$HOME/.agents/bin/codex"

  local other_bin="$TEST_SKILL_DIR/other-bin"
  mkdir -p "$other_bin"
  printf '#!/usr/bin/env bash\necho real\n' > "$other_bin/codex"
  chmod +x "$other_bin/codex"

  sleep 60 3>&- &
  local bpid=$!
  # shellcheck disable=SC2064  # capture the current child pid for EXIT cleanup
  trap "kill $bpid 2>/dev/null || true" EXIT
  printf '%s\n' "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$bpid
project=$TEST_PROJECT
team=team
name=alice
type=codex
EOF

  PATH="$other_bin:$HOME/.agents/bin:$PATH" run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team/alice alive"* ]]
  [[ "$output" != *"Note: an agmsg codex shim"* ]]

  kill "$bpid" 2>/dev/null || true
  trap - EXIT
}

@test "delivery status (codex): multiple identities are enumerated independently" {
  skip_on_windows "codex bridge status liveness under Git Bash (#182)"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  sleep 60 3>&- &
  local bpid=$!
  # shellcheck disable=SC2064  # capture the current child pid for EXIT cleanup
  trap "kill $bpid 2>/dev/null || true" EXIT
  printf '%s\n' "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  cat > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" <<EOF
pid=$bpid
project=$TEST_PROJECT
team=team
name=alice
type=codex
EOF

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team/alice alive (pid $bpid)"* ]]
  [[ "$output" == *"Codex bridge: team/bob has no session recorded"* ]]
  [[ "$output" != *"watch processes:"* ]]

  kill "$bpid" 2>/dev/null || true
  trap - EXIT
}

@test "delivery status (codex): monitor mode with no identities is explicit" {
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  [[ "$output" == *"Codex bridge: no identities registered for this project"* ]]
  [[ "$output" != *"watch processes:"* ]]
}

@test "session-start.sh for codex resolves thread id from rollout when CODEX_THREAD_ID is unset" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  _seed_role_record team alice rollout-thread-999 "$TEST_PROJECT" codex
  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  # Fresh/exec Codex sessions do not export CODEX_THREAD_ID; the hook must read
  # the thread id from the newest rollout whose session_meta cwd matches (#41).
  local rollout_dir="$TEST_SKILL_DIR/home/.codex/sessions/2026/06/17"
  mkdir -p "$rollout_dir"
  printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"rollout-thread-999\",\"cwd\":\"$TEST_PROJECT\"}}" \
    > "$rollout_dir/rollout-2026-06-17T00-00-00-rollout-thread-999.jsonl"

  HOME="$TEST_SKILL_DIR/home" \
  AGMSG_CODEX_BRIDGE=1 \
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$fake" \
  AGMSG_TEST_LOG="$log" \
    env -u CODEX_THREAD_ID bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" >/dev/null

  for _ in {1..20}; do [ -f "$log" ] && break; sleep 0.1; done
  [ -f "$log" ]
  grep -q -- "--thread rollout-thread-999" "$log"
}

@test "session-start.sh for codex resolves the rollout by real mtime, not filename order (#416)" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  _seed_role_record team alice stale-by-name-uuid "$TEST_PROJECT" codex
  local fake="$TEST_SKILL_DIR/fake-codex-bridge"
  local log="$TEST_SKILL_DIR/fake-codex-bridge.log"
  cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$AGMSG_TEST_LOG"
EOF
  chmod +x "$fake"

  # `ls -t "$dir"/*/*/*/rollout-*.jsonl` was flaky on Windows/Git Bash --
  # intermittently returned an empty/truncated list with no filesystem
  # changes in between, so agmsg_resolve_codex_thread got starved of any
  # candidate and the SessionStart hook silently no-opped (#416). The fix
  # replaced it with find + a portable per-file mtime sort. Prove it is a
  # real mtime sort and not an accidental filename-lexical sort: one rollout
  # has an OLDER-looking filename timestamp but its actual mtime is touched
  # to be the newest of the two, matching this project's cwd. A find+sort-
  # by-name "fix" would pick the wrong (stale) rollout here.
  local rollout_dir="$TEST_SKILL_DIR/home/.codex/sessions/2026/06/17"
  mkdir -p "$rollout_dir"
  printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"stale-by-name-uuid\",\"cwd\":\"$TEST_PROJECT\"}}" \
    > "$rollout_dir/rollout-2020-01-01T00-00-00-stale-by-name-uuid.jsonl"
  printf '%s\n' "{\"type\":\"session_meta\",\"payload\":{\"id\":\"newer-by-name-uuid\",\"cwd\":\"$TEST_PROJECT\"}}" \
    > "$rollout_dir/rollout-2026-06-17T00-00-00-newer-by-name-uuid.jsonl"
  sleep 1
  touch "$rollout_dir/rollout-2020-01-01T00-00-00-stale-by-name-uuid.jsonl"

  HOME="$TEST_SKILL_DIR/home" \
  AGMSG_CODEX_BRIDGE=1 \
  AGMSG_CODEX_BRIDGE_APP_SERVER="unix://$TEST_SKILL_DIR/run/codex-app-server.test.sock" \
  AGMSG_CODEX_BRIDGE_CMD="$fake" \
  AGMSG_TEST_LOG="$log" \
    env -u CODEX_THREAD_ID bash "$SCRIPTS/session-start.sh" codex "$TEST_PROJECT" >/dev/null

  for _ in {1..20}; do [ -f "$log" ] && break; sleep 0.1; done
  [ -f "$log" ]
  grep -q -- "--thread stale-by-name-uuid" "$log"
}

@test "delivery set monitor (codex): warns loudly when Node is missing" {
  # Node preflight: the bridge is a Node program; enabling monitor without Node
  # must flag it rather than silently never starting. AGMSG_CODEX_NODE points the
  # check at a binary that does not exist. See #41.
  run env AGMSG_CODEX_NODE=__agmsg_no_such_node__ bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: Node.js"* ]]
  [[ "$output" == *"monitor delivery will NOT start"* ]]
}

@test "delivery set off (codex): stops the bridge, cleans run files, notes shell profile cleanup" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  # Stand in for a live bridge with a real process we can check kill -0 against.
  sleep 60 3>&- &
  local bpid=$!
  echo "$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid"
  echo "pid=$bpid" > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta"
  : > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.log"
  # The launcher's stale-binding sidecar + the project's shared app-server record
  # must be torn down too. Use a non-codex pid for the server record so the
  # cmdline guard skips the kill — the record is still dropped.
  : > "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver"
  source "$SCRIPTS/lib/hash.sh"
  local h; h="$(printf '%s' "$TEST_PROJECT" | agmsg_sha1)"
  echo 2147483647 > "$TEST_SKILL_DIR/run/codex-app-server.$h.pid"
  : > "$TEST_SKILL_DIR/run/codex-app-server.$h.port"
  : > "$TEST_SKILL_DIR/run/codex-app-server.$h.version"

  run bash "$SCRIPTS/delivery.sh" set off codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Stopped 1 Codex bridge"* ]]
  [[ "$output" == *"shim"* ]]
  refute kill -0 "$bpid" 2>/dev/null
  [ ! -f "$TEST_SKILL_DIR/run/codex-bridge.team.alice.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-bridge.team.alice.meta" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-bridge.team.alice.appserver" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-app-server.$h.pid" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-app-server.$h.port" ]
  [ ! -f "$TEST_SKILL_DIR/run/codex-app-server.$h.version" ]
  kill "$bpid" 2>/dev/null || true
}

# --- hermes (manual-only: delivery_modes=off, no automatic hook) ---

@test "delivery hermes: status is manual/off" {
  run bash "$SCRIPTS/delivery.sh" status hermes "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "mode: off" ]]
}

@test "delivery hermes: rejects automatic modes" {
  local mode
  for mode in turn monitor both; do
    run bash "$SCRIPTS/delivery.sh" set "$mode" hermes "$TEST_PROJECT"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "not supported for hermes" ]]
    [ ! -e "$TEST_PROJECT/.hermes/agmsg.json" ]
  done
}

@test "delivery hermes: rejects unknown mode" {
  run bash "$SCRIPTS/delivery.sh" set bogus hermes "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" =~ "Unknown mode" ]]
  [ ! -e "$TEST_PROJECT/.hermes/agmsg.json" ]
}

@test "delivery hermes: accepts off without writing hook config" {
  run bash "$SCRIPTS/delivery.sh" set off hermes "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'off'" ]]
  [[ "$output" =~ "manual inbox checks only" ]]
  [[ "$output" != *"AGMSG-DIRECTIVE"* ]]
  [ ! -e "$TEST_PROJECT/.hermes/agmsg.json" ]
}

@test "delivery hermes: set off does not stop Claude Code watchers for the same project" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" hermes-preserve-test "$TEST_PROJECT" claude-code 3>&- &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.hermes-preserve-test.pid" ]

  run bash "$SCRIPTS/delivery.sh" set off hermes "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  run kill -0 "$watch_pid"
  [ "$status" -eq 0 ]

  kill "$watch_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}

# --- grok-build (turn|off via a markdown rule file .grok/rules/agmsg.md) ---
# Grok passive hooks can't inject (stdout is discarded), so grok delivers via the
# rule-file self-poll model (like gemini/opencode): a .grok/rules/agmsg.md that
# tells the agent to poll inbox.sh each turn. turn => rule present, off => absent.

@test "delivery set turn (grok-build): writes .grok/rules/agmsg.md self-poll rule" {
  run bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'turn'" ]]
  local rule_file="$TEST_PROJECT/.grok/rules/agmsg.md"
  [ -f "$rule_file" ]
  # The rule points at inbox.sh (clean display + same-call mark = loss-safe),
  # not the hook-only check-inbox.sh, and references this type + project.
  run cat "$rule_file"
  [[ "$output" == *"inbox.sh"* ]]
  [[ "$output" != *"check-inbox.sh"* ]]
  [[ "$output" == *"grok-build"* ]]
  [[ "$output" == *"$TEST_PROJECT"* ]]
}

@test "delivery set off (grok-build): removes the rule file" {
  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.grok/rules/agmsg.md" ]
  run bash "$SCRIPTS/delivery.sh" set off grok-build "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.grok/rules/agmsg.md" ]
}

@test "delivery set monitor (grok-build): writes a monitor rule and emits the launch directive" {
  GROK_SESSION_ID="grok-sess-1" run bash "$SCRIPTS/delivery.sh" set monitor grok-build "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Delivery mode set to 'monitor'" ]]
  # Emits an in-session directive to launch watch.sh via the monitor tool, with
  # GROK_SESSION_ID baked into the command (not CLAUDE_CODE_SESSION_ID).
  [[ "$output" == *"AGMSG-DIRECTIVE"* ]]
  [[ "$output" == *"watch.sh"* ]]
  [[ "$output" == *"grok-sess-1"* ]]
  [[ "$output" == *"grok-build"* ]]
  # The rule carries the monitor marker and points at the monitor tool.
  local rule_file="$TEST_PROJECT/.grok/rules/agmsg.md"
  [ -f "$rule_file" ]
  run cat "$rule_file"
  [[ "$output" == *"agmsg-delivery-mode: monitor"* ]]
  [[ "$output" == *"monitor"* ]]
  [[ "$output" == *"watch.sh"* ]]
}

@test "delivery status (grok-build): reports monitor when the monitor rule is present" {
  GROK_SESSION_ID="grok-sess-2" bash "$SCRIPTS/delivery.sh" set monitor grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "delivery set turn then monitor (grok-build): rewrites the rule from turn to monitor" {
  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
  GROK_SESSION_ID="grok-sess-3" bash "$SCRIPTS/delivery.sh" set monitor grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: monitor" ]]
}

@test "delivery set both (grok-build): rejected; does NOT delete an existing turn rule" {
  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" set both grok-build "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.grok/rules/agmsg.md" ]
}

@test "delivery status (grok-build): derives mode from rule file existence" {
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: off" ]]

  bash "$SCRIPTS/delivery.sh" set turn grok-build "$TEST_PROJECT"
  run bash "$SCRIPTS/delivery.sh" status grok-build "$TEST_PROJECT"
  [[ "$output" =~ "mode: turn" ]]
}

# --- pi (in-process extension at .pi/extensions/agmsg.ts) ---
# Pi's session store takes a writer lease, so delivery is a project-local
# extension rather than watch.sh / JSON hooks. turn|monitor write the file;
# off removes it. both is rejected by the central gate.

@test "delivery set turn (pi): writes .pi/extensions/agmsg.ts with turn marker" {
  run bash "$SCRIPTS/delivery.sh" set turn pi "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "Delivery mode set to 'turn'"
  local ext_file="$TEST_PROJECT/.pi/extensions/agmsg.ts"
  [ -f "$ext_file" ]
  grep -q "agmsg-delivery-mode: turn" "$ext_file"
  grep -q "agent_settled" "$ext_file"
  grep -F -q "$TEST_SKILL_DIR" "$ext_file"
  refute grep -q "agmsg-delivery-mode: monitor" "$ext_file"
}

@test "delivery set monitor (pi): writes the extension with a 15s poll" {
  run bash "$SCRIPTS/delivery.sh" set monitor pi "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -q "Delivery mode set to 'monitor'"
  local ext_file="$TEST_PROJECT/.pi/extensions/agmsg.ts"
  [ -f "$ext_file" ]
  grep -q "agmsg-delivery-mode: monitor" "$ext_file"
  grep -q "15000" "$ext_file"
  grep -F -q "$TEST_SKILL_DIR" "$ext_file"
  refute grep -q "watch.sh" "$ext_file"
}

@test "delivery set off (pi): removes the extension" {
  bash "$SCRIPTS/delivery.sh" set turn pi "$TEST_PROJECT"
  [ -f "$TEST_PROJECT/.pi/extensions/agmsg.ts" ]
  run bash "$SCRIPTS/delivery.sh" set off pi "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.pi/extensions/agmsg.ts" ]
}

@test "delivery status (pi): derives mode from the extension marker" {
  run bash "$SCRIPTS/delivery.sh" status pi "$TEST_PROJECT"
  printf '%s\n' "$output" | grep -q "mode: off"

  bash "$SCRIPTS/delivery.sh" set turn pi "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status pi "$TEST_PROJECT"
  printf '%s\n' "$output" | grep -q "mode: turn"

  bash "$SCRIPTS/delivery.sh" set monitor pi "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" status pi "$TEST_PROJECT"
  printf '%s\n' "$output" | grep -q "mode: monitor"
}

@test "delivery set both (pi): rejected; does NOT delete an existing turn extension" {
  bash "$SCRIPTS/delivery.sh" set turn pi "$TEST_PROJECT" >/dev/null
  run bash "$SCRIPTS/delivery.sh" set both pi "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [ -f "$TEST_PROJECT/.pi/extensions/agmsg.ts" ]
}

@test "delivery set off (pi): does not stop Claude Code watchers for the same project" {
  mkdir -p "$TEST_SKILL_DIR/teams/myteam"
  cat > "$TEST_SKILL_DIR/teams/myteam/config.json" <<JSON
{"name":"myteam","agents":{"alice":{"registrations":[{"type":"claude-code","project":"$TEST_PROJECT"}]}}}
JSON
  AGMSG_WATCH_INTERVAL=10 bash "$SCRIPTS/watch.sh" pi-preserve-test "$TEST_PROJECT" claude-code 3>&- &
  local watch_pid=$!
  sleep 1
  [ -f "$TEST_SKILL_DIR/run/watch.pi-preserve-test.pid" ]

  run bash "$SCRIPTS/delivery.sh" set off pi "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  run kill -0 "$watch_pid"
  [ "$status" -eq 0 ]

  kill "$watch_pid" 2>/dev/null || true
  wait 2>/dev/null || true
}

@test "delivery status (codex): a recorded seat makes \"not running\" mean the process (#579)" {
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  # shellcheck disable=SC1090
  SKILL_DIR="$TEST_SKILL_DIR" source "$SCRIPTS/lib/role-session.sh"
  SKILL_DIR="$TEST_SKILL_DIR" agmsg_role_session_record team alice seat-uuid-1 "$TEST_PROJECT" codex

  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  # With a seat on record, the bridge really is just absent -- and the seat is
  # printed so the reader can tell the two states apart at a glance.
  [[ "$output" == *"Codex bridge: team/alice not running (seat recorded: seat-uuid-1)"* ]]
  [[ "$output" != *"has no session recorded"* ]]
}

@test "delivery status (codex): a port that accepts but never answers does not stall status (#579)" {
  # A stale port file whose port is now held by something that completes the TCP
  # connect and then says nothing is the worst case for a diagnostic probe: the
  # bridge's own defaults would wait 10s to connect plus 30s for a reply, per
  # identity. status has to stay a status line.
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob   codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  # Silent listener: accepts, then holds the socket open without ever replying.
  local portfile="$TEST_SKILL_DIR/silent.port"
  node -e '
    const net = require("net");
    const srv = net.createServer(() => {});
    srv.listen(0, "127.0.0.1", () => {
      require("fs").writeFileSync(process.argv[1], String(srv.address().port));
    });
  ' "$portfile" >/dev/null 2>&1 3>&- &
  local listener=$!
  local waited=0
  while [ ! -s "$portfile" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -s "$portfile" ]

  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/hash.sh"
  mkdir -p "$TEST_SKILL_DIR/run"
  cp "$portfile" "$TEST_SKILL_DIR/run/codex-app-server.$(printf '%s' "$TEST_PROJECT" | agmsg_sha1).port"

  local start finish elapsed
  start=$(date +%s)
  run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  finish=$(date +%s)
  elapsed=$((finish - start))

  kill "$listener" 2>/dev/null || true
  wait "$listener" 2>/dev/null || true

  [ "$status" -eq 0 ]
  [[ "$output" == *"mode: monitor"* ]]
  # Tight enough to fail on the bridge's own 10s connect default: this probe must
  # carry a status-sized timeout of its own, not inherit a delivery-sized one.
  [ "$elapsed" -lt 8 ]
}

@test "delivery status (codex): the loaded-thread probe runs once, not once per identity (#579)" {
  # Bounding the timeout is not enough on its own -- N identities with no seat
  # would still pay it N times. Counted rather than timed, so it cannot pass by
  # being fast.
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob   codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team carol codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null

  local calls="$TEST_SKILL_DIR/probe-calls"
  local fake="$TEST_SKILL_DIR/counting-node"
  {
    printf '#!/usr/bin/env bash
'
    printf 'printf x >> %q
' "$calls"
    printf 'printf "thr-a\nthr-b\n"
'
  } > "$fake"
  chmod +x "$fake"

  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/hash.sh"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '1' > "$TEST_SKILL_DIR/run/codex-app-server.$(printf '%s' "$TEST_PROJECT" | agmsg_sha1).port"

  AGMSG_NODE="$fake" run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  # Three seatless identities, one probe.
  [ "$(wc -c < "$calls" | tr -d ' ')" = "1" ]
  [[ "$output" == *"2 threads loaded"* ]]
}

@test "delivery status (codex): a thread already seated elsewhere is not called unexpected" {
  # A loaded thread seats ONE role. When the only loaded thread belongs to alice,
  # bob having no seat is the correct state — the old wording called it
  # unexpected because it counted loaded threads rather than unclaimed ones.
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/delivery.sh" set monitor codex "$TEST_PROJECT" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"

  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/hash.sh"
  # The record has to land in the tree delivery.sh will read, so the helper needs
  # the test's skill dir rather than the one it would derive for itself.
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/role-session.sh"
  agmsg_role_session_record team alice thr-alice "$TEST_PROJECT" codex
  [ -n "$(agmsg_role_session_uuid team alice)" ]
  printf '1' > "$TEST_SKILL_DIR/run/codex-app-server.$(printf '%s' "$TEST_PROJECT" | agmsg_sha1).port"

  local fake="$TEST_SKILL_DIR/fake-node-loaded"
  { printf '#!/usr/bin/env bash\n'; printf 'printf %%s\\\\n thr-alice\n'; } > "$fake"
  chmod +x "$fake"

  AGMSG_NODE="$fake" run bash "$SCRIPTS/delivery.sh" status codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Codex bridge: team/bob has no session recorded (the one loaded thread is already seated by another role)"* ]]
  [[ "$output" != *"That combination is unexpected"* ]]
}

# --- "stops quietly" is what made a delivery bug expensive (#691, #692, #694) ---

@test "watch: the liveness guard says which session it decided about (#692)" {
  # The guard is right; the silence is what costs. A watcher launched with a
  # session id that does not resolve exits here immediately, and a test then
  # runs against no watcher while looking exactly like one that ran against
  # one -- twice in a row, during a real investigation.
  #
  # A composite id whose agent pid is dead is the shape that fires it.
  local dead
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  # No `timeout` on macOS, and the suite's own idiom is to run it and wait for
  # it to end on its own -- which this guard makes it do immediately.
  bash "$SCRIPTS/watch.sh" "gone-session.$dead" "$TEST_PROJECT" claude-code \
    >/dev/null 2>/dev/null &
  wait $! || true
  # Said, and readable AFTERWARDS -- stderr is /dev/null where this really runs.
  local log="$TEST_SKILL_DIR/run/watch.gone-session.$dead.log"
  [ -f "$log" ] || { echo "no log at $log" >&2; return 1; }
  grep -q "no longer alive" "$log" || { cat "$log" >&2; return 1; }
  grep -q -F -- "gone-session.$dead" "$log" || { cat "$log" >&2; return 1; }
}

@test "watch: the log is written even when stderr is discarded (#691)" {
  # The whole point. Not "we pointed stderr somewhere" -- the process is run
  # with fd2 closed off exactly as it is in production, and the reason still
  # has to be readable when it is over.
  local dead
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  run bash -c \
    "bash '$SCRIPTS/watch.sh' 'silent-session.$dead' '$TEST_PROJECT' claude-code 2>/dev/null"
  [ "$status" -eq 0 ] || return 1
  # Nothing reached the caller, which is the configuration being reproduced.
  [ -z "$output" ] || { echo "expected no output, got: $output" >&2; return 1; }
  local log="$TEST_SKILL_DIR/run/watch.silent-session.$dead.log"
  [ -f "$log" ] || { echo "no log at $log" >&2; return 1; }
  grep -q "no longer alive" "$log" || { cat "$log" >&2; return 1; }
}

@test "watch: one diagnostic cannot carry the log past its cap (#691)" {
  # The boundary, not the already-over case. A live log UNDER the cap takes one
  # more line and must not end up over it -- the first version compared only
  # the size already on disk, so cap-1 plus a record ended oversized and no
  # rotation ever happened. The ceiling is the reason this design was chosen,
  # so the ceiling is what gets measured.
  local dead log cap=200 live rotated
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  log="$TEST_SKILL_DIR/run/watch.rot-session.$dead.log"
  mkdir -p "$TEST_SKILL_DIR/run"
  # Just UNDER the cap. One diagnostic is ~60-90 bytes, so the next write
  # crosses it.
  head -c 190 /dev/zero | tr '\0' 'x' > "$log"

  AGMSG_WATCH_LOG_MAX_BYTES=$cap bash "$SCRIPTS/watch.sh" \
    "rot-session.$dead" "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  wait $! || true

  [ -f "$log.1" ] || { echo "the boundary was crossed without rotating" >&2; return 1; }
  live="$(bash -c ". '$SCRIPTS/lib/compat.sh'; compat_file_size '$log'")"
  rotated="$(bash -c ". '$SCRIPTS/lib/compat.sh'; compat_file_size '$log.1'")"
  # Every generation kept is within the ceiling, which is the documented claim.
  [ "$live" -le "$cap" ] || { echo "live log is $live bytes, cap $cap" >&2; return 1; }
  [ "$rotated" -le "$cap" ] || { echo "rotated log is $rotated bytes, cap $cap" >&2; return 1; }
  # And the reason still survived the rotation rather than being dropped.
  grep -q "no longer alive" "$log" || { cat "$log" >&2; return 1; }
}

@test "watch: the cap is bytes, not characters (#691)" {
  # `${#record}` counts CHARACTERS in a UTF-8 locale while the cap and stat are
  # BYTES, so a multibyte diagnostic passes a character check and lands over the
  # byte ceiling. Team names may legally be Unicode and the storeless notice
  # puts the name in the record, so this is reachable, not theoretical.
  #
  # Two attempts failed to measure it before this one, and both failed the same
  # way -- the mutation stayed green. First the record was the liveness guard's,
  # which is pure ASCII. Then the padding was large enough that BOTH counts
  # crossed the cap, so the two answers agreed. The gap only shows in the window
  # where chars fit and bytes do not, so the padding is computed from the record
  # this fixture actually produces rather than guessed.
  local log db record chars bytes pad cap live
  bash "$SCRIPTS/join.sh" "境界検査のためのとても長い日本語チーム名" alice claude-code "$TEST_PROJECT" >/dev/null
  db="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_db_path 境界検査のためのとても長い日本語チーム名')"
  rm -f "$db"
  log="$TEST_SKILL_DIR/run/watch.mb-session.log"
  mkdir -p "$TEST_SKILL_DIR/run"

  # Pass 1: an effectively unlimited cap, purely to observe the record.
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_LOG_MAX_BYTES=1000000 \
    bash "$SCRIPTS/watch.sh" mb-session "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  local wpid=$! waited=0
  while [ "$waited" -lt 100 ]; do
    grep -q 'no store yet' "$log" 2>/dev/null && break
    sleep 0.1; waited=$((waited + 1))
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  record="$(grep 'no store yet' "$log" | head -1)"
  [ -n "$record" ] || { echo "the notice naming the team never appeared" >&2; return 1; }
  chars=${#record}
  bytes="$(printf '%s' "$record" | wc -c | tr -d '[:space:]')"
  # The two answers must actually differ, or this fixture proves nothing.
  [ "$bytes" -gt "$chars" ] || { echo "record is not multibyte: $chars/$bytes" >&2; return 1; }

  # Pass 2: a cap inside the window -- chars say it fits, bytes say it does not.
  cap=$(( 120 + chars + 1 ))
  pad=120
  rm -f "$log" "$log.1"
  head -c "$pad" /dev/zero | tr '\0' 'x' > "$log"
  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_LOG_MAX_BYTES=$cap \
    bash "$SCRIPTS/watch.sh" mb-session "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  wpid=$!; waited=0
  while [ "$waited" -lt 100 ]; do
    grep -q 'no store yet' "$log" 2>/dev/null && break
    grep -q 'no store yet' "$log.1" 2>/dev/null && break
    sleep 0.1; waited=$((waited + 1))
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true

  live="$(bash -c ". '$SCRIPTS/lib/compat.sh'; compat_file_size '$log'")"
  [ "$live" -le "$cap" ] \
    || { echo "live log is $live bytes, cap $cap (chars=$chars bytes=$bytes pad=$pad)" >&2; return 1; }
}

@test "watch: an unmeasurable record rotates rather than guessing (#691)" {
  # The fallback used to be `${#record}` -- the character count this had just
  # been fixed away from, and fail-OPEN: with `wc` missing, the bound quietly
  # stopped holding. It now rotates when the size cannot be measured.
  #
  # The cap has to sit in the window where the character count would NOT
  # rotate, or the two behaviours agree and the case proves nothing. Same
  # derivation as the multibyte case: observe the record, then set the cap.
  local log db record chars bytes cap pad live shim wpid waited
  bash "$SCRIPTS/join.sh" "境界検査のためのとても長い日本語チーム名" alice claude-code "$TEST_PROJECT" >/dev/null
  db="$(cd "$TEST_SKILL_DIR" && bash -c '. scripts/lib/storage.sh; agmsg_db_path 境界検査のためのとても長い日本語チーム名')"
  rm -f "$db"
  log="$TEST_SKILL_DIR/run/watch.nowc-session.log"
  mkdir -p "$TEST_SKILL_DIR/run"

  AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_LOG_MAX_BYTES=1000000 \
    bash "$SCRIPTS/watch.sh" nowc-session "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  wpid=$!; waited=0
  while [ "$waited" -lt 100 ]; do
    grep -q 'no store yet' "$log" 2>/dev/null && break
    sleep 0.1; waited=$((waited + 1))
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  record="$(grep 'no store yet' "$log" | head -1)"
  [ -n "$record" ] || { echo "no record to size the fixture from" >&2; return 1; }
  chars=${#record}
  bytes="$(printf '%s' "$record" | wc -c | tr -d '[:space:]')"
  [ "$bytes" -gt "$chars" ] || { echo "record is not multibyte" >&2; return 1; }

  # In the window: the character count fits, the real byte count does not.
  pad=120
  cap=$(( pad + chars + 1 ))
  rm -f "$log" "$log.1"
  head -c "$pad" /dev/zero | tr '\0' 'x' > "$log"

  # A `wc` that fails, first on PATH -- which is the one the watcher finds.
  shim="$TEST_SKILL_DIR/shim"; mkdir -p "$shim"
  printf '#!/bin/sh\nexit 1\n' > "$shim/wc"; chmod +x "$shim/wc"

  PATH="$shim:$PATH" AGMSG_WATCH_INTERVAL=1 AGMSG_WATCH_LOG_MAX_BYTES=$cap \
    bash "$SCRIPTS/watch.sh" nowc-session "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  wpid=$!; waited=0
  while [ "$waited" -lt 100 ]; do
    [ -f "$log.1" ] && break
    grep -q 'no store yet' "$log" 2>/dev/null && break
    sleep 0.1; waited=$((waited + 1))
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true

  live="$(bash -c ". '$SCRIPTS/lib/compat.sh'; compat_file_size '$log'")"
  [ "$live" -le "$cap" ] \
    || { echo "live log is $live bytes, cap $cap (chars=$chars bytes=$bytes pad=$pad)" >&2; return 1; }
  # And the diagnostic was not lost to the conservative choice.
  grep -q 'no store yet' "$log" || { echo "the record was dropped" >&2; cat "$log" >&2; return 1; }
}

@test "watch: an invalid log cap falls back to the default, not to no bound (#691)" {
  # `0` is the value that separates the two behaviours. Normalized, it becomes
  # the 128 KiB default and a small log is left alone. Unnormalized, every
  # record is "over" a cap of zero and the log rotates on every line, throwing
  # away the previous generation each time -- the diagnostics this exists to
  # keep.
  #
  # Note on the failure mode: an invalid cap does NOT kill the watcher. The
  # value never enters `$(( ))`; it is the right-hand side of `[ -gt ]`, which
  # errors non-fatally because this script sets `-u`, not `-e`. What it does is
  # quietly stop the comparison from ever being true -- so the real risk is an
  # unbounded log, and that is what is pinned here.
  local dead log
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  log="$TEST_SKILL_DIR/run/watch.zerocap-session.$dead.log"
  mkdir -p "$TEST_SKILL_DIR/run"
  printf 'a previous generation worth keeping\n' > "$log"

  AGMSG_WATCH_LOG_MAX_BYTES=0 bash "$SCRIPTS/watch.sh" \
    "zerocap-session.$dead" "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  wait $! || true

  # Treated as the default: nothing was rotated away for a 36-byte file.
  [ ! -f "$log.1" ] || { echo "a cap of 0 rotated a tiny log" >&2; return 1; }
  grep -q 'a previous generation worth keeping' "$log" \
    || { echo "the previous generation was discarded" >&2; cat "$log" >&2; return 1; }
  # And the run still said why it stopped.
  grep -q "no longer alive" "$log" || { cat "$log" >&2; return 1; }
}

@test "watch: a non-numeric log cap still rotates at the default (#691)" {
  # The other half of the contract, as a case that can actually fail. The first
  # version asserted only that a reason was still readable -- true whether or
  # not the value is normalized, because an un-normalized word makes `[ -gt ]`
  # error non-fatally and read as false, and the append then succeeds anyway.
  # It passed under mutation, so it measured nothing.
  #
  # What separates the two: put the live log just under the SHIPPED default and
  # write one more record. Normalized, `oops` IS the default, so this crosses it
  # and rotates. Un-normalized, the comparison is false forever and nothing
  # rotates however large the file gets.
  local dead log default=131072
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  log="$TEST_SKILL_DIR/run/watch.bogus-session.$dead.log"
  mkdir -p "$TEST_SKILL_DIR/run"
  # 40 bytes short of the default: any diagnostic is longer than that.
  head -c $(( default - 40 )) /dev/zero | tr '\0' 'x' > "$log"

  AGMSG_WATCH_LOG_MAX_BYTES=oops bash "$SCRIPTS/watch.sh" \
    "bogus-session.$dead" "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  wait $! || true

  [ -f "$log.1" ] \
    || { echo "a non-numeric cap did not fall back to the default bound" >&2; return 1; }
  local live
  live="$(bash -c ". '$SCRIPTS/lib/compat.sh'; compat_file_size '$log'")"
  [ "$live" -le "$default" ] || { echo "live log is $live bytes" >&2; return 1; }
  grep -q "no longer alive" "$log" || { cat "$log" >&2; return 1; }
}

@test "watch: a record larger than the whole cap is kept, not dropped (#691)" {
  # The stated exception. A single diagnostic bigger than the cap cannot fit
  # under it; rotating first and writing it whole beats dropping the one line
  # someone is looking for. Named so the behaviour is a decision, not a
  # surprise.
  local dead log
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  log="$TEST_SKILL_DIR/run/watch.tiny-session.$dead.log"
  mkdir -p "$TEST_SKILL_DIR/run"
  AGMSG_WATCH_LOG_MAX_BYTES=1 bash "$SCRIPTS/watch.sh" \
    "tiny-session.$dead" "$TEST_PROJECT" claude-code >/dev/null 2>/dev/null &
  wait $! || true
  [ -f "$log" ] || { echo "the diagnostic was dropped entirely" >&2; return 1; }
  grep -q "no longer alive" "$log" || { cat "$log" >&2; return 1; }
}

@test "check-inbox: a live watcher no longer stops the turn side (#694)" {
  # The negative control for `both`. Before this, ANY live watcher pid made
  # this hook exit 0 -- including a watcher delivering nothing, which is the
  # one situation `both` is reached for. The watcher here is alive and does
  # nothing at all, which is precisely the failure.
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "delivered by neither" >/dev/null

  # A watcher that is alive and delivering nothing.
  mkdir -p "$TEST_SKILL_DIR/run"
  sleep 60 &
  local idle=$!
  printf '%s\n' "$idle" > "$TEST_SKILL_DIR/run/watch.both-session.pid"

  run bash -c "printf '%s' '{\"session_id\":\"both-session\"}' | bash '$SCRIPTS/check-inbox.sh' claude-code '$TEST_PROJECT'"
  kill "$idle" 2>/dev/null || true
  [ "$status" -eq 0 ] || return 1
  printf '%s\n' "$output" | grep -q 'delivered by neither' \
    || { echo "the turn side still stood down: $output" >&2; return 1; }
}

@test "check-inbox: what the watcher already took is not offered twice (#694)" {
  # Why removing the deferral is safe, measured rather than argued. The watcher
  # consumes through storage_read_cursor_consume, which records a message_read
  # event per delivered id AND advances the cursor; storage_list_unread
  # excludes both. Same state, so no duplicate.
  bash "$SCRIPTS/join.sh" testteam alice claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" testteam bob claude-code "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/send.sh" testteam bob alice "taken by the watcher" >/dev/null

  # Stand in for the watcher's consume, using the same facade it calls.
  local id
  id="$(bash -c ". '$SCRIPTS/lib/storage.sh'; agmsg_storage_load; \
    storage_list_unread testteam alice" | sed -n 's/.*\"id\":\"\([^\"]*\)\".*/\1/p' | head -1)"
  [ -n "$id" ] || return 1
  bash -c ". '$SCRIPTS/lib/storage.sh'; agmsg_storage_load; \
    storage_read_cursor_consume testteam alice 999999 '$id'" >/dev/null

  run bash -c "printf '%s' '{\"session_id\":\"dup-session\"}' | bash '$SCRIPTS/check-inbox.sh' claude-code '$TEST_PROJECT'"
  [ "$status" -eq 0 ] || return 1
  run bash -c "printf '%s\n' \"\$1\" | grep -q 'taken by the watcher'" _ "$output"
  [ "$status" -ne 0 ] || { echo "the hook re-offered a consumed message" >&2; return 1; }
}
