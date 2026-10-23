#!/usr/bin/env bats

@test "agmsgd executor: bootId is stable, isAlive tells living/dead/wrong-boot apart" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_executor.test.mjs"
  [ "$status" -eq 0 ]
}
