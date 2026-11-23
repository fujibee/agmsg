#!/usr/bin/env bats
#
# A rerun of a CI shard runs only what the earlier attempt did not pass
# (.github/scripts/bats-rerun-plan.sh, run-bats-timed.sh, fetch-prior-bats-results.sh).
# The property that matters is the one-sided one: the plan may remove work only for
# a file the record positively says passed, or narrow a file to tests the record
# names as failed. Every doubt must run more.

setup() {
  load 'test_helper'
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  PLAN="$REPO_ROOT/.github/scripts/bats-rerun-plan.sh"
  TIMED="$REPO_ROOT/.github/scripts/run-bats-timed.sh"
  FETCH="$REPO_ROOT/.github/scripts/fetch-prior-bats-results.sh"
  unset AGMSG_BATS_PLAN AGMSG_BATS_RESULTS
  # The outer bats' per-test timeout (CI sets it) must not reach the nested bats:
  # on Linux a nested bats that runs a failing test under it never exits.
  unset BATS_TEST_TIMEOUT
  W="$BATS_TEST_TMPDIR"
  printf '%s\n' a.bats b.bats c.bats > "$W/manifest"
}

tab() { printf '\t'; }

@test "plan: no record means every file runs" {
  run "$PLAN" "$W/manifest"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'all\ta.bats\nall\tb.bats\nall\tc.bats')" ]
  run "$PLAN" "$W/manifest" "$W/absent.tsv"
  [ "$output" = "$(printf 'all\ta.bats\nall\tb.bats\nall\tc.bats')" ]
}

@test "plan: passed files are skipped, named failures narrow, unmentioned files run whole" {
  printf 'pass\ta.bats\nfail\tb.bats\tfirst bad\nfail\tb.bats\tsecond bad\n' > "$W/prior"
  run "$PLAN" "$W/manifest" "$W/prior"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'skip\ta.bats\nonly\tb.bats\tfirst bad\nonly\tb.bats\tsecond bad\nall\tc.bats')" ]
}

@test "plan: a failure without a test name runs the whole file" {
  printf 'failfile\ta.bats\npass\tb.bats\npass\tc.bats\n' > "$W/prior"
  run "$PLAN" "$W/manifest" "$W/prior"
  [ "$output" = "$(printf 'all\ta.bats\nskip\tb.bats\nskip\tc.bats')" ]
}

@test "plan: a file recorded both passed and failed runs whole" {
  printf 'pass\ta.bats\nfail\ta.bats\tx\npass\tb.bats\nfailfile\tb.bats\n' > "$W/prior"
  run "$PLAN" "$W/manifest" "$W/prior"
  [ "$(printf '%s\n' "$output" | grep -c '^all')" -eq 3 ]
}

@test "plan: a malformed record is not trusted at all" {
  local bad
  for bad in 'pass' 'pass\t' 'fail\ta.bats' 'fail\ta.bats\t' 'bogus\ta.bats' 'pass\ta.bats\textra'; do
    { printf 'pass\tb.bats\n'; printf "$bad\n"; } > "$W/prior"
    run "$PLAN" "$W/manifest" "$W/prior"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -c '^all')" -eq 3 ] || { echo "kept a record with: $bad" >&2; return 1; }
  done
}

@test "plan: an empty record runs every file" {
  : > "$W/prior"
  run "$PLAN" "$W/manifest" "$W/prior"
  [ "$(printf '%s\n' "$output" | grep -c '^all')" -eq 3 ]
}

# ---- the runner, against real nested bats ----

make_fixtures() {
  cat > "$W/a.bats" <<'FIX'
@test "fine one" { true; }
@test "odd (name) [x] a.b|c*d" { [ -f "$FLAG" ]; }
@test "fine two" { true; }
FIX
  cat > "$W/b.bats" <<'FIX'
@test "b fine" { true; }
FIX
  printf '%s\n' "$W/a.bats" "$W/b.bats" > "$W/m"
  export FLAG="$W/flag"
}

@test "runner: records pass and per-test failures; the rerun runs only the failed test and then passes" {
  make_fixtures
  AGMSG_BATS_RESULTS="$W/r1" run "$TIMED" "$W/m" "$W/t1"
  [ "$status" -ne 0 ]
  [ "$(cat "$W/r1")" = "$(printf 'fail\t%s\todd (name) [x] a.b|c*d\npass\t%s' "$W/a.bats" "$W/b.bats")" ]

  "$PLAN" "$W/m" "$W/r1" > "$W/plan"
  : > "$FLAG"
  AGMSG_BATS_PLAN="$W/plan" AGMSG_BATS_RESULTS="$W/r2" run "$TIMED" "$W/m" "$W/t2"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- "rerun 1 failed test(s)"
  printf '%s\n' "$output" | grep -Fq -- "skip $W/b.bats"
  # only the one failed test ran: its TAP plan is 1..1
  printf '%s\n' "$output" | grep -Fq -- "1..1"
  [ -z "$(printf '%s\n' "$output" | grep -F -- 'fine one')" ]
  [ "$(sort "$W/r2")" = "$(printf 'pass\t%s\npass\t%s' "$W/a.bats" "$W/b.bats" | sort)" ]
}

@test "runner: a still-failing narrowed test fails the shard and is recorded again" {
  make_fixtures
  printf 'only\t%s\todd (name) [x] a.b|c*d\n' "$W/a.bats" > "$W/plan"
  rm -f "$FLAG"
  AGMSG_BATS_PLAN="$W/plan" AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$status" -ne 0 ]
  [ "$(sed -n 1p "$W/r")" = "$(printf 'fail\t%s\todd (name) [x] a.b|c*d' "$W/a.bats")" ]
}

@test "runner: a named test that no longer exists runs the whole file" {
  make_fixtures
  : > "$FLAG"
  printf 'only\t%s\tno such test\nskip\t%s\n' "$W/a.bats" "$W/b.bats" > "$W/plan"
  AGMSG_BATS_PLAN="$W/plan" AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- "running the whole file"
  printf '%s\n' "$output" | grep -Fq -- "1..3"
}

@test "runner: an unreadable plan runs every file" {
  make_fixtures
  : > "$FLAG"
  AGMSG_BATS_PLAN="$W/nope" run "$TIMED" "$W/m" "$W/t"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq -- "1..3"
  printf '%s\n' "$output" | grep -Fq -- "b fine"
}

@test "runner: a failing file whose report has no test name is recorded as a whole-file failure" {
  printf '@test "x" { true; }\nsetup_file() { return 1; }\n' > "$W/s.bats"
  printf '%s\n' "$W/s.bats" > "$W/m"
  AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$status" -ne 0 ]
  [ "$(cat "$W/r")" = "$(printf 'failfile\t%s' "$W/s.bats")" ]
}

# A report that ends early (killed, timed out, bailed out) lists only the failures
# it reached; the tests it never ran must not be lost by narrowing the next attempt.
stub_bats_with_report() {
  mkdir -p "$W/bin"
  cat > "$W/bin/bats" <<STUB
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do [ "\$1" = --output ] && out="\$2"; shift; done
printf '%s' "$1" > "\$out/report.tap"
exit $2
STUB
  chmod +x "$W/bin/bats"
}

@test "runner: a truncated TAP report (plan 1..2, one result) is a whole-file failure" {
  printf 'x.bats\n' > "$W/m"
  stub_bats_with_report $'1..2\nnot ok 1 first\n' 124
  PATH="$W/bin:$PATH" AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$status" -eq 124 ]
  [ "$(cat "$W/r")" = "$(printf 'failfile\tx.bats')" ]
}

@test "runner: a report with no plan line, or a bail-out, is a whole-file failure" {
  printf 'x.bats\n' > "$W/m"
  stub_bats_with_report $'not ok 1 first\n' 1
  PATH="$W/bin:$PATH" AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$(cat "$W/r")" = "$(printf 'failfile\tx.bats')" ]
  stub_bats_with_report $'1..2\nnot ok 1 first\nBail out! stop\nnot ok 2 second\n' 1
  PATH="$W/bin:$PATH" AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$(cat "$W/r")" = "$(printf 'failfile\tx.bats')" ]
}

@test "runner: a complete report still records the named failure" {
  printf 'x.bats\n' > "$W/m"
  stub_bats_with_report $'1..2\nnot ok 1 first\nok 2 second\n' 1
  PATH="$W/bin:$PATH" AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$(cat "$W/r")" = "$(printf 'fail\tx.bats\tfirst')" ]
}

# mktemp failing must never turn into an empty --output or a delete at the root.
@test "runner: no temp dir runs bats without a report, records a failure whole-file, touches nothing else" {
  mkdir -p "$W/bin"
  printf '#!/bin/sh\nexit 1\n' > "$W/bin/mktemp"
  printf '#!/bin/sh\necho "rm $*" >> "%s/calls"\n' "$W" > "$W/bin/rm"
  printf '#!/bin/sh\necho "rmdir $*" >> "%s/calls"\n' "$W" > "$W/bin/rmdir"
  printf '#!/bin/sh\necho "bats $*" >> "%s/calls"\nexit 3\n' "$W" > "$W/bin/bats"
  chmod +x "$W/bin/mktemp" "$W/bin/rm" "$W/bin/rmdir" "$W/bin/bats"
  printf 'x.bats\n' > "$W/m"
  PATH="$W/bin:$PATH" AGMSG_BATS_RESULTS="$W/r" run "$TIMED" "$W/m" "$W/t"
  [ "$status" -eq 3 ]
  [ "$(cat "$W/r")" = "$(printf 'failfile\tx.bats')" ]
  [ "$(cat "$W/calls")" = "bats --print-output-on-failure x.bats" ]
}

@test "fetch: no temp dir fetches nothing and runs no download or delete" {
  mkdir -p "$W/bin"
  printf '#!/bin/sh\nexit 1\n' > "$W/bin/mktemp"
  printf '#!/bin/sh\ncase "$1" in api) echo bats-results-ubuntu-latest-3-a1;; *) echo "gh $*" >> "%s/calls";; esac\n' "$W" > "$W/bin/gh"
  printf '#!/bin/sh\necho "rm $*" >> "%s/calls"\n' "$W" > "$W/bin/rm"
  chmod +x "$W/bin/mktemp" "$W/bin/gh" "$W/bin/rm"
  PATH="$W/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 run "$FETCH" ubuntu-latest 3 2 "$W/out"
  [ "$status" -eq 0 ]
  [ ! -e "$W/out" ]
  # the only delete is the script's own clearing of its output path; no download
  [ "$(cat "$W/calls")" = "rm -f -- $W/out" ]
}

@test "runner: without the variables the behaviour is unchanged and no record is written" {
  make_fixtures
  : > "$FLAG"
  run "$TIMED" "$W/m" "$W/t"
  [ "$status" -eq 0 ]
  [ ! -e "$W/r" ]
}

# ---- the fetch step fails open ----

@test "fetch: attempt 1 or a bad attempt fetches nothing and leaves no file" {
  : > "$W/out"
  run "$FETCH" ubuntu-latest 3 1 "$W/out"
  [ "$status" -eq 0 ]
  [ ! -e "$W/out" ]
  run "$FETCH" ubuntu-latest 3 x "$W/out"
  [ "$status" -eq 0 ]
  [ ! -e "$W/out" ]
}

@test "fetch: an API failure leaves no file and exits 0 (the shard then runs whole)" {
  mkdir "$W/bin"
  printf '#!/bin/sh\nexit 1\n' > "$W/bin/gh"; chmod +x "$W/bin/gh"
  PATH="$W/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 run "$FETCH" ubuntu-latest 3 2 "$W/out"
  [ "$status" -eq 0 ]
  [ ! -e "$W/out" ]
}

@test "fetch: takes the newest earlier attempt that left a record" {
  mkdir "$W/bin"
  cat > "$W/bin/gh" <<'GH'
#!/bin/sh
case "$1" in
  api) printf 'bats-results-ubuntu-latest-3-a1\nbats-results-ubuntu-latest-3-a2\nbats-results-ubuntu-latest-4-a3\n' ;;
  run) shift; while [ "$#" -gt 0 ]; do [ "$1" = -D ] && d="$2"; [ "$1" = -n ] && n="$2"; shift; done
       printf 'pass\t%s\n' "$n" > "$d/bats-results.tsv" ;;
esac
GH
  chmod +x "$W/bin/gh"
  PATH="$W/bin:$PATH" GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 run "$FETCH" ubuntu-latest 3 4 "$W/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$W/out")" = "$(printf 'pass\tbats-results-ubuntu-latest-3-a2')" ]
}

# ---- the workflow wiring ----

@test "workflow: results are uploaded per attempt and the plan step can only narrow" {
  local wf="$REPO_ROOT/.github/workflows/tests.yml"
  grep -Fq 'name: bats-results-${{ matrix.os }}-${{ matrix.shard }}-a${{ github.run_attempt }}' "$wf"
  grep -Fq 'path: ${{ runner.temp }}/bats-results.tsv' "$wf"
  grep -Fq 'AGMSG_BATS_RESULTS: ${{ runner.temp }}/bats-results.tsv' "$wf"
  grep -Fq '.github/scripts/fetch-prior-bats-results.sh' "$wf"
  grep -Fq '.github/scripts/bats-rerun-plan.sh shard-files.txt' "$wf"
  # the plan step may never fail the job: an error there means the whole shard runs
  awk '/- name: Plan the rerun from the earlier attempt/ {f=1} f && /continue-on-error: true/ {ok=1} f && /run: \|/ {exit} END {exit !ok}' "$wf"
}
