#!/usr/bin/env bash
# Run each tests/*.bats under strace and keep only the repo files it used.
# usage: strace_sweep.sh <repo> <outdir> <jobs> [file-glob]
# Re-runnable: a file whose reads/<name>.tsv already exists is skipped.
set -u
repo="$1"; out="$2"; jobs="${3:-2}"; glob="${4:-*.bats}"
tools="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$out/raw" "$out/reads" "$out/tap"
export repo out tools
one() {
  f="$1"; b="$(basename "$f" .bats)"
  [ -s "$out/reads/$b.tsv" ] && return 0
  start=$(date +%s)
  ( cd "$repo" && timeout 2400 strace -f -qq -e trace=execve,openat -e signal=none -s 400 \
      -o "$out/raw/$b.trace" bats "tests/$b.bats" ) > "$out/tap/$b.tap" 2>&1 < /dev/null
  rc=$?
  end=$(date +%s)
  python3 -I "$tools/extract_reads.py" "$repo" "$out/raw/$b.trace" > "$out/reads/$b.tsv.tmp" \
    && mv "$out/reads/$b.tsv.tmp" "$out/reads/$b.tsv"
  rm -f "$out/raw/$b.trace"
  printf '%s\t%s\t%s\n' "$b" "$rc" "$((end - start))" >> "$out/summary.tsv"
}
export -f one
ls "$repo"/tests/$glob | xargs -P "$jobs" -I{} bash -c 'one "$@"' _ {}
echo "sweep done: $(wc -l < "$out/summary.tsv") files"
