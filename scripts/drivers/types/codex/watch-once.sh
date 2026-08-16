#!/usr/bin/env bash
set -euo pipefail

# One-shot pending-message oracle for the Codex app-server bridge.
#
# Usage:
#   watch-once.sh <project_path> <agent_type> [--name <agent>] [--team <team>] [--timeout <sec>] [--interval <sec>]
#
# Exits:
#   0  unread inbound exists for the subscription
#   1  configuration or runtime error
#   2  timeout with no unread inbound
#
# This script does not maintain a watermark and never marks messages as read.
# `inbox.sh` remains the only read cursor; watch-once simply waits until the
# inbox cursor says there is something to handle.

# Taken before any startup work, because the deadline below has to bound this
# process's LIFETIME, not just its polling. The bridge force-kills the child at
# (timeout + interval + 10) seconds measured from spawn (codex-bridge.js,
# process/spawn timeoutMs), so a deadline computed after startup makes the real
# wall time startup + TIMEOUT. Where startup is slower than interval + 10 — MSYS
# fork emulation measured at 55-300ms per spawn puts a Windows host at ~29s — the
# bridge kills the child before it can reach its own deadline, so it exits 124
# instead of the clean 2 on every single re-arm, the bridge counts three failures
# and self-destructs, and the launcher restarts it forever. Reported with
# measurements by 東リ屋 (#558). Startup on Linux is ~0.2s, which is why this has
# never surfaced here.
#
# Making the deadline lifetime-based means a slow startup eats into the polling
# window rather than overrunning the ceiling. It cannot skip the inbox check
# entirely: the loop queries before it tests the deadline, so even a deadline
# that is already past yields one full check first.
_AGMSG_WO_START="$(date +%s)"

PROJECT_PATH="${1:?Usage: watch-once.sh <project_path> <agent_type> [--name <agent>] [--team <team>] [--timeout <sec>] [--interval <sec>]}"
AGENT_TYPE="${2:?Missing agent_type}"
shift 2

ACTIVE_NAME=""
TEAM_FILTER=""
PAIR_FILTERS=""
TIMEOUT="${AGMSG_WATCH_ONCE_TIMEOUT:-300}"
INTERVAL="${AGMSG_WATCH_ONCE_INTERVAL:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) ACTIVE_NAME="${2:?--name needs an agent name}"; shift 2 ;;
    --team) TEAM_FILTER="${2:?--team needs a team name}"; shift 2 ;;
    --pair) PAIR_FILTERS="${PAIR_FILTERS:+$PAIR_FILTERS$'\n'}${2:?--pair needs team<TAB>agent}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    -h|--help)
      echo "Usage: watch-once.sh <project_path> <agent_type> [--name <agent>] [--team <team>] [--timeout <sec>] [--interval <sec>]"
      exit 0
      ;;
    *) echo "watch-once: unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$TIMEOUT" in ''|*[!0-9]*) echo "watch-once: --timeout must be a whole number of seconds" >&2; exit 1 ;; esac
if [ -z "$INTERVAL" ]; then
  INTERVAL=2
fi
case "$INTERVAL" in ''|*[!0-9]*) echo "watch-once: --interval must be a whole number of seconds" >&2; exit 1 ;; esac
[ "$INTERVAL" -gt 0 ] || INTERVAL=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$SCRIPT_DIR/../../../lib/storage.sh"
agmsg_storage_load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/subscription.sh"

PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

PAIRS="$(agmsg_subscription_pairs "$PROJECT_PATH" "$AGENT_TYPE" "" "$ACTIVE_NAME")" || exit 1
if [ -n "$TEAM_FILTER" ]; then
  PAIRS=$(printf '%s\n' "$PAIRS" | awk -v t="$TEAM_FILTER" -F'\t' 'NF >= 2 && $1 == t')
fi
if [ -n "$PAIR_FILTERS" ]; then
  selected=""
  while IFS=$'\t' read -r team agent; do
    printf '%s\n' "$PAIR_FILTERS" | grep -Fxq "${team}"$'\t'"${agent}" || continue
    selected="${selected:+$selected$'\n'}${team}"$'\t'"${agent}"
  done <<< "$PAIRS"
  PAIRS="$selected"
fi

if [ -z "$PAIRS" ]; then
  echo "watch-once: no available subscription for project=$PROJECT_PATH type=$AGENT_TYPE name=${ACTIVE_NAME:-*} team=${TEAM_FILTER:-*}" >&2
  exit 1
fi

# Bound by this run's lifetime, not by the moment polling happens to start
# (#560): _AGMSG_WO_START is stamped at the top of the script, so startup cost
# is inside the timeout rather than added to it.
#
# main's companion line here built WHERE_PAIRS for a raw `WHERE read_at IS NULL
# AND (...)` query. That query is gone on this branch -- unread is read through
# storage_list_unread per pair -- so carrying the assignment would leave a
# variable nothing reads.
deadline=$(( _AGMSG_WO_START + TIMEOUT ))

while true; do
  {
    # Unread across the subscription via the storage facade (§2.1, events ∪ legacy)
    # — one storage_list_unread per pair, summed. max_id is an OPAQUE equality-only
    # token for codex-bridge stale-wake detection (never ordered): a cksum DIGEST of
    # the whole unread SET, so it changes whenever the set changes. A "greatest id"
    # frontier could miss a set change under a backend whose ids aren't
    # recency-ordered (jsonl); a set digest is robust on every backend.
    count=0
    all_ids=""
    while IFS=$'\t' read -r _team _agent; do
      [ -n "$_team" ] && [ -n "$_agent" ] || continue
      # Asked per team, inside the loop: stores are per team, so whether one
      # exists is a question about a team and there is no subscription-wide
      # answer. It used to be asked once above the loop, when a single store
      # served every team — that form skipped the whole subscription as soon as
      # any store was missing. Mirrors check-inbox.sh and watch.sh.
      storage_store_exists "$_team" || continue
      u="$(storage_list_unread "$_team" "$_agent" 2>/dev/null || true)"
      [ -n "$u" ] || continue
      uarr="[$(printf '%s' "$u" | paste -sd, -)]"
      ids="$(agmsg_sqlite ':memory:' "
        SELECT json_extract(value,'\$.id') FROM json_each('$(printf '%s' "$uarr" | sed "s/'/''/g")');
      " 2>/dev/null || true)"
      [ -n "$ids" ] || continue
      count=$(( count + $(printf '%s\n' "$ids" | grep -c .) ))
      all_ids="$all_ids$ids"$'\n'
    done <<< "$PAIRS"
    if [ "$count" -gt 0 ]; then
      # cksum = POSIX (no shasum dep). Field 1 is whitespace-free for the bridge's
      # `max_id=(\S+)` parse. The bridge only compares it within one session, so the
      # checksum needn't be stable across platforms — only deterministic per run.
      max_id="$(printf '%s' "$all_ids" | sed '/^$/d' | LC_ALL=C sort | cksum | cut -d' ' -f1)"
      printf 'status=pending count=%s max_id=%s\n' "$count" "$max_id"
      exit 0
    fi
  }

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    echo "status=timeout"
    exit 2
  fi
  sleep_for="$INTERVAL"
  remaining=$(( deadline - now ))
  [ "$remaining" -lt "$sleep_for" ] && sleep_for="$remaining"
  [ "$sleep_for" -gt 0 ] || sleep_for=1
  sleep "$sleep_for"
done
