#!/usr/bin/env bats

@test "agmsgd owner: daemon_owner CAS lifecycle (take/ready/revert/stop) matches arch-7 §1/§2" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_owner.test.mjs"
  [ "$status" -eq 0 ]
}
