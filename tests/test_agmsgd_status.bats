#!/usr/bin/env bats

@test "agmsgd status: decision table for daemon_owner/daemon_intent" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_status.test.mjs"
  [ "$status" -eq 0 ]
}
