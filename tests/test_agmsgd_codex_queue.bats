#!/usr/bin/env bats

@test "agmsgd Codex queue support tests" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_codex_queue.test.mjs"
  [ "$status" -eq 0 ]
}
