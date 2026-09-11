#!/usr/bin/env bash
# Summarize one or more run-bats-timed.sh TSV artifacts.
#
# Usage: summarize-bats-timings.sh [--timeout-seconds N] <timings.tsv>...
#
# File percentiles are nearest-rank values across every supplied run. Shard
# headroom is kept per run and OS so a fast sample cannot hide a slow sibling.
set -euo pipefail

timeout=1800
if [ "${1:-}" = --timeout-seconds ]; then
  timeout="${2:-}"
  shift 2
fi
case "$timeout" in ''|*[!0-9]*) echo "${0##*/}: timeout must be seconds" >&2; exit 2 ;; esac
[ "$#" -gt 0 ] || { echo "usage: ${0##*/} [--timeout-seconds N] <timings.tsv>..." >&2; exit 2; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-bats-timings.XXXXXX")"
cleanup() {
  rm -f "$tmp/files" "$tmp/shards"
  rmdir "$tmp" 2>/dev/null || true
}
trap cleanup EXIT

awk -F '\t' '$1 == 1 && $2 == "file_end" && $13 == 0 { print $6 "\t" $9 "\t" $12 }' "$@" \
  | LC_ALL=C sort -t '	' -k1,1 -k2,2 -k3,3n > "$tmp/files"

printf 'record\tos\tfile\tsamples\tp50_seconds\tp95_seconds\tmax_seconds\n'
awk -F '\t' '
  function emit(   p50,p95) {
    if (!n) return
    p50 = int((n + 1) / 2)
    p95 = int((95 * n + 99) / 100)
    printf "file\t%s\t%s\t%d\t%d\t%d\t%d\n", os, file, n, value[p50], value[p95], value[n]
  }
  {
    key = $1 FS $2
    if (last != "" && key != last) { emit(); delete value; n=0 }
    os=$1; file=$2; value[++n]=$3; last=key
  }
  END { emit() }
' "$tmp/files"

awk -F '\t' '$1 == 1 && $2 == "shard" { print $3 "\t" $4 "\t" $6 "\t" $7 "\t" $12 "\t" $13 }' "$@" \
  | LC_ALL=C sort -t '	' -k1,1 -k2,2n -k3,3 -k5,5nr > "$tmp/shards"

printf 'record\trun_id\trun_attempt\tos\tmax_shard\tmax_seconds\theadroom_seconds\tstatus\n'
awk -F '\t' -v timeout="$timeout" '
  {
    key=$1 FS $2 FS $3
    if (!(key in seen)) {
      seen[key]=1
      printf "run\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, $4, $5, timeout-$5, $6
    }
  }
' "$tmp/shards"
