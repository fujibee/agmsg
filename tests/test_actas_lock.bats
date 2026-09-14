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

# Install a config.json + a one-line roster journal for <team>/<agent>, with
# LITERAL, caller-chosen team_id/member_id -- not minted by join.sh. #1023
# Review finding: a test that derives its expected id-keyed path by calling
# _agmsg_id_key_for (the function under test) can never catch that function
# being broken, since a broken resolver and the test's own expectation would
# agree with each other. Writing the ids here lets a test assert the exact
# literal path a real reader would compute, independent of this codebase's
# own id-resolution code.
_fixture_known_ids() {   # <team> <team_id> <agent> <member_id>
  local team="$1" team_id="$2" agent="$3" member_id="$4" dir
  dir="$SKILL_DIR/teams/$team"
  mkdir -p "$dir"
  printf '{"name":"%s","team_id":"%s","agents":{}}' "$team" "$team_id" > "$dir/config.json"
  printf '{"type":"member_joined","id":"ev-fixture","member_id":"%s","name":"%s","at":"2026-01-01T00:00:00Z"}\n' \
    "$member_id" "$agent" > "$dir/roster.jsonl"
}

# The role-keyed claim producer, addressed through its real interface: the
# shared path-keyed core actas_lock_claim itself calls. There is no more a
# role-keyed wrapper around it (removed as unused outside tests); this is the
# SAME consistency check the tests below want -- one shared verdict, reached
# from a second producer -- just no longer through a pass-through nobody else
# called.
_try_claim() {   # <team> <agent> <sid>
  _agmsg_lock_try_claim_at "$(actas_lock_path "$1" "$2")" "$3"
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
  [ "$(_owner_only "T" "alice")" = "sid-1" ]
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
  [ "$(_owner_only "T" "alice")" = "sid-other" ]
}

@test "claim: reclaims a stale lock whose owner is dead" {
  # Lock exists but no live cc-instance references that sid.
  echo "sid-dead" > "$(actas_lock_path "T" "alice")"

  run actas_lock_claim "T" "alice" "sid-mine"
  [ "$status" -eq 0 ]
  [ "$(_owner_only "T" "alice")" = "sid-mine" ]
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
  [ "$(_owner_only "T" "alice")" = "sid-A" ]
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
  # The mutex is an owner-bearing lock file (a bare directory had no owner
  # and outlived a crashed reclaimer forever); the peer holding it is live.
  # (One marker per pid in this harness, so the live peer is sid-A itself.)
  local rd="$(actas_lock_path "T" "alice").reclaim"
  echo "sid-A" > "$rd"

  run actas_lock_claim "T" "alice" "sid-B"
  rm -f "$rd"

  [ "$status" -eq 1 ]
  [[ "$output" == "held:sid-A" ]]
  [ "$(_owner_only "T" "alice")" = "sid-A" ]
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
  # (Review.)
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
  [ "$(_owner_only T alice)" = sid-ghost ]   # and the lock was left alone
}

@test "claim: a POSITIVELY dead owner is still reclaimed" {
  # The partner: a genuinely stale lock must still be takeable, or a crashed
  # session wedges its role permanently.
  actas_lock_claim T alice sid-ghost
  agmsg_instance_alive() { [ "$1" = sid-me ]; }   # sid-ghost dead, sid-me alive
  # What this test is about is the exit status and the lock changing hands; the
  # success verdict on stdout has its own control ("claim: says 'ok' out loud").
  local rc=0; actas_lock_claim T alice sid-me >/dev/null || rc=$?
  [ "$rc" -eq 0 ]
  [ "$(_owner_only T alice)" = sid-me ]
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
  # or truncated. try_claim's `[ -z "$existing" ]` handed it over. (#1071)
  actas_lock_claim T alice sid-me
  : > "$(actas_lock_path T alice)"          # empty, still present
  # Assert the VERDICT, not only the outcome. Measured before the fix: the steal
  # did not happen, but only because the reclaim guard refused to rm an empty
  # owner — try_claim still answered `stale`. A test that checks only "the lock
  # survived" passes on a wrong verdict held up by a different mechanism.
  [ "$(_try_claim T alice sid-other)" = 'unknown:owner_empty' ]
  local r rc=0; r="$(actas_lock_claim T alice sid-other)" || rc=$?
  [ "$rc" -ne 0 ]
  refute grep -q '^ok$' <<<"$r"
  [ -f "$(actas_lock_path T alice)" ]       # and it was not removed
}

# The tree deliberately has no owner-only reader any more (#983): every lock read
# reports its own outcome next to the owner, so that no caller can mistake "could
# not read it" for "nobody holds it". These assertions want the owner alone and
# each compares it against a specific sid, so a read that failed shows up as a
# failed assertion rather than as a passing empty string.
_owner_only() {   # <team> <agent>
  local _r; _r="$(actas_lock_read "$1" "$2")"
  [ "${_r%%$'\t'*}" = "ok" ] || return 1
  printf '%s' "${_r#*$'\t'}"
}

# --- #983 / #1071: one reader, one verdict, one answer per state ---------------

@test "read: an absent lock is 'absent' and an unreadable one is 'unreadable'" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  local tab; tab="$(printf '\t')"
  [ "$(actas_lock_read T nobody)" = "absent${tab}" ]
  # The differential partner. The reader this replaced answered "" and rc 0 for
  # BOTH of these, so no caller could tell "there is no lock" from "there is a
  # lock I cannot open" — and four producers guessed the destructive way.
  echo sid-x > "$(actas_lock_path T alice)"
  chmod 000 "$(actas_lock_path T alice)"
  local r; r="$(actas_lock_read T alice)"
  chmod 644 "$(actas_lock_path T alice)"
  [ "$r" = "unreadable${tab}" ]
}

@test "read: an EMPTY lock is 'ok' with an empty owner, which is not 'absent'" {
  local tab; tab="$(printf '\t')"
  : > "$(actas_lock_path T alice)"
  # The third world the old reader folded into the same empty string. Here the
  # read SUCCEEDED, and that is a fact about the file worth carrying: nothing in
  # this tree writes an empty lock, so it is a torn write, not a free role.
  [ "$(actas_lock_read T alice)" = "ok${tab}" ]
  [ "$(actas_lock_read T nobody)" = "absent${tab}" ]
}

@test "read: an unsearchable lock DIRECTORY is unreadable, a missing one is absent" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  local tab; tab="$(printf '\t')"
  # `[ -e ]` is false for both, so asking it alone reports "absent" for a
  # directory we cannot look inside — the answer that makes callers act (review).
  echo sid-x > "$(actas_lock_path T alice)"
  chmod 000 "$(_actas_lock_dir)"
  local r; r="$(actas_lock_read T alice)"
  chmod 755 "$(_actas_lock_dir)"
  [ "$r" = "unreadable${tab}" ]
  # The partner, in the other direction: a lock directory that was never created
  # is the ordinary state of a fresh install. Calling THAT unknown is just as
  # wrong and much louder — measured, it made spawn refuse to start anything
  # (58 tests red in one run).
  rm -rf "$(_actas_lock_dir)"
  [ "$(actas_lock_read T alice)" = "absent${tab}" ]
}

@test "one state one answer: an empty lock is unknown:owner_empty on EVERY path" {
  # Review found the same file answered `free` by observe and `unknown:owner_empty`
  # by try_claim. Both had been made three-valued — separately — so the tree held
  # two answers for one state and nothing marked either wrong. The verdict now
  # lives in one function and each producer translates it, which is what makes
  # this assertion writable at all. (Review axis 5.)
  : > "$(actas_lock_path T alice)"
  [ "$(actas_lock_state T alice sid-me)" = 'unknown:owner_empty' ]
  [ "$(_try_claim T alice sid-me)" = 'unknown:owner_empty' ]
  local r rc=0; r="$(actas_lock_claim T alice sid-me)" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$r" = 'unknown:owner_empty' ]
}

@test "one state one answer: an unreadable lock is unknown:lock_unreadable on EVERY path" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  echo sid-x > "$(actas_lock_path T alice)"
  chmod 000 "$(actas_lock_path T alice)"
  local s v; s="$(actas_lock_state T alice sid-me)"; v="$(_try_claim T alice sid-me)"
  chmod 644 "$(actas_lock_path T alice)"
  [ "$s" = 'unknown:lock_unreadable' ]
  [ "$v" = 'unknown:lock_unreadable' ]
}

@test "one state one answer: a POSITIVELY dead owner is still free/stale, not unknown" {
  # The partner the two tests above need. Without it, a library that answered
  # `unknown:` for everything would pass both of them, and the roles of every
  # crashed session would wedge forever. The words differ because the producers'
  # vocabularies differ — observe says `free`, try_claim says `stale` — but both
  # come from the one shared verdict, which is the property axis 5 is about.
  echo sid-dead > "$(actas_lock_path T alice)"
  agmsg_instance_alive() { return 1; }
  [ "$(actas_lock_state T alice sid-me)" = free ]
  [ "$(_try_claim T alice sid-me)" = stale ]
}

@test "claim: says 'ok' out loud on success" {
  # Success used to print NOTHING — and so did every failure the case did not
  # name. The three call sites branch on this output, so silence read as "we got
  # it" in both cases. Naming the success is what lets a caller refuse by default.
  local r rc=0; r="$(actas_lock_claim T alice sid-me)" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$r" = ok ]
}

@test "claim: a failure that learned nothing prints a verdict, not silence" {
  # The partner. This claim fails BEFORE it can read anything: the lock directory
  # is not writable, so mktemp cannot make its temp file. Nothing was claimed and
  # no holder was established — and that used to be indistinguishable, on stdout,
  # from a successful claim.
  [ "$(id -u)" -eq 0 ] && skip "a read-only directory is ineffective as root"
  chmod 500 "$(_actas_lock_dir)"
  local r rc=0; r="$(actas_lock_claim T alice sid-me)" || rc=$?
  chmod 755 "$(_actas_lock_dir)"
  [ "$rc" -eq 1 ]
  [ "$r" = 'unknown:claim_failed' ]
}

@test "release_all: keeps a lock it could not read, releases the one it could" {
  [ "$(id -u)" -eq 0 ] && skip "chmod 000 is ineffective as root"
  actas_lock_claim T alice sid-me >/dev/null
  actas_lock_claim T bob   sid-me >/dev/null
  chmod 000 "$(actas_lock_path T alice)"
  actas_lock_release_all sid-me
  local kept=0; [ -f "$(actas_lock_path T alice)" ] && kept=1
  chmod 644 "$(actas_lock_path T alice)"
  # An unreadable lock is not one we can confirm we own, and release DELETES.
  [ "$kept" -eq 1 ]
  # The partner: the sweep still does its job on the locks it can read, or a
  # session's roles would never be given back.
  refute test -f "$(actas_lock_path T bob)"
}

@test "every actas_lock_claim consumer names its success and refuses by default" {
  # A behavioural test can reach the two NAMED refusals. It cannot reach a
  # verdict nobody has thought of yet — and that unnamed value is exactly what
  # the old shape accepted as success. So this is pinned on the shape: an `ok`
  # arm, and a `*)` arm so nothing falls through.
  local f blk n=0
  for f in "$SKILL_DIR/scripts/actas-claim.sh" "$SKILL_DIR/scripts/watch.sh" \
           "$SKILL_DIR/scripts/lib/subscription.sh"; do
    blk="$(awk 'index($0,"$(actas_lock_claim"){f=1} f{print} f&&/esac/{exit}' "$f")"
    grep -qE '^[[:space:]]*ok\)' <<<"$blk"
    # Anchored: `held:*)` and `unknown:*)` also END in `*)`, so an unanchored
    # match was satisfied by the arms that were already there and the check
    # passed with the default arm deleted. Measured — the mutation that removes
    # it produced zero reds until this line was anchored.
    grep -qE '^[[:space:]]*\*\)' <<<"$blk"
    n=$((n + 1))
  done
  # Canary: every file was opened and every block was found, so the greps above
  # ran three times rather than passing on an empty set.
  [ "$n" -eq 3 ]
}

@test "claim: a lock whose contents did not land is never published (axis 6)" {
  # The write half. printf's own status does not prove the bytes reached the
  # disk, so try_claim reads the temp file back before linking it into place;
  # this stubs that read to answer what a short write leaves behind (present,
  # readable, empty). A lock published in that state is READ BY PEERS as
  # unknown:owner_empty while the claimant believes it holds the role.
  _actas_lock_read_path() { printf 'ok\t\n'; }
  local r rc=0; r="$(actas_lock_claim T alice sid-me)" || rc=$?
  [ "$rc" -eq 1 ]
  [ "$r" = 'unknown:claim_failed' ]
  # And nothing was published. This is the assertion that matters: refusing is
  # only worth anything if the broken file did not become the lock.
  refute test -f "$(actas_lock_path T alice)"
}

# --- #1023: id-keyed paths, so a team/agent name containing '__' cannot ------
# collide with a different pair that happens to split at the same point -----

@test "#1023: id-bearing pairs no longer collide across the team/agent boundary" {
  # The issue's OWN reproduction: the ambiguity is in the JOIN POINT, not in
  # either half alone -- ("a__b","c") and ("a","b__c") are TWO DIFFERENT TEAMS
  # whose <team>__<agent> concatenation is identical either way. Known,
  # literal ids (not minted by join.sh, not derived by calling the id-key
  # resolver under test) so the expected path for all three functions is a
  # literal the test wrote itself -- review finding: deriving the expectation
  # from _agmsg_id_key_for would let a broken resolver agree with its own
  # broken expectation. (A first version of this test compared two agents in
  # the SAME team, which every member naming scheme already tells apart via a
  # different member_id -- it could not have caught the encoder skipping the
  # join entirely, and passed under a mutation that broke actas_lock_path
  # outright. Caught by mutation, not by inspection.)
  _fixture_known_ids "a__b" "tid-AB" c "mid-C"
  _fixture_known_ids a "tid-A" "b__c" "mid-BC"
  local dir; dir="$(_actas_lock_dir)"

  [ "$(actas_lock_path "a__b" c)"   = "$dir/actas.tid-AB__mid-C.session" ]
  [ "$(agmsg_ready_path "a__b" c)"  = "$dir/ready.tid-AB__mid-C" ]
  [ "$(agmsg_spawn_path "a__b" c)"  = "$dir/spawn.tid-AB__mid-C" ]

  [ "$(actas_lock_path a "b__c")"   = "$dir/actas.tid-A__mid-BC.session" ]
  [ "$(agmsg_ready_path a "b__c")"  = "$dir/ready.tid-A__mid-BC" ]
  [ "$(agmsg_spawn_path a "b__c")"  = "$dir/spawn.tid-A__mid-BC" ]

  [ "$(actas_lock_path "a__b" c)" != "$(actas_lock_path a "b__c")" ]
}

@test "#1023: a team with no team_id still collides -- a decided scope cut, not silent" {
  # No join.sh call at all: no config.json exists for this team, so
  # _agmsg_id_key_for cannot resolve anything and every path function falls
  # back to the original name-encoded form, unchanged. This is the explicit
  # scope cut: an id-less team is not fixed by this change.
  [ "$(actas_lock_path "a__b" c)" = "$(actas_lock_path a "b__c")" ]
}

@test "#1023: an id-bearing team, agent not yet in the roster, still collides" {
  # The team has an id (join.sh minted one for T, above -- but "a__b" itself
  # has never joined). agmsg_roster_name_owner returns nothing for a name that
  # never joined, so the id key cannot be built and the path falls back to
  # exactly what the OLD scheme produced -- not some new, different value.
  bash "$SKILL_DIR/scripts/join.sh" T zzz claude-code /tmp/proj >/dev/null
  local t a; t="$(_actas_lock_encode T)"; a="$(_actas_lock_encode "a__b")"
  [ "$(actas_lock_path T "a__b")" = "$(printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$t" "$a")" ]
}

@test "#1023: migration -- an existing legacy-path lock keeps being served after ids exist" {
  # A lock written before this change (or while the name was still
  # unregistered) must not be orphaned the moment the pair gains an id: the
  # path functions check the legacy location before handing back the new one.
  bash "$SKILL_DIR/scripts/join.sh" T alice claude-code /tmp/proj >/dev/null
  local legacy; legacy="$(printf '%s/actas.T__alice.session' "$(_actas_lock_dir)")"
  mkdir -p "$(dirname "$legacy")"
  echo "sid-old" > "$legacy"
  [ "$(actas_lock_path T alice)" = "$legacy" ]
  [ "$(cat "$(actas_lock_path T alice)")" = "sid-old" ]
}

@test "#1023: migration -- claiming an id-bearing pair with a pre-existing legacy lock never leaves the member locked at BOTH paths" {
  # actas_lock_claim resolves the path exactly once (via actas_lock_path) and
  # writes only there, so a lock written before the pair had ids cannot be
  # orphaned by the id-keyed path springing into existence alongside it. This
  # exercises the real claim flow, not just path resolution, since a caller
  # that computed its own path independently of actas_lock_path would defeat
  # the single-resolution guarantee without failing any test that only calls
  # actas_lock_path directly. idpath is a LITERAL built from the fixture's own
  # known ids, not derived via _agmsg_id_key_for -- same reason as
  # the boundary-collision test above.
  _fixture_known_ids T "tid-T" alice "mid-alice"
  local legacy; legacy="$(printf '%s/actas.T__alice.session' "$(_actas_lock_dir)")"
  echo "sid-old" > "$legacy"

  local idpath; idpath="$(printf '%s/actas.tid-T__mid-alice.session' "$(_actas_lock_dir)")"

  run actas_lock_claim T alice new-sid
  [ "$status" -eq 0 ]
  [ "$(cat "$legacy")" = new-sid ]
  refute test -e "$idpath"
}

@test "#1023: both an id-keyed AND a legacy lock existing for the same member is never silently accepted" {
  # Review finding: the prior test coverage only exercised legacy-alone. A stale
  # duplicate (crash mid-migration, a manual copy, or a caller that built its
  # own path independently of these functions) must not resolve without a
  # signal -- a caller with no reason to suspect anything is wrong would never
  # know two locks exist for the one member.
  _fixture_known_ids T "tid-T" eve "mid-eve"
  local legacy idpath
  legacy="$(printf '%s/actas.T__eve.session' "$(_actas_lock_dir)")"
  idpath="$(printf '%s/actas.tid-T__mid-eve.session' "$(_actas_lock_dir)")"
  echo "sid-legacy" > "$legacy"
  echo "sid-idpath" > "$idpath"

  local resolved warn_log="$BATS_TEST_TMPDIR/warn.log"
  resolved="$(actas_lock_path T eve 2>"$warn_log")"

  # Resolves deterministically (id-keyed wins) -- a caller still gets a path
  # to act on -- but never silently: the warning names BOTH files.
  [ "$resolved" = "$idpath" ]
  [ -s "$warn_log" ]
  grep -Fq "$idpath" "$warn_log"
  grep -Fq "$legacy" "$warn_log"
}

@test "#1023: a fresh id-bearing pair with no file anywhere gets the NEW path" {
  bash "$SKILL_DIR/scripts/join.sh" T bob claude-code /tmp/proj >/dev/null
  local p; p="$(actas_lock_path T bob)"
  local legacy; legacy="$(printf '%s/actas.T__bob.session' "$(_actas_lock_dir)")"
  [ "$p" != "$legacy" ]
  refute test -e "$p"
}

@test "#1023: a rename does not move an id-keyed lock (the #1017 side-benefit)" {
  # member_id is stable across a rename; the path is derived from it, not from
  # the display name, so the SAME file keeps backing the lock across a rename
  # -- unlike the legacy name-keyed path, which would silently start pointing
  # at a different (nonexistent) file the moment the name changed.
  bash "$SKILL_DIR/scripts/join.sh" T carol claude-code /tmp/proj >/dev/null
  local before; before="$(actas_lock_path T carol)"
  echo "sid-me" > "$before"
  bash "$SKILL_DIR/scripts/rename.sh" T carol dana >/dev/null 2>&1 || true
  [ "$(actas_lock_path T dana)" = "$before" ]
  [ "$(cat "$(actas_lock_path T dana)")" = "sid-me" ]
}

@test "#1023: a config.json with no team_id field falls back, does not error" {
  mkdir -p "$SKILL_DIR/teams/notyet"
  printf '{"name":"notyet","agents":{}}' > "$SKILL_DIR/teams/notyet/config.json"
  run actas_lock_path notyet alice
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s/actas.notyet__alice.session' "$(_actas_lock_dir)")" ]
}

@test "#1023: corrupt team config.json falls back, does not error or hang" {
  mkdir -p "$SKILL_DIR/teams/broken"
  printf 'not json at all {{{' > "$SKILL_DIR/teams/broken/config.json"
  run actas_lock_path broken alice
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s/actas.broken__alice.session' "$(_actas_lock_dir)")" ]
}
