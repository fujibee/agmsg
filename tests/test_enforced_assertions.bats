#!/usr/bin/env bats

# The checker that stops the suite growing assertions that cannot fail (#670).
#
# It is a static count, so it can be exercised against a fixture directory
# rather than only against the real tree — which is the difference between a
# guard that has been shown to work and one that has only ever seen a clean
# input.

CHECK="${BATS_TEST_DIRNAME}/../.github/scripts/check-enforced-assertions.sh"
BASELINE="${BATS_TEST_DIRNAME}/../.github/enforced-assertions-baseline"

@test "enforced-assertions: the real tree sits at its baseline" {
  run bash "$CHECK"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q 'at the baseline'
}

@test "enforced-assertions: the baseline is a number, and matches what is there" {
  # Both halves: a baseline that cannot be read is exit 2 below, but a baseline
  # that is readable and WRONG would let the count drift silently.
  n="$(tr -d '[:space:]' < "$BASELINE")"
  case "$n" in ''|*[!0-9]*) echo "baseline is not a number: [$n]" >&2; return 1 ;; esac
  run bash "$CHECK"
  printf '%s\n' "$output" | grep -q -F -- "($n)"
}

@test "enforced-assertions: a new non-last [[ ]] is reported and fails" {
  # macOS-only silence.
  fixture="$BATS_TEST_TMPDIR/t"; mkdir -p "$fixture"
  printf '@test "x" {\n  [[ a == a ]]\n  true\n}\n' > "$fixture/test_x.bats"
  printf '0\n' > "$BATS_TEST_TMPDIR/base"
  run env AGMSG_ASSERTION_BASELINE="$BATS_TEST_TMPDIR/base" bash "$CHECK" "$fixture"
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q '\[\[ \]\]'
}

@test "enforced-assertions: a new non-last ! cmd is reported and fails" {
  # Silent on every platform, which is why it is in the same net.
  fixture="$BATS_TEST_TMPDIR/t2"; mkdir -p "$fixture"
  printf '@test "x" {\n  ! false\n  true\n}\n' > "$fixture/test_x.bats"
  printf '0\n' > "$BATS_TEST_TMPDIR/base"
  run env AGMSG_ASSERTION_BASELINE="$BATS_TEST_TMPDIR/base" bash "$CHECK" "$fixture"
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q 'negated'
}

@test "enforced-assertions: the LAST statement is not reported" {
  # It is the body's exit status, enforced on both shells. Counting it would
  # make the baseline meaningless and the burn-down impossible.
  fixture="$BATS_TEST_TMPDIR/t3"; mkdir -p "$fixture"
  printf '@test "x" {\n  true\n  [[ a == a ]]\n}\n' > "$fixture/test_x.bats"
  printf '0\n' > "$BATS_TEST_TMPDIR/base"
  run env AGMSG_ASSERTION_BASELINE="$BATS_TEST_TMPDIR/base" bash "$CHECK" "$fixture"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q '^check-enforced-assertions: 0 '
}

@test "enforced-assertions: a guarded || is not reported" {
  # Explicit control works on both shells; flagging it would push people away
  # from the idiom that already fixes this.
  fixture="$BATS_TEST_TMPDIR/t4"; mkdir -p "$fixture"
  printf '@test "x" {\n  [[ a == a ]] || return 1\n  true\n}\n' > "$fixture/test_x.bats"
  printf '0\n' > "$BATS_TEST_TMPDIR/base"
  run env AGMSG_ASSERTION_BASELINE="$BATS_TEST_TMPDIR/base" bash "$CHECK" "$fixture"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q '^check-enforced-assertions: 0 '
}

@test "enforced-assertions: a condition inside if is not reported" {
  fixture="$BATS_TEST_TMPDIR/t5"; mkdir -p "$fixture"
  printf '@test "x" {\n  if [[ a == a ]]; then true; fi\n  true\n}\n' > "$fixture/test_x.bats"
  printf '0\n' > "$BATS_TEST_TMPDIR/base"
  run env AGMSG_ASSERTION_BASELINE="$BATS_TEST_TMPDIR/base" bash "$CHECK" "$fixture"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q '^check-enforced-assertions: 0 '
}

@test "enforced-assertions: BELOW the baseline fails, and says to lower it" {
  # The ratchet's whole point, and the branch that was demonstrated by hand but
  # never pinned: deleting it left all the other cases green. A baseline with
  # slack in it after a burn-down is how the next violation arrives silently,
  # so "fewer than expected" is a failure that demands the ceiling come down.
  fixture="$BATS_TEST_TMPDIR/below"; mkdir -p "$fixture"
  printf '@test "x" {\n  [[ a == a ]]\n  true\n}\n' > "$fixture/test_x.bats"
  printf '2\n' > "$BATS_TEST_TMPDIR/base-2"
  run env AGMSG_ASSERTION_BASELINE="$BATS_TEST_TMPDIR/base-2" bash "$CHECK" "$fixture"
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  printf '%s\n' "$output" | grep -q 'below the baseline'
  printf '%s\n' "$output" | grep -q 'Lower the baseline'
  # And it names the number to lower it TO, so the fix is mechanical.
  printf '%s\n' "$output" | grep -q ' to 1'
}

@test "enforced-assertions: scanning nothing is not a pass" {
  # The failure this class is about, applied to the checker itself.
  run bash "$CHECK" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 2 ]
  printf '%s\n' "$output" | grep -q 'not a clean tree'
}
