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

@test "placement: a watcher does NOT record, in either mode (#1128)" {
  # Narrowed twice in review, and this is where it landed. Being launched FOR a
  # seat says this session acts as it; the pane still comes from the resolver,
  # and when the label path finds nothing the resolver falls back to the
  # environment -- the daemon's pane, for a seat under a shared app-server. A
  # hole filled with the wrong pane is still wrong.
  _join team alice
  rm -f "$SKILL_DIR"/run/spawn.*

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" watch-sid-1128 "$PROJ" claude-code alice \
    >/dev/null 2>&1 3>&- &
  local pid=$!
  sleep 4
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  [ -z "$(_placement team alice)" ]
  # Positive control: it ran and it NAMED, so the absence is a decision.
  grep -q '\[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
}

# --- the inbox read -----------------------------------------------------------

@test "placement: reading the inbox does NOT record (#1128)" {
  # Same reason as the watcher: the turn hook runs in the seat's own pane, but
  # the pane comes from the resolver and can be the shared environment's. The
  # seat's own next ACTION fills the record instead, through lib/self-name.sh,
  # which since #1130 asks the pane whether it carries this seat's label first.
  _join team alice
  rm -f "$SKILL_DIR"/run/spawn.*

  echo '{}' | bash "$SCRIPTS/check-inbox.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ -z "$(_placement team alice)" ]
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

# --- the reservation is atomic, not check-then-act ----------------------------
#
# Raised in review: `[ -f "$rec" ]` followed by a temp+rename is check-then-act.
# Two shells joining the same name at once both see it absent and the later
# rename wins -- the exact two-shell race this mode exists to close. The
# reservation is now one atomic create (`set -C`, so bash opens with O_EXCL).

@test "placement: a rival that arrives inside the window is REFUSED, not clobbered (#1128)" {
  # The deterministic form, at the seam instead of through timing. Eight
  # concurrent joins do NOT catch this: measured, reverting the reservation to
  # `[ -f ] && return` left that test green, because the window is small and
  # whichever writer lands last still leaves one whole value. A race control
  # that cannot fail is not a control.
  #
  # So the rival is placed exactly in the window: after this process has decided
  # the record is absent, before its content is written. The rival follows the
  # same protocol a real second join would -- an exclusive create -- so what is
  # measured is whether OUR side had already taken the file.
  #
  #   reserved first  -> the rival's create fails; it never writes
  #   check-then-act  -> the rival's create succeeds, it writes, and our later
  #                      write lands on top of it
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
  export TMUX="/tmp/s,4242,0" TMUX_PANE="%3"
  local rec; rec="$(agmsg_spawn_path team alice)"
  mkdir -p "$(dirname "$rec")"
  rm -f "$rec"

  local flag="$BATS_TEST_TMPDIR/rival.created"
  eval "_real_write_atomic() $(declare -f agmsg_write_atomic | tail -n +2)"
  agmsg_write_atomic() {
    # A second joiner, arriving now, doing exactly what this code does.
    local had_C=0; case $- in *C*) had_C=1 ;; esac
    set -C
    if : > "$1" 2>/dev/null; then
      : > "$flag"
      printf 'tmux:/tmp/s:%%RIVAL\t/proj/R\tclaude-code\n' > "$1"
    fi
    [ "$had_C" = 1 ] || set +C
    _real_write_atomic "$@"
  }

  agmsg_terminal_name_self "" team alice /proj/A claude-code record_if_unset

  # The rival never got the file. (If it had, our write would have landed on top
  # of it -- silently, which is the whole point.)
  [ ! -f "$flag" ] || { echo "a rival created the record inside the window and was overwritten"; return 1; }
  local r; IFS=$'\t' read -r r _ < "$rec"
  [ "$r" = 'tmux:/tmp/s:%3' ]
}

@test "placement: concurrent first joins leave ONE whole record, not a mixture (#1128)" {
  # Many joins at once, each from a different pane, all with nothing recorded.
  # Exactly one of them may win, the file must hold that one's value whole, and
  # it must not change afterwards.
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null 2>&1
  rm -f "$SKILL_DIR"/run/spawn.team__alice

  local i pids=""
  for i in 1 2 3 4 5 6 7 8; do
    ( export TMUX="/tmp/s,4242,0" TMUX_PANE="%$i"
      bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null 2>&1 ) &
    pids="$pids $!"
  done
  for i in $pids; do wait "$i" 2>/dev/null || true; done

  local got; got="$(_placement team alice)"
  [ -n "$got" ] || { echo "no record was written at all"; return 1; }
  # ONE writer's value, whole. A mixture (a clobbered rename landing on another
  # writer's bytes) would not match any of them.
  case "$got" in
    tmux:/tmp/s:%1|tmux:/tmp/s:%2|tmux:/tmp/s:%3|tmux:/tmp/s:%4|\
    tmux:/tmp/s:%5|tmux:/tmp/s:%6|tmux:/tmp/s:%7|tmux:/tmp/s:%8) : ;;
    *) echo "record is not any single writer's value: '$got'"; return 1 ;;
  esac

  # And the winner stands: a ninth join from yet another pane changes nothing.
  ( export TMUX="/tmp/s,4242,0" TMUX_PANE="%9"
    bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null 2>&1 )
  [ "$(_placement team alice)" = "$got" ]
}

@test "placement: the reservation refuses a record that appears first (#1128)" {
  # The deterministic half of the race, at the seam rather than through timing:
  # the destination exists at reservation time, so the fill declines and the
  # bytes that were there stay there -- byte for byte, because a rewrite that
  # changed only the trailing newline would pass a string comparison.
  _join team alice
  local rec; rec="$(_recpath team alice)"
  printf 'tmux:/tmp/s:%%FIRST\t/proj/F\tclaude-code\n' > "$rec"
  local snap="$BATS_TEST_TMPDIR/first.snapshot"; cp "$rec" "$snap"

  run bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ"
  [ "$status" -eq 0 ]
  cmp -s "$rec" "$snap"
}
