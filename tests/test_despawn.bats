#!/usr/bin/env bats

# Tests for despawn (#109): a leader tears down a spawned member. Graceful path
# is watcher-driven (watch.sh sees ctrl:despawn, drops its own role); --force is
# leader-driven from the recorded placement.

load test_helper

setup() {
  setup_test_env
  # Never inherit a real herdr environment from the test runner. A watcher
  # started here that keeps the host's HERDR_PANE_ID will, on ctrl:despawn,
  # close the developer's own pane — the suite kills the session running it.
  # This belongs in setup, not on individual watch.sh launches: guarding each
  # launch site means every test added later has to remember, and one that
  # did not (the #439 read_at test, added after this file first grew herdr
  # awareness) is exactly how a real host pane got closed.
  unset HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID
  export PROJ="/tmp/agmsg-despawn-proj"
  export RUN="$TEST_SKILL_DIR/run"
  mkdir -p "$RUN"
}

teardown() {
  teardown_test_env
}

@test "despawn: graceful — ctrl:despawn makes the member drop its role" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  # Make the member session look alive so the leader sees a live lock to wait on.
  setup_live_owner "$RUN" sess-m

  # Unset TMUX_PANE and HERDR_PANE_ID: the ctrl:despawn handler runs
  # `tmux kill-pane` / `herdr pane close`, and a watcher launched from inside
  # the developer's environment would inherit the REAL pane id and close the
  # session running the tests. With both empty, the handler takes the "close
  # manually" branch — role-drop is still asserted.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$! i
  # Wait for the watcher to attach (it claims the lock + writes the ready sentinel).
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$RUN/ready.team__alice" ] && break; sleep 0.5; done
  [ -e "$RUN/ready.team__alice" ]
  [ -f "$RUN/actas.team__alice.session" ]

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=ok"* ]]

  # Member dropped its role: lock released and registration gone.
  [ ! -f "$RUN/actas.team__alice.session" ]
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

# The current driver owns read state; a consumed control row must not appear in
# the recipient's unread view, regardless of whether the backend has legacy
# `messages.read_at` storage.
_is_unread_for_alice() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    storage_list_unread team alice | grep -Fq "$1" )
}

_control_row_exists_for_alice() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    storage_history team alice | grep -F '"to":"alice"' | grep -Fq '"body":"ctrl:despawn"' )
}

@test "despawn: graceful — ctrl:despawn control row is marked read (does not linger as unread)" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m

  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local wpid=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$RUN/ready.team__alice" ] && break; sleep 0.5; done
  [ -e "$RUN/ready.team__alice" ]

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 10
  [ "$status" -eq 0 ]

  # The ctrl:despawn row itself must not be left permanently unread — a
  # broad (non-actas) watcher that later scans this project's inbox must not
  # see it resurface as a "new" message (2026-07-19 review finding).
  _control_row_exists_for_alice
  # `refute`, not a bare `!` (#715). `! cmd` is exempt from errexit on every bash,
  # so `! _is_unread_for_alice ...` reported ok even when the row WAS unread — the
  # assertion was written but watched nothing (#670). `refute` makes it fail when
  # the row lingers unread. The separate, load-dependent flake this then exposes
  # (the row not yet read right after despawn returns, under load) is NOT fixed
  # here; it stays open as #715.
  refute _is_unread_for_alice "ctrl:despawn"

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

# A tmux stub whose kill-pane / kill-window exits with a chosen code, so a --force
# teardown can be made to CONFIRM (0) or FAIL (non-zero).
_stub_tmux_exit() {
  local code="${1:-0}" bin="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$bin"
  printf '#!/usr/bin/env bash\ncase "$1" in kill-pane|kill-window) exit %s ;; esac\nexit 0\n' "$code" > "$bin/tmux"
  chmod +x "$bin/tmux"; export PATH="$bin:$PATH"
}

@test "despawn --force: kills recorded placement and drops registration without the member" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' '%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"
  _stub_tmux_exit 0                                 # kill-pane confirms the teardown

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__alice" ]                 # placement record cleaned
  [ ! -f "$RUN/actas.team__alice.session" ]         # lock released
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" != *alice* ]]                        # registration dropped
}

@test "despawn --force: an UNCONFIRMED teardown keeps the record and reports error (#625, --force side)" {
  # If the terminal driver does not confirm the pane closed (here: kill-pane exits
  # non-zero), the pane may still be alive. --force must NOT delete the record (the
  # only retry authority) or claim status=forced.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' 'tmux:%99' "$PROJ" claude-code > "$RUN/spawn.team__alice"
  _stub_tmux_exit 1                                 # kill-pane FAILS -> not confirmed

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -ne 0 ]
  grep -q "status=error" <<<"$output"
  grep -q "force-teardown-unconfirmed" <<<"$output"
  [ -f "$RUN/spawn.team__alice" ]                   # record KEPT for a retry
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" == *alice* ]]                        # registration NOT dropped
}

@test "despawn --force: a CORRUPT placement ref does not tear down and keeps the record" {
  # A corrupt ref resolves to no terminal (agmsg_terminal_ref_terminal fails closed),
  # so there is nothing to confirm — treat it as an unconfirmed teardown, keep the
  # record, and never hand the corrupt value to a terminal as a target.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' 'garbage-ref' "$PROJ" claude-code > "$RUN/spawn.team__alice"

  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -ne 0 ]
  grep -q "status=error" <<<"$output"
  [ -f "$RUN/spawn.team__alice" ]                   # record KEPT
}

@test "despawn --force: errors when there is no placement record" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -ne 0 ]
  [[ "$output" =~ "no placement record" ]]
}

@test "despawn: times out (exit 3) when the member never drops" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m
  printf 'sess-m\n' > "$RUN/actas.team__alice.session"   # held live, no watcher to act

  run bash "$SCRIPTS/despawn.sh" team leader alice --timeout 2
  [ "$status" -eq 3 ]
  [[ "$output" == *"status=timeout"* ]]
}

@test "despawn: a broad (non-actas) watcher ignores ctrl:despawn and does not self-destruct" {
  # Regression for the self-kill bug: a leader's default watcher subscribes to
  # EVERY project role. If it acted on a ctrl:despawn addressed to one of them,
  # it would run `tmux kill-pane -t $TMUX_PANE` against the leader's OWN pane and
  # take down the leader session. A broad watcher must skip the control message.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team boss claude-code "$PROJ" >/dev/null

  # Broad watcher (no actas arg) — subscribes to both alice and leader.
  AGMSG_WATCH_INTERVAL=1 env -u TMUX_PANE -u HERDR_PANE_ID -u HERDR_ENV \
    bash "$SCRIPTS/watch.sh" sess-broad "$PROJ" claude-code \
    >/dev/null 2>&1 3>&- &
  local wpid=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$wpid" 2>/dev/null && break; sleep 0.5; done

  # Deliver a despawn aimed at alice straight into the stream.
  bash "$SCRIPTS/send.sh" team boss alice "ctrl:despawn" >/dev/null
  sleep 2

  kill -0 "$wpid" 2>/dev/null            # watcher still alive — did NOT self-destruct
  run bash "$SCRIPTS/identities.sh" "$PROJ" claude-code
  [[ "$output" == *alice* ]]             # broad watcher did not drop alice's role

  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
}

@test "despawn: graceful no-op when the member holds no live lock (e.g. codex)" {
  bash "$SCRIPTS/join.sh" team alice codex "$PROJ" >/dev/null
  run bash "$SCRIPTS/despawn.sh" team leader alice
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-live-lock"* ]]
}

@test "despawn: a free lock WITH a placement record does not report ok or delete the record (#625)" {
  # A monitor=no member (cursor) never holds an actas lock, so the graceful path
  # lands in `free` on every despawn. The old code read that as "gone", deleted the
  # placement record and reported status=ok — while the pane/process were still
  # there, and the deletion made the --force it advises impossible. A free lock WITH
  # a record must NOT report ok and must NOT delete the record.
  bash "$SCRIPTS/join.sh" team alice cursor "$PROJ" >/dev/null
  printf '%s\t%s\t%s\n' 'tmux:%99' "$PROJ" cursor > "$RUN/spawn.team__alice"
  run bash "$SCRIPTS/despawn.sh" team leader alice
  [ "$status" -ne 0 ]
  grep -q "needs-force" <<<"$output"
  refute grep -q "status=ok" <<<"$output"
  [ -f "$RUN/spawn.team__alice" ]              # record KEPT so --force can use it
  # ...and --force then works against the preserved record (teardown confirmed).
  _stub_tmux_exit 0
  run bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  grep -q "status=forced" <<<"$output"
}

@test "despawn --force: kills a herdr: placement via herdr pane close" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  # Record a herdr-tagged placement (herdr: scheme prefix).
  printf 'herdr:wC:p99\t%s\tclaude-code\n' "$PROJ" > "$RUN/spawn.team__alice"
  printf 'somesid\n' > "$RUN/actas.team__alice.session"

  # Stub herdr so we can assert the pane close call without touching real herdr.
  local stub_bin="$TEST_SKILL_DIR/stub-bin"
  mkdir -p "$stub_bin"
  cat > "$stub_bin/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HERDR_CALL_LOG"
echo '{"id":"cli:pane:close","result":{"type":"ok"}}'
STUB
  chmod +x "$stub_bin/herdr"
  export HERDR_CALL_LOG="$TEST_SKILL_DIR/herdr-calls.log"

  run env PATH="$stub_bin:$PATH" bash "$SCRIPTS/despawn.sh" team leader alice --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=forced"* ]]
  [ ! -f "$RUN/spawn.team__alice" ]
  # herdr was called with "pane close wC:p99" (prefix stripped).
  grep -q "pane close wC:p99" "$HERDR_CALL_LOG"
}

# --- graceful despawn folds the member's OWN pane through its terminal driver
#
# Until the terminals axis, this teardown was `tmux kill-pane -t $TMUX_PANE`
# inline: a tmux member could fold itself away and a herdr member could not.
# The v1 scope named that asymmetry and said the teardown goes through the
# placement record like despawn.sh does. These four cover the two terminals and
# the two ways the record can fail to authorise anything.
#
# The terminals are STUBBED on PATH rather than real: the point being proved is
# "the driver was invoked with the recorded id", and a real pane cannot be part
# of a test that must not close the developer's own session (see the setup note
# above — that has already happened once here).

_spawn_rec_path() {
  ( export SKILL_DIR="$TEST_SKILL_DIR" RUN_DIR="$RUN"
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/actas-lock.sh"
    agmsg_spawn_path "$1" "$2" )
}

# Stub terminal binaries. Each logs its argv so the test can assert WHAT was
# asked of it, not merely that something happened.
_stub_herdr() {   # <bindir> <session_id> <pane_id>
  mkdir -p "$1"
  cat > "$1/herdr" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/herdr.log"
if [ "\$1" = agent ] && [ "\$2" = list ]; then
  cat <<'JSON'
{"id":1,"result":{"type":"agents","agents":[
 {"pane_id":"$3","agent_session":{"agent":"claude","kind":"id","value":"$2"}}
]}}
JSON
  exit 0
fi
exit 0
EOF
  chmod +x "$1/herdr"
}

_stub_tmux() {    # <bindir>
  mkdir -p "$1"
  cat > "$1/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/tmux.log"
exit 0
EOF
  chmod +x "$1/tmux"
}

# Run a member watcher to the point where a ctrl:despawn has been handled.
# Returns with the watcher already exited (the teardown path ends in exit 0).
_despawn_member_with_env() {   # <bindir> <env assignments...>
  local bindir="$1"; shift
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  setup_live_owner "$RUN" sess-m

  AGMSG_WATCH_INTERVAL=1 PATH="$bindir:$PATH" env "$@" \
    bash "$SCRIPTS/watch.sh" sess-m "$PROJ" claude-code alice \
    >"$RUN/watch.out" 2>"$RUN/watch.err" 3>&- &
  WPID=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$RUN/ready.team__alice" ] && break; sleep 0.5; done
  [ -e "$RUN/ready.team__alice" ]

  # The stub is the terminal for the CALLER too, not only for the watcher. The
  # caller asks the terminal whether the pane is still there (#1051), and without
  # this it asks whatever tmux happens to be on the machine — which answered
  # `gone` about a pane id it had never heard of, and the record was deleted on
  # that. Measured here before it was noticed anywhere else.
  # DESPAWN_BIN (optional) is prepended for the CALLER only, never for the
  # watcher: a stub that has to break one of despawn's own syscalls must not also
  # break the watcher's unrelated cleanup, or the test measures two things.
  DESPAWN_RC=0
  PATH="${DESPAWN_BIN:+$DESPAWN_BIN:}$bindir:$PATH" bash "$SCRIPTS/despawn.sh" \
    team leader alice --timeout 10 >"$RUN/despawn.out" 2>"$RUN/despawn.err" || DESPAWN_RC=$?
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$WPID" 2>/dev/null || break; sleep 0.5; done
  kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
}

@test "despawn: graceful — a herdr member closes its own pane through the driver" {
  local bin="$BATS_TEST_TMPDIR/bin"
  _stub_herdr "$bin" sess-m wT:p1
  local rec; rec="$(_spawn_rec_path team alice)"
  mkdir -p "$(dirname "$rec")"
  printf 'herdr:wT:p1\t%s\tclaude-code\n' "$PROJ" > "$rec"

  _despawn_member_with_env "$bin" HERDR_ENV=1

  # THE point of the change: herdr is asked to close the recorded pane. Before
  # this, no herdr member could fold itself away at all.
  [ -f "$bin/herdr.log" ]
  grep -Fq 'pane close wT:p1' "$bin/herdr.log"
}

@test "despawn: graceful — a tmux member still closes its own pane (no regression)" {
  local bin="$BATS_TEST_TMPDIR/bin"
  _stub_tmux "$bin"
  local rec; rec="$(_spawn_rec_path team alice)"
  mkdir -p "$(dirname "$rec")"
  printf 'tmux:%%9\t%s\tclaude-code\n' "$PROJ" > "$rec"

  _despawn_member_with_env "$bin" TMUX=/tmp/fake-tmux-socket,0,0 TMUX_PANE=%9

  [ -f "$bin/tmux.log" ]
  grep -Fq 'kill-pane -t %9' "$bin/tmux.log"
}

@test "despawn: graceful — no placement record closes nothing, and says why" {
  local bin="$BATS_TEST_TMPDIR/bin"
  _stub_tmux "$bin"
  # deliberately NO record written

  _despawn_member_with_env "$bin" TMUX=/tmp/fake-tmux-socket,0,0 TMUX_PANE=%9

  # Nothing was closed...
  if [ -f "$bin/tmux.log" ]; then
    refute grep -Fq 'kill-pane' "$bin/tmux.log"
  fi
  # ...and the member was TOLD, rather than left wondering why its window is
  # still open. Silence here is the state an operator cannot see.
  grep -Fq 'no placement record' "$RUN/watch.err"
}

@test "despawn: graceful — a record naming another session's pane is left alone" {
  local bin="$BATS_TEST_TMPDIR/bin"
  _stub_tmux "$bin"
  local rec; rec="$(_spawn_rec_path team alice)"
  mkdir -p "$(dirname "$rec")"
  # The record says %9; this session is in %1. A record for (team, alice) proves
  # a pane was placed for that seat — never that THIS process is in it. Acting
  # on the weaker fact is how a record becomes authority it was not given.
  printf 'tmux:%%9\t%s\tclaude-code\n' "$PROJ" > "$rec"

  _despawn_member_with_env "$bin" TMUX=/tmp/fake-tmux-socket,0,0 TMUX_PANE=%1

  if [ -f "$bin/tmux.log" ]; then
    refute grep -Fq 'kill-pane -t %9' "$bin/tmux.log"
  fi
  grep -Fq 'belongs to someone else' "$RUN/watch.err"
}

# --- #1051: a teardown that did not fold the pane does not report success -----
#
# The dogfood that produced #1051: graceful despawn said `status=ok`, the pane
# stayed open with the agent running, and `--force` then refused because the
# graceful path had already deleted the record it works from. Three things had to
# line up, and each gets a control here.
#
# The one that made it unrecoverable is the caller's: it treated "the actas lock
# went free" as proof the pane was folded. The lock goes free when the watcher
# lets go of it — before it tries to close anything, and also when its owner
# simply died. Proof of one event was read as proof of another.

# A `tmux` stub whose pane LIST still contains the pane after a kill: the shape
# of "the close did not take". The kill is recorded so the test can prove it was
# attempted, and the list is what `terminal_pane_state` reads.
_stub_tmux_close_fails() {
  local bin="$1"; mkdir -p "$bin"
  cat > "$bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$bin/tmux.log"
case "\$1" in
  list-panes)   echo '%1' ;;   # still there, whatever we were asked to close
  kill-pane)    exit 1 ;;
  capture-pane) echo 'x' ;;
esac
exit 0
EOF
  chmod +x "$bin/tmux"
}

@test "despawn: graceful does not report ok when the pane is still open (#1051)" {
  local bin="$BATS_TEST_TMPDIR/bin"
  _stub_tmux_close_fails "$bin"
  local rec; rec="$(_spawn_rec_path team alice)"
  mkdir -p "$(dirname "$rec")"
  printf 'tmux:%%1\t%s\tclaude-code\n' "$PROJ" > "$rec"

  _despawn_member_with_env "$bin" TMUX=/tmp/fake-tmux-socket,0,0 TMUX_PANE=%1

  # Positive control: the teardown really did try to close it. Without this the
  # assertions below also pass for a run that never got that far.
  grep -Fq 'kill-pane' "$bin/tmux.log"

  # 1. The record — the only thing --force can work from — is KEPT.
  [ -f "$rec" ]

  # 2. The failure reached the channel an operator actually has. watch_log writes
  #    to stderr and the shipped launcher runs the watcher with fd2 on /dev/null
  #    (#691), so stderr alone is nowhere.
  grep -Fq 'did not close pane' "$RUN/watch.out"
}

# NOTE ON WHICH BRANCH THIS COVERS. With no watcher the lock is free from the
# start, so this exits through the PRE-EXISTING "no live actas lock, but a record
# remains" branch and never reaches the post-teardown check added by #1051 —
# measured: forcing that check to answer `gone` leaves this test green. It is a
# control for the branch it does reach (the record survives a graceful attempt
# that confirmed nothing), and the test above is the one that covers the new
# code. Saying so because a name that implies the other branch is how a test gets
# counted as coverage it does not provide.
@test "despawn: a settled 'gone' that could not delete the record is NOT ok (#1051)" {
  # Whether the record MAY go and whether it WENT are different questions, and
  # this branch answered only the first: `rm -f ... || true`, then status=ok. A
  # record that outlives the pane it names is exactly what --force then acts on,
  # so reporting success here hands the next caller a wrong authority — the same
  # shape as the bug this whole change is about, one layer further out.
  local bin="$BATS_TEST_TMPDIR/bin"
  _stub_tmux "$bin"                       # list-panes prints nothing -> settled `gone`
  local rec; rec="$(_spawn_rec_path team alice)"
  mkdir -p "$(dirname "$rec")"
  printf 'tmux:/tmp/fake-tmux-socket:%%9\t%s\tclaude-code\n' "$PROJ" > "$rec"

  # Break the deletion itself, for the caller only. The fix asserts the STATE of
  # the record rather than rm's exit code, so a stub that exits non-zero AND one
  # that lies with exit 0 are both caught — this one does both at once.
  local dbin="$BATS_TEST_TMPDIR/dbin"; mkdir -p "$dbin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dbin/rm"      # succeeds, removes nothing
  chmod +x "$dbin/rm"

  DESPAWN_BIN="$dbin" _despawn_member_with_env "$bin" \
    TMUX=/tmp/fake-tmux-socket,0,0 TMUX_PANE=%9

  # Positive control: the terminal really was asked, so `gone` is the settled
  # answer and this test is exercising the delete branch, not an earlier refusal.
  grep -Fq 'list-panes' "$bin/tmux.log"
  # The record did survive — the premise of the assertions below.
  [ -f "$rec" ]

  refute grep -q 'status=ok' "$RUN/despawn.out"
  grep -q 'note=record-not-removed' "$RUN/despawn.out"
  [ "$DESPAWN_RC" -ne 0 ]
}

@test "despawn: a free lock with a record still reports needs-force (#1051, pre-existing branch)" {
  local bin="$BATS_TEST_TMPDIR/bin"
  _stub_tmux_close_fails "$bin"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team leader claude-code "$PROJ" >/dev/null
  local rec; rec="$(_spawn_rec_path team alice)"
  mkdir -p "$(dirname "$rec")"
  printf 'tmux:%%1\t%s\tclaude-code\n' "$PROJ" > "$rec"

  # No watcher at all: the lock is free from the start, which is exactly the
  # state the caller used to read as "torn down". The pane, per the stub, is not.
  run env PATH="$bin:$PATH" bash "$SCRIPTS/despawn.sh" team leader alice --timeout 2
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -Fq 'needs-force'
  [ -f "$rec" ]
}
