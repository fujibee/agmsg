#!/usr/bin/env bats

# agmsg_shq exists so that a command this tool PRINTS can be pasted and run.
# The values spliced into one -- team names above all -- are validated only
# against empty / '.' / '..' / '/' / '\' / a leading '-' / control characters,
# so a single quote and a space are both legal in a team name. These assert on
# what a shell does with the result, not on how it looks: the failure being
# guarded against is a quoted string ending early and the remainder being read
# as syntax.

setup() {
  SHQUOTE="$BATS_TEST_DIRNAME/../scripts/lib/shquote.sh"
  # shellcheck source=../scripts/lib/shquote.sh
  source "$SHQUOTE"
}

# Round-trips <value> through a shell as a single argument and prints what
# arrived, so a broken quote shows up as the wrong count or the wrong text.
roundtrip() {
  local quoted
  quoted="$(agmsg_shq "$1")"
  eval "printf '%s\n' $quoted"
}

argc() {
  local quoted
  quoted="$(agmsg_shq "$1")"
  eval "set -- $quoted; printf '%s' \"\$#\""
}

@test "shquote: a plain value survives" {
  [ "$(roundtrip "team")" = "team" ]
  [ "$(argc "team")" = "1" ]
}

@test "shquote: a value with spaces stays ONE argument" {
  [ "$(roundtrip "my team")" = "my team" ]
  [ "$(argc "my team")" = "1" ]
}

@test "shquote: a single quote does not end the quoting" {
  [ "$(roundtrip "it's")" = "it's" ]
  [ "$(argc "it's")" = "1" ]
}

@test "shquote: a quote followed by shell syntax is not executed" {
  # The shape that matters: naive '$var' would close the quote and leave
  # `; touch pwned` as a command for the pasting shell.
  local evil="x'; echo PWNED; :'"
  [ "$(roundtrip "$evil")" = "$evil" ]
  [ "$(argc "$evil")" = "1" ]
  [[ "$(roundtrip "$evil")" != *"PWNED"$'\n'* ]]
}

@test "shquote: quotes and spaces together stay one argument" {
  local name="it's a team"
  [ "$(roundtrip "$name")" = "$name" ]
  [ "$(argc "$name")" = "1" ]
}

@test "shquote: naive single-quoting would fail these — the helper is load-bearing" {
  # Pins WHY the helper exists. If someone replaces agmsg_shq with '$var',
  # this is the test that says what breaks.
  local name="it's"
  local naive="'$name'"
  run eval "set -- $naive; printf '%s' \"\$#\""
  # Either the eval fails outright (unterminated quote) or it produces a
  # different argument count than the one correct answer.
  [ "$status" -ne 0 ] || [ "$output" != "1" ]
}
