#!/usr/bin/env bats

@test "agmsgd codex pane fill: a request runs the fill script once, no request runs nothing" {
  run node --test "$BATS_TEST_DIRNAME/agmsgd_codex_pane_fill.test.mjs"
  [ "$status" -eq 0 ]
}
