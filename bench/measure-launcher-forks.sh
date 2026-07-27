#!/usr/bin/env bash
# Count the processes a running codex-bridge-launcher spawns over a fixed
# window, for a given checkout of the script. Builds a throwaway skill dir with
# a configurable number of teams and roles, puts counting shims for every
# external command the poll path uses in front of PATH, runs one dispatcher plus
# its role children, and reports what was spawned.
#
# Usage: measure-launcher-forks.sh <repo_root> <seconds> [teams] [roles]
set -uo pipefail

REPO="${1:?usage: measure-launcher-forks.sh <repo_root> <seconds> [teams] [roles]}"
WINDOW="${2:-10}"
TEAMS="${3:-8}"
ROLES="${4:-4}"

WORK="$(mktemp -d)"
SK="$WORK/skill"
mkdir -p "$SK"
cp -R "$REPO/scripts" "$SK/scripts"
mkdir -p "$SK/run" "$SK/teams" "$SK/db"
PROJ="$WORK/proj"; mkdir -p "$PROJ"

export SKILL_DIR="$SK"
export AGMSG_STORAGE_PATH="$SK/db"

# Roles for the measured project, plus filler teams so identities.sh has the
# same number of config files to parse as the machine the baseline came from.
for r in $(seq 1 "$ROLES"); do
  bash "$SK/scripts/join.sh" main "role$r" codex "$PROJ" >/dev/null 2>&1
done
for t in $(seq 2 "$TEAMS"); do
  bash "$SK/scripts/join.sh" "filler$t" "someone" codex "$WORK/elsewhere$t" >/dev/null 2>&1
done

for r in $(seq 1 "$ROLES"); do
  SKILL_DIR="$SK" bash -c \
    'source "$1/lib/role-session.sh"; agmsg_role_session_record main "role$2" "thr-$2" "$3" codex' \
    _ "$SK/scripts" "$r" "$PROJ" >/dev/null 2>&1
done

MOCK="$WORK/mock-bridge.sh"
printf '#!/usr/bin/env bash\nsleep 3600\n' > "$MOCK"
chmod +x "$MOCK"
export AGMSG_CODEX_BRIDGE_CMD="$MOCK"

SHIM="$WORK/shim"; mkdir -p "$SHIM"
COUNTS="$WORK/counts"; : > "$COUNTS"
for c in sqlite3 awk sed sort grep tr cat head basename dirname find wc uname readlink shasum cksum date mktemp rm nohup sleep; do
  real="$(command -v "$c" 2>/dev/null)" || continue
  printf '#!/bin/sh\necho %s >> "%s"\nexec "%s" "$@"\n' "$c" "$COUNTS" "$real" > "$SHIM/$c"
  chmod +x "$SHIM/$c"
done
export PATH="$SHIM:$PATH"

sleep 3600 & PARENT=$!
bash "$SK/scripts/drivers/types/codex/codex-bridge-launcher.sh" \
  codex "$PROJ" "ws://127.0.0.1:1" "$PARENT" >/dev/null 2>&1 &
DISPATCHER=$!

# Let the children start and their bridges settle before the counted window, so
# this measures the steady state rather than one-off startup work.
sleep 4
: > "$COUNTS"
sleep "$WINDOW"
TOTAL="$(wc -l < "$COUNTS" | tr -d ' ')"

echo "teams=$TEAMS roles=$ROLES window=${WINDOW}s"
echo "total spawns in window: $TOTAL  ($(awk -v t="$TOTAL" -v w="$WINDOW" 'BEGIN{printf "%.1f", t/w}' /dev/null)/s)"
echo "by command:"
sort "$COUNTS" | uniq -c | sort -rn | head -15

pkill -P "$DISPATCHER" 2>/dev/null
kill -9 "$DISPATCHER" "$PARENT" 2>/dev/null
pkill -f "$PROJ" 2>/dev/null
sleep 0.5
pkill -f "$WORK" 2>/dev/null
rm -rf "$WORK"
