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

CONVERTED=(
  "check-inbox.sh 1" "history.sh 2" "inbox.sh 1" "send.sh 1" "watch.sh 1"
  "lib/sqlpath.sh 1" "drivers/storage/sqlite.sh 1"
)

# The COUNT is pinned, not just the presence of a declaration. Without it a site
# can leave the set entirely -- reverted to the backslash form, say -- and every
# other check here still passes: it is no longer a usage to count, and it is not
# the forking form either, so it falls through both. Measured: that mutation left
# the earlier four tests green.
@test "local quoting: every site is present, counted, and has its quote in scope (#897)" {
  local entry f want subs decls total=0
  for entry in "${CONVERTED[@]}"; do
    set -- $entry
    f="$BATS_TEST_DIRNAME/../scripts/$1"; want="$2"
    subs=$(grep -c '_AGMSG_SQ}\|\$q\$q}' "$f" || true)
    decls=$(grep -cE "_AGMSG_SQ=\"'\"|q=\"'\"" "$f" || true)
    [ "$subs" -eq "$want" ] || {
      echo "$1: expected $want quote substitutions, found $subs" >&2
      false
    }
    [ "$decls" -ge 1 ] || {
      echo "$1 substitutes with a quote variable it never declares" >&2
      false
    }
    total=$((total + subs))
  done
  [ "$total" -eq 8 ] || { echo "expected 8 sites, counted $total" >&2; false; }
}

# The form that broke #897 on macOS: a backslashed quote as the REPLACEMENT.
# Refused by shape, so reverting a site to it fails here even though it is
# neither a counted usage nor a fork.
@test "local quoting: no site writes the quote inline in the pattern (#897)" {
  local entry
  for entry in "${CONVERTED[@]}"; do
    set -- $entry
    refute grep -qF "//\\'/" "$BATS_TEST_DIRNAME/../scripts/$1"
  done
}

# The bash-3.2 equivalence above drives _sqlite_lit, which is ONE of the eight
# sites. The other seven are written inline in a SQL string, and no function call
# reaches them -- so a 3.2 test that only sources sqlite.sh leaves them
# unguarded, and inline is exactly where the backslash form was.
#
# The claim is split rather than re-executing each site by string surgery, which
# is its own source of error:
#
#   every site uses this operator form   pinned by the two tests above -- the
#                                        count per file, and the refusal of a
#                                        backslashed quote in the pattern
#   this operator form is correct on 3.2 measured here, directly
#
# Together those give what running each site would give, without a rebuilt
# expression that can be wrong in a way the test cannot see.
@test "local quoting: the operator every site uses is correct under /bin/bash (#897)" {
  local ver out
  ver="$(/bin/bash -c 'echo "$BASH_VERSION"')"
  if [ "${ver%%.*}" -ge 4 ]; then
    skip "/bin/bash is $ver; the 3.2 replacement-backslash difference cannot appear here"
  fi

  # The form the eight sites use.
  out=$(/bin/bash -c 'q="'"'"'"; v="a'"'"'b"; printf "%s" "${v//$q/$q$q}"')
  [ "$out" = "a''b" ] || {
    echo "the quote-in-a-variable form did not double under bash $ver: got [$out]" >&2
    false
  }

  # And the form it replaced, which is why this test exists: it must NOT agree,
  # or bash 3.2 is not the shell this is about and the whole change is moot.
  out=$(/bin/bash -c 'v="a'"'"'b"; printf "%s" "${v//\'"'"'/\'"'"'\'"'"'}"')
  [ "$out" != "a''b" ] || {
    echo "the backslash form doubled correctly under bash $ver -- the premise of" >&2
    echo "this change does not hold on this machine, so nothing here is measuring it." >&2
    false
  }
}

@test "local quoting: the forking form is gone from the converted files (#897)" {
  local f
  for f in check-inbox.sh history.sh inbox.sh send.sh watch.sh \
           lib/sqlpath.sh drivers/storage/sqlite.sh; do
    refute grep -q "sed \"s/'/''/g\"" "$BATS_TEST_DIRNAME/../scripts/$f"
  done
}
