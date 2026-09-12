#!/usr/bin/env bash
# Run one bats file at a time and append machine-readable wall-clock timings.
#
# Usage: run-bats-timed.sh <manifest> <timings.tsv>
#
# The TSV is intentionally append-only while the suite runs. If the job reaches
# its wall-clock cap, every completed file remains useful evidence instead of
# disappearing with the unfinished bats invocation. Files from several runs can
# be concatenated directly: the run metadata is repeated on every row.
set -u

usage() {
  echo "usage: ${0##*/} <manifest> <timings.tsv>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
manifest="$1"
timings="$2"
[ -s "$manifest" ] || { echo "${0##*/}: empty or missing manifest: $manifest" >&2; exit 1; }

run_id="${GITHUB_RUN_ID:-local}"
run_attempt="${GITHUB_RUN_ATTEMPT:-1}"
sha="${GITHUB_SHA:-unknown}"
runner_os="${RUNNER_OS:-unknown}"
shard="${SHARD:-unknown}"
shard_total="${SHARD_TOTAL:-unknown}"

printf 'schema\trecord\trun_id\trun_attempt\tsha\tos\tshard\tshard_total\tfile\tstarted_at\tended_at\telapsed_seconds\tstatus\n' > "$timings"

suite_started_epoch="$(date -u +%s)"
suite_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
suite_status=0
completed=0

finish() {
  rc=$?
  suite_ended_epoch="$(date -u +%s)"
  suite_ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  suite_elapsed=$((suite_ended_epoch - suite_started_epoch))
  [ "$suite_status" -ne 0 ] || suite_status="$rc"
  printf '1\tshard\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$run_attempt" "$sha" "$runner_os" "$shard" "$shard_total" \
    "$suite_started_at" "$suite_ended_at" "$suite_elapsed" "$suite_status" >> "$timings"
  echo "bats timing: shard $shard/$shard_total completed $completed file(s) in ${suite_elapsed}s (status $suite_status)"
}
trap finish EXIT
stop() {
  suite_status=143
  exit 143
}
trap stop INT TERM

while IFS= read -r file; do
  [ -n "$file" ] || continue
  started_epoch="$(date -u +%s)"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '1\tfile_start\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t-\t-\n' \
    "$run_id" "$run_attempt" "$sha" "$runner_os" "$shard" "$shard_total" \
    "$file" "$started_at" >> "$timings"
  echo "bats timing: start $file at $started_at"

  bats --print-output-on-failure "$file" </dev/null
  status=$?

  ended_epoch="$(date -u +%s)"
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  elapsed=$((ended_epoch - started_epoch))
  printf '1\tfile_end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$run_attempt" "$sha" "$runner_os" "$shard" "$shard_total" \
    "$file" "$started_at" "$ended_at" "$elapsed" "$status" >> "$timings"
  echo "bats timing: end $file at $ended_at (${elapsed}s, status $status)"

  completed=$((completed + 1))
  [ "$status" -eq 0 ] || suite_status="$status"
done < "$manifest"

exit "$suite_status"
