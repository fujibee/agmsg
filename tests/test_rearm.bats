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
  local proj_a_link="$BATS_TEST_TMPDIR/proj-a-link"
  mkdir -p "$proj_a" "$proj_b"
  ln -s "$proj_a" "$proj_a_link"

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

  # Same real project as the caller, reached through a symlink -- the
  # #1315 review's round-2 finding: a raw pwd/string comparison misses this
  # seat even though it is genuinely the same project. carol joins through
  # proj_a_link, a symlink to proj_a itself, and must still be selected when
  # the caller runs rearm.sh from the canonical proj_a path below.
  bash "$SCRIPTS/join.sh" fleet carol claude-code "$proj_a_link"

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
  grep -q '^carol: refused' <<<"$output"
  grep -q "^dave: skipped (not claude-code (type=codex))" <<<"$output"
  grep -q "^frank: skipped (registered to a different project ($proj_b))" <<<"$output"
  grep -qF -- "rearm: 0/3 claude-code monitor/both seat(s) poked in team 'fleet' for project '$proj_a'" <<<"$output"

  # Same project, same members, but claude-code's own delivery mode in
  # proj_a is no longer monitor/both -- alice, bob and carol must now be
  # reported as skipped, by delivery reason, not silently dropped either.
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$proj_a" >/dev/null
  run bash "$SCRIPTS/rearm.sh" fleet
  [ "$status" -eq 0 ]
  grep -q "^alice: skipped (delivery=turn)" <<<"$output"
  grep -q "^bob: skipped (delivery=turn)" <<<"$output"
  grep -q "^carol: skipped (delivery=turn)" <<<"$output"
  grep -qF -- "rearm: no claude-code seat registered to '$proj_a' in team 'fleet' is configured for monitor or both delivery" <<<"$output"

  # Registry-verification control (#1315 review, round 3): a project with NO
  # claude-code registration at all in this team is refused outright, rather
  # than reported as "found zero monitor/both seats" -- proves PROJECT is
  # checked against the team's own registered claude-code projects instead of
  # trusting agmsg_resolve_project's raw-pwd fallback (which prints pwd and
  # returns 0 even when marker/ancestor/git-common resolution all fail) at
  # face value. Nobody is poked.
  local proj_c="$BATS_TEST_TMPDIR/proj-c"
  mkdir -p "$proj_c"
  cd "$proj_c" || return 1
  run bash "$SCRIPTS/rearm.sh" fleet
  [ "$status" -ne 0 ]
  refute grep -q ': refused' <<<"$output"
  refute grep -q ': ok' <<<"$output"
  grep -q "could not verify '$proj_c' as a registered claude-code project in team 'fleet'" <<<"$output"
}
