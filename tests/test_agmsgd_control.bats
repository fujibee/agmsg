#!/usr/bin/env bats

@test "agmsgd control: hello/stop/status framing, protocol/role/duplicate-key rejection, frame ceiling" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_control.test.mjs"
  [ "$status" -eq 0 ]
}
