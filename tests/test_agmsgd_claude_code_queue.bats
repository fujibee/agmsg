#!/usr/bin/env bats

@test "agmsgd Claude Code queue support tests" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_claude_code_queue.test.mjs"
  [ "$status" -eq 0 ]
}
