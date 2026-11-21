#!/usr/bin/env bash
# Decide, per test file of one shard, what a rerun has to run again.
#
#   bats-rerun-plan.sh <manifest> [<prior-results.tsv>]
#
# <manifest> is the shard's test files, one per line. <prior-results.tsv> is the
# results record the previous attempt of this shard uploaded (run-bats-timed.sh
# writes it). One plan line per manifest file is printed, tab separated:
#
#   skip  <file>            passed last time: not run again
#   only  <file>  <name>    one line per test that failed last time
#   all   <file>            run the whole file
#
# The plan only ever REMOVES work for a file the record positively says passed,
# or narrows a file to the tests the record names as failed. Everything else is
# `all`: no record, an unreadable or malformed record, a file the record does not
# mention (the attempt was cancelled before reaching it), a file recorded both
# passed and failed, a failure with no test name. Doubt runs more, never less.
set -u

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || { echo "usage: ${0##*/} <manifest> [<prior-results.tsv>]" >&2; exit 2; }
manifest="$1"
prior="${2:-}"
[ -r "$manifest" ] || { echo "${0##*/}: cannot read manifest: $manifest" >&2; exit 1; }

usable=0
if [ -n "$prior" ] && [ -s "$prior" ]; then
  # Every line must be one of the three record shapes; one bad line and the
  # whole record is not trusted.
  if awk -F'\t' '
      $1 == "pass" && NF == 2 && $2 != "" { next }
      $1 == "fail" && NF == 3 && $2 != "" && $3 != "" { next }
      $1 == "failfile" && NF == 2 && $2 != "" { next }
      { bad = 1 }
      END { exit bad }' "$prior" 2>/dev/null; then
    usable=1
  else
    echo "${0##*/}: prior results are malformed; running every file" >&2
  fi
fi

while IFS= read -r file || [ -n "$file" ]; do
  [ -n "$file" ] || continue
  if [ "$usable" = 0 ]; then
    printf 'all\t%s\n' "$file"
    continue
  fi
  awk -F'\t' -v f="$file" '
    $2 == f && $1 == "pass"     { pass = 1 }
    $2 == f && $1 == "failfile" { failfile = 1 }
    $2 == f && $1 == "fail"     { names[++n] = $3 }
    END {
      if (pass && !failfile && n == 0) { print "skip\t" f; exit }
      if (!pass && !failfile && n > 0) { for (i = 1; i <= n; i++) print "only\t" f "\t" names[i]; exit }
      print "all\t" f
    }' "$prior"
done < "$manifest"
