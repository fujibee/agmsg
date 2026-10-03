#!/usr/bin/env bats

@test "agmsgd owner: daemon_owner compare-and-swap lifecycle (take/ready/revert/stop)" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_owner.test.mjs"
  [ "$status" -eq 0 ]
}
