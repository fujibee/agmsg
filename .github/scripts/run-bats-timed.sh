#!/usr/bin/env bash
# Run one bats file at a time and append machine-readable wall-clock timings.
#
# Usage: run-bats-timed.sh <manifest> <timings.tsv>
#
# The TSV is intentionally append-only while the suite runs. If the job reaches
# its wall-clock cap, every completed file remains useful evidence instead of
# disappearing with the unfinished bats invocation. Files from several runs can
# be concatenated directly: the run metadata is repeated on every row.
#
# Two optional environment variables make a rerun cheaper (see
# bats-rerun-plan.sh, which writes the plan):
#
#   AGMSG_BATS_RESULTS  one record per file: `pass<TAB>file`, `fail<TAB>file<TAB>name`
#                       per failed test, or `failfile<TAB>file` for a failure with no
#                       usable test name. The next attempt reads it.
#   AGMSG_BATS_PLAN     `skip file` is not run (recorded as passed), `only file name`
#                       runs just those tests, anything else runs the whole file. A
#                       file the plan does not mention runs whole.
#
# Narrowing never runs less than it was told to: a filter that selects fewer tests
# than the names asked for (renamed, or a name bats cannot match) runs the whole
# file instead.
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
results="${AGMSG_BATS_RESULTS:-}"
plan="${AGMSG_BATS_PLAN:-}"
[ -z "$plan" ] || [ -r "$plan" ] || { echo "bats timing: cannot read plan $plan; running every file" >&2; plan=""; }
[ -z "$results" ] || : > "$results"

# Escape every ERE metacharacter of a test name.
escape_re() { printf '%s' "$1" | sed -e 's#[][\\.^$*+?(){}|/-]#\\&#g'; }

record() { [ -z "$results" ] || printf '%s\n' "$1" >> "$results"; }

# A TAP report is complete only when it has a `1..N` plan, exactly N result lines,
# and no bail-out. Anything else (the run was killed, timed out, or bats died
# part-way) means tests may not have run at all, so the failure names it lists
# are not the whole picture.
tap_complete() {
  awk '
    /^Bail out!/ { bad = 1 }
    /^1\.\.[0-9]+$/ { split($0, p, "\\.\\."); plan = p[2] + 0; have_plan = 1; next }
    /^(not ok|ok) [0-9]+( |$)/ { n++ }
    END { exit !(have_plan && !bad && n == plan) }' "$1" 2>/dev/null
}

# Failed test names of a TAP report, one per line.
failed_names() { grep -E '^not ok [0-9]+ ' "$1" 2>/dev/null | sed -E 's/^not ok [0-9]+ //'; }

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

while IFS= read -r file <&3; do
  [ -n "$file" ] || continue
  started_epoch="$(date -u +%s)"
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '1\tfile_start\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t-\t-\n' \
    "$run_id" "$run_attempt" "$sha" "$runner_os" "$shard" "$shard_total" \
    "$file" "$started_at" >> "$timings"
  echo "bats timing: start $file at $started_at"

  mode=all
  names=""
  if [ -n "$plan" ]; then
    names="$(awk -F'\t' -v f="$file" '$2 == f && $1 == "only" { print $3 }' "$plan")"
    if awk -F'\t' -v f="$file" '$2 == f && $1 == "skip" { found = 1 } END { exit !found }' "$plan"; then
      mode=skip
    elif [ -n "$names" ]; then
      mode=only
    fi
  fi

  if [ "$mode" = skip ]; then
    echo "bats timing: skip $file (passed in the previous attempt)"
    record "$(printf 'pass\t%s' "$file")"
    continue
  fi

  filter_args=()
  if [ "$mode" = only ]; then
    want="$(printf '%s\n' "$names" | grep -c .)"
    re=""
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      re="${re:+$re|}$(escape_re "$n")"
    done <<< "$names"
    have="$(bats --count --filter "^($re)\$" "$file" </dev/null 2>/dev/null)" || have=0
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    if [ "$have" -ge "$want" ]; then
      filter_args=(--filter "^($re)\$")
      echo "bats timing: rerun $want failed test(s) of $file"
    else
      echo "bats timing: $file: filter selects $have of $want named test(s); running the whole file"
    fi
  fi

  repdir="$(mktemp -d)"
  bats --print-output-on-failure --report-formatter tap --output "$repdir" \
    ${filter_args[@]+"${filter_args[@]}"} "$file" </dev/null
  status=$?

  if [ -n "$results" ]; then
    if [ "$status" -eq 0 ]; then
      record "$(printf 'pass\t%s' "$file")"
    else
      failed="$(failed_names "$repdir/report.tap")"
      if ! tap_complete "$repdir/report.tap" || [ -z "$failed" ] || printf '%s\n' "$failed" | grep -qE '^(setup_file|teardown_file|setup_suite|teardown_suite)'; then
        record "$(printf 'failfile\t%s' "$file")"
      else
        while IFS= read -r n; do
          [ -n "$n" ] || continue
          case "$n" in *"$(printf '\t')"*) record "$(printf 'failfile\t%s' "$file")"; continue ;; esac
          record "$(printf 'fail\t%s\t%s' "$file" "$n")"
        done <<< "$failed"
      fi
    fi
  fi
  rm -f -- "$repdir/report.tap"
  rmdir -- "$repdir" 2>/dev/null || true

  ended_epoch="$(date -u +%s)"
  ended_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  elapsed=$((ended_epoch - started_epoch))
  printf '1\tfile_end\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$run_id" "$run_attempt" "$sha" "$runner_os" "$shard" "$shard_total" \
    "$file" "$started_at" "$ended_at" "$elapsed" "$status" >> "$timings"
  echo "bats timing: end $file at $ended_at (${elapsed}s, status $status)"

  completed=$((completed + 1))
  [ "$status" -eq 0 ] || suite_status="$status"
done 3< "$manifest"

exit "$suite_status"
