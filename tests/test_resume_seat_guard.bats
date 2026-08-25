#!/usr/bin/env bats

# #982 — a resumed session that cannot be matched to a seat must NOT get the
# generic, unfiltered watcher on a multi-seat project.
#
# The generic watch.sh (no 4th <agent> arg) subscribes to EVERY registered
# (team, agent) pair for the project and, as it delivers, stamps read_at and
# advances each pair's read cursor to the tip. On a project with more than one
# seat that is not "receive a little extra" — it CONSUMES other seats' unread
# mail, and the taken seats never get those messages delivered again. So the
# safe fallback is fail-CLOSED: identify the seat (from an actas lock this sid
# owns) or stand down; never emit the unfiltered watcher where it can eat someone
# else's inbox.
#
# The one "broken but green" these tests are written against: a test that only
# greps the emitted directive text ("standing down", "acting as bob") stays green
# even if watch.sh's delivery is wrong or the wrong watcher is emitted elsewhere
# in the output. So the two load-bearing tests below RUN the directive that was
# actually emitted and observe which pairs' read cursors move — the behaviour, not
# the wording.

load test_helper

setup() {
  setup_test_env
  # Bare-sid keying (#93) so the sid these tests pass is the id the scripts key
  # on, deterministic whether the suite runs under an agent process or in CI.
  export AGMSG_AGENT_PID=""
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export PROJ="/tmp/agmsg-seat-guard-proj"
  # Two registered seats — the shape in which the defect exists. A single-seat
  # project is exercised by test_delivery.bats's generic-directive test, where the
  # unfiltered watcher cannot consume anyone else's mail and stays the safe default.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob   claude-code "$PROJ" >/dev/null
}

teardown() { teardown_test_env; }

# Read one pair's store-owned local read frontier (copied from test_watch.bats).
_read_cursor() {
  ( # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    storage_read_cursor_get "$1" "$2" )
}

# The `command:` line the directive tells the host to launch, or empty if the
# script emitted no watcher (the stand-down path).
_directive_command() { printf '%s\n' "$1" | sed -n 's/^[[:space:]]*command: //p'; }

# Mark <sid> alive as a bare session id (a live cc-instance.<pid> naming it), the
# way actas liveness (agmsg_instance_alive) resolves a bare owner token.
_mark_sid_alive() { echo "$1" > "$RUN_DIR/cc-instance.$$"; }

# Give <sid> ownership of the actas lock for (team, <agent>), as a claim would.
_seed_actas_lock() {
  local team="$1" agent="$2" sid="$3"
  echo "$sid" > "$RUN_DIR/actas.${team}__${agent}.session"
}

# Write a role-session record into the isolated skill dir's run/ (as actas-claim
# would), so the record path — not narrowing — seats the session.
_seed_role_record() {
  local team="$1" agent="$2" sid="$3" proj="$4" type="${5:-claude-code}"
  SKILL_DIR="$TEST_SKILL_DIR" bash -c '
    source "$1/lib/role-session.sh"
    agmsg_role_session_record "$2" "$3" "$4" "$5" "$6"
  ' _ "$SCRIPTS" "$team" "$agent" "$sid" "$proj" "$type"
}

_run_session_start() {
  env AGMSG_RESOLVE_PROJECT=0 bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" <<< "{\"session_id\":\"$1\"}"
}

# --- fail-closed stand-down (no seat, several pairs) ---

@test "resume, unidentified seat, multi-pair: stands down and emits NO watcher" {
  run _run_session_start "sid-nobody"
  [ "$status" -eq 0 ]
  # grep, not `[[ == ]]`: a non-last `[[ ]]` cannot fail the test on bash 3.2
  # (#670), and these must actually be able to fail.
  grep -qF "standing down" <<<"$output"
  # It must not be silent about why (a missing watcher reads as "no messages").
  grep -qF "/agmsg actas alice" <<<"$output"
  grep -qF "/agmsg actas bob" <<<"$output"
  grep -qF "history.sh" <<<"$output"
  # The load-bearing assertion: no runnable watch command was emitted, so the
  # host has nothing to launch and no seat's mail can be consumed. A regression to
  # the old fail-open path re-appears here as a non-empty command, not as a
  # reworded paragraph.
  local cmd; cmd="$(_directive_command "$output")"
  [ -z "$cmd" ]
}

@test "resume, unidentified seat, multi-pair: whatever is emitted consumes no one's mail" {
  # Behavioural form of the above: seed unread for both seats, run whatever the
  # directive emitted (nothing, when fixed), and assert neither read cursor moved.
  # If the script regresses to a generic watcher, this runs it and the cursors
  # advance — red.
  bash "$SCRIPTS/send.sh" team bob   alice "to-alice" >/dev/null
  bash "$SCRIPTS/send.sh" team alice bob   "to-bob"   >/dev/null
  local a0 b0; a0="$(_read_cursor team alice)"; b0="$(_read_cursor team bob)"

  run _run_session_start "sid-nobody"
  local cmd; cmd="$(_directive_command "$output")"
  if [ -n "$cmd" ]; then
    eval "set -- $cmd"
    AGMSG_WATCH_INTERVAL=1 bash "$@" >/dev/null 2>&1 3>&- 4>&- &
    local wpid=$!; sleep 3; kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true
  fi
  local a1 b1; a1="$(_read_cursor team alice)"; b1="$(_read_cursor team bob)"
  [ "${a1:-0}" = "${a0:-0}" ]
  [ "${b1:-0}" = "${b0:-0}" ]
}

# --- narrowing (no record, but an actas lock this sid owns) ---

@test "resume, no record, actas lock owned by this sid: re-seats to that pair" {
  _mark_sid_alive "sid-bob"
  _seed_actas_lock team bob "sid-bob"

  run _run_session_start "sid-bob"
  [ "$status" -eq 0 ]
  grep -qF "resumed role" <<<"$output"
  grep -qF "acting as bob" <<<"$output"
  # #993: the narrowing path must state its basis honestly — the actas lock it
  # holds, not a record it does not have. The reader launches a watcher on the
  # strength of this sentence, so the inferred seat must not read as a recorded one.
  grep -qF "actas exclusivity lock" <<<"$output"
  refute grep -qF "was recorded as that role's seat" <<<"$output"
  local cmd; cmd="$(_directive_command "$output")"
  eval "set -- $cmd"
  [ "$#" -eq 5 ]
  [ "$5" = "bob" ]
}

@test "resume, role-session record present: says recorded, not the actas-lock basis" {
  # The other half of the #993 distinction: a real record must read as recorded,
  # so the two bases stay distinguishable to the reader.
  _seed_role_record team alice "sid-alice" "$PROJ" claude-code
  run _run_session_start "sid-alice"
  [ "$status" -eq 0 ]
  grep -qF "acting as alice" <<<"$output"
  grep -qF "was recorded as that role's seat" <<<"$output"
  refute grep -qF "no role record was found" <<<"$output"
}

@test "resume, narrowed to bob: the emitted watcher consumes bob's mail only, not alice's" {
  # The strongest guard (tl's ask): run the directive AS EMITTED and check which
  # pairs it actually consumes. A watcher that ignored its 4th arg — or a
  # regression that emitted the generic one — would advance alice's cursor too.
  _mark_sid_alive "sid-bob"
  _seed_actas_lock team bob "sid-bob"
  bash "$SCRIPTS/send.sh" team alice bob   "to-bob"   >/dev/null
  bash "$SCRIPTS/send.sh" team bob   alice "to-alice" >/dev/null
  local a0; a0="$(_read_cursor team alice)"

  run _run_session_start "sid-bob"
  local cmd; cmd="$(_directive_command "$output")"
  eval "set -- $cmd"

  AGMSG_WATCH_INTERVAL=1 bash "$@" >/dev/null 2>&1 3>&- 4>&- &
  local wpid=$!
  local i b1
  for i in $(seq 1 100); do
    b1="$(_read_cursor team bob)"
    [ "${b1:-0}" -gt 0 ] && break
    sleep 0.1
  done
  kill "$wpid" 2>/dev/null || true; wait "$wpid" 2>/dev/null || true

  # bob's own mail was delivered (cursor advanced past it) ...
  [ "${b1:-0}" -gt 0 ]
  # ... and alice's was left untouched for alice's own watcher.
  local a1; a1="$(_read_cursor team alice)"
  [ "${a1:-0}" = "${a0:-0}" ]
}

# --- an ambiguous multi-claim is treated as unidentified, not guessed ---

@test "resume, sid owns two actas locks: refuses to guess, stands down" {
  _mark_sid_alive "sid-both"
  _seed_actas_lock team alice "sid-both"
  _seed_actas_lock team bob   "sid-both"

  run _run_session_start "sid-both"
  [ "$status" -eq 0 ]
  grep -qF "standing down" <<<"$output"
  local cmd; cmd="$(_directive_command "$output")"
  [ -z "$cmd" ]
}
