#!/usr/bin/env bats

# The lock is a mkdir. mkdir fails for more than one reason, and only one of
# them ever clears on its own — so the failure the operator is shown has to say
# which one it was.
#
# From the field: a second machine running as a different OS account pointed at
# the first one's store. The team directory was 0755 and owned by the other
# user, so mkdir could never succeed. The message said "timed out acquiring
# registry lock", which sent three separate diagnoses after processes — a sync
# engine was killed for it — while the cause sat in the directory's mode the
# whole time.

load test_helper

setup() {
  setup_test_env
  LOCKLIB="$SCRIPTS/lib/registry-lock.sh"
  TEAM_DIR="$BATS_TEST_TMPDIR/teams/someteam"
  mkdir -p "$TEAM_DIR"
}

teardown() {
  # Restore before the harness cleans up, or the tree cannot be removed.
  chmod u+w "$TEAM_DIR" 2>/dev/null || true
  teardown_test_env
}

acquire() {  # runs the acquire in its own shell, with a short spin budget
  run env AGMSG_LOCK_TRIES="${TRIES:-5}" LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR"
  '
}

@test "lock: a held lock is contention — it waits, then reports a timeout" {
  # The reason the spin exists. Nothing here should change.
  mkdir "$TEAM_DIR/.config.lock"
  acquire
  [ "$status" -ne 0 ]
  [[ "$output" == *"timed out acquiring registry lock"* ]]
  # And must NOT blame permissions: this directory is perfectly writable.
  [[ "$output" != *"cannot be written to"* ]]
}

@test "lock: an unwritable team dir fails immediately and names the cause" {
  if [ "$(id -u)" = "0" ]; then
    skip "root ignores the mode bits this is about"
  fi
  # No lock directory exists — nothing is holding anything. mkdir still cannot
  # succeed, and no amount of waiting changes that.
  chmod a-w "$TEAM_DIR"
  [ ! -e "$TEAM_DIR/.config.lock" ]

  # A budget large enough that the old code visibly waits (~2s) and small
  # enough that a regression FAILS rather than hanging CI. The first draft used
  # 100000 to make the wait unmistakable and instead sat for ten minutes: a
  # regression must be reported, not survived.
  TRIES=200 acquire
  [ "$status" -ne 0 ]

  # Fast-fail, asserted by what it did NOT say rather than by a clock. The old
  # code reaches the budget and says "timed out"; this path never enters the
  # spin at all. Timing assertions are flaky; this one is exact.
  [[ "$output" != *"timed out"* ]]

  # And it says what is actually wrong, in terms someone can act on.
  [[ "$output" == *"cannot create the registry lock"* ]]
  [[ "$output" == *"waiting will not clear it"* ]]
  [[ "$output" == *"mkdir:"* ]]
  # The evidence: who owns it, and who we are.
  [[ "$output" == *"running as:"* ]]
  [[ "$output" == *"uid="* ]]
}

@test "lock: the timeout carries the mkdir error too" {
  # Even on the path this function did not anticipate, the errno is not thrown
  # away. `2>/dev/null` discarding it is what left the field with one sentence
  # and no cause.
  mkdir "$TEAM_DIR/.config.lock"
  acquire
  [ "$status" -ne 0 ]
  [[ "$output" == *"last mkdir error:"* ]]
  [[ "$output" == *"File exists"* || "$output" == *"exists"* ]]
}

@test "lock: a free, writable team dir is acquired" {
  # The positive control. Without it, a version that failed every acquire
  # would satisfy both failure tests above.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    [ -d "$TEAM_DIR/.config.lock" ] || exit 2
    agmsg_lock_release
    [ ! -d "$TEAM_DIR/.config.lock" ] || exit 3
  '
  [ "$status" -eq 0 ]
}

@test "lock: a held lock names its holder (#778)" {
  # A lock directory with nothing in it says something holds it and nothing
  # about what. When one leaks, that is the difference between "remove this,
  # the process is gone" and guessing — and guessing wrong removes a live lock.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    cat "$TEAM_DIR/.config.lock.holder"
  '
  [ "$status" -eq 0 ]
  grep -qE "^pid [0-9]+$" <<<"$output"
  grep -q "^command " <<<"$output"
}

@test "lock: a lock that cannot be released says so, and the way out works (#778)" {
  # The defect: `rmdir … || true` treated "already gone" and "will not go" as
  # the same event. The second is a permanent leak — every later command for
  # this team waits for a holder that is never coming back — and it was silent.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    printf "x\n" > "$TEAM_DIR/.config.lock/stray"
    agmsg_lock_release
  '
  grep -q "could not release the registry lock" <<<"$output"
  grep -q "commands for this team will wait" <<<"$output"

  # The route it prints has to work on the case that produced it. `rmdir` does
  # not: it is what just failed. Lifted out of the message and run, so the two
  # cannot drift apart.
  local remedy
  remedy="$(grep -oE 'rm -r .*' <<<"$output" | tail -1)"
  [ -n "$remedy" ]
  run bash -c "$remedy"
  [ "$status" -eq 0 ]
  [ ! -d "$TEAM_DIR/.config.lock" ]
}

@test "lock: releasing a lock that is already gone stays quiet (#778)" {
  # The other half of the same distinction. A lock that is already released is
  # not an event, and reporting it would train the operator to ignore the line
  # that matters.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    rm -f "$TEAM_DIR/.config.lock.holder"; rmdir "$TEAM_DIR/.config.lock"
    agmsg_lock_release
  '
  [ "$status" -eq 0 ]
  refute grep -q "could not release" <<<"$output"
}

@test "lock: the wait is budgeted in seconds, and stops at the declared one (#779)" {
  # The old budget was an attempt count with "= ~10s" written beside it. That
  # arithmetic holds only where an mkdir and a sleep are free: measured here,
  # 100 attempts take 3 seconds, not 1 — and the report that raised this saw
  # minutes on Windows. A wait announced in seconds has to be counted in them.
  mkdir -p "$TEAM_DIR/.config.lock"
  local start end
  start="$(date +%s)"
  # TRIES is set to a number that CANNOT be the thing that stops this: measured
  # on this machine, ~100 attempts take 3 seconds, so 300 would run about nine
  # if the wait were counted in iterations. Only the time bound ends it at two.
  # Deliberately not 1000000 — under a mutation that removes the time bound,
  # that number does not fail the test, it hangs the suite, and a check that
  # hangs instead of reddening is a worse check than one that is slow.
  run env AGMSG_LOCK_SECONDS=2 AGMSG_LOCK_TRIES=300 LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR"
  '
  end="$(date +%s)"
  [ "$status" -ne 0 ]
  # Not "roughly": the point of the change is that the number in the message is
  # about the wait. Allow one second of slack for the clock's granularity.
  [ "$((end - start))" -ge 2 ]
  [ "$((end - start))" -le 4 ]
  grep -q "timed out acquiring registry lock" <<<"$output"
  grep -qE "after [0-9]+s" <<<"$output"
}

@test "lock: the attempt ceiling still ends the wait, and says which bound it was (#779)" {
  # Both bounds exist and they are different facts. An operator deciding
  # whether to retry needs the one that actually stopped it — "1000 tries" and
  # "10 seconds" send them to different places.
  mkdir -p "$TEAM_DIR/.config.lock"
  run env AGMSG_LOCK_TRIES=5 AGMSG_LOCK_SECONDS=60 LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR"
  '
  [ "$status" -ne 0 ]
  # Same phrase for both bounds — callers match on it. The clause is what
  # separates them, and an operator deciding whether to retry needs the clause.
  grep -q "timed out acquiring registry lock" <<<"$output"
  grep -qE "after 5 attempts" <<<"$output"
  refute grep -qE "after [0-9]+s$" <<<"$output"
}

@test "lock: release leaves a SUCCESSOR's lock alone (#778)" {
  # The hazard this change created. The remedy printed for a stuck lock tells
  # an operator to remove the directory; another process can then take the same
  # path. Releasing on "I once locked this path" would delete the successor's
  # lock and take mutual exclusion away from a process that is using it —
  # worse than the leak (raised in review).
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    rm -f "$TEAM_DIR/.config.lock.holder"; rmdir "$TEAM_DIR/.config.lock"
    mkdir "$TEAM_DIR/.config.lock"
    printf "token successor-owns-this\n" > "$TEAM_DIR/.config.lock.holder"
    agmsg_lock_release
    [ -d "$TEAM_DIR/.config.lock" ] || exit 2
    grep -q "successor-owns-this" "$TEAM_DIR/.config.lock.holder" || exit 3
  '
  [ "$status" -eq 0 ]
}

@test "lock: the printed remedy is safe on a path with a space (#778)" {
  # A store root or a team name may contain a space — team names are validated
  # against empty / . / .. / / / \ / a leading - / control characters, and
  # nothing else. An unquoted path in a pasted command becomes several
  # arguments, and `rm -r` then removes something the operator never read about.
  local spaced="$BATS_TEST_TMPDIR/with space/team"
  mkdir -p "$spaced" "$BATS_TEST_TMPDIR/with space/DO-NOT-TOUCH"
  run env LOCKLIB="$LOCKLIB" SPACED="$spaced" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$SPACED" || exit 1
    printf "x\n" > "$SPACED/.config.lock/stray"
    agmsg_lock_release
  '
  local remedy
  remedy="$(grep -oE "rm -r .*" <<<"$output" | tail -1)"
  [ -n "$remedy" ]
  # Run it the way it is meant to be run: through a shell, as one pasted line.
  run bash -c "$remedy"
  [ "$status" -eq 0 ]
  [ ! -d "$spaced/.config.lock" ]
  # And it took nothing else with it.
  [ -d "$BATS_TEST_TMPDIR/with space/DO-NOT-TOUCH" ]
}

@test "lock: a process holding TWO locks releases both (#778)" {
  # This library's contract is that a caller can hold several locks at once —
  # rename-team takes two. A single per-process token is overwritten by the
  # second acquire, so releasing the first reads a mismatch, calls it someone
  # else's, and leaks it. Measured before the fix: both leaked (raised in
  # review).
  local a="$BATS_TEST_TMPDIR/A" b="$BATS_TEST_TMPDIR/B"
  mkdir -p "$a" "$b"
  run env LOCKLIB="$LOCKLIB" A="$a" B="$b" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$A" || exit 1
    agmsg_lock_acquire "$B" || exit 1
    agmsg_lock_release
    [ ! -d "$A/.config.lock" ] || exit 2
    [ ! -d "$B/.config.lock" ] || exit 3
  '
  [ "$status" -eq 0 ]
  refute grep -q "not releasing" <<<"$output"
}

@test "lock: a stuck lock keeps saying WHO, not just that it is owned (#778)" {
  # The moment the diagnosis is needed is the moment the removal fails. An
  # earlier version restored only the token line, so pid, command and host —
  # the whole point of writing a holder — disappeared exactly then.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    printf "x\n" > "$TEAM_DIR/.config.lock/stray"
    agmsg_lock_release >/dev/null 2>&1
    cat "$TEAM_DIR/.config.lock.holder"
  '
  [ "$status" -eq 0 ]
  grep -qE "^token " <<<"$output"
  grep -qE "^pid [0-9]+$" <<<"$output"
  grep -q "^command " <<<"$output"
  grep -q "^host " <<<"$output"
}

@test "lock: two locks taken in the same second by the same pid differ (#778)" {
  # Ownership is decided by this token, so a collision means deleting someone
  # else's successor — the hazard the token exists to close. A pid and a second
  # are not unique across hosts on a shared store.
  local a="$BATS_TEST_TMPDIR/T1" b="$BATS_TEST_TMPDIR/T2"
  mkdir -p "$a" "$b"
  run env LOCKLIB="$LOCKLIB" A="$a" B="$b" bash -c '
    . "$LOCKLIB"
    agmsg_lock_acquire "$A" || exit 1
    agmsg_lock_acquire "$B" || exit 1
    sed -n "s/^token //p" "$A/.config.lock.holder" "$B/.config.lock.holder"
  '
  [ "$status" -eq 0 ]
  [ "$(sort -u <<<"$output" | grep -c .)" -eq 2 ]
}

@test "lock: with no entropy source, no token is recorded and nothing is removed (#778)" {
  # Fail-safe means NO token, not a weak one. With neither /dev/urandom nor
  # $RANDOM, what is left is host.pid.second — which collides across hosts, and
  # a collision makes this process delete someone else's successor. So the
  # degraded path records nothing, release finds no match, and the lock leaks
  # rather than being taken from whoever holds it (raised in review).
  local lib="$BATS_TEST_TMPDIR/nolib.sh"
  sed -e 's|^  nonce="\$(LC_ALL=C od.*|  nonce=""|' \
      -e 's|^  \[ -n "\$nonce" \] \|\| nonce=.*|  :|' "$LOCKLIB" > "$lib"
  bash -n "$lib"

  run env LIB="$lib" TEAM_DIR="$TEAM_DIR" bash -c '
    . "$LIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    [ -z "$(sed -n "s/^token //p" "$TEAM_DIR/.config.lock.holder" 2>/dev/null)" ] || exit 2
    agmsg_lock_release
    [ -d "$TEAM_DIR/.config.lock" ] || exit 3
  '
  [ "$status" -eq 0 ]
  # And the refusal names the real reason rather than accusing another process.
  grep -q "cannot prove the lock is its own" <<<"$output"
}

@test "lock: a failed release is clean under set -u (#778)" {
  # The dead `saved` restore was an unbound-variable error waiting for a caller
  # with `set -u`, and every test here ran without it — so the suite could not
  # have caught it. The reviewer found it by reading. This drives the same path
  # with `set -u` on, which is the shape a real caller has.
  run env LOCKLIB="$LOCKLIB" TEAM_DIR="$TEAM_DIR" SNAP="$BATS_TEST_TMPDIR/holder.before" bash -c '
    set -u
    . "$LOCKLIB"
    agmsg_lock_acquire "$TEAM_DIR" || exit 1
    cp "$TEAM_DIR/.config.lock.holder" "$SNAP"
    printf "x\n" > "$TEAM_DIR/.config.lock/stray"
    agmsg_lock_release
  '
  # The release reports the stuck lock and does not abort the caller.
  [ "$status" -eq 0 ]
  grep -q "could not release the registry lock" <<<"$output"
  refute grep -qi "unbound variable" <<<"$output"
  # And the holder is BYTE FOR BYTE what acquire wrote. Checking that `pid` and
  # `command` are present would pass a change that drops `token` or `host`,
  # rewrites a value, reorders the lines, or appends to the file — and the claim
  # being made is that a failed release does not touch it at all (raised in
  # review). The comparison is against a copy taken while the lock was held.
  run diff "$BATS_TEST_TMPDIR/holder.before" "$TEAM_DIR/.config.lock.holder"
  [ "$status" -eq 0 ]
}
