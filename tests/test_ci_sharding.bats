#!/usr/bin/env bats
#
# The CI suite is split across parallel shards by .github/scripts/shard-tests.sh.
# If that split ever stops being a partition of tests/*.bats, CI keeps reporting
# green while quietly running less than it did before — the failure mode this
# file exists to make impossible.

setup() {
  load 'test_helper'
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SHARD="$REPO_ROOT/.github/scripts/shard-tests.sh"
  TIMED_RUNNER="$REPO_ROOT/.github/scripts/run-bats-timed.sh"
  TIMING_SUMMARY="$REPO_ROOT/.github/scripts/summarize-bats-timings.sh"
}

@test "timing summary computes cross-run percentiles and per-run headroom" {
  local timings
  timings="$BATS_TEST_TMPDIR/timings.tsv"
  printf '%s\n' \
    $'schema\trecord\trun_id\trun_attempt\tsha\tos\tshard\tshard_total\tfile\tstarted_at\tended_at\telapsed_seconds\tstatus' \
    $'1\tfile_end\t1\t1\ta\tmacOS\t1\t4\ttests/a.bats\ts\te\t10\t0' \
    $'1\tfile_end\t2\t1\tb\tmacOS\t2\t4\ttests/a.bats\ts\te\t30\t0' \
    $'1\tshard\t1\t1\ta\tmacOS\t1\t4\t-\ts\te\t70\t0' \
    $'1\tshard\t1\t1\ta\tmacOS\t2\t4\t-\ts\te\t90\t0' > "$timings"

  run "$TIMING_SUMMARY" --timeout-seconds 100 "$timings"

  [ "$status" -eq 0 ]
  [[ "$output" == *$'file\tmacOS\ttests/a.bats\t2\t10\t30\t30'* ]]
  [[ "$output" == *$'run\t1\t1\tmacOS\t2\t90\t10\t0'* ]]
}

all_test_files() {
  find "$REPO_ROOT/tests" -maxdepth 1 -name '*.bats' -exec basename {} \; | LC_ALL=C sort
}

union_of_shards() {
  local total="$1" i
  for ((i = 1; i <= total; i++)); do
    (cd "$REPO_ROOT" && bash "$SHARD" "$i" "$total")
  done | sed 's|.*/||' | LC_ALL=C sort
}

@test "shard-tests.sh is executable and self-documents its usage" {
  [ -x "$SHARD" ]
  run bash "$SHARD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "timed bats runner is executable and self-documents its usage" {
  [ -x "$TIMED_RUNNER" ]
  run "$TIMED_RUNNER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "timed bats runner records each file and the shard total" {
  local fixture manifest timings fake_bin
  fixture="$BATS_TEST_TMPDIR/fixture.bats"
  manifest="$BATS_TEST_TMPDIR/manifest.txt"
  timings="$BATS_TEST_TMPDIR/timings.tsv"
  fake_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$fake_bin"
  printf '@test "passes" { true; }\n' > "$fixture"
  printf '%s\n' "$fixture" > "$manifest"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_bin/bats"
  chmod +x "$fake_bin/bats"

  run env PATH="$fake_bin:$PATH" GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=3 \
    GITHUB_SHA=abc RUNNER_OS=macOS SHARD=2 SHARD_TOTAL=4 \
    "$TIMED_RUNNER" "$manifest" "$timings"

  [ "$status" -eq 0 ]
  [ "$(awk -F '\t' '$2 == "file_start" { n++ } END { print n+0 }' "$timings")" -eq 1 ]
  [ "$(awk -F '\t' '$2 == "file_end" { n++ } END { print n+0 }' "$timings")" -eq 1 ]
  [ "$(awk -F '\t' '$2 == "shard" { n++ } END { print n+0 }' "$timings")" -eq 1 ]
  awk -F '\t' '$2 == "file_end" && $3 == 42 && $4 == 3 && $5 == "abc" && $6 == "macOS" && $7 == 2 && $8 == 4 && $9 != "" && $12 ~ /^[0-9]+$/ && $13 == 0 { ok=1 } END { exit !ok }' "$timings"
}

@test "timed bats runner records a failure and continues the shard" {
  local manifest timings fake_bin calls
  manifest="$BATS_TEST_TMPDIR/manifest.txt"
  timings="$BATS_TEST_TMPDIR/timings.tsv"
  fake_bin="$BATS_TEST_TMPDIR/bin"
  calls="$BATS_TEST_TMPDIR/calls.txt"
  mkdir -p "$fake_bin"
  printf '%s\n' tests/fail.bats tests/pass.bats > "$manifest"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "$2" >> "$BATS_CALLS"' 'case "$2" in *fail*) exit 7 ;; esac' > "$fake_bin/bats"
  chmod +x "$fake_bin/bats"

  run env PATH="$fake_bin:$PATH" BATS_CALLS="$calls" "$TIMED_RUNNER" "$manifest" "$timings"

  [ "$status" -eq 7 ]
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 2 ]
  [ "$(awk -F '\t' '$2 == "file_end" { n++ } END { print n+0 }' "$timings")" -eq 2 ]
  awk -F '\t' '$2 == "shard" && $13 == 7 { ok=1 } END { exit !ok }' "$timings"
}

@test "CI runs the timed runner and uploads each shard artifact" {
  local workflow
  workflow="$REPO_ROOT/.github/workflows/tests.yml"
  grep -Fq '.github/scripts/run-bats-timed.sh shard-files.txt "$RUNNER_TEMP/bats-timings.tsv"' "$workflow"
  grep -Fq 'name: bats-timings-${{ matrix.os }}-${{ matrix.shard }}' "$workflow"
  grep -Fq 'path: ${{ runner.temp }}/bats-timings.tsv' "$workflow"
}

@test "the shards cover every test file exactly once" {
  # Checked across several totals: an off-by-one in the greedy loop can easily
  # be invisible at one shard count and drop a file at another.
  local total
  for total in 1 2 3 4 5 8; do
    run union_of_shards "$total"
    [ "$status" -eq 0 ]
    [ "$output" = "$(all_test_files)" ] || {
      echo "shard total $total did not reproduce the suite" >&2
      diff <(echo "$output") <(all_test_files) >&2 || true
      return 1
    }
  done
}

@test "this test file is itself assigned to a shard" {
  # Guards the specific regression the partition property is meant to prevent:
  # a new test file that lands in no shard and therefore never runs in CI.
  run union_of_shards 4
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_ci_sharding.bats"* ]]
}

@test "the split is deterministic across repeated runs" {
  local first second
  first="$(cd "$REPO_ROOT" && bash "$SHARD" 2 4)"
  second="$(cd "$REPO_ROOT" && bash "$SHARD" 2 4)"
  [ "$first" = "$second" ]
}

@test "no shard is empty at the shard count CI uses" {
  local i out
  for i in 1 2 3 4; do
    out="$(cd "$REPO_ROOT" && bash "$SHARD" "$i" 4)"
    [ -n "$out" ]
  done
}

@test "the heaviest file does not share a shard with the second heaviest" {
  # Not a correctness property — a balance smoke test. Greedy LPT should never
  # put the two largest files together while lighter shards exist; if it does,
  # the weighting has broken and CI is slower than it looks.
  local heaviest second
  heaviest="$(cd "$REPO_ROOT" && grep -c '^[[:space:]]*@test' tests/*.bats \
    | sort -t: -k2 -rn | sed -n '1s/:.*//p')"
  second="$(cd "$REPO_ROOT" && grep -c '^[[:space:]]*@test' tests/*.bats \
    | sort -t: -k2 -rn | sed -n '2s/:.*//p')"
  local i shard_files
  for i in 1 2 3 4; do
    shard_files="$(cd "$REPO_ROOT" && bash "$SHARD" "$i" 4)"
    if [[ "$shard_files" == *"$heaviest"* ]]; then
      [[ "$shard_files" != *"$second"* ]]
    fi
  done
}

# The test above catches drift in the TOP TWO BY COUNT — exactly the metric
# that misses the files pinned below (#847, #848): both are near the bottom
# of the count-weighted sort (9 and 31 tests) despite carrying some of the
# largest measured durations in the suite (722s and 380s; see
# shard-tests.sh's own comment for the measurement). This test guards the
# actual fix, not the metric that already worked.
@test "the pinned-apart heavy files never share a shard, at any shard total >= 2 (#847, #848)" {
  # total=1 is deliberately not checked: with one shard both pins wrap into
  # slot 0 and land together by construction, same as every other file — the
  # pin has nothing to separate them FROM at total=1, so that is not a case
  # this property claims to hold.
  local pin1="test_remote_engine_start_refusal.bats"
  local pin2="test_remote_status_liveness.bats"
  local total i shard_files together
  for total in 2 3 4 5 8; do
    together=0
    for ((i = 1; i <= total; i++)); do
      shard_files="$(cd "$REPO_ROOT" && bash "$SHARD" "$i" "$total")"
      if grep -qF "$pin1" <<<"$shard_files" && grep -qF "$pin2" <<<"$shard_files"; then
        together=1
      fi
    done
    [ "$together" -eq 0 ]
  done
}

@test "adding tests to an unrelated file does not reunite the pinned-apart files (#847 positive control)" {
  # Reproduces #847's actual trigger, not a stand-in for it: that issue's
  # collision was caused by appending @test cases to ONE file
  # (test_roster_journal.bats) and having the repack land two OTHER, entirely
  # untouched files in the same shard. This does the same append and checks
  # the two files pinned above specifically, since a pin is exactly the part
  # of the fix that is supposed to make this kind of drift unable to reunite
  # them, whatever else in the tree changes shape.
  local pin1="test_remote_engine_start_refusal.bats"
  local pin2="test_remote_status_liveness.bats"
  local dir="$BATS_TEST_TMPDIR/tests-plus"
  mkdir -p "$dir"
  cp "$REPO_ROOT"/tests/*.bats "$dir"/
  local i
  for i in $(seq 1 20); do
    printf '\n@test "synthetic case %d" {\n  true\n}\n' "$i" >> "$dir/test_roster_journal.bats"
  done

  local shard1="" shard2="" shard_files
  for i in 1 2 3 4; do
    shard_files="$(cd "$REPO_ROOT" && bash "$SHARD" "$i" 4 "$dir")"
    grep -qF "$pin1" <<<"$shard_files" && shard1="$i"
    grep -qF "$pin2" <<<"$shard_files" && shard2="$i"
  done
  [ -n "$shard1" ]
  [ -n "$shard2" ]
  [ "$shard1" != "$shard2" ]
}

@test "shard-tests.sh rejects out-of-range and non-numeric arguments" {
  run bash "$SHARD" 0 4
  [ "$status" -eq 2 ]
  run bash "$SHARD" 5 4
  [ "$status" -eq 2 ]
  run bash "$SHARD" abc 4
  [ "$status" -eq 2 ]
  run bash "$SHARD" 1 0
  [ "$status" -eq 2 ]
}

@test "shard-tests.sh fails loudly on a directory with no test files" {
  local empty="$BATS_TEST_TMPDIR/empty"
  mkdir -p "$empty"
  run bash "$SHARD" 1 4 "$empty"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no .bats files"* ]]

  run bash "$SHARD" 1 4 "$BATS_TEST_TMPDIR/does-not-exist"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such directory"* ]]
}

@test "the CI workflow shard matrix matches the SHARD_TOTAL it passes" {
  # The matrix is a literal list (so a broken `changes` job cannot take the
  # whole suite down with an unevaluatable dynamic matrix), which means these
  # two numbers have to be kept in step by hand. CI verifies coverage
  # end-to-end from the shard manifests as well; this catches the drift here,
  # where the fix is obvious.
  local wf="$REPO_ROOT/.github/workflows/tests.yml"
  local total matrix_entries
  total="$(sed -n 's/^  SHARD_TOTAL: \([0-9]*\)$/\1/p' "$wf")"
  [ -n "$total" ]
  matrix_entries="$(sed -n 's/^ *shard: \[\(.*\)\]$/\1/p' "$wf" | tr ',' '\n' | grep -c '[0-9]')"
  [ "$matrix_entries" -eq "$total" ]
  # ...and the shard job's display name must name the same total, or the run
  # log claims a split the workflow is not performing.
  grep -q "bats (\${{ matrix.os }} \${{ matrix.shard }}/$total)" "$wf"
}
