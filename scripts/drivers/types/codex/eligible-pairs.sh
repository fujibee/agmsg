#!/usr/bin/env bash
set -euo pipefail

# Print identities this bridge may read right now. This deliberately resolves
# locks at read time: a role may be claimed by another session after the bridge
# armed its watcher, and inbox.sh would otherwise mark that role's rows read.
PROJECT="${1:?project required}"
TYPE="${2:?type required}"
shift 2
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$SCRIPT_DIR/../../../lib/actas-lock.sh"
source "$SCRIPT_DIR/../../../lib/subscription.sh"

requested=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --pair) requested="${requested:+$requested$'\n'}${2:?pair required}"; shift 2 ;;
    *) echo "eligible-pairs: unknown option: $1" >&2; exit 1 ;;
  esac
done

pairs="$(agmsg_subscription_pairs "$PROJECT" "$TYPE" "")"
if [ -n "$requested" ]; then
  pairs="$(printf '%s\n' "$pairs" | while IFS=$'\t' read -r team name; do
    printf '%s\n' "$requested" | grep -Fxq "${team}"$'\t'"${name}" && printf '%s\t%s\n' "$team" "$name"
  done || true)"
fi
printf '%s\n' "$pairs"
