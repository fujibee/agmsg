#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "rearm.sh pokes only claude-code seats with monitor or both delivery, never turn/off or another type" {
  # Six seats, one of each combination that matters: a claude-code monitor
  # seat and a claude-code both seat must be selected; a claude-code turn
  # seat, a claude-code off seat, and a codex seat (even one set to
  # "monitor", since that type has no Monitor tool to re-arm) must not be.
  local proj_a="$BATS_TEST_TMPDIR/alice" proj_b="$BATS_TEST_TMPDIR/bob"
  local proj_c="$BATS_TEST_TMPDIR/carol" proj_d="$BATS_TEST_TMPDIR/dave"
  local proj_e="$BATS_TEST_TMPDIR/erin"
  mkdir -p "$proj_a" "$proj_b" "$proj_c" "$proj_d" "$proj_e"
  bash "$SCRIPTS/join.sh" fleet alice claude-code "$proj_a"
  bash "$SCRIPTS/join.sh" fleet bob claude-code "$proj_b"
  bash "$SCRIPTS/join.sh" fleet carol claude-code "$proj_c"
  bash "$SCRIPTS/join.sh" fleet dave claude-code "$proj_d"
  bash "$SCRIPTS/join.sh" fleet erin codex "$proj_e"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$proj_a" >/dev/null
  bash "$SCRIPTS/delivery.sh" set both claude-code "$proj_b" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj_c" >/dev/null
  bash "$SCRIPTS/delivery.sh" set off claude-code "$proj_d" >/dev/null
  # codex supports its own "monitor" mode (its bridge, not Claude Code's
  # Monitor tool) -- erin genuinely reports delivery=monitor here, so this
  # is the real discriminator for the type filter, not merely an absent one.
  bash "$SCRIPTS/delivery.sh" set monitor codex "$proj_e" >/dev/null

  # None of these fixture seats has a real placement record, so poke.sh
  # refuses each one it is asked about -- that failure is exactly what lets
  # this test tell "rearm.sh decided to poke this seat" from "it did not",
  # without needing a real terminal: only a NAMED, refused attempt proves
  # the seat was selected at all.
  run bash "$SCRIPTS/rearm.sh" fleet
  [ "$status" -eq 1 ]
  grep -q '^alice: ' <<<"$output"
  grep -q '^bob: ' <<<"$output"
  refute grep -q '^carol: ' <<<"$output"
  refute grep -q '^dave: ' <<<"$output"
  refute grep -q '^erin: ' <<<"$output"
  [[ "$output" =~ "rearm: 0/2 claude-code monitor/both seat(s) poked in team 'fleet'" ]]
}
