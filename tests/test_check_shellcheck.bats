#!/usr/bin/env bats
#
# .github/scripts/check-shellcheck.sh: the tracked .sh files must not carry
# more shellcheck findings than the recorded baseline, and the checker must
# refuse to be green when the tool did not demonstrably run. Pinned here, each
# with a control the other way:
#
#   - the RATCHET: above the baseline is red and names the findings, at it is
#     green, below it is red and asks for the baseline to be lowered;
#   - the ATTRIBUTION: the version that ran is printed, and a baseline measured
#     with another version is exit 2, not a comparison;
#   - the ZERO-TARGET answer: no shellcheck, no .sh files, no baseline -- exit 2;
#   - the POSITIVE CONTROL: the checker can prove, on demand, that it fires.
#
# These need a shellcheck binary. Where there is none the tests skip -- visibly,
# as `ok # skip`, never as a silent green -- and the CI job that matters runs
# the checker with a pinned binary regardless (see .github/workflows/shellcheck.yml).

setup() {
  load 'test_helper'
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECK="$REPO_ROOT/.github/scripts/check-shellcheck.sh"
  export SHELLCHECK="${SHELLCHECK:-shellcheck}"
  if ! "$SHELLCHECK" --version >/dev/null 2>&1; then
    SC_VERSION=""
  else
    SC_VERSION="$("$SHELLCHECK" --version | sed -n 's/^version: *//p')"
  fi
}

_need_shellcheck() {
  [ -n "$SC_VERSION" ] || skip "no shellcheck binary (set SHELLCHECK=<path>); the CI job pins one"
}

# A throwaway git tree holding the given .sh files. Prints its path.
_tree() {   # <name>=<content>...
  local d="$BATS_TEST_TMPDIR/tree-$RANDOM" spec
  git init -q "$d"
  for spec in "$@"; do
    printf '%b' "${spec#*=}" > "$d/${spec%%=*}"
    git -C "$d" add "${spec%%=*}"
  done
  printf '%s' "$d"
}

_baseline() {   # <version> <count>  -> path
  local f="$BATS_TEST_TMPDIR/baseline-$RANDOM"
  printf '%s\n%s\n' "$1" "$2" > "$f"
  printf '%s' "$f"
}

BROKEN='#!/bin/bash\nfoo=$1\necho $foo\n'
CLEAN='#!/bin/bash\nfoo="$1"\necho "$foo"\n'

# --- the ratchet --------------------------------------------------------------------

@test "above the baseline is red and names the finding with its real level" {
  _need_shellcheck
  local d; d="$(_tree "broken.sh=$BROKEN")"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 0)" run bash "$CHECK"
  [ "$status" -eq 1 ]
  grep -q 'above the baseline' <<<"$output"
  # SC2086 is an `info` finding: the level the text formatters rename (gcc
  # prints it as `note`), and therefore the one a severity list loses first.
  grep -q 'broken.sh:3:6: info: .*\[SC2086\]' <<<"$output"
}

@test "every level counts: the checker's count equals shellcheck's own json count over a tree with all four levels" {
  # Derived, not listed: the expected count is what shellcheck's structured
  # output reports for the same files, and the tree carries at least one
  # finding of each level so a level dropped by the counter is a mismatch.
  _need_shellcheck
  local d expected got
  d="$(_tree \
    "err.sh=#!/bin/bash\na=1\nb=2\nif [ \"\$a\" \\\\> \"\$b\" ]; then :; fi\n" \
    "warn.sh=#!/bin/bash\necho \"\$undefined_var\"\n" \
    "info.sh=$BROKEN" \
    "style.sh=#!/bin/bash\ncat file | grep x\n")"
  expected="$(cd "$d" && "$SHELLCHECK" -f json1 err.sh warn.sh info.sh style.sh | python3 -c 'import json,sys; d=json.load(sys.stdin)["comments"]; print(len(d), " ".join(sorted(set(c["level"] for c in d))))')"
  [ "${expected#* }" = "error info style warning" ] || { echo "fixture does not cover all four levels: $expected"; return 1; }
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 0)" run bash "$CHECK"
  [ "$status" -eq 1 ]
  got="$(grep -oE '[0-9]+ findings, baseline' <<<"$output" | grep -oE '^[0-9]+')"
  [ "$got" = "${expected%% *}" ] || { echo "checker counted $got, shellcheck json says ${expected%% *}"; echo "$output"; return 1; }
  [ "$(grep -oE ': (error|warning|info|style): ' <<<"$output" | sort -u | wc -l | tr -d ' ')" -eq 4 ]
}

@test "at the baseline is green, and says how many files and which version" {
  _need_shellcheck
  local d; d="$(_tree "broken.sh=$BROKEN" "clean.sh=$CLEAN")"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 1)" run bash "$CHECK"
  [ "$status" -eq 0 ]
  grep -q '2 tracked .sh files, 1 findings, baseline 1' <<<"$output"
  grep -q "shellcheck $SC_VERSION" <<<"$output"
  grep -q 'at the baseline' <<<"$output"
}

@test "below the baseline is red and asks for the baseline to be lowered" {
  _need_shellcheck
  local d; d="$(_tree "clean.sh=$CLEAN")"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 3)" run bash "$CHECK"
  [ "$status" -eq 1 ]
  grep -q 'below the baseline' <<<"$output"
  grep -q 'Lower line 2' <<<"$output"
}

# --- attribution ----------------------------------------------------------------------

@test "a baseline measured with another shellcheck version is exit 2, not a comparison" {
  # Differential pair: same tree, same count, only the version line differs.
  _need_shellcheck
  local d; d="$(_tree "clean.sh=$CLEAN")"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "0.0.1" 0)" run bash "$CHECK"
  [ "$status" -eq 2 ]
  grep -q 'not comparable' <<<"$output"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 0)" run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "the version that ran is the first thing printed, in every outcome" {
  _need_shellcheck
  local d; d="$(_tree "clean.sh=$CLEAN")"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 0)" run bash "$CHECK"
  [ "${lines[0]}" = "check-shellcheck: shellcheck $SC_VERSION ($SHELLCHECK)" ]
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 5)" run bash "$CHECK"
  [ "${lines[0]}" = "check-shellcheck: shellcheck $SC_VERSION ($SHELLCHECK)" ]
}

# --- zero targets are not a pass ------------------------------------------------------

@test "no shellcheck binary is exit 2 -- an absent tool is not a clean tree" {
  # This is the failure that motivated the job: on a machine without the
  # binary, 'no output' read as '0 findings'.
  local d; d="$(_tree "broken.sh=$BROKEN")"
  SHELLCHECK=/nonexistent/shellcheck AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "0.10.0" 0)" run bash "$CHECK"
  [ "$status" -eq 2 ]
  grep -q 'no shellcheck, no claim' <<<"$output"
}

@test "a tree with no tracked .sh files is exit 2, not green" {
  _need_shellcheck
  local d; d="$(_tree "notes.txt=hello\n")"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 0)" run bash "$CHECK"
  [ "$status" -eq 2 ]
  grep -q 'empty scan' <<<"$output"
}

@test "an untracked .sh file is not scanned: the scope is what git tracks" {
  _need_shellcheck
  local d; d="$(_tree "clean.sh=$CLEAN")"
  printf '%b' "$BROKEN" > "$d/untracked.sh"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$(_baseline "$SC_VERSION" 0)" run bash "$CHECK"
  [ "$status" -eq 0 ]
}

@test "a missing or malformed baseline is exit 2" {
  _need_shellcheck
  local d; d="$(_tree "clean.sh=$CLEAN")"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$BATS_TEST_TMPDIR/missing" run bash "$CHECK"
  [ "$status" -eq 2 ]
  printf '%s\nmany\n' "$SC_VERSION" > "$BATS_TEST_TMPDIR/bad"
  AGMSG_SHELLCHECK_ROOT="$d" AGMSG_SHELLCHECK_BASELINE="$BATS_TEST_TMPDIR/bad" run bash "$CHECK"
  [ "$status" -eq 2 ]
}

# --- the positive control ---------------------------------------------------------------

@test "--positive-control proves the checker fires, and fails loudly when it cannot" {
  _need_shellcheck
  run bash "$CHECK" --positive-control
  [ "$status" -eq 0 ]
  grep -q 'positive control fired' <<<"$output"
  grep -q 'info-level finding' <<<"$output"
  # Without a working tool the control must not report success either.
  SHELLCHECK=/nonexistent/shellcheck run bash "$CHECK" --positive-control
  [ "$status" -eq 2 ]
}

# --- the repository's own baseline and workflow ------------------------------------------

@test "the repository baseline has the shape the checker reads: a version, then a count" {
  local f="$REPO_ROOT/.github/shellcheck-baseline"
  [ "$(wc -l < "$f" | tr -d ' ')" -eq 2 ]
  sed -n '1p' "$f" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
  sed -n '2p' "$f" | grep -Eq '^[0-9]+$'
}

@test "the workflow pins the version the baseline names, verifies a digest, and runs the control before the verdict" {
  local wf="$REPO_ROOT/.github/workflows/shellcheck.yml" pinned
  pinned="$(sed -nE "s/^ *SHELLCHECK_VERSION: *'([^']+)'.*/\1/p" "$wf")"
  [ "$pinned" = "$(sed -n '1p' "$REPO_ROOT/.github/shellcheck-baseline")" ]
  grep -Eq "SHELLCHECK_SHA256: *'[0-9a-f]{64}'" "$wf"
  grep -q 'sha256sum -c' "$wf"
  # Order: the control step must come before the verdict step.
  [ "$(grep -n 'check-shellcheck.sh --positive-control' "$wf" | cut -d: -f1)" -lt "$(grep -n 'run: .github/scripts/check-shellcheck.sh$' "$wf" | cut -d: -f1)" ]
}

@test "the recorded baseline is what shellcheck measures on this tree (when the pinned version is available)" {
  # The one test that reads the real tree. It only runs with the pinned
  # version, since any other version's count is not comparable.
  _need_shellcheck
  [ "$SC_VERSION" = "$(sed -n '1p' "$REPO_ROOT/.github/shellcheck-baseline")" ] || skip "shellcheck $SC_VERSION is not the pinned version"
  run bash "$CHECK"
  [ "$status" -eq 0 ]
  grep -q 'at the baseline' <<<"$output"
}
