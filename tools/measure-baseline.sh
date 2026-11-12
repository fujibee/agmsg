#!/usr/bin/env bash
set -euo pipefail

# MEASUREMENT-ONLY (not for merge): baseline numbers for comparing against
# install.sh --update's own PHASE/WAIT trace (see AGMSG_PHASE_TRACE in
# install.sh). Prints the time to spawn a do-nothing process 100 times, and
# the time to `cmp` two small files 100 times, so a phase's own wall time can
# be read against "what one bare process spawn costs on this machine" rather
# than assumed.

N=100
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'line one\nline two\n' > "$tmp/a.txt"
printf 'line one\nline two\n' > "$tmp/b.txt"

echo "Spawning /usr/bin/true (or 'true' on PATH) $N times..."
time for _ in $(seq 1 "$N"); do /usr/bin/true 2>/dev/null || true; done

echo ""
echo "Running cmp on two small files $N times..."
time for _ in $(seq 1 "$N"); do cmp -s "$tmp/a.txt" "$tmp/b.txt"; done
