#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEMPLATE="$ROOT/scripts/drivers/types/claude-code/template.md"
}

@test "Claude template distinguishes sandbox enablement from the write allowlist" {
  grep -Fq 'The allowlist does not enable sandboxing by itself.' "$TEMPLATE"
  grep -Fq '"enabled": true' "$TEMPLATE"
  grep -Fq '`/sandbox`' "$TEMPLATE"
}

@test "Claude template forbids bypassing the scripts with direct SQLite access" {
  grep -Fq 'never construct a database path or invoke `sqlite3` directly' "$TEMPLATE"
}

@test "Claude template tells actas and drop not to treat any off wording as silently deliberate except turn (#687 review round 3)" {
  # #684 recovery: a seat read the bare word "off" and reported no delivery
  # as a deliberate configuration, when delivery.sh actually could not find
  # the project. Round 3 went one layer deeper: even a settings file that
  # genuinely has zero agmsg entries can't be asserted deliberate either --
  # `set off` writes no marker distinguishing it from "never configured" --
  # so only `turn` (has_st=1 is positive evidence) may stay silent now. Both
  # off-shaped wordings appear once for actas and once for drop.
  count_unrecognized=$(grep -c 'mode: off (unrecognized: \.\.\.)' "$TEMPLATE")
  [ "$count_unrecognized" -eq 2 ] \
    || { echo "expected 2 occurrences of the unrecognized wording (actas + drop), found $count_unrecognized" >&2; return 1; }
  count_nohooks=$(grep -c 'mode: off (no agmsg delivery hooks installed for this project)' "$TEMPLATE")
  [ "$count_nohooks" -eq 2 ] \
    || { echo "expected 2 occurrences of the no-hooks wording (actas + drop), found $count_nohooks" >&2; return 1; }
  # delivery.sh never emits a bare, unannotated "mode: off" anymore -- the
  # template must not describe that exact string as the silent/deliberate
  # case, or a future edit could quietly resurrect the #684 failure.
  run grep -q 'exactly `mode: off`' "$TEMPLATE"
  [ "$status" -ne 0 ]
  grep -Fq 'Do not report `actas` as complete without saying this' "$TEMPLATE"
  grep -Fq 'Do not report the drop as complete without mentioning it' "$TEMPLATE"
}
