#!/usr/bin/env bats

# The helper 48 absence checks are about to depend on (#670).
#
# If it stops failing, all 48 go quietly green and nothing rings -- which is
# the exact shape this whole issue is about. So both directions are pinned, and
# the assertions are the LAST statement of their bodies: a `[[ ]]` in a
# non-last position would be unenforced on macOS, i.e. this file would step on
# the bug it exists to fix.

load test_helper

@test "refute: passes when the condition does NOT hold" {
  # The everyday direction: the thing that must be absent is absent.
  refute false
}

@test "refute: FAILS when the condition holds" {
  # The direction that matters. Run in a subshell so its failure is data here
  # rather than this test's own death.
  run bash -c '. "$1"; refute true' _ "$BATS_TEST_DIRNAME/test_helper.bash"
  [ "$status" -ne 0 ]
}

@test "refute: says which check fired" {
  run bash -c '. "$1"; refute true' _ "$BATS_TEST_DIRNAME/test_helper.bash"
  printf '%s\n' "$output" | grep -q "unexpectedly succeeded"
}

@test "refute: a real grep, needle present, is caught" {
  printf 'hit\n' > "$BATS_TEST_TMPDIR/f"
  run bash -c '. "$1"; refute grep -q hit "$2"' _ "$BATS_TEST_DIRNAME/test_helper.bash" "$BATS_TEST_TMPDIR/f"
  [ "$status" -ne 0 ]
}

@test "refute: a real grep, needle absent, passes" {
  printf 'hit\n' > "$BATS_TEST_TMPDIR/f"
  refute grep -q miss "$BATS_TEST_TMPDIR/f"
}

@test "refute: does not clobber \$output" {
  # Why this helper exists rather than `run cmd` + status: an absence check
  # must not eat the output a later assertion reads.
  run echo keepme
  refute false
  [ "$output" = keepme ]
}
