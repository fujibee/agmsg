#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "rearm.sh pokes every claude-code monitor/both seat in the team regardless of project, deduplicated by member name, and names every skipped row's reason" {
  local proj_a="$BATS_TEST_TMPDIR/proj-a" proj_b="$BATS_TEST_TMPDIR/proj-b"
  mkdir -p "$proj_a" "$proj_b"

  # Two distinct claude-code seats in one project -- delivery mode is a
  # (type, project) setting, not per-agent, so both inherit whatever
  # claude-code is set to in proj_a; this also exercises the dedup path
  # being a no-op for two genuinely distinct members, not just for repeated
  # rows of the same one.
  bash "$SCRIPTS/join.sh" fleet alice claude-code "$proj_a"
  bash "$SCRIPTS/join.sh" fleet bob claude-code "$proj_a"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$proj_a" >/dev/null

  # Same project, codex -- excluded by TYPE, never by project.
  bash "$SCRIPTS/join.sh" fleet dave codex "$proj_a"
  bash "$SCRIPTS/delivery.sh" set monitor codex "$proj_a" >/dev/null

  # claude-code, a DIFFERENT project than the caller's own (#1321, maintainer's
  # ruling): rearm covers the WHOLE team, so this seat must be poked too, not
  # skipped as "a different project" -- the project predicate a prior review
  # (#1315) added without asking the maintainer first, since removed.
  bash "$SCRIPTS/join.sh" fleet frank claude-code "$proj_b"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$proj_b" >/dev/null

  # The same member registered in TWO projects -- dedup by member name must
  # poke gina exactly once, not once per registration row.
  bash "$SCRIPTS/join.sh" fleet gina claude-code "$proj_a"
  bash "$SCRIPTS/join.sh" fleet gina claude-code "$proj_b"

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
  grep -q '^frank: refused' <<<"$output"
  grep -q '^gina: refused' <<<"$output"
  [ "$(grep -c '^gina: refused' <<<"$output")" -eq 1 ]
  grep -q "^dave: skipped (not claude-code (type=codex))" <<<"$output"
  grep -qF -- "rearm: 0/4 claude-code monitor/both seat(s) poked in team 'fleet'" <<<"$output"

  # Turn off monitor/both delivery in both projects -- everyone still named,
  # now by delivery reason.
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj_a" >/dev/null
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj_b" >/dev/null
  run bash "$SCRIPTS/rearm.sh" fleet
  [ "$status" -eq 0 ]
  grep -q "^alice: skipped (delivery=turn)" <<<"$output"
  grep -q "^bob: skipped (delivery=turn)" <<<"$output"
  grep -q "^frank: skipped (delivery=turn)" <<<"$output"
  grep -q "^gina: skipped (delivery=turn)" <<<"$output"
  grep -qF -- "rearm: no claude-code seat in team 'fleet' is configured for monitor or both delivery" <<<"$output"
}
