#!/usr/bin/env bats

@test "agmsgd lifecycle: completion-record state, digest/install_id verification, and drift detection" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_lifecycle.test.mjs"
  [ "$status" -eq 0 ]
}
