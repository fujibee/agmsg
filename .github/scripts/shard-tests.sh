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
# Balancing is by @test count, greedy longest-processing-time first, rather
# than by file count: the suite's files differ by more than an order of
# magnitude in size, so splitting on names alone would leave one shard doing
# most of the work and cap the speedup at whatever that shard costs.
#
# Test count is a proxy for runtime, and a loose one — measured on macOS, the
# whole suite is 860s and the count-balanced quarters (197/196/197/197 tests)
# come out at 125s/298s/366s/71s. Per-test cost varies from ~0.0s to ~8s
# depending on how much a file forks or waits. So the real speedup here is
# 860s -> 366s (~2.4x), not 4x.
#
# It is still the right weight to ship first. The alternative, a checked-in
# table of measured per-file seconds, buys ~150s more but goes stale silently:
# it would be wrong the moment the fixed `sleep`s in the suite are replaced by
# condition polling, which is the very next CI change queued. Weights are worth
# revisiting once runtimes stop moving. Note the floor either way is the
# slowest single file (test_spawn.bats, 199s) — no split beats that, so the
# ceiling on this approach is ~4.5x, not 4x-and-then-some.
#
# Whatever the weights, the property that matters is coverage, not balance: the
# worst case of a bad weight is an unevenly filled shard, never a missing file.

set -euo pipefail

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

# Weight each file by its number of test cases. `grep -c` exits 1 on no match
# after printing 0, which set -e would otherwise treat as fatal.
weighted=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  n="$(grep -c '^[[:space:]]*@test' "$f" || true)"
  [ -n "$n" ] || n=0
  weighted="${weighted}${n}	${f}
"
done <<EOF
$files
EOF

# Heaviest first; ties broken by path so the order is total, not incidental.
sorted="$(printf '%s' "$weighted" | LC_ALL=C sort -t'	' -k1,1nr -k2,2)"

# Greedy LPT: hand each file to the currently lightest shard.
i=0
while [ "$i" -lt "$total" ]; do
  load[i]=0
  i=$((i + 1))
done

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
