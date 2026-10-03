#!/usr/bin/env bats

@test "agmsgd main: startup/pollOnce/gracefulStop wire owner+control+lifecycle+log correctly" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_main.test.mjs"
  [ "$status" -eq 0 ]
}
