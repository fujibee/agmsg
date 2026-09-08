#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
}

teardown() { teardown_test_env; }

# Pretend a CC instance with the given pid is alive and owns the given sid.
fake_cc_instance() {
  local pid="$1" sid="$2"
  echo "$sid" > "$RUN_DIR/cc-instance.$pid"
}

# Use the test process's own PID for "live owner" scenarios. It's guaranteed
# alive for the duration of the test. Avoids subshell-vs-stdout hangs that
# bite when you try to spawn a separate long-lived background pid from
# inside command substitution.
live_pid() { echo "$$"; }

# --- path encoding ---

@test "actas_lock_path: percent-encodes special bytes in team/agent" {
  local p
  p=$(actas_lock_path "team/foo" "ag ent")
  [[ "$p" == "$RUN_DIR/actas.team%2Ffoo__ag%20ent.session" ]]
}

@test "actas_lock_path: leaves safe chars alone" {
  local p
  p=$(actas_lock_path "team-A.1" "agent_B")
  [[ "$p" == "$RUN_DIR/actas.team-A.1__agent_B.session" ]]
}

# Regression for #65 review finding 2: the old underscore-replacement scheme
# made "foo bar" and "foo_bar" map to the same lock file. With percent
# encoding the two are unambiguous.
@test "actas_lock_path: names that collided under the old scheme are now distinct" {
  [ "$(actas_lock_path "foo bar" alice)" != "$(actas_lock_path "foo_bar" alice)" ]
  [ "$(actas_lock_path "a/b"   alice)" != "$(actas_lock_path "a_b"     alice)" ]
}

@test "actas_lock_path: encodes non-ASCII (UTF-8) bytes" {
  local p
  p=$(actas_lock_path "チーム" alice)
  # "チ" = E3 83 81, so the encoded prefix must contain that triple.
  [[ "$p" == *"%E3%83%81%E3%83%BC%E3%83%A0"* ]]
}

# --- claim / state ---

@test "claim: succeeds when lock file absent" {
  run actas_lock_claim "T" "alice" "sid-1"
  [ "$status" -eq 0 ]
  [ "$(actas_lock_owner "T" "alice")" = "sid-1" ]
}

@test "claim: idempotent when caller already owns it" {
  actas_lock_claim "T" "alice" "sid-1"
  run actas_lock_claim "T" "alice" "sid-1"
  [ "$status" -eq 0 ]
}

@test "claim: refuses when held by a live other session" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-other"
  echo "sid-other" > "$(actas_lock_path "T" "alice")"

  run actas_lock_claim "T" "alice" "sid-mine"
  [ "$status" -eq 1 ]
  [[ "$output" == "held:sid-other" ]]
  [ "$(actas_lock_owner "T" "alice")" = "sid-other" ]
}

@test "claim: reclaims a stale lock whose owner is dead" {
  # Lock exists but no live cc-instance references that sid.
  echo "sid-dead" > "$(actas_lock_path "T" "alice")"

  run actas_lock_claim "T" "alice" "sid-mine"
  [ "$status" -eq 0 ]
  [ "$(actas_lock_owner "T" "alice")" = "sid-mine" ]
}

# Regression for #65 review finding 1, then re-review of 48339d8: a naive
# stale clear (rm or mv) reads-then-removes lock_path with no guard on the
# content, so a second caller carrying a stale decision can delete a fresh
# live lock the first caller installed. Fixed by guarding the removal with
# a per-lock mutex (mkdir on `.reclaim.d`) and re-checking ownership
# *inside* it: if a live owner snuck in between the stale observation and
# the reclaim, leave it alone.
#
# bats can't truly interleave, so we exercise the invariant via two
# complementary cases:

# Case 1: serial — once a live owner claims, peer is refused (basic
# exclusivity sanity check).
@test "claim: a live owner is never replaced by a serial peer's claim" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  echo "sid-dead" > "$(actas_lock_path "T" "alice")"
  setup_live_owner "$RUN_DIR" "sid-A"
  actas_lock_claim "T" "alice" "sid-A"
  run actas_lock_claim "T" "alice" "sid-B"
  [ "$status" -eq 1 ]
  [[ "$output" == "held:sid-A" ]]
  [ "$(actas_lock_owner "T" "alice")" = "sid-A" ]
}

# Case 2: simulates the exact race window flagged on re-review.
# We pre-populate lock_path with a live-owner record (modeling "winner A
# has installed its lock"), then drive a claim() call that on its first
# try_claim *would* see stale if it observed the prior state — but in our
# substitute we just verify the resulting state. Then we additionally
# stage the reclaim mutex held externally to simulate the would-be racer
# carrying a stale decision: claim must NOT touch the existing live lock
# even if it tried to enter the stale path.
@test "claim: a fresh live lock survives a concurrent claimer's stale reclaim attempt" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  # lock_path already records a live owner (sid-A is alive via cc-instance).
  setup_live_owner "$RUN_DIR" "sid-A"
  echo "sid-A" > "$(actas_lock_path "T" "alice")"

  # Externally hold the reclaim mutex — modeling a peer that thinks the
  # slot is stale and is about to enter the cleanup. With the fix the
  # reclaim path now re-checks ownership *inside* this mutex, so even
  # if a peer made it through, sid-A's live lock would be respected.
  local rd="$(actas_lock_path "T" "alice").reclaim.d"
  mkdir "$rd"

  run actas_lock_claim "T" "alice" "sid-B"
  rmdir "$rd"

  [ "$status" -eq 1 ]
  [[ "$output" == "held:sid-A" ]]
  [ "$(actas_lock_owner "T" "alice")" = "sid-A" ]
}

# --- liveness ---

@test "sid_alive: empty sid is not alive" {
  run actas_lock_sid_alive ""
  [ "$status" -ne 0 ]
}

@test "sid_alive: pid alive + cc-instance content matches -> alive" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-A"
  run actas_lock_sid_alive "sid-A"
  [ "$status" -eq 0 ]
}

@test "sid_alive: pid dead -> not alive" {
  fake_cc_instance "99999" "sid-A"  # very unlikely live pid
  run actas_lock_sid_alive "sid-A"
  [ "$status" -ne 0 ]
}

# --- release / release_all ---

@test "release: removes a lock we own" {
  actas_lock_claim "T" "alice" "sid-mine"
  actas_lock_release "T" "alice" "sid-mine"
  [ ! -f "$(actas_lock_path "T" "alice")" ]
}

@test "release: leaves another session's lock alone" {
  fake_cc_instance "$(live_pid)" "sid-other"
  echo "sid-other" > "$(actas_lock_path "T" "alice")"
  actas_lock_release "T" "alice" "sid-mine"
  [ -f "$(actas_lock_path "T" "alice")" ]
}

@test "release_all: removes every lock owned by the sid, leaves others" {
  fake_cc_instance "$(live_pid)" "sid-keeper"
  actas_lock_claim "T1" "alice" "sid-going"
  actas_lock_claim "T2" "bob"   "sid-going"
  echo "sid-keeper" > "$(actas_lock_path "T3" "carol")"

  actas_lock_release_all "sid-going"

  [ ! -f "$(actas_lock_path "T1" "alice")" ]
  [ ! -f "$(actas_lock_path "T2" "bob")" ]
  [ -f   "$(actas_lock_path "T3" "carol")" ]
}

# --- gc_stale ---

@test "gc_stale: removes locks whose owner is dead, returns count" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  echo "sid-dead-1" > "$(actas_lock_path "T1" "alice")"
  echo "sid-dead-2" > "$(actas_lock_path "T2" "bob")"
  fake_cc_instance "$(live_pid)" "sid-live"
  echo "sid-live" > "$(actas_lock_path "T3" "carol")"

  run actas_lock_gc_stale
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
  [ ! -f "$(actas_lock_path "T1" "alice")" ]
  [ ! -f "$(actas_lock_path "T2" "bob")" ]
  [ -f   "$(actas_lock_path "T3" "carol")" ]
}

@test "gc_stale: noop when no stale locks" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-live"
  echo "sid-live" > "$(actas_lock_path "T" "alice")"

  run actas_lock_gc_stale
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  [ -f "$(actas_lock_path "T" "alice")" ]
}

# --- state classification ---

@test "state: free when no lock exists" {
  run actas_lock_state "T" "alice" "sid-me"
  [ "$status" -eq 0 ]
  [ "$output" = "free" ]
}

@test "state: mine when caller owns the lock" {
  actas_lock_claim "T" "alice" "sid-me"
  run actas_lock_state "T" "alice" "sid-me"
  [ "$output" = "mine" ]
}

@test "state: other:<sid> when held by a live different session" {
  skip_on_windows "actas live-session liveness under Git Bash (#182)"
  fake_cc_instance "$(live_pid)" "sid-other"
  echo "sid-other" > "$(actas_lock_path "T" "alice")"
  run actas_lock_state "T" "alice" "sid-me"
  [ "$output" = "other:sid-other" ]
}

@test "state: free when held by a dead session (stale)" {
  echo "sid-dead" > "$(actas_lock_path "T" "alice")"
  run actas_lock_state "T" "alice" "sid-me"
  [ "$output" = "free" ]
}

# --- #983: "could not read" is its own answer, not "nobody holds it" -----------

@test "observe: an unreadable lock is unknown, not free" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  actas_lock_claim T alice sid-me
  local lock; lock="$(actas_lock_path T alice)"
  [ -f "$lock" ]                          # canary: there is a lock to make unreadable
  chmod 000 "$lock"
  local st; st="$(actas_lock_state T alice sid-other)"
  chmod 644 "$lock" 2>/dev/null || true
  [ "$st" = "unknown:lock_unreadable" ]
}

@test "observe: an ABSENT lock is still free" {
  # The partner. Without it, returning `unknown:` for everything passes the test
  # above, and every caller then refuses forever.
  [ "$(actas_lock_state T nobody sid-me)" = free ]
}

@test "observe: returns the state and the raw owner from ONE read" {
  # The pairing is the point: callers that need a baseline were reading the state
  # and then reading the owner separately, and a claim landing between the two
  # produced a stale state with a fresh owner.
  actas_lock_claim T alice sid-me
  local out; out="$(actas_lock_observe T alice sid-me)"
  [ "$out" = "$(printf 'mine\tsid-me')" ]
}

@test "observe: a lock owned by a session that cannot be judged is unknown" {
  # liveness undecidable -> unknown, not free. `free` here would mean "stale",
  # and stale is what reclaim and gc act on.
  actas_lock_claim T alice sid-ghost
  agmsg_instance_alive() { return 2; }     # cannot tell
  [ "$(actas_lock_state T alice sid-me)" = "unknown:liveness_undecidable" ]
}

@test "observe: a lock owned by a POSITIVELY dead session is still free" {
  # The partner again: undecidable and dead must not collapse back together.
  actas_lock_claim T alice sid-ghost
  agmsg_instance_alive() { return 1; }     # positively dead
  [ "$(actas_lock_state T alice sid-me)" = free ]
}

@test "observe: a lock DIRECTORY we cannot search is unknown, not free" {
  # `[ -e "$lock" ]` is false when the parent lacks search permission, so an
  # inaccessible directory answered "absent" -> `free` -> callers act. The
  # file-level chmod control does not reach this: there the directory is fine.
  # (co3)
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  actas_lock_claim T alice sid-me
  local lock dir; lock="$(actas_lock_path T alice)"; dir="${lock%/*}"
  [ -f "$lock" ]                            # canary: the lock is really there
  chmod 000 "$dir"
  local st; st="$(actas_lock_state T alice sid-other)"
  chmod 755 "$dir" 2>/dev/null || true
  [ "$st" = "unknown:lock_unreadable" ]
}

# --- #983: the DESTRUCTIVE readers act only on a POSITIVE dead -----------------

@test "gc_stale: an unreadable lock is not swept" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  actas_lock_claim T alice sid-ghost
  local lock; lock="$(actas_lock_path T alice)"
  chmod 000 "$lock"
  local n; n="$(actas_lock_gc_stale)"
  chmod 644 "$lock" 2>/dev/null || true
  [ "$n" = 0 ]
  [ -f "$lock" ]                     # still there
}

@test "gc_stale: a POSITIVELY dead owner is still swept" {
  # The partner. Without it, "never sweep" passes the test above and stale locks
  # accumulate forever.
  actas_lock_claim T alice sid-ghost
  agmsg_instance_alive() { return 1; }
  local lock; lock="$(actas_lock_path T alice)"
  [ "$(actas_lock_gc_stale)" = 1 ]
  [ ! -f "$lock" ]
}

@test "gc_stale: an owner whose liveness cannot be judged is not swept" {
  actas_lock_claim T alice sid-ghost
  agmsg_instance_alive() { return 2; }
  local lock; lock="$(actas_lock_path T alice)"
  [ "$(actas_lock_gc_stale)" = 0 ]
  [ -f "$lock" ]
}

@test "claim: an undecidable liveness does not read as stale" {
  # try_claim's `stale` arm hands the lock over. Undecidable must not reach it.
  actas_lock_claim T alice sid-ghost
  agmsg_instance_alive() { return 2; }
  local r rc=0; r="$(actas_lock_claim T alice sid-me)" || rc=$?
  [ "$r" = "unknown:liveness_undecidable" ]
  [ "$rc" -eq 1 ]                    # refused, not claimed
  [ "$(actas_lock_owner T alice)" = sid-ghost ]   # and the lock was left alone
}

@test "claim: a POSITIVELY dead owner is still reclaimed" {
  # The partner: a genuinely stale lock must still be takeable, or a crashed
  # session wedges its role permanently.
  actas_lock_claim T alice sid-ghost
  agmsg_instance_alive() { [ "$1" = sid-me ]; }   # sid-ghost dead, sid-me alive
  # Success prints nothing and returns 0 — the verdict is the exit status here,
  # not the output. Assert what the function actually does, and that the lock
  # really changed hands.
  local rc=0; actas_lock_claim T alice sid-me >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(actas_lock_owner T alice)" = sid-me ]
}

@test "observe: a lock directory that does not exist yet is free, not unknown" {
  # The partner to the inaccessible-directory control. A fresh install has no
  # lock directory at all, and calling that `unknown` makes every caller refuse:
  # measured, spawn stopped starting anything (58 tests red).
  rm -rf "$(_actas_lock_dir)"
  [ "$(actas_lock_state T nobody sid-me)" = free ]
}

@test "claim: an EMPTY lock file is not treated as free to steal" {
  # A third case, distinct from "unreadable" and from "undecidable": the file is
  # there and readable, and its contents are empty. That is not "nobody holds
  # it" — it is a lock written by someone whose write we may be seeing halfway,
  # or truncated. try_claim's `[ -z "$existing" ]` handed it over. (cc3)
  actas_lock_claim T alice sid-me
  : > "$(actas_lock_path T alice)"          # empty, still present
  # Assert the VERDICT, not only the outcome. Measured before the fix: the steal
  # did not happen, but only because the reclaim guard refused to rm an empty
  # owner — try_claim still answered `stale`. A test that checks only "the lock
  # survived" passes on a wrong verdict held up by a different mechanism.
  [ "$(_actas_lock_try_claim T alice sid-other)" = 'unknown:owner_empty' ]
  local r rc=0; r="$(actas_lock_claim T alice sid-other)" || rc=$?
  [ "$rc" -ne 0 ]
  refute grep -q '^ok$' <<<"$r"
  [ -f "$(actas_lock_path T alice)" ]       # and it was not removed
}
