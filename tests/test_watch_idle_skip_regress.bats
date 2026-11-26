#!/usr/bin/env bats

# #1842 review round 1: integration-level coverage, against a REAL
# running watch.sh, for the three correctness gaps found in the idle skip
# feature's first version:
#
#   1. A broad (unfiltered) watcher serving MULTIPLE pairs of the same team:
#      one pair's clean read must never arm -- or satisfy the safety net
#      for -- a DIFFERENT pair's own checkpoint.
#   2. A message that arrives to an ALREADY-ARMED pair must still be
#      delivered on a later cycle, not swallowed by the checkpoint.
#   3. A cycle that found something pending must not arm; the pair needs a
#      SUBSEQUENT clean read before it is allowed to skip.
#
# The DETERMINISTIC proof that #1's root cause (a per-TEAM checkpoint/clock)
# is actually fixed lives in tests/test_watch_idle_skip_lib.bats, which
# calls lib/watch-idle-skip.sh's own map functions directly and asserts the
# per-PAIR isolation as an invariant, independent of timing. The reviewers'
# own reproduction of the original bug used exactly that approach (an
# isolated fixture around the extracted helpers) rather than a live
# watcher, because the race needs the checkpoint to be touched inside a
# window too narrow to land reliably against a real poll loop and a real
# filesystem clock. The tests below exercise the same three scenarios
# end-to-end anyway, as integration coverage that the fixed design behaves
# correctly in a real running watcher -- not as a red/green reproduction of
# the original, timing-dependent bug.

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watch-idleskip-regress-proj"
}

teardown() {
  teardown_test_env
}

_run_watcher_until() {   # <sid> <out> <needle>, broad (unfiltered) subscription
  local sid="$1" out="$2" needle="$3" pid rc=0
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$out" 2>/dev/null 3>&- 4>&- &
  pid=$!
  wait_for_file_contains "$out" "$needle" || rc=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return "$rc"
}

@test "watch idle-skip: a second pair's PRE-EXISTING unread message is not swallowed by the first pair's checkpoint" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team carol claude-code "$PROJ" >/dev/null

  # alice: seeded and already read, so her pair goes idle immediately.
  bash "$SCRIPTS/send.sh" team bob alice "seed-for-alice" >/dev/null
  bash "$SCRIPTS/inbox.sh" team alice >/dev/null

  # carol: a message sent and left UNREAD *before* the watcher ever starts,
  # so her pair has a genuine backlog from cycle 1 on -- the exact shape a
  # team-wide checkpoint got wrong (round 1): alice's pair is processed
  # first in each cycle's iteration order and, on the OLD per-team design,
  # her own clean read touched a checkpoint carol's pair (next in the same
  # cycle, having never itself been checked) then read as "already
  # confirmed unchanged" and skipped -- even though carol's backlog existed
  # before the watcher's first cycle ever ran.
  bash "$SCRIPTS/send.sh" team bob carol "for-carol" >/dev/null

  local out="$BATS_TEST_TMPDIR/watch.out"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "regress-multi" "$PROJ" claude-code \
    >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  local rc=0
  wait_for_file_contains "$out" "for-carol" || rc=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [ "$rc" -ne 0 ]; then
    echo "carol's pre-existing message never appeared in the watcher's output:" >&3
    cat "$out" >&3
  fi
  [ "$rc" -eq 0 ]
}

@test "watch idle-skip: a message delivered after a pair's checkpoint armed is still seen" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null

  bash "$SCRIPTS/send.sh" team bob alice "seed" >/dev/null
  bash "$SCRIPTS/inbox.sh" team alice >/dev/null

  local out="$BATS_TEST_TMPDIR/watch.out"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "regress-after-arm" "$PROJ" claude-code alice \
    >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  # Let alice's pair go through at least one clean (armable) cycle.
  sleep 3

  bash "$SCRIPTS/send.sh" team bob alice "after-arm" >/dev/null

  local rc=0
  wait_for_file_contains "$out" "after-arm" || rc=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [ "$rc" -ne 0 ]; then
    echo "the post-arm message never appeared:" >&3
    cat "$out" >&3
  fi
  [ "$rc" -eq 0 ]
}

@test "watch idle-skip: a pair with a pending message does not arm on that same cycle" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null

  local out="$BATS_TEST_TMPDIR/watch.out"
  : > "$out"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "regress-no-arm-pending" "$PROJ" claude-code alice \
    >"$out" 2>/dev/null 3>&- 4>&- &
  local pid=$!

  # First message: delivered on whichever cycle first observes it. A cycle
  # that found this pending must not arm -- only confirmed here indirectly,
  # by the SECOND message (sent right after) also being delivered rather
  # than silently absorbed into a checkpoint the first message's own cycle
  # should never have been allowed to set.
  bash "$SCRIPTS/send.sh" team bob alice "first" >/dev/null
  wait_for_file_contains "$out" "first"

  bash "$SCRIPTS/send.sh" team bob alice "second" >/dev/null
  local rc=0
  wait_for_file_contains "$out" "second" || rc=1
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  if [ "$rc" -ne 0 ]; then
    echo "the second message never appeared:" >&3
    cat "$out" >&3
  fi
  [ "$rc" -eq 0 ]
}
