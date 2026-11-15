#!/usr/bin/env bash
#
# Trace one bats file on macOS with eslogger and append what its process tree
# looked at to <out.tsv> (rows as in mac-trace-filter.mjs).
#
#   mac-trace-one.sh <tests/x.bats> <out.tsv>
#
# Needs root for eslogger (a GitHub macOS runner allows sudo without a prompt).
# Never exits non-zero because the test failed: only an unusable trace matters,
# and that is reported as an X row.
set -uo pipefail
test_file="$1"
out="$2"
here="$(cd "$(dirname "$0")" && pwd)"
dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/agmsg-mt.XXXXXX")"

fail() {
  printf 'X\t%s\t%s\n' "$test_file" "$1" >> "$out"
  sudo pkill -f "eslogger exec fork" >/dev/null 2>&1 || true
  exit 0
}

sudo eslogger exec fork exit open stat access readlink lookup readdir chdir getattrlist \
  2> "$dir/es.err" \
  | node "$here/mac-trace-filter.mjs" "$test_file" "$out" "$dir" &
pipe=$!

# Wait until the tracer is live: keep opening the ready marker until the filter
# acknowledges having seen it.
i=0
until [ -e "$dir/ack" ]; do
  : > "$dir/ready"
  sleep 0.5
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "eslogger never came up: $(head -c 200 "$dir/es.err" 2>/dev/null)"
done

# The wrapper opens the start marker, then becomes the test: its pid is the root.
bash -c ': > "$1"; shift; exec "$@"' _ "$dir/start" bats "$test_file" </dev/null >/dev/null 2>&1 || true
: > "$dir/end"

i=0
until [ -e "$dir/done" ]; do
  sleep 0.5
  i=$((i + 1))
  [ "$i" -lt 60 ] || fail "the end marker never came through"
done
sudo pkill -f "eslogger exec fork" >/dev/null 2>&1 || true
wait "$pipe" 2>/dev/null || true
exit 0
