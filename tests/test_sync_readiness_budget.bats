#!/usr/bin/env bats

# The readiness poll's ceiling, and the seam that lets the suites skip it (#831).
#
# WHY THE SEAM EXISTS. Reaching `sync start`'s give-up path means waiting out the
# poll, and five regression cases were doing that at the shipped 1600 turns:
# 12 minutes 24 seconds of a macOS CI shard whose job cap is 25, measured from
# the gaps between consecutive `ok` lines on a run that was cancelled for
# exceeding it. None of those five is about the length of the wait; each needs
# only a state where readiness never arrives, which 40 turns produces just as
# well.
#
# WHAT MUST NOT MOVE is the shipped number, and that is what this file pins --
# separately from the suites that use the seam, so that lowering the default
# reddens something even if every one of those suites is passing.

load test_helper

setup() { setup_test_env; export SKILL_DIR="$TEST_SKILL_DIR"; }
teardown() { teardown_test_env; }

ask_turns() {
  cat > "$TEST_SKILL_DIR/turns.sh" <<'EOF_TURNS'
#!/usr/bin/env bash
. "$SCRIPTS/remote.sh"
printf 'turns=%s\n' "$(_remote_sync_ready_turns)"
EOF_TURNS
}

@test "the shipped readiness ceiling is 1600 turns (#831)" {
  # The number itself, asked for rather than run. Bound by letting the poll reach
  # the ceiling it cost 52 seconds in one case; this costs milliseconds and holds
  # the same fact.
  ask_turns
  run env SCRIPTS="$SCRIPTS" bash "$TEST_SKILL_DIR/turns.sh"
  [ "$status" -eq 0 ]
  grep -qF 'turns=1600' <<<"$output"
}

@test "the seam is honoured when it is set (#831)" {
  # THE NEGATIVE CONTROL FOR THE CASE ABOVE. Without it, a resolver that ignored
  # the variable and always answered 1600 would satisfy the shipped-default test
  # while silently putting every suite that sets the seam back on the full
  # ceiling -- which is the CI failure this change exists to remove, restored
  # invisibly.
  ask_turns
  run env SCRIPTS="$SCRIPTS" AGMSG_TEST_SYNC_READY_TURNS=40 bash "$TEST_SKILL_DIR/turns.sh"
  grep -qF 'turns=40' <<<"$output"
}

@test "a value that is not a count falls back to shipped, not to zero (#831)" {
  # A ceiling of zero would end the poll before it began: every `sync start`
  # would report failure instantly, and the suites would still be green because
  # they are asserting on the give-up path. Asserted for three shapes, because
  # they reach the fallback down different comparisons.
  ask_turns
  for bad in oops -5 12x; do
    run env SCRIPTS="$SCRIPTS" AGMSG_TEST_SYNC_READY_TURNS="$bad" bash "$TEST_SKILL_DIR/turns.sh"
    grep -qF 'turns=1600' <<<"$output"
  done
}

@test "an unset seam and an empty seam agree (#831)" {
  # `export FOO=` is not the same shape as never exporting it, and a case split
  # on `-n`/`-z` can tell them apart. Both must mean shipped.
  ask_turns
  run env SCRIPTS="$SCRIPTS" AGMSG_TEST_SYNC_READY_TURNS= bash "$TEST_SKILL_DIR/turns.sh"
  grep -qF 'turns=1600' <<<"$output"
}
