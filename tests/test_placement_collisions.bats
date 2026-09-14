#!/usr/bin/env bats
# Record-only layer of the #1144 placement collision report. See the design
# note reached from the issue and the header of scripts/placement-collisions.sh
# for the two-layer contract this file exercises only the first half of.

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# <team> <agent> <ref>
_place() {
  local team="$1" agent="$2" ref="$3"
  bash "$SCRIPTS/join.sh" "$team" "$agent" claude-code /tmp/proj >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '%s\t/tmp/proj\tclaude-code\n' "$ref" > "$TEST_SKILL_DIR/run/spawn.${team}__${agent}"
}

@test "reports a canonical tmux collision between two distinct seats (#1144)" {
  _place alpha alice tmux:/tmp/sockA:%3
  _place beta bob tmux:/tmp/sockA:%3

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "Placement collisions (record-only):" <<< "$output"
  grep -Fq "ref: tmux:/tmp/sockA:%3" <<< "$output"
  grep -Fq -- "- alpha/alice" <<< "$output"
  grep -Fq -- "- beta/bob" <<< "$output"
  grep -Fq "collisions: 1" <<< "$output"
  grep -Fq "unscoped_records: 0" <<< "$output"
  grep -Fq "coverage: complete" <<< "$output"
}

@test "two different tmux instances sharing a bare pane number are not joined (#1144)" {
  _place alpha alice tmux:/tmp/sockA:%3
  _place beta bob tmux:/tmp/sockB:%3

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  refute grep -Fq "collisions: 1" <<< "$output"
  grep -Fq "collisions: none" <<< "$output"
}

@test "herdr refs are never joined as a collision, even when the raw id repeats (#1144)" {
  _place alpha alice herdr:w1:p9
  _place beta bob herdr:w1:p9

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  # The whole point: a bare herdr id is not an address (#1155). Record-only
  # evidence cannot tell two live instances apart, so this must never read as
  # a proven collision.
  refute grep -Fq "collisions: 1" <<< "$output"
  grep -Fq "collisions: none" <<< "$output"
  grep -Fq "unscoped_records: 2" <<< "$output"
  grep -Fq "ref: herdr:w1:p9" <<< "$output"
  grep -Fq -- "- alpha/alice" <<< "$output"
  grep -Fq -- "- beta/bob" <<< "$output"
}

@test "a legacy bare tmux ref with no socket is unscoped, not joined (#1144)" {
  _place alpha alice %3
  _place beta bob %3

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: none" <<< "$output"
  grep -Fq "unscoped_records: 2" <<< "$output"
}

@test "the same agent name registered in two teams is one seat, not a collision (#1144)" {
  _place alpha alice tmux:/tmp/sockA:%3
  _place beta alice tmux:/tmp/sockA:%3

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: none" <<< "$output"
  grep -Fq "unscoped_records: 0" <<< "$output"
}

@test "a plain ref (no addressable pane) is neither a collision nor unscoped (#1144)" {
  _place alpha alice plain:-
  _place beta bob plain:-

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: none" <<< "$output"
  grep -Fq "unscoped_records: 0" <<< "$output"
  grep -Fq "coverage: complete" <<< "$output"
}

@test "no teams directory at all is not_attempted, not none (#1144)" {
  rm -rf "$TEST_SKILL_DIR/teams"

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: not_attempted" <<< "$output"
  grep -Fq "reason: no teams directory" <<< "$output"
  refute grep -Fq "collisions: none" <<< "$output"
}

@test "an empty teams directory is a fully observed empty answer (#1144)" {
  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: none" <<< "$output"
  grep -Fq "coverage: complete" <<< "$output"
}

@test "rejects arguments rather than implying a repair scope (#1144)" {
  run bash "$SCRIPTS/placement-collisions.sh" alpha
  [ "$status" -eq 2 ]
  grep -Fq "Usage: placement-collisions.sh" <<< "$output"
}

# --- negative controls: an unreadable path must never read as "none" -------
#
# Each of these forces one of the walk's failure branches and asserts the
# output says WHY it is empty, distinctly from a genuinely observed empty
# answer. Removing the corresponding counting in placement-collisions.sh
# (reverting to a bare `continue`) makes each of these red: the coverage
# line and its named category would silently disappear and "collisions:
# none" would come back instead of "none_observed".

@test "control: a team config whose agents cannot be enumerated is coverage:partial, not none (#1144)" {
  _place alpha alice tmux:/tmp/sockA:%3
  # Malformed JSON: the sqlite3 json_each extraction genuinely errors, rather
  # than the file merely being absent.
  mkdir -p "$TEST_SKILL_DIR/teams/broken"
  printf '{ this is not json' > "$TEST_SKILL_DIR/teams/broken/config.json"

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  refute grep -Fq "collisions: none$" <<< "$output"
  grep -Fq "collisions: none_observed" <<< "$output"
  grep -Fq "coverage: partial" <<< "$output"
  grep -Fq "agent_enumeration_failed: 1 (broken)" <<< "$output"
}

@test "control: a path-resolution failure for one agent is coverage:partial, not none (#1144)" {
  bash "$SCRIPTS/join.sh" alpha alice claude-code /tmp/proj >/dev/null
  # Force agmsg_spawn_path to fail for exactly this agent, the way a future
  # caller's own bug would -- proving the walk surfaces it instead of quietly
  # treating alice as "never placed".
  cat >> "$TEST_SKILL_DIR/scripts/lib/actas-lock.sh" <<'OVERRIDE'
agmsg_spawn_path() {
  [ "$2" = alice ] && return 1
  printf '%s/run/spawn.%s__%s' "$SKILL_DIR" "$1" "$2"
}
OVERRIDE

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: none_observed" <<< "$output"
  grep -Fq "coverage: partial" <<< "$output"
  grep -Fq "path_resolution_failed: 1 (alpha/alice)" <<< "$output"
}

@test "control: an unreadable placement record is coverage:partial, not none (#1144)" {
  bash "$SCRIPTS/join.sh" alpha alice claude-code /tmp/proj >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  : > "$TEST_SKILL_DIR/run/spawn.alpha__alice"   # present, but empty: read fails

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: none_observed" <<< "$output"
  grep -Fq "coverage: partial" <<< "$output"
  grep -Fq "record_unreadable: 1 (alpha/alice)" <<< "$output"
}

@test "control: a record with an empty ref field is coverage:partial, not none (#1144)" {
  bash "$SCRIPTS/join.sh" alpha alice claude-code /tmp/proj >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '\t/tmp/proj\tclaude-code\n' > "$TEST_SKILL_DIR/run/spawn.alpha__alice"

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: none_observed" <<< "$output"
  grep -Fq "coverage: partial" <<< "$output"
  grep -Fq "empty_ref: 1 (alpha/alice)" <<< "$output"
}

@test "a coverage gap does not suppress a collision found alongside it (#1144)" {
  _place alpha alice tmux:/tmp/sockA:%3
  _place beta bob tmux:/tmp/sockA:%3
  mkdir -p "$TEST_SKILL_DIR/teams/broken"
  printf '{ this is not json' > "$TEST_SKILL_DIR/teams/broken/config.json"

  run bash "$SCRIPTS/placement-collisions.sh"
  [ "$status" -eq 0 ]
  grep -Fq "collisions: 1" <<< "$output"
  grep -Fq "ref: tmux:/tmp/sockA:%3" <<< "$output"
  grep -Fq "coverage: partial" <<< "$output"
  grep -Fq "agent_enumeration_failed: 1 (broken)" <<< "$output"
}
