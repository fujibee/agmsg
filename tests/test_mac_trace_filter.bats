#!/usr/bin/env bats
#
# mac-trace-filter.mjs keeps only what the traced test's own process tree looked
# at, and says so when it cannot vouch for the result.

setup() {
  FILTER="$BATS_TEST_DIRNAME/../.github/scripts/mac-trace-filter.mjs"
  D="$BATS_TEST_TMPDIR/m"; mkdir -p "$D"; : > "$D/out.tsv"
}

ev() { # seq type-json pid ppid exe
  printf '{"seq_num":%s,"event":%s,"process":{"audit_token":{"pid":%s},"ppid":%s,"executable":{"path":"%s"}}}\n' "$1" "$2" "$3" "$4" "$5"
}

stream() { # the standard bracket around a body given on stdin
  ev 1 '{"open":{"file":{"path":"'"$D"'/ready"}}}' 10 1 /bin/bash
  ev 2 '{"open":{"file":{"path":"'"$D"'/start"}}}' 20 10 /bin/bash
  cat
}

@test "only the test's own process tree is kept, with the program that touched each path" {
  {
    ev 3 '{"fork":{"child":{"audit_token":{"pid":21},"ppid":20}}}' 20 10 /bin/bash
    ev 4 '{"open":{"file":{"path":"/r/scripts/x.sh"}}}' 21 20 /bin/cat
    ev 5 '{"open":{"file":{"path":"/elsewhere/secret"}}}' 99 1 /bin/cat
    ev 6 '{"readdir":{"target":{"path":"/r/scripts/drivers"}}}' 22 21 /bin/ls
    ev 7 '{"lookup":{"source_dir":{"path":"/r/scripts"},"relative_target":"y.sh"}}' 22 21 /bin/ls
    ev 8 '{"open":{"file":{"path":"'"$D"'/end"}}}' 10 1 /bin/bash
  } | stream | node "$FILTER" tests/t.bats "$D/out.tsv" "$D"
  grep -qxF "$(printf 'tests/t.bats\tF\tcat\t/r/scripts/x.sh')" "$D/out.tsv"
  grep -qxF "$(printf 'tests/t.bats\tD\tls\t/r/scripts/drivers')" "$D/out.tsv"
  grep -qxF "$(printf 'tests/t.bats\tF\tls\t/r/scripts/y.sh')" "$D/out.tsv"
  run grep -c secret "$D/out.tsv"
  [ "$output" = 0 ]
  run grep -c '^X' "$D/out.tsv"
  [ "$output" = 0 ]
}

@test "a gap in the sequence numbers marks the test as untrustworthy" {
  {
    ev 3 '{"open":{"file":{"path":"/r/a"}}}' 20 10 /bin/cat
    ev 9 '{"open":{"file":{"path":"/r/b"}}}' 20 10 /bin/cat
    ev 10 '{"open":{"file":{"path":"'"$D"'/end"}}}' 10 1 /bin/bash
  } | stream | node "$FILTER" tests/t.bats "$D/out.tsv" "$D"
  grep -q "^X.tests/t.bats.events were dropped" "$D/out.tsv"
}

@test "input that ends before the end marker marks the test as untrustworthy" {
  ev 3 '{"open":{"file":{"path":"/r/a"}}}' 20 10 /bin/cat | stream | node "$FILTER" tests/t.bats "$D/out.tsv" "$D"
  grep -q "^X.tests/t.bats.input ended" "$D/out.tsv"
}

@test "a test that touched nothing is untrustworthy, not an empty dependency list" {
  { ev 3 '{"open":{"file":{"path":"'"$D"'/end"}}}' 10 1 /bin/bash; } | stream | node "$FILTER" tests/t.bats "$D/out.tsv" "$D"
  grep -q "^X.tests/t.bats.no event was attributed" "$D/out.tsv"
}
