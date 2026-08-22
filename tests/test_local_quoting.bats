#!/usr/bin/env bats

# #897. The local send/inbox/history/watch path quoted SQL literals by forking
# `printf | sed` at every use site; these are now bash expansions. A speed change
# that alters one quoted byte corrupts rows or opens an injection, so the new
# form is held equal to the old one on the inputs that matter to SQL quoting --
# the same contract tests/test_remote_sync.bats already holds for the sync path.
#
# Run under /bin/bash as well as the suite's own shell, because the two disagree:
# bash 3.2 keeps the backslash of a `\'` REPLACEMENT, so the inline form doubles
# a quote into \'\' there and into '' on bash 4+. That difference is the whole
# reason the quote is held in a variable, and a suite that only ever runs on a
# modern bash cannot see it.

load test_helper

QUOTE_INPUTS=(
  "plain" "it's" "two''quotes" "'leading" "trailing'" "'" "''" ""
  $'line one\nline two' $'tab\there' 'back\slash' "back\\'slash quote"
  '100% $HOME' 'and & ampersand' 'a/b' 'dots...' '$_AGMSG_SQ' '${x//y/z}'
)

# The forking form this replaces, kept here as the reference implementation.
reference_lit() { printf '%s' "$1" | sed "s/'/''/g"; }

@test "local quoting: the builtin form agrees with the forking form it replaces (#897)" {
  . "$BATS_TEST_DIRNAME/../scripts/drivers/storage/sqlite.sh"
  local input expected actual
  for input in "${QUOTE_INPUTS[@]}"; do
    expected="$(reference_lit "$input")"
    actual="$(_sqlite_lit "$input")"
    [ "$actual" = "$expected" ] || {
      printf 'quote mismatch for %q: builtin %q, forking %q\n' "$input" "$actual" "$expected" >&2
      false
    }
  done
  # And the shape SQL needs: every single quote doubled, nothing else touched.
  [ "$(_sqlite_lit "a'b''c")" = "a''b''''c" ]
}

@test "local quoting: it agrees under /bin/bash too, which is 3.2 on macOS (#897)" {
  # The premise. If /bin/bash is not the old one, this test still runs but is not
  # testing the thing it exists for, and saying so is better than a silent pass.
  local ver
  ver="$(/bin/bash -c 'echo "$BASH_VERSION"')"
  if [ "${ver%%.*}" -ge 4 ]; then
    skip "/bin/bash is $ver; the 3.2 replacement-backslash difference cannot appear here"
  fi

  local input expected actual
  for input in "${QUOTE_INPUTS[@]}"; do
    expected="$(reference_lit "$input")"
    actual="$(/bin/bash -c '. "$1"; _sqlite_lit "$2"' _ \
      "$BATS_TEST_DIRNAME/../scripts/drivers/storage/sqlite.sh" "$input")"
    [ "$actual" = "$expected" ] || {
      printf 'bash %s mismatch for %q: builtin %q, forking %q\n' "$ver" "$input" "$actual" "$expected" >&2
      false
    }
  done
}

@test "local quoting: every converted site has the quote variable in scope (#897)" {
  # An undefined quote variable expands to empty, and `${v//​/}` with an empty
  # pattern returns the value UNCHANGED -- quotes not doubled, silently. That is
  # the worst failure this change can have, and it is invisible on both bash
  # versions, so it is counted rather than eyeballed.
  local f subs decls
  for f in check-inbox.sh history.sh inbox.sh send.sh watch.sh \
           lib/sqlpath.sh drivers/storage/sqlite.sh; do
    f="$BATS_TEST_DIRNAME/../scripts/$f"
    subs=$(grep -c '_AGMSG_SQ}\|\$q\$q}' "$f" || true)
    decls=$(grep -cE "_AGMSG_SQ=\"'\"|q=\"'\"" "$f" || true)
    [ "$subs" -eq 0 ] || [ "$decls" -ge 1 ] || {
      echo "$f substitutes with a quote variable it never declares" >&2
      false
    }
  done
}

@test "local quoting: the forking form is gone from the converted files (#897)" {
  local f
  for f in check-inbox.sh history.sh inbox.sh send.sh watch.sh \
           lib/sqlpath.sh drivers/storage/sqlite.sh; do
    refute grep -q "sed \"s/'/''/g\"" "$BATS_TEST_DIRNAME/../scripts/$f"
  done
}
