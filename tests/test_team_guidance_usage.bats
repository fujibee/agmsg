#!/usr/bin/env bats

# Every place that tells an agent how to reach a teammate (SKILL.md, the
# session-start terminal/team lines, and every rule-file type's generated
# rule) has to match the actual calling convention of team.sh/peek.sh/
# poke.sh/arrange.sh, or the guidance hands out a call that fails on the
# first argument. Caught in review (#1224): the guidance said
# "peek.sh/poke.sh/arrange.sh <name>", but all three require <team> as their
# FIRST positional argument — a call built from that guidance would error out
# immediately. This file pins two things: that the real scripts still
# require <team> first (so a future script-side change is caught here too,
# not only a guidance-side one), and that every guidance source spells the
# same <team> <name> shape next to those script names.

load test_helper

ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# --- pin what the real scripts actually require ---

@test "team.sh's own usage requires <team> as its first argument" {
  grep -qF 'Usage: team.sh <team>' "$ROOT/scripts/team.sh"
}

@test "peek.sh's own usage requires <team> as its first argument" {
  grep -qF 'peek.sh <team>' "$ROOT/scripts/peek.sh"
}

@test "poke.sh's own usage requires <team> <name> as its first two arguments" {
  grep -qF 'poke.sh <team> <name>' "$ROOT/scripts/poke.sh"
}

@test "arrange.sh's own usage requires <team> as its first argument" {
  grep -qF 'Usage: arrange.sh <team>' "$ROOT/scripts/arrange.sh"
}

# --- pin that every guidance source spells the calling convention that way ---

# Flattens a file to one line so a phrase wrapped across source lines (the
# rule-file generators word-wrap their heredocs) still matches a plain
# substring grep the same as a single-line source (SKILL.md, session-start.sh).
_flat() { tr '\n' ' ' < "$1"; }

@test "SKILL.md's teammate-actions guidance uses <team> <name>, not <name> alone" {
  grep -qF 'peek.sh`/`poke.sh`/`arrange.sh <team> <name>' "$ROOT/SKILL.md"
}

@test "session-start.sh's TEAM_LINE uses <team> <name>, not <name> alone" {
  _flat "$ROOT/scripts/session-start.sh" | grep -qF 'peek.sh/poke.sh/arrange.sh <team> <name>'
}

@test "each rule-file generator's teammate-actions text uses <team> <name>, not <name> alone" {
  for f in \
    "$ROOT/scripts/lib/delivery-rulefile.sh" \
    "$ROOT/scripts/drivers/types/antigravity/_delivery.sh" \
    "$ROOT/scripts/drivers/types/opencode/_delivery.sh" \
    "$ROOT/scripts/drivers/types/grok-build/_delivery.sh" \
    "$ROOT/scripts/drivers/types/cursor/_delivery.sh"
  do
    _flat "$f" | grep -qF "'poke.sh' / 'arrange.sh' <team> <name>" \
      || { echo "$f: teammate-actions text does not say <team> <name>" >&2; return 1; }
  done
}
