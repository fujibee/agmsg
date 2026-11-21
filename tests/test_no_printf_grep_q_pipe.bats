#!/usr/bin/env bats

# `printf ... | grep -q` under pipefail: grep -q leaves at the first match, printf
# may still be writing, gets EPIPE, and the pipeline's status is non-zero although
# the text matched. Every place that did this read "no match" and went on (a
# table skipped by a migration, a shim not refreshed, a paused seat missed). The
# input is held in a variable, so a here-string says the same thing with no writer
# to cut off. This keeps the pattern from coming back.

load test_helper

@test "no printf-into-grep -q pipeline in scripts/ or install.sh" {
  local root hits
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  hits="$(grep -rnE 'printf [^|]*\| *grep -q' "$root/scripts" "$root/install.sh" || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    return 1
  fi
}
