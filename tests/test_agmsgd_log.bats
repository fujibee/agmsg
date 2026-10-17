#!/usr/bin/env bats

@test "agmsgd log: appends and rotates at 1 MiB, one prior generation kept" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_log.test.mjs"
  [ "$status" -eq 0 ]
}
