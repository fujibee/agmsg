#!/usr/bin/env bash
#
# Deterministically partition the bats suite into shards, and print the test
# files belonging to one of them (one path per line).
#
#   .github/scripts/shard-tests.sh <index> <total> [tests-dir]
#
# The partition is computed from the tree itself, not from a list someone has
# to remember to update. That is the point: with a hand-maintained matrix, a
# newly added test file lands in no shard at all and simply never runs — a
# green CI that silently stopped testing something. Here every `*.bats` file in
# the directory is assigned to exactly one shard, so the union of all shards is
# always the whole suite (asserted by tests/test_ci_sharding.bats).
#
# Balancing is by each file's real measured wall time, greedy
# longest-processing-time first, rather than by file count or @test count:
# the suite's files differ by more than an order of magnitude in cost, so
# splitting on names alone would leave one shard doing most of the work and
# cap the speedup at whatever that shard costs, and @test count is only a
# loose proxy for that cost (a file whose time is almost entirely waiting --
# background processes, poll loops -- can carry a tiny count while
# dominating its shard's wall clock; see #847/#1243 below for the measured
# instance of this that motivated moving off count entirely).
#
# Real time comes from .github/scripts/bats-file-seconds.tsv, a checked-in
# table of per-file macOS wall seconds measured from a real CI run (see that
# file's own header for which run and how to refresh it). A file with no row
# in the table -- renamed, or added since the last measurement -- is
# estimated at the table's own average seconds/file, never at zero: coverage
# (every file lands in exactly one shard) does not depend on the table being
# current, only balance does, and an unmeasured file at the average is a far
# better guess than an unmeasured file at zero.
#
# Whatever the weights, the property that matters MOST is coverage, not
# balance: the worst case of a bad weight is an unevenly filled shard, never
# a missing file.
#
# --- Pinned-apart files (#847, #848, #1243) ---------------------------------
#
# Two files are additionally seeded into FIXED, distinct shard slots before
# the ordinary weighted pass runs, rather than simply sorting into place by
# their (now real-time) weight like everything else:
#
#   test_remote_engine_start_refusal.bats
#   test_remote_status_liveness.bats
#
# Real-time weighting already prevents either from dominating its shard's
# wall clock unnoticed -- that was #847's original problem, and it is what
# @test-count weighting could not see. What fixed-slot seeding buys ON TOP of
# that is a STRUCTURAL guarantee, independent of whatever else the tree looks
# like on a given day: these specific two files can never land on the same
# shard, at any shard total >= 2 (asserted by tests/test_ci_sharding.bats).
# Without it, two files that happen to be the two heaviest overall could in
# principle still be placed together by an unlucky greedy pass at a low
# shard total -- fixed slots rule that out by construction rather than by
# probability.
#
# This seeding does NOT exclude these two shards from the rest of the
# weighted pass (#1243 revision): earlier this pinned a shard by excluding it
# outright, which produced a *correctness* guarantee (never refilled) at the
# cost of *balance* -- on the merged (2550 @test) tree, forcing all
# non-pinned work onto only 3 of 5 shards floored the worst case at ~29
# minutes of the 30-minute cap, regardless of how well those 3 were balanced
# (5243s of non-pinned macOS work over 3 shards = ~1748s = 29.1min each, even
# under perfect packing). Letting the other files fill a pinned shard's
# remaining real-time budget -- exactly like any other shard -- brings every
# shard to ~20.8 minutes on that same measured tree, because the two pinned
# files' own real costs (660s, 346s) are ordinary-sized next to the whole
# suite's 6249s once every file is weighted in the same unit.
#
# Matched by basename, not by the `$dir`-relative path `files` below uses, so
# the pin still resolves when this script is invoked against a different
# tests-dir (as several of this file's own tests do). A pinned name that no
# longer exists in the tree (renamed, removed) is silently skipped rather
# than treated as an error: the partition's correctness (full coverage,
# asserted by tests/test_ci_sharding.bats) never depended on it.
set -euo pipefail

PINNED_APART="test_remote_engine_start_refusal.bats test_remote_status_liveness.bats"

usage() {
  echo "usage: ${0##*/} <shard-index> <shard-total> [tests-dir]" >&2
  echo "  shard-index is 1-based and must be <= shard-total" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
index="$1"
total="$2"
dir="${3:-tests}"

case "$index" in ''|*[!0-9]*) usage ;; esac
case "$total" in ''|*[!0-9]*) usage ;; esac
[ "$total" -ge 1 ] || usage
[ "$index" -ge 1 ] || usage
[ "$index" -le "$total" ] || usage
[ -d "$dir" ] || { echo "${0##*/}: no such directory: $dir" >&2; exit 1; }

# LC_ALL=C keeps the enumeration order identical across the GNU and BSD
# userlands the suite already runs on, so a given tree always produces the same
# partition regardless of which runner computes it.
files="$(find "$dir" -maxdepth 1 -name '*.bats' | LC_ALL=C sort)"
[ -n "$files" ] || { echo "${0##*/}: no .bats files under $dir" >&2; exit 1; }

# The checked-in table of measured per-file macOS seconds this script weights
# by. Overridable so this script's own tests can point at a fixture table
# without touching the real one.
SECONDS_TABLE="${SHARD_TESTS_SECONDS_TABLE:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bats-file-seconds.tsv}"

# The table's own average seconds/file, used below as every unmeasured file's
# estimate. Computed from the table itself (not a second hardcoded number)
# so it can never silently drift out of step with the table it is meant to
# summarize; nearest-integer rounding via the usual awk `(x+0.5)` idiom.
# Falls back to a small positive constant if the table is missing or empty
# so an unmeasured file is still weighted something, never zero or an error.
avg_seconds=1
if [ -r "$SECONDS_TABLE" ]; then
  avg_seconds="$(awk -F'\t' '
    $0 !~ /^#/ && NF == 2 { sum += $2; n++ }
    END { if (n > 0) printf "%d", (sum / n) + 0.5; else print 1 }
  ' "$SECONDS_TABLE")"
  [ -n "$avg_seconds" ] || avg_seconds=1
fi

# Weight a file by its own measured real seconds from the table, matched by
# basename (see the header comment above on why basename, not path). A file
# absent from the table -- renamed, or added since the measurement -- is
# estimated at the table's average rather than treated as zero-cost or an
# error: this function must never fail or omit a value, since every file in
# the tree passes through it once and a missing weight would silently drop
# that file from the balance pass (not from coverage, which does not use
# this value at all).
file_seconds() {
  local base line
  base="$(basename "$1")"
  if [ -r "$SECONDS_TABLE" ]; then
    line="$(awk -F'\t' -v b="$base" '$1 == b { print $2; exit }' "$SECONDS_TABLE" 2>/dev/null || true)"
    if [ -n "$line" ]; then
      printf '%s' "$line"
      return
    fi
  fi
  printf '%s' "$avg_seconds"
}

# Seed the pinned files into distinct shards first, in PINNED_APART's own
# order (each consumes one shard slot, wrapping if there are more pinned
# files than shards) -- not sorted into place by weight like everything
# else, because their whole point is a STRUCTURAL "never share a shard"
# guarantee (see the header comment), which sorting cannot provide even
# though real-time weighting alone now keeps either from dominating its
# shard unnoticed. `load` starts seeded with each pinned file's own real
# cost; the ordinary weighted pass below is free to add more to these same
# shards; it does not skip them.
i=0
while [ "$i" -lt "$total" ]; do
  load[i]=0
  i=$((i + 1))
done

pinned_paths=" "
slot=0
for p in $PINNED_APART; do
  match=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ "$(basename "$f")" = "$p" ]; then
      match="$f"
      break
    fi
  done <<EOF
$files
EOF
  [ -n "$match" ] || continue
  s=$((slot % total))
  load[s]=$((load[s] + $(file_seconds "$match")))
  if [ "$s" -eq "$((index - 1))" ]; then
    printf '%s\n' "$match"
  fi
  pinned_paths="${pinned_paths}${match} "
  slot=$((slot + 1))
done

# Weight every remaining (non-pinned) file by its own real seconds.
weighted=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$pinned_paths" in
    *" $f "*) continue ;;
  esac
  weighted="${weighted}$(file_seconds "$f")	${f}
"
done <<EOF
$files
EOF

# Heaviest first; ties broken by path so the order is total, not incidental.
sorted="$(printf '%s' "$weighted" | LC_ALL=C sort -t'	' -k1,1nr -k2,2)"

# Greedy LPT: hand each remaining file to the currently lightest shard,
# pinned or not -- `load` already carries the pinned seeds from above, not
# reset here, so a pinned shard's existing real cost is what keeps it from
# being picked again and again, exactly like any other shard's load would.
while IFS='	' read -r n f; do
  [ -n "$f" ] || continue
  best=0
  best_load=${load[0]}
  j=1
  while [ "$j" -lt "$total" ]; do
    if [ "${load[j]}" -lt "$best_load" ]; then
      best=$j
      best_load=${load[j]}
    fi
    j=$((j + 1))
  done
  load[best]=$((best_load + n))
  # An `if`, not `[ ... ] && printf`: a false test as the loop's last command
  # becomes the script's exit status, so the caller would see failure or
  # success depending on nothing but whether the final file happened to land
  # in the requested shard.
  if [ "$best" -eq "$((index - 1))" ]; then
    printf '%s\n' "$f"
  fi
done <<EOF
$sorted
EOF

exit 0
