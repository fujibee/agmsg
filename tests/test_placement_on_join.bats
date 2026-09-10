#!/usr/bin/env bats
#
# A seat that has JOINED and never acted must already be reachable (#1128).
#
# `agmsg_terminal_name_self` names the pane always and writes the placement
# record only when its sixth argument is `record`. Three of the six call sites
# did not pass it, and they were the three that matter most for a hand-started
# seat: `join.sh` (the moment the seat becomes addressable) and the two later
# chances to notice a seat that was named without a record -- the watcher
# re-arming and the inbox read. So the seat carried its label and nothing knew
# which pane it was in; `peek` refused with "no placement record".
#
# Why this file exists rather than one more assertion in the naming suites: an
# assertion that the pane WAS NAMED stays green with the record write deleted --
# that is precisely how these three were missed. Each test here asserts the
# RECORD, and then that `peek` reaches the pane through it. Deleting the
# `record` argument from one script reddens that script's test and no other.

setup() {
  load 'test_helper'
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export PROJ="$TEST_SKILL_DIR/project"
  mkdir -p "$PROJ" "$SKILL_DIR/run"
  FAKEBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$FAKEBIN"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"; : > "$ARGV_LOG"
  export FAKEBIN ARGV_LOG
  agmsg_install_fake_tmux
  # A pane of our own to be found in, and the seat is never asked to act.
  export TMUX="/tmp/s,4242,0" TMUX_PANE="%3"
}
teardown() { teardown_test_env; }

# The placement record's ref -- the half peek/poke/despawn resolve through.
_placement() {   # <team> <agent>
  local rec r
  rec="$(bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path "$1" "$2"' _ "$1" "$2")" || return 0
  [ -f "$rec" ] || return 0
  IFS=$'\t' read -r r _ < "$rec" || return 0
  printf '%s' "$r"
}

_recpath() {   # <team> <agent>
  bash -c '. "'"$SKILL_DIR"'/scripts/lib/actas-lock.sh"; agmsg_spawn_path "$1" "$2"' _ "$1" "$2"
}

# Does `peek` reach the pane? Asserted through the real entry point, because the
# record exists to be resolved by it and nothing else proves that end to end.
_peek_reaches() {   # <team> <agent>
  local out
  out="$(bash "$SCRIPTS/peek.sh" "$1" "$2" 2>&1)" || {
    printf '%s' "$out"; return 1
  }
  printf '%s' "$out"
}

_join() { bash "$SCRIPTS/join.sh" "$1" "$2" claude-code "$PROJ" >/dev/null 2>&1; }

# --- join --------------------------------------------------------------------

@test "placement: a seat that joined and never acted is recorded and peek reaches it (#1128)" {
  _join team alice
  # The record, not the name. `_name_calls`-style assertions pass without it.
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]

  run _peek_reaches team alice
  [ "$status" -eq 0 ]
  refute grep -q 'no placement record' <<<"$output"
  # Positive control: peek actually went to the pane, on the record's own server.
  grep -q 'tmux \[-S\] \[/tmp/s\] \[capture-pane\]' "$ARGV_LOG"
}

@test "placement: with no record, peek says exactly that -- the state #1128 left behind (#1128)" {
  # The other direction, so the test above is not passed by "peek always works".
  # A seat registered without ever being named: no record, and peek refuses by
  # name rather than resolving something else.
  _join team alice
  rm -f "$SKILL_DIR"/run/spawn.*
  run _peek_reaches team alice
  [ "$status" -ne 0 ]
  grep -q 'no placement record' <<<"$output"
}

# --- the watcher re-arming ----------------------------------------------------

@test "placement: a watcher launched FOR a seat records that seat (#1128)" {
  # The watcher records only with an actas name, because only then does it know
  # whose pane this is -- see the broad-mode test below, which is the half that
  # keeps this one from being "record whatever you are subscribed to".
  _join team alice
  rm -f "$SKILL_DIR"/run/spawn.*

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" watch-sid-1128 "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local pid=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    [ -n "$(_placement team alice)" ] && break
    sleep 1
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
}

# --- the inbox read -----------------------------------------------------------

@test "placement: reading the inbox records the seat's pane (#1128)" {
  # The second later chance. check-inbox.sh is the turn hook: it runs in the
  # seat's own pane, about itself, so it may speak for its placement.
  _join team alice
  rm -f "$SKILL_DIR"/run/spawn.*

  echo '{}' | bash "$SCRIPTS/check-inbox.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
}

# --- the other direction: one pane cannot be two differently-named seats -------
#
# Raised in review of this change: the watcher serves every pair not held by
# another live session, and "not held" says nothing about where that pair
# actually is. Passing `record` for each of them would write THIS pane as the
# placement of whichever one is reached first.
#
# It does not, and the reason is not in this file: the #1114 placement guard
# refuses a pane another seat's record already claims. What is here is the proof
# that the two changes meet correctly -- each alone is defensible and the seam is
# where it would go wrong.

@test "placement: a second, differently-named seat does not take the first one's pane (#1128)" {
  _join team alice
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]

  # A second seat joins from the SAME pane. It is a different name, so it is not
  # "this seat under another team" and the guard treats it as what it is.
  run bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ"
  [ "$status" -eq 0 ]

  # alice keeps the pane, and bob did not take it.
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
  [ -z "$(_placement team bob)" ]
  # And the refusal named the seat that holds it, rather than failing silently.
  run bash -c "bash '$SCRIPTS/join.sh' team carol claude-code '$PROJ' 2>&1 >/dev/null"
  grep -q 'already recorded as' <<<"$output"
  grep -q 'team__alice' <<<"$output"
}

@test "placement: a BROAD watcher records nothing at all (#1128)" {
  # Raised in review, and the first draft got it wrong. A broad watcher
  # subscribes to every identity of the project that no other live session
  # holds -- which is not the same as every identity that lives HERE. It has no
  # evidence which of them, if any, is in this pane.
  #
  # The first version of this test asked for "exactly one record" on the theory
  # that the #1114 placement guard refuses the second. That limits an arbitrary
  # false placement to one; it does not prevent it. The contract is zero: a
  # process that cannot say whose pane this is does not get to say.
  _join team alice
  _join team bob
  rm -f "$SKILL_DIR"/run/spawn.*

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" watch-sid-broad "$PROJ" claude-code \
    >/dev/null 2>&1 3>&- &
  local pid=$!
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # Nothing recorded, for either of them.
  [ -z "$(_placement team alice)" ]
  [ -z "$(_placement team bob)" ]
  # Positive control: the watcher DID run and DID name, so the absence above is
  # a decision and not a watcher that never started.
  grep -q '\[@agmsg_agent\]' "$ARGV_LOG"
}

@test "placement: join does not overwrite an existing record, whoever wrote it (#1128)" {
  # The other half of "join fills the hole". join runs BEFORE actas-claim and
  # neither takes nor reads the exclusivity lock -- measured, no lock symbol
  # appears in join.sh -- so two shells can join one name from two panes, and
  # the loser's `actas` fails with status=held only after an unconditional
  # record would already have moved the placement to the loser's pane.
  #
  # So an existing record stands, whatever it says. Repairing a wrong one
  # belongs to the paths that check the LABEL first (#1130 on action, and
  # `team --fix`); this one cannot check it.
  _join team alice
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]

  printf 'tmux:/tmp/s:%%OTHER\t/proj/X\tclaude-code\n' > "$(_recpath team alice)"
  : > "$ARGV_LOG"

  run bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ"
  [ "$status" -eq 0 ]

  [ "$(_placement team alice)" = 'tmux:/tmp/s:%OTHER' ]
  # Positive control: join ran and NAMED the pane, so the record standing still
  # is a decision and not a join that did nothing.
  grep -q '\[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
}

@test "placement: join DOES write when there is no record (#1128 control)" {
  # The partner. "Never record from join" also passes the test above, and it is
  # exactly the state #1128 exists to end.
  _join team alice
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
  rm -f "$SKILL_DIR"/run/spawn.team__alice

  run bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ"
  [ "$status" -eq 0 ]
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
}
