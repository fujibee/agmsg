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

@test "mark: fixed shape, fixed length, and only the safe alphabet (#1152)" {
  run agmsg_self_mark
  [ "$status" -eq 0 ]
  # prefix + exactly the digest width. A mark trimmed to fit a pane is a mark
  # with less entropy, and entropy is the only thing between "my output" and
  # "someone typed it" -- so the length is pinned here rather than left to fit.
  [ "${output#agmsg-self-}" != "$output" ]
  [ "${#output}" -eq $(( ${#_AGMSG_SELF_MARK_PREFIX} + _AGMSG_SELF_MARK_DIGEST_CHARS )) ]
  # base32 lower, no padding: nothing a terminal folds, nothing a reader splits on.
  printf '%s\n' "${output#agmsg-self-}" | grep -qx '[a-z2-7]\{13\}'
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
  run agmsg_self_mark_line 'agmsg-self-abcdefghijklm'
  [ "$status" -eq 0 ]
  [ "$output" = 'agmsg-self-abcdefghijklm' ]
}

@test "line: a row that merely CONTAINS the mark is not a match (#1152)" {
  # This is the whole reason the contract is a full-line one. A row that contains
  # the mark is exactly what quoting it produces -- in a message, in a log, in
  # somebody's paste -- and accepting it would make every quote an observation.
  m='agmsg-self-abcdefghijklm'
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
  m='agmsg-self-abcdefghijklm'
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
  m='agmsg-self-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "herdr"$'\t'"w1:p2"$'\t'"something else")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "unique"$'\t'"herdr"$'\t'"w1:p7" ]
}

@test "classify: no pane carried it -> not_observed (#1152)" {
  m='agmsg-self-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"nope" "herdr"$'\t'"w1:p2"$'\t'"also nope")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "not_observed" ]
}

@test "classify: two panes carried it -> ambiguous, and neither is named (#1152)" {
  # Naming one would be choosing between panes, one of which is somebody else's
  # -- the failure the whole design exists to stop, re-introduced in the matcher.
  m='agmsg-self-abcdefghijklm'
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
  m='agmsg-self-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "!"$'\t'"herdr"$'\t'"w1:p2")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "classify: an unreadable pane with NO hit is still unreadable, not not_observed (#1152)" {
  # The other direction of the same fold: "we could not look there" must not be
  # reported as "it is not there".
  m='agmsg-self-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"nope" "!"$'\t'"herdr"$'\t'"w1:p2")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "unreadable" ]
}

@test "classify: the same pane on several rows is ONE pane (#1152)" {
  m='agmsg-self-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "herdr"$'\t'"w1:p7"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "unique"$'\t'"herdr"$'\t'"w1:p7" ]
}

@test "classify: the same pane id on DIFFERENT terminals is two panes (#1152)" {
  # A pane id is not unique across servers (#1051), so the terminal is part of
  # the identity here too.
  m='agmsg-self-abcdefghijklm'
  f="$(_obs "herdr"$'\t'"w1:p7"$'\t'"$m" "tmux"$'\t'"w1:p7"$'\t'"$m")"
  run agmsg_self_classify "$m" "$f"
  [ "$status" -eq 1 ]
  [ "$output" = "ambiguous" ]
}

@test "classify: an observation file that cannot be read is unreadable, not empty (#1152)" {
  m='agmsg-self-abcdefghijklm'
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
