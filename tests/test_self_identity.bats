#!/usr/bin/env bats

# The PURE half of a seat deriving its own pane (#1152).
#
# Everything here runs without a terminal. That is the point: this file holds
# the mark, the line contract and the classifier, and none of them may acquire a
# candidate, read a pane, or choose a location. If a test in here ever needs a
# fake terminal, something has crossed back over the line.

setup() {
  load 'test_helper'
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/hash.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-identity.sh"
}
teardown() { teardown_test_env; }

# --- the mark ------------------------------------------------------------------

@test "mark: the agreed shape -- 17 characters, agp- plus base32 13 (#1152)" {
  run agmsg_self_mark
  [ "$status" -eq 0 ]
  # The TOTAL length is asserted, not the length relative to whatever prefix the
  # implementation happens to use. An earlier revision asserted the relative form
  # and therefore fixed a 24-character mark as correct (found in review) -- a
  # test written against the implementation instead of the contract.
  [ "${#output}" -eq 17 ]
  [ "${output#agp-}" != "$output" ]
  printf '%s\n' "${output#agp-}" | grep -qx '[a-z2-7]\{13\}'
}

@test "mark: a short or missing entropy read is a refusal, not a weaker mark (#1152)" {
  # The group pipeline in the first revision swallowed a failed or short
  # /dev/urandom read and issued a mark from the pid and the clock alone -- and a
  # hash does not add entropy to what it is given. A mark with less entropy than
  # intended is worse than no mark, because it still looks like one.
  short() { printf 'abc'; }
  head() { short; }
  run agmsg_self_mark
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "mark: two calls do not collide (#1152)" {
  # Not a proof of entropy -- a collision here would be one, and its absence is
  # only the cheapest control. The width is what carries the claim.
  a="$(agmsg_self_mark)"; b="$(agmsg_self_mark)"
  [ -n "$a" ] && [ -n "$b" ]
  [ "$a" != "$b" ]
}

@test "mark: nothing a caller passes can steer it (#1152)" {
  # A caller-supplied seed would let the caller predict or replay the mark, which
  # is the same hole as transmitting it. The function takes no arguments, and
  # passing some changes nothing.
  a="$(agmsg_self_mark some-seed 12345)"
  b="$(agmsg_self_mark some-seed 12345)"
  [ "$a" != "$b" ]
}

# --- the line contract ---------------------------------------------------------

@test "line: the emitted line is the mark and nothing else (#1152)" {
  run agmsg_self_mark_line 'agp-abcdefghijklm'
  [ "$status" -eq 0 ]
  [ "$output" = 'agp-abcdefghijklm' ]
}

@test "grammar: anything that is not exactly a mark is refused everywhere (#1152)" {
  # Every boundary validates the grammar. A function that accepts "any non-empty
  # string" accepts a newline, a row of spaces, or somebody else's token, and
  # then every later comparison is against something that was never a mark.
  for bad in '' 'agp-' 'agp-SHORT' 'agp-abcdefghijklmn' 'agp-abcdefghijkl1' \
             'xyz-abcdefghijklm' 'agp-abcdefghijkl ' "agp-abcdefghijklm$(printf '\n')x"; do
    if agmsg_self_mark_line "$bad" >/dev/null 2>&1; then
      echo "mark_line accepted: [$bad]"; return 1
    fi
    if _agmsg_self_line_is_mark "$bad" "$bad" 2>/dev/null; then
      echo "line_is_mark accepted: [$bad]"; return 1
    fi
  done
  # And the valid one still passes, so the loop above is not vacuous.
  agmsg_self_mark_line 'agp-abcdefghijklm' >/dev/null
}

@test "line: a row that merely CONTAINS the mark is not a match (#1152)" {
  # This is the whole reason the contract is a full-line one. A row that contains
  # the mark is exactly what quoting it produces -- in a message, in a log, in
  # somebody's paste -- and accepting it would make every quote an observation.
  m='agp-abcdefghijklm'
  _agmsg_self_line_is_mark "$m" "$m"
  if _agmsg_self_line_is_mark "see $m here" "$m"; then
    echo "a containing row matched"; return 1
  fi
  if _agmsg_self_line_is_mark "$m trailing" "$m"; then
    echo "a trailing row matched"; return 1
  fi
  if _agmsg_self_line_is_mark "  $m" "$m"; then
    echo "an indented row matched"; return 1
  fi
}

@test "line: a trailing CR is normalised, and nothing else is (#1152)" {
  m='agp-abcdefghijklm'
  _agmsg_self_line_is_mark "$m$(printf '\r')" "$m"
  # A tab is not whitespace to be trimmed: the observation format is
  # tab-separated, so a mark with a tab in the row is a different row.
  if _agmsg_self_line_is_mark "$m$(printf '\t')" "$m"; then
    echo "a trailing tab was trimmed"; return 1
  fi
}

# --- the classifier ------------------------------------------------------------

_obs() {   # write an observation file from the lines given
  local f="$BATS_TEST_TMPDIR/obs.$RANDOM"
  printf '%s\n' "$@" > "$f"
  printf '%s' "$f"
}

@test "classify: exactly one pane carried it -> unique, with the pane as witness (#1152)" {
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "herdr"$'\t'"w1:p2"$'\t'"something else")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "unique"$'\t'"herdr"$'\t'"w1:p7" ]
}

@test "classify: no pane carried it -> not_observed (#1152)" {
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"nope" "herdr"$'\t'"w1:p2"$'\t'"also nope")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "not_observed" ]
}

@test "classify: two panes carried it -> ambiguous, and neither is named (#1152)" {
  # Naming one would be choosing between panes, one of which is somebody else's
  # -- the failure the whole design exists to stop, re-introduced in the matcher.
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "herdr"$'\t'"w1:p2"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "ambiguous" ]
  if printf '%s\n' "$output" | grep -q 'w1:p'; then
    echo "a pane was named in an ambiguous answer: $output"; return 1
  fi
}

@test "classify: one hit PLUS an unreadable pane -> unreadable, not unique (#1152)" {
  # The control that keeps the whole thing honest. "Exactly one" is a claim about
  # every pane; a pane nobody could open is a gap in that claim, so the hit we
  # did see does not settle it.
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "!"$'\t'"herdr"$'\t'"w1:p2")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "classify: an unreadable pane with NO hit is still unreadable, not not_observed (#1152)" {
  # The other direction of the same fold: "we could not look there" must not be
  # reported as "it is not there".
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"nope" "!"$'\t'"herdr"$'\t'"w1:p2")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "classify: the same pane on several rows is ONE pane (#1152)" {
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "herdr"$'\t'"w1:p7"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "unique"$'\t'"herdr"$'\t'"w1:p7" ]
}

@test "classify: the same pane id on DIFFERENT terminals is two panes (#1152)" {
  # A pane id is not unique across servers (#1051), so the terminal is part of
  # the identity here too.
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "tmux"$'\t'"w1:p7"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "ambiguous" ]
}

@test "classify: an observation file that cannot be read is unreadable, not empty (#1152)" {
  m='agp-abcdefghijklm'
  run agmsg_self_classify "$m" "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "classify: an empty mark is unreadable, never a match (#1152)" {
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"")"
  run agmsg_self_classify "" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

# --- the line this file must not cross -----------------------------------------

@test "the pure half reaches no terminal and chooses no location (#1152)" {
  # Derived, not typed: the guard is that these names do not appear at all. A
  # candidate, a pane read or a record write in here would be the frozen half
  # wearing a different name.
  local f="$SKILL_DIR/scripts/lib/self-identity.sh" bad=""
  for sym in terminal_peek terminal_team_observe terminal_label_of \
             terminal_find_by_label terminal_name agmsg_terminal_self_env \
             agmsg_terminal_resolve_name agmsg_spawn_path agmsg_write_atomic; do
    if grep -q "$sym" "$f"; then bad="$bad $sym"; fi
  done
  [ -z "$bad" ] || { echo "the pure half references:$bad"; return 1; }
}

@test "classify: a malformed row makes the whole observation unreadable (#1152)" {
  # Skipping the row and counting the rest would report a number over an input
  # we did not understand. A gap in the observation is a gap in the claim.
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "this row has no tabs")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "classify: an unreadable marker with missing fields is unreadable, not skipped (#1152)" {
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "!"$'\t'"herdr")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "classify: a pane id with glob characters does not collide with another (#1152)" {
  # The first revision kept the seen-set as a concatenated string and tested it
  # with a `case` glob, so a pane carrying `*`, `?`, `[` or `;` could swallow a
  # DIFFERENT pair and be counted once -- turning ambiguous into unique, which is
  # the one direction that must never happen (found in review).
  m='agp-abcdefghijklm'
  f="$(_obs "tmux"$'\t'"/tmp/s:%1"$'\t'"$m" "tmux"$'\t'"/tmp/s:%2"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "ambiguous" ]
}

@test "classify: the pair key cannot be made ambiguous by a separator (#1152)" {
  # The control the glob test above does NOT give: joining the two fields with a
  # character that may appear in either makes ("a", "b:c") and ("a:b", "c") the
  # same key, so two distinct panes are counted once -- ambiguous silently
  # becomes unique. Measured: with a ":" join this test reddens and the glob one
  # does not, because awk array keys are exact strings and never globs.
  #
  # HONESTLY: with today's schema the first field is a DRIVER NAME, and no driver
  # is called "a:b", so this exact pair is not something the tree can produce. An
  # earlier version of this comment claimed it was, on the strength of tmux refs
  # carrying a socket -- which is true of the PANE field, not this one. The test
  # stays because the encoding should not depend on that: the pair key is generic
  # and the driver-name set is not this file's to assume.
  m='agp-abcdefghijklm'
  f="$(_obs "a"$'\t'"b:c"$'\t'"$m" "a:b"$'\t'"c"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "ambiguous" ]
}

@test "classify: a row whose TEXT contains tabs is compared whole (#1152)" {
  # The text is everything after the second tab. Truncating at the third would
  # compare a prefix, and a prefix that equals the mark is a row that merely
  # starts with it.
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m"$'\t'"trailing")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "not_observed" ]
}

@test "dependencies: without awk the mark REFUSES rather than weakening (#1152)" {
  # A missing tool must not degrade into a mark that is still shaped like one.
  command() { if [ "${2:-}" = awk ]; then return 1; fi; builtin command "$@"; }
  run agmsg_self_mark
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "dependencies: without awk the classifier says unreadable, never a count (#1152)" {
  m='agp-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m")"
  command() { if [ "${2:-}" = awk ]; then return 1; fi; builtin command "$@"; }
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "mark: a hash that is short or not hex is a refusal (#1152)" {
  # `>= 32` with no alphabet check was not a check: the encoder SKIPS characters
  # that are not hex nibbles, so a truncated or non-hex digest would have made a
  # short-but-plausible mark instead of a refusal.
  agmsg_sha256() { printf 'abc123\n'; }
  run agmsg_self_mark
  [ "$status" -ne 0 ]
  agmsg_sha256() { printf 'zzzz%s\n' "$(printf 'a%.0s' $(seq 1 60))"; }
  run agmsg_self_mark
  [ "$status" -ne 0 ]
}

@test "dependencies: the tools this file needs are the ones it says it needs (#1152)" {
  # The header names its dependency set, and the minimal-PATH contract in
  # registry-lock.sh is what makes that a question at all. Derived, so the
  # statement cannot drift away from the code.
  local f="$SKILL_DIR/scripts/lib/self-identity.sh" found="" t
  for t in awk head od tr date sed cut base32 xxd python3 perl; do
    # Comments are prose: the header NAMES base32 and xxd to explain why they
    # are not used, and a scan that reads prose would report them as used.
    if grep -v '^[[:space:]]*#' "$f" | grep -qE "(^|[^a-zA-Z0-9_])$t([[:space:]]|\\|)" ; then
      found="$found $t"
    fi
  done
  # awk, head, od, tr and date are used and documented -- `date` was missing from
  # both lists in the first version of this test, which is how a test that claims
  # to derive an inventory can still be incomplete (found in review).
  # cut/base32/xxd/sed/python3/perl must NOT appear: each was removed or
  # deliberately never introduced.
  for t in cut base32 xxd sed python3 perl; do
    case " $found " in *" $t "*) echo "undocumented dependency: $t"; return 1 ;; esac
  done
  for t in awk head od tr date; do
    case " $found " in *" $t "*) : ;; *) echo "documented but unused: $t"; return 1 ;; esac
  done
}

@test "dependencies: the two contracts that are not commands are named too (#1152)" {
  # `agmsg_sha256` and /dev/urandom are dependencies as much as any binary, and a
  # tool-name scan does not see them. Both are used, and both have a refusal
  # path; this pins that the header says so.
  local f="$SKILL_DIR/scripts/lib/self-identity.sh"
  grep -q 'agmsg_sha256' "$f"
  grep -q '/dev/urandom' "$f"
  grep -q 'agmsg_sha256' "$f" && grep -q 'urandom' "$f"
  # and the header states them, not only the code
  grep -q '^# .*agmsg_sha256' "$f" || grep -q '^#.*`agmsg_sha256`' "$f"
}

@test "classify: a socket ref with a space is a pane, not a malformed row (#1152)" {
  # The framing check must not narrow the driver's grammar. tmux socket paths
  # carry ordinary spaces -- a home directory with a space in it is normal, and
  # the tmux driver deliberately allows them, rejecting only control bytes. An
  # earlier charset here would have called this row malformed and thrown the
  # whole observation away (found in review).
  m='agp-abcdefghijklm'
  f="$(_obs "tmux"$'\t'"/Users/some one/.tmux/sock:%5"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "unique"$'\t'"tmux"$'\t'"/Users/some one/.tmux/sock:%5" ]
}

@test "classify: a control byte in a field IS malformed (#1152)" {
  # The other direction: framing is still checked, because a field carrying a
  # control byte is a row this format cannot represent.
  m='agp-abcdefghijklm'
  f="$(_obs "tmux"$'\t'"$(printf 'w1\001p7')"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "grammar: the alphabet is written as a SET, checked statically (#1152)" {
  # The behavioural test below can only fail where the hazard exists -- bash 3.2
  # under a UTF-8 locale -- so on bash 5 it passes no matter what the code says.
  # Measured: swapping the set back for a range produced ZERO reds in this
  # suite. A control that cannot go red is not a control, so the property is
  # ALSO pinned statically, which fires on every interpreter.
  local body
  # CODE only. The function's own comment documents the hazard by showing
  # `[a-z]`, and a scan that read comments reported the clean code as defective
  # -- the second time in this file that a derived check read prose (the first
  # was the dependency inventory). Prose is not the thing being checked.
  body="$(awk '/^_agmsg_self_mark_ok\(\)/,/^}/' "$SKILL_DIR/scripts/lib/self-identity.sh" \
          | grep -v '^[[:space:]]*#')"
  [ -n "$body" ] || { echo "could not read the grammar function"; return 1; }
  # A glob RANGE anywhere in the grammar check is the defect: bash 3.2 widens it
  # by collation order under a non-C locale.
  if printf '%s\n' "$body" | grep -qE '\[[^]]*[a-zA-Z0-9]-[a-zA-Z0-9][^]]*\]'; then
    echo "the grammar check uses a glob range:"; printf '%s\n' "$body" | grep -nE '\[[^]]*-[^]]*\]'
    return 1
  fi
  # And the set it does use is the contract's alphabet, entire.
  printf '%s\n' "$body" | grep -qF '[abcdefghijklmnopqrstuvwxyz234567]'
}

@test "grammar: a locale cannot widen the alphabet, behaviourally (#1152)" {
  # Measured: on bash 3.2 (the macOS /bin/bash) under en_US.UTF-8, the glob RANGE
  # [a-z] matches `A` and `é`; the explicit set does not, in any locale, on
  # either shell. So this test is a real check on macOS and a trivially passing
  # one on bash 5 -- the same shape as the #670 table, where a construct is fatal
  # on one interpreter and silent on the other.
  if locale -a 2>/dev/null | grep -qi '^en_US.UTF-8$'; then
    export LC_ALL=en_US.UTF-8
  fi
  for bad in 'agp-Abcdefghijklm' 'agp-abcdefghijklM'; do
    if agmsg_self_mark_line "$bad" >/dev/null 2>&1; then
      echo "mark_line accepted an upper-case letter: [$bad]"; return 1
    fi
    if _agmsg_self_line_is_mark "$bad" "$bad" 2>/dev/null; then
      echo "line_is_mark accepted an upper-case letter: [$bad]"; return 1
    fi
    f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$bad")"
    run agmsg_self_classify "$bad" "$f"
    [ "$status" -eq 1 ]
    [ "$output" = "unreadable" ]
  done
  # The valid mark still passes under the same locale, so the loop is not vacuous.
  agmsg_self_mark_line 'agp-abcdefghijklm' >/dev/null
}
