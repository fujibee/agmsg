#!/usr/bin/env bats

# Tests for the per-process instance id (#93): parallel claude --continue /
# --resume processes share a session_id, so watcher/lock state keyed on the
# bare session_id collides. instance-id.sh disambiguates with the enclosing
# agent pid. These cover the helper functions and the actas-lock distinctness
# the fix turns on.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/resolve-project.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/instance-id.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
}

teardown() { teardown_test_env; }

# --- agmsg_instance_id_from_pid ---

@test "instance_id_from_pid: numeric pid yields composite" {
  [ "$(agmsg_instance_id_from_pid sess 1234)" = "sess.1234" ]
}

@test "instance_id_from_pid: empty pid yields bare sid" {
  [ "$(agmsg_instance_id_from_pid sess "")" = "sess" ]
}

@test "instance_id_from_pid: non-numeric pid yields bare sid" {
  [ "$(agmsg_instance_id_from_pid sess abc)" = "sess" ]
}

# --- agmsg_instance_is_composite ---

@test "is_composite: true for <sid>.<numeric>" {
  agmsg_instance_is_composite "sess.1234"
}

@test "is_composite: true for a UUID-shaped sid with numeric suffix" {
  agmsg_instance_is_composite "11111111-2222-3333-4444-555555555555.987"
}

@test "is_composite: false for a bare sid" {
  ! agmsg_instance_is_composite "sess"
}

@test "is_composite: false for empty suffix" {
  ! agmsg_instance_is_composite "sess."
}

@test "is_composite: false for empty prefix" {
  ! agmsg_instance_is_composite ".1234"
}

@test "is_composite: false for non-numeric suffix" {
  ! agmsg_instance_is_composite "sess.12a"
}

# --- agmsg_instance_bare_sid ---

@test "bare_sid: strips the pid from a composite token" {
  [ "$(agmsg_instance_bare_sid "sess.1234")" = "sess" ]
}

@test "bare_sid: UUID-shaped composite yields the bare UUID" {
  [ "$(agmsg_instance_bare_sid "11111111-2222-3333-4444-555555555555.987")" = "11111111-2222-3333-4444-555555555555" ]
}

@test "bare_sid: a bare sid passes through unchanged" {
  [ "$(agmsg_instance_bare_sid "sess")" = "sess" ]
}

@test "bare_sid: a non-composite token with a dot but non-numeric suffix is unchanged" {
  # "sess.12a" is NOT composite (suffix not all-digits), so it is a bare sid.
  [ "$(agmsg_instance_bare_sid "sess.12a")" = "sess.12a" ]
}

# --- agmsg_instance_alive ---

@test "instance_alive: composite with a live pid is alive" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  agmsg_instance_alive "sess.$$"
}

@test "instance_alive: composite with a dead pid is not alive" {
  ! agmsg_instance_alive "sess.2147483647"
}

@test "instance_alive: composite is not alive when cc-instance.<pid> now names a different token (#349)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  # Simulates a shared pid (Claude Code 2.1.x daemon) whose cc-instance record
  # was overwritten by a newer session attaching to the same pid — the pid is
  # still alive, but this token is no longer the one it currently names.
  echo "newsess.$$" > "$RUN_DIR/cc-instance.$$"
  ! agmsg_instance_alive "oldsess.$$"
}

@test "instance_alive: composite is alive when cc-instance.<pid> still names this exact token (#349)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  echo "sess.$$" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "sess.$$"
}

@test "instance_alive: bare sid with a live cc-instance is alive" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  echo "barex" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "barex"
}

@test "instance_alive: bare sid is alive when cc-instance was upgraded to composite (compat)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  # A pre-upgrade lock holds a bare sid while cc-instance already stores the
  # composite "<sid>.<pid>" — must not be stale'd out.
  echo "barey.$$" > "$RUN_DIR/cc-instance.$$"
  agmsg_instance_alive "barey"
}

@test "instance_alive: bare sid with no cc-instance is not alive" {
  ! agmsg_instance_alive "ghost"
}

@test "instance_alive: empty token is not alive" {
  ! agmsg_instance_alive ""
}

# --- _agmsg_pid_alive: EPERM vs ESRCH (Claude Code sandbox) ---
#
# Under the sandbox `kill -0` on a live pid returns EPERM, not ESRCH. Only ESRCH
# is dead; EPERM must read as alive or the watcher self-exits. `kill` is stubbed
# to script each errno string (real EPERM is hard to force).

@test "pid_alive: a real live pid (self) is alive" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  _agmsg_pid_alive $$
}

@test "pid_alive: a real dead pid is not alive (ESRCH end-to-end)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  ! _agmsg_pid_alive 2147483647
}

@test "pid_alive: a signalable pid (kill -0 exit 0) is alive" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  kill() { return 0; }
  _agmsg_pid_alive 12345
}

# A pid that is genuinely gone, so the real ps agrees with the stubbed kill.
# Stubbing kill alone stopped being enough once "dead" required ps to agree:
# a made-up number like 999 IS a running process on some hosts, which is
# exactly the case the cross-check exists to catch.
gone_pid() {
  local pid
  pid="$(bash -c 'echo $$')"
  wait_for_pid_exit "$pid" || true
  echo "$pid"
}

@test "pid_alive: ESRCH 'No such process' reads as dead" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  local gone; gone="$(gone_pid)"
  kill() { echo "bash: kill: ($gone) - No such process" >&2; return 1; }
  ! _agmsg_pid_alive "$gone"
}

@test "pid_alive: lowercase 'no such process' (zsh wording) also reads as dead" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  local gone; gone="$(gone_pid)"
  kill() { echo "kill: ($gone) - no such process" >&2; return 1; }
  ! _agmsg_pid_alive "$gone"
}

@test "pid_alive: ESRCH is not enough while ps still shows the process" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  # kill(2) and ps must agree before a pid is called dead. ps does not depend on
  # signalling permission at all, so it is what stops "cannot signal" from
  # becoming "not running" — and calling a live pid dead is how a running
  # owner's lock gets reclaimed out from under it.
  kill() { echo "bash: kill: ($$) - No such process" >&2; return 1; }
  _agmsg_pid_alive $$
}

@test "pid_alive: EPERM 'Operation not permitted' reads as alive (sandbox)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  kill() { echo "bash: kill: (1) - Operation not permitted" >&2; return 1; }
  _agmsg_pid_alive 1
}

@test "pid_alive: an unrecognized kill failure defaults to alive (fail-safe)" {
  skip_on_windows "POSIX kill path; Windows uses tasklist (#134)"
  kill() { echo "kill: some novel platform error" >&2; return 1; }
  _agmsg_pid_alive 42
}

# --- agmsg_normalize_instance_id ---

@test "normalize: a composite token passes through unchanged (idempotent)" {
  [ "$(agmsg_normalize_instance_id "sess.4242" claude-code 2>/dev/null)" = "sess.4242" ]
}

@test "normalize: a bare sid derives the composite from the agent pid" {
  # Stub the resolver so the derivation is deterministic without a real agent
  # ancestor (bats has none).
  agmsg_agent_pid() { echo 4242; }
  [ "$(agmsg_normalize_instance_id "sess" claude-code)" = "sess.4242" ]
}

@test "normalize: falls back to the bare sid when the agent pid is unresolved" {
  agmsg_agent_pid() { return 1; }
  # Capture stdout only — the fallback also writes a warning to stderr.
  local got
  got="$(agmsg_normalize_instance_id "sess" claude-code 2>/dev/null)"
  [ "$got" = "sess" ]
}

@test "normalize: warns on stderr when falling back" {
  agmsg_agent_pid() { return 1; }
  run bash -c '
    source "'"$SKILL_DIR"'/scripts/lib/resolve-project.sh"
    source "'"$SKILL_DIR"'/scripts/lib/instance-id.sh"
    agmsg_agent_pid() { return 1; }
    agmsg_normalize_instance_id sess claude-code 2>&1 1>/dev/null
  '
  [[ "$output" == *"falling back to bare session_id"* ]]
}

# --- AGMSG_AGENT_PID override ---

@test "override: a numeric AGMSG_AGENT_PID pins the resolved pid" {
  AGMSG_AGENT_PID=4242 run agmsg_agent_pid claude-code
  [ "$status" -eq 0 ]
  [ "$output" = "4242" ]
  [ "$(AGMSG_AGENT_PID=4242 agmsg_instance_id sess claude-code)" = "sess.4242" ]
}

@test "override: an empty AGMSG_AGENT_PID forces the bare fallback" {
  AGMSG_AGENT_PID="" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(AGMSG_AGENT_PID="" agmsg_instance_id sess claude-code 2>/dev/null)" = "sess" ]
}

@test "override: a non-numeric AGMSG_AGENT_PID is ignored with a warning" {
  AGMSG_AGENT_PID="abc" run agmsg_agent_pid claude-code
  [ "$status" -ne 0 ]
  [[ "$output" == *"ignoring non-numeric AGMSG_AGENT_PID"* ]]
}

# --- actas distinctness: the #93 payoff ---

# Two instance ids that share a session_id prefix but differ in pid must be
# treated as distinct owners — the collision that broke the actas lock is gone.
@test "actas: same session_id, different pid -> distinct live owners (#93)" {
  skip_on_windows "instance-id live PID liveness under Git Bash (#182)"
  sleep 60 3>&- & local pa=$!
  sleep 60 3>&- & local pb=$!
  local ta="sess.$pa" tb="sess.$pb"

  # pa claims; pb is refused because pa is a live, distinct owner.
  run actas_lock_claim team alice "$ta"
  [ "$status" -eq 0 ]
  run actas_lock_claim team alice "$tb"
  [ "$status" -eq 1 ]
  [ "$output" = "held:$ta" ]

  # State classification agrees from both sides.
  [ "$(actas_lock_state team alice "$ta")" = "mine" ]
  [ "$(actas_lock_state team alice "$tb")" = "other:$ta" ]

  # When the owner pid dies, the lock is reclaimable (stale → free).
  kill "$pa" 2>/dev/null || true
  wait "$pa" 2>/dev/null || true
  [ "$(actas_lock_state team alice "$tb")" = "free" ]

  kill "$pb" 2>/dev/null || true
  wait "$pb" 2>/dev/null || true
}

# --- grok-build session binding (#245) ---
#
# A grok-build watcher launched by Grok's `monitor` tool gets an empty session id.
# Keying on a bare throwaway id means no liveness gating, so the watcher lingers
# forever after grok exits (the pid-91475-alive-3h orphan). These cover the
# resolution that binds the watcher to a composite "<grok-session>.<grok-pid>"
# (liveness-gated) for both the `--resume` and the fresh (no-resume) launch.

@test "grok_newest_session_id: returns the newest UUID-form session dir (#245)" {
  local sd="$HOME/.grok/sessions/proj"
  mkdir -p "$sd/aaaa1111-1111-1111-1111-111111111111"
  mkdir -p "$sd/bbbb2222-2222-2222-2222-222222222222"
  mkdir -p "$sd/not-a-session"        # non-UUID dir must be ignored
  touch -t 202601010000 "$sd/aaaa1111-1111-1111-1111-111111111111"
  touch -t 202612310000 "$sd/bbbb2222-2222-2222-2222-222222222222"
  run agmsg_grok_newest_session_id "$sd"
  [ "$status" -eq 0 ]
  [ "$output" = "bbbb2222-2222-2222-2222-222222222222" ]
}

@test "grok_newest_session_id: fails on a dir with no UUID session (#245)" {
  local sd="$HOME/.grok/sessions/empty"
  mkdir -p "$sd/scratch"
  run agmsg_grok_newest_session_id "$sd"
  [ "$status" -ne 0 ]
}

@test "grok_instance_id: prefers the watcher's ancestor grok over other live groks (#245)" {
  # Two live `grok --resume` sessions share this project; the watcher must bind
  # to ITS ancestor grok (2222 / gidB), not whichever pgrep lists first.
  local proj="/tmp/agmsg-grok-multi"
  local enc; enc=$(printf '%s' "$proj" | sed 's#/#%2F#g')
  local gidA="019faaaa-1111-1111-1111-111111111111"
  local gidB="019fbbbb-2222-2222-2222-222222222222"
  mkdir -p "$HOME/.grok/sessions/$enc/$gidA" "$HOME/.grok/sessions/$enc/$gidB"
  pgrep() { printf '1111\n2222\n'; }
  ps() { case "$*" in *1111*) echo "grok --resume $gidA" ;; *2222*) echo "grok --resume $gidB" ;; esac; }
  agmsg_grok_ancestor_pid() { echo 2222; }
  run agmsg_grok_instance_id "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "$gidB.2222" ]
}

@test "grok_instance_id: a live grok --resume yields composite <id>.<pid> via fallback (#245)" {
  # Ancestor unresolvable (detached watcher) -> the pgrep fallback finds the live
  # `grok --resume` for this project. Distinct var name from the function's own
  # local `gid`, which would otherwise shadow it (dynamic scope) in the ps stub.
  local proj="/tmp/agmsg-grok-resume"
  local enc; enc=$(printf '%s' "$proj" | sed 's#/#%2F#g')
  local gidval="019f0a8a-e25f-7f52-ac5c-543643b1755a"
  mkdir -p "$HOME/.grok/sessions/$enc/$gidval"
  agmsg_grok_ancestor_pid() { return 1; }
  pgrep() { echo 4242; }
  ps() { case "$*" in *4242*) echo "grok --resume $gidval" ;; esac; }
  run agmsg_grok_instance_id "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "$gidval.4242" ]
  agmsg_instance_is_composite "$output"
}

@test "grok_instance_id: a fresh grok (no --resume) binds via ancestor + newest session (#245)" {
  local proj="/tmp/agmsg-grok-fresh"
  local enc; enc=$(printf '%s' "$proj" | sed 's#/#%2F#g')
  local gid="019fabcd-1111-2222-3333-444455556666"
  mkdir -p "$HOME/.grok/sessions/$enc/$gid"
  # No `grok --resume` process; the fresh grok is found as the watcher's ancestor.
  pgrep() { return 0; }
  ps() { return 0; }
  agmsg_grok_ancestor_pid() { echo 7777; }
  run agmsg_grok_instance_id "$proj"
  [ "$status" -eq 0 ]
  [ "$output" = "$gid.7777" ]
  agmsg_instance_is_composite "$output"
}

@test "grok_instance_id: fails (caller falls back) when no live grok exists (#245)" {
  local proj="/tmp/agmsg-grok-none"
  local enc; enc=$(printf '%s' "$proj" | sed 's#/#%2F#g')
  mkdir -p "$HOME/.grok/sessions/$enc/019f0049-95e5-7e70-af04-450a9c487da1"
  pgrep() { return 0; }
  ps() { return 0; }
  agmsg_grok_ancestor_pid() { return 1; }   # watcher not under any grok
  run agmsg_grok_instance_id "$proj"
  [ "$status" -ne 0 ]
}

@test "grok_ancestor_pid: fails when no grok is in the ancestry (#245)" {
  # The bats process tree has no grok ancestor (except if the suite itself is run
  # under a grok session, which CI never is).
  run agmsg_grok_ancestor_pid $$
  [ "$status" -ne 0 ]
}

@test "args_is_grok_watcher: matches a real watcher invocation (#245)" {
  local proj="/Users/x/projects/notes-app"
  agmsg_args_is_grok_watcher "bash /skills/agmsg/scripts/watch.sh sess.1 $proj grok-build" "$proj"
}

@test "args_is_grok_watcher: matches an empty-sid watcher (double space) (#245)" {
  local proj="/Users/x/projects/notes-app"
  agmsg_args_is_grok_watcher "bash /skills/agmsg/scripts/watch.sh  $proj grok-build" "$proj"
}

@test "args_is_grok_watcher: excludes a shell that merely mentions the strings (#245)" {
  # A process running `grep watch.sh ... grok-build` would be wrongly killed by a
  # loose substring match. watch.sh is not the executed program here.
  local proj="/Users/x/projects/notes-app"
  run agmsg_args_is_grok_watcher "/bin/zsh -c grep watch.sh foo grok-build $proj" "$proj"
  [ "$status" -ne 0 ]
}

@test "args_is_grok_watcher: excludes a watcher for a different project (#245)" {
  run agmsg_args_is_grok_watcher "bash /s/watch.sh sess.1 /other/proj grok-build" "/Users/x/notes-app"
  [ "$status" -ne 0 ]
}

@test "args_is_grok_watcher: set -u safe on empty / short args (#245)" {
  # watch.sh runs under set -u; ps lists kernel procs with empty args, so the
  # matcher must not trip nounset on unset positional params.
  run bash -u -c "source '$SCRIPTS/lib/instance-id.sh'
    agmsg_args_is_grok_watcher '' '/p' && echo unexpected1
    agmsg_args_is_grok_watcher 'bash' '/p' && echo unexpected2
    echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "reap_orphan_grok_watchers: survives set -u scanning the real ps table (#245)" {
  # Regression for a startup crash: under set -u the reaper scanned ps output
  # that includes empty-args processes and tripped nounset, killing the watcher
  # before it armed. It must complete and leave the caller alive.
  run bash -u -c "SKILL_DIR='$SKILL_DIR'
    source '$SCRIPTS/lib/instance-id.sh'
    agmsg_reap_orphan_grok_watchers '/tmp/agmsg-no-such-project-xyz' \$\$
    echo OK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

@test "reap_orphan_grok_watchers: no-op and self-safe when nothing matches (#245)" {
  # No grok-build watcher for this throwaway project exists; the reaper must not
  # error and must never touch the caller (a pattern kill once wiped live ones).
  run agmsg_reap_orphan_grok_watchers "/tmp/agmsg-no-such-project-xyz" $$
  [ "$status" -eq 0 ]
  kill -0 $$
}

# --- liveness: "can I signal this" is not "is this running" ---

# A pid that exists but this user cannot signal, so `kill -0` fails with EPERM
# rather than ESRCH. pid 1 is that on any normal desktop or CI runner; when the
# suite runs as root, or in a container where pid 1 is ours, there is no such
# pid to borrow and the distinction under test cannot be staged.
require_eperm_pid() {
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
}

@test "instance-id: an unsignalable pid is alive, not dead" {
  require_eperm_pid
  run _agmsg_pid_alive 1
  [ "$status" -eq 0 ]
}

@test "instance-id: liveness rejects a dead pid, and anything that is not a pid" {
  local dead
  dead="$(bash -c 'echo $$')"
  wait_for_pid_exit "$dead" || true
  run _agmsg_pid_alive "$dead"; [ "$status" -ne 0 ]
  run _agmsg_pid_alive "";     [ "$status" -ne 0 ]
  run _agmsg_pid_alive "abc";  [ "$status" -ne 0 ]
  run _agmsg_pid_alive "12x";  [ "$status" -ne 0 ]
  run _agmsg_pid_alive $$;     [ "$status" -eq 0 ]
}

@test "instance-id: 0 is not a live pid, it is this process group" {
  # `kill -0 0` SUCCEEDS: 0 addresses the caller's own process group, not pid 0.
  # A digits-only check therefore called 0 alive, and callers kill whatever this
  # reports alive — `kill 0` TERMs the group, the caller included. All it takes
  # is a pidfile holding 0.
  run kill -0 0; [ "$status" -eq 0 ]
  local bad
  for bad in 0 00 000 0123; do
    run _agmsg_pid_alive "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_alive $bad reported alive"; false; }
    run _agmsg_pid_valid "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_valid $bad accepted it"; false; }
  done
  run _agmsg_pid_valid $$;   [ "$status" -eq 0 ]
  run _agmsg_pid_valid "";   [ "$status" -ne 0 ]
  run _agmsg_pid_valid "1x"; [ "$status" -ne 0 ]
}

@test "instance-id: a pid too large for pid_t is dead, not alive forever" {
  # Past INT32_MAX kill(1) rejects the ARGUMENT instead of reporting ESRCH, and
  # everything that is not ESRCH is read as EPERM, i.e. alive. Unbounded, an
  # oversized value in a pidfile reads as alive forever: its lock is never
  # reclaimed and its bridge is never restarted.
  local err
  err="$(export LC_ALL=C; kill -0 2147483648 2>&1)" || true
  case "$err" in
    *[Nn]'o such process'*) skip "kill treats out-of-range pids as ESRCH here" ;;
  esac
  local bad
  for bad in 2147483648 4294967296 999999999999999999999; do
    run _agmsg_pid_valid "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_valid $bad accepted it"; false; }
    run _agmsg_pid_alive "$bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_alive $bad reported alive"; false; }
  done
  # The boundary itself is a legal pid value and must still be accepted.
  run _agmsg_pid_valid 2147483647; [ "$status" -eq 0 ]
  run _agmsg_pid_valid 9999999;    [ "$status" -eq 0 ]
}

@test "instance-id: the pid ceiling is the platform's, not one number" {
  # A Windows process id is a DWORD, and liveness there reads the native process
  # table through tasklist rather than kill(1)'s signed pid_t. Applying the
  # POSIX ceiling to it would call a legitimate native pid dead and its live
  # watcher stale. Only the bound depends on MSYSTEM, so both sides are
  # checkable from either host.
  run env MSYSTEM=MINGW64 bash -c \
    'SKILL_DIR="'"$SKILL_DIR"'"; . "$SKILL_DIR/scripts/lib/instance-id.sh"
     _agmsg_pid_valid 2147483648 || exit 1
     _agmsg_pid_valid 4294967295 || exit 2
     _agmsg_pid_valid 4294967296 && exit 3
     _agmsg_pid_valid 0 && exit 4
     exit 0'
  [ "$status" -eq 0 ]

  # POSIX keeps the signed pid_t ceiling.
  run _agmsg_pid_valid 2147483648; [ "$status" -ne 0 ]
  run _agmsg_pid_valid 4294967295; [ "$status" -ne 0 ]
}

@test "instance-id: liveness answers alive on the builtin, before any subshell" {
  # The launcher polls liveness in loops that were deliberately made fork-free
  # (#466/#496). Routing them through a helper is only acceptable while the
  # common answer — alive — is still decided by the builtin, so the cheap check
  # has to come first and has to be able to return on its own.
  local body fast slow
  # The fast path lives in the _local helper now; _agmsg_pid_alive delegates to
  # it once the Windows branch declines. A function call is not a fork, so the
  # property this test exists for is unchanged -- but it has to be read where
  # the code is.
  body="$(declare -f _agmsg_pid_alive_local)"
  fast="$(printf '%s\n' "$body" | grep -n 'kill -0 .*&& return 0;$' | grep -v '\$(' | head -1 | cut -d: -f1)"
  slow="$(printf '%s\n' "$body" | grep -n 'kill -0 .*2>&1' | head -1 | cut -d: -f1)"
  [ -n "$fast" ]
  [ -n "$slow" ]
  [ "$fast" -lt "$slow" ]
  # And the delegation is a plain call, not a subshell, so the fork-free claim
  # survives the split.
  printf '%s\n' "$(declare -f _agmsg_pid_alive)" | grep -q '^ *_agmsg_pid_alive_local "\$pid"$'
}

# --- which pid space (#567) ---

@test "pid_alive_local: a pid we minted is alive even where tasklist cannot see it" {
  skip_on_windows "stubs tasklist; the real one is authoritative on Windows"
  # MSYSTEM steers _agmsg_pid_alive into its tasklist branch. tasklist reports
  # Windows pids, and a pid from $! or $$ in one of these shells is numbered in
  # the MSYS space, so it is absent -- which the plain helper reads as dead.
  # _local is the one that must not ask.
  local stub="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stub/tasklist"
  chmod +x "$stub/tasklist"

  MSYSTEM=MINGW64 PATH="$stub:$PATH" _agmsg_pid_alive_local $$
  # The counterpart, pinned so the split is not a distinction without a
  # difference: the same live pid reads as dead through the plain helper.
  ! MSYSTEM=MINGW64 PATH="$stub:$PATH" _agmsg_pid_alive $$
}

@test "pid_alive_local: an oversized pid is dead on Windows too" {
  skip_on_windows "POSIX kill path; the ceiling is what is under test"
  # The validator widens to the DWORD range when MSYSTEM is set, because a
  # Windows pid is a DWORD and tasklist is only asked to match a number. But
  # _local hands the value to kill(1) even there, and past INT32_MAX kill
  # rejects the argument rather than reporting ESRCH -- which reads as alive.
  # Inheriting the wide ceiling would make an oversized pidfile value alive
  # forever: lock never reclaimed, bridge never restarted (#505).
  local err
  err="$(export LC_ALL=C; kill -0 2147483648 2>&1)" || true
  case "$err" in
    *[Nn]'o such process'*) skip "kill treats out-of-range pids as ESRCH here" ;;
  esac
  local bad
  for bad in 2147483648 4294967295; do
    run env MSYSTEM=MINGW64 bash -c \
      ". '$SCRIPTS/lib/instance-id.sh'; _agmsg_pid_alive_local $bad"
    [ "$status" -ne 0 ] || { echo "_agmsg_pid_alive_local $bad reported alive"; false; }
  done
  # The platform ceiling itself is untouched: the same value is still a legal
  # thing to ask tasklist about.
  run env MSYSTEM=MINGW64 bash -c \
    ". '$SCRIPTS/lib/instance-id.sh'; _agmsg_pid_valid 4294967295"
  [ "$status" -eq 0 ]
}

@test "pid_alive_local: EPERM still reads as alive (sandbox)" {
  skip_on_windows "POSIX kill path"
  # The reason the fix is not a bare `kill -0`: a pid we minted is still a pid a
  # sandbox may refuse to let us signal, and #505 is what made that not mean dead.
  kill() { echo "bash: kill: (1) - Operation not permitted" >&2; return 1; }
  _agmsg_pid_alive_local 1
}

@test "no shipped script decides liveness with a bare kill -0" {
  # #500's lesson: a partially-hardened file reads as a fixed one. Every
  # liveness check must go through _agmsg_pid_alive, which is EPERM-aware and
  # cross-checks ps; instance-id.sh is where that check is implemented, so it
  # is the one file allowed to call kill -0 directly.
  local offenders
  offenders="$(cd "$BATS_TEST_DIRNAME/.." && grep -rn -e 'kill -0' -e 'kill -s 0' scripts bin 2>/dev/null \
    | grep -v '^scripts/lib/instance-id.sh:' \
    | grep -v ':[0-9]*: *#' || true)"
  [ -z "$offenders" ] || { echo "$offenders"; false; }
}
