#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "rearm.sh selects only claude-code monitor/both seats registered to the caller's own project, and names every skipped row's reason" {
  local proj_a="$BATS_TEST_TMPDIR/proj-a" proj_b="$BATS_TEST_TMPDIR/proj-b"
  mkdir -p "$proj_a" "$proj_b"

  # In scope: two different claude-code seats sharing the SAME project as
  # the caller. delivery mode is a (type, project) setting, not per-agent,
  # so both alice and bob inherit whatever claude-code is set to in proj_a
  # -- this also exercises the dedup path being a no-op for two genuinely
  # distinct members, not just for repeated rows of the same one.
  bash "$SCRIPTS/join.sh" fleet alice claude-code "$proj_a"
  bash "$SCRIPTS/join.sh" fleet bob claude-code "$proj_a"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$proj_a" >/dev/null

  # Same project as the caller, but codex -- the #1315 review's "even a
  # same-type-shaped delivery in the right project must not cross a type
  # boundary" case, isolated from the project check entirely (dave's project
  # IS proj_a; only his type disqualifies him).
  bash "$SCRIPTS/join.sh" fleet dave codex "$proj_a"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$proj_a" >/dev/null

  # A same-team claude-code seat with a qualifying delivery mode, but
  # registered to a DIFFERENT local project -- the exact bug the review
  # found: the old filter had no project predicate at all and would have
  # poked this seat too.
  bash "$SCRIPTS/join.sh" fleet frank claude-code "$proj_b"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$proj_b" >/dev/null

  # None of these fixture seats has a real placement record, so poke.sh
  # refuses each candidate it is actually asked about -- that failure is
  # exactly what lets this test tell "rearm.sh decided to poke this seat"
  # from "it did not", without needing a real terminal: only a NAMED,
  # refused attempt proves the seat was selected as a candidate at all.
  cd "$proj_a" || return 1
  run bash "$SCRIPTS/rearm.sh" fleet
  [ "$status" -eq 1 ]
  grep -q '^alice: refused' <<<"$output"
  grep -q '^bob: refused' <<<"$output"
  grep -q "^dave: skipped (not claude-code (type=codex))" <<<"$output"
  grep -q "^frank: skipped (registered to a different project ($proj_b))" <<<"$output"
  [[ "$output" =~ "rearm: 0/2 claude-code monitor/both seat(s) poked in team 'fleet' for project '$proj_a'" ]]

  # Same project, same members, but claude-code's own delivery mode in
  # proj_a is no longer monitor/both -- alice and bob must now be reported
  # as skipped, by delivery reason, not silently dropped either.
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj_a" >/dev/null
  run bash "$SCRIPTS/rearm.sh" fleet
  [ "$status" -eq 0 ]
  grep -q "^alice: skipped (delivery=turn)" <<<"$output"
  grep -q "^bob: skipped (delivery=turn)" <<<"$output"
  [[ "$output" =~ "rearm: no claude-code seat registered to '$proj_a' in team 'fleet' is configured for monitor or both delivery" ]]
}
