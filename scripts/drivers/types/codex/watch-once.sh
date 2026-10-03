#!/usr/bin/env bash
set -euo pipefail

# One-shot pending-message oracle for the Codex app-server bridge.
#
# Usage:
#   watch-once.sh <project_path> <agent_type> [--name <agent>] [--team <team>] [--owner <owner>] [--timeout <sec>] [--interval <sec>]
#
# Exits:
#   0  unread inbound exists for the subscription
#   1  configuration or runtime error
#   2  timeout with no unread inbound
#   3  only oversized inline messages remain (once per bridge)
#
# This script does not maintain a watermark and never marks messages as read.
# Claim-capable stores report only deliverable rows; live claims and durable
# role reservations do not trigger metadata wakes. This is never a receipt.

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
OWNER_ID="${AGMSG_CODEX_OWNER_ID:-}"
TIMEOUT="${AGMSG_WATCH_ONCE_TIMEOUT:-300}"
INTERVAL="${AGMSG_WATCH_ONCE_INTERVAL:-}"
MAX_BYTES=""
OVERSIZED_REPORTED=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name) ACTIVE_NAME="${2:?--name needs an agent name}"; shift 2 ;;
    --team) TEAM_FILTER="${2:?--team needs a team name}"; shift 2 ;;
    --pair) PAIR_FILTERS="${PAIR_FILTERS:+$PAIR_FILTERS$'\n'}${2:?--pair needs team<TAB>agent}"; shift 2 ;;
    --owner) OWNER_ID="${2:?--owner needs an owner id}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    --interval) INTERVAL="${2:?--interval needs seconds}"; shift 2 ;;
    --max-bytes) MAX_BYTES="${2:?--max-bytes needs a byte bound}"; shift 2 ;;
    --oversized-reported) OVERSIZED_REPORTED=true; shift ;;
    -h|--help)
      echo "Usage: watch-once.sh <project_path> <agent_type> [--name <agent>] [--team <team>] [--owner <owner>] [--timeout <sec>] [--interval <sec>]"
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
if [ -n "$MAX_BYTES" ]; then
  case "$MAX_BYTES" in *[!0-9]*|????????*) echo 'watch-once: invalid --max-bytes' >&2; exit 1 ;; esac
  [ "$MAX_BYTES" -ge 4096 ] && [ "$MAX_BYTES" -le 1048576 ] || { echo 'watch-once: invalid --max-bytes' >&2; exit 1; }
elif [ "$OVERSIZED_REPORTED" = true ]; then
  echo 'watch-once: --oversized-reported requires --max-bytes' >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
source "$SCRIPT_DIR/../../../lib/storage.sh"
agmsg_storage_load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/delivery-claims.sh"
CLAIMS_SUPPORTED=false
_capability_rc=0
agmsg_delivery_claims_supported || _capability_rc=$?
case "$_capability_rc" in
  0) CLAIMS_SUPPORTED=true ;;
  1) echo "watch-once: delivery claims unavailable; using legacy unread readiness" >&2 ;;
  *) echo "watch-once: delivery capability check failed" >&2; exit 1 ;;
esac
if [ -n "$MAX_BYTES" ]; then
  [ "$CLAIMS_SUPPORTED" = true ] && agmsg_delivery_claims_bytes_supported || {
    echo 'watch-once: inline claims require delivery-claims-bytes-v1 support' >&2; exit 1;
  }
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../../lib/subscription.sh"

PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

PAIRS="$(agmsg_subscription_pairs "$PROJECT_PATH" "$AGENT_TYPE" "$OWNER_ID" "$ACTIVE_NAME")" || exit 1
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
    oversized=false
    all_ids=""
    while IFS=$'\t' read -r _team _agent; do
      [ -n "$_team" ] && [ -n "$_agent" ] || continue
      # Asked per team, inside the loop: stores are per team, so whether one
      # exists is a question about a team and there is no subscription-wide
      # answer. It used to be asked once above the loop, when a single store
      # served every team — that form skipped the whole subscription as soon as
      # any store was missing. Mirrors check-inbox.sh and watch.sh.
      storage_store_exists "$_team" || continue
      if [ "$CLAIMS_SUPPORTED" = true ]; then
        if [ -n "$MAX_BYTES" ]; then
          u="$(agmsg_delivery_list_deliverable_bounded "$_team" "$_agent" 32 "$MAX_BYTES")" || {
            echo "watch-once: deliverable read failed for $_team/$_agent" >&2; exit 1;
          }
          # The facade validates JSONL before emission and emits one final LF;
          # command substitution removes that LF. Count bytes, not characters.
          _agmsg_wo_bytes=$(LC_ALL=C printf '%s' "$u" | wc -c)
          [ -z "$u" ] || [ $((_agmsg_wo_bytes + 1)) -le "$MAX_BYTES" ] || {
            echo 'watch-once: bounded readiness response exceeds its byte limit' >&2; exit 1;
          }
        else
          u="$(agmsg_delivery_list_deliverable "$_team" "$_agent")" || {
          echo "watch-once: deliverable read failed for $_team/$_agent" >&2; exit 1;
          }
        fi
      else
        u="$(storage_list_unread "$_team" "$_agent")" || {
          echo "watch-once: unread read failed for $_team/$_agent" >&2; exit 1;
        }
      fi
      [ -n "$u" ] || continue
      uarr="[$(printf '%s' "$u" | paste -sd, -)]"
      # Keep large/control-character IDs off argv and preserve their record
      # boundaries with hex. A malformed read is an error, never an empty poll.
      _agmsg_wo_sql=$(mktemp "${TMPDIR:-/tmp}/agmsg-watchonce-ids.XXXXXX") || exit 1
      trap 'rm -f "$_agmsg_wo_sql"' EXIT HUP INT TERM
      invalid_id="json_type(value,'\$.id')!='text' OR COALESCE(json_extract(value,'\$.id'),'')=''"
      if [ -n "$MAX_BYTES" ]; then invalid_id="json_extract(value,'\$.type')!='delivery_oversized' AND ($invalid_id)"; fi
      {
        printf '%s\n' "CREATE TEMP TABLE unread(document TEXT CHECK(json_valid(document)));"
        printf "INSERT INTO unread VALUES('%s');\n" "${uarr//\'/\'\'}"
        if [ -n "$MAX_BYTES" ]; then
          printf '%s\n' "CREATE TEMP TABLE valid_bounded(ok INTEGER CHECK(ok=1));
            INSERT INTO valid_bounded SELECT CASE WHEN json_array_length(document)<=33
              AND NOT EXISTS(SELECT 1 FROM json_each(document) m WHERE COALESCE(CASE
                WHEN json_extract(m.value,'\$.type')='delivery_oversized' THEN
                  m.key=json_array_length(document)-1 AND (SELECT count(*) FROM json_each(m.value))=1
                ELSE json_extract(m.value,'\$.type')='message_sent'
                  AND (SELECT count(*) FROM json_each(m.value))=7
                  AND NOT EXISTS(SELECT 1 FROM json_each(m.value) WHERE key NOT IN ('type','id','team','from','to','body','at') OR type!='text')
                  AND (SELECT count(*) FROM json_each(document) WHERE json_extract(value,'\$.type')='message_sent')<=32
                END,0)=0) THEN 1 ELSE 0 END FROM unread;"
        fi
        printf '%s\n' "CREATE TEMP TABLE valid_read(ok INTEGER CHECK(ok=1));
          INSERT INTO valid_read SELECT CASE WHEN json_type(document)='array'
            AND NOT EXISTS(SELECT 1 FROM json_each(document) WHERE
              $invalid_id)
            THEN 1 ELSE 0 END FROM unread;
          SELECT CASE WHEN json_extract(value,'\$.type')='delivery_oversized' AND '$MAX_BYTES'!=''
            THEN 'oversized' ELSE hex(json_extract(value,'\$.id')) END FROM unread,json_each(document);"
      } > "$_agmsg_wo_sql"
      ids="$(agmsg_sqlite -bail ':memory:' < "$_agmsg_wo_sql")" || {
        echo "watch-once: malformed unread records for $_team/$_agent" >&2; exit 1;
      }
      rm -f "$_agmsg_wo_sql"
      trap - EXIT HUP INT TERM
      if [ -n "$MAX_BYTES" ]; then
        case "$ids" in oversized|*$'\n'oversized)
          oversized=true
          if [ "$ids" = oversized ]; then ids=""; else ids="${ids%$'\n'oversized}"; fi
          ;;
        esac
        [ -n "$ids" ] || continue
      fi
      [ -n "$ids" ] || { echo "watch-once: empty unread record set" >&2; exit 1; }
      count=$(( count + $(printf '%s\n' "$ids" | grep -c .) ))
      all_ids="$all_ids$_team"$'\t'"$_agent"$'\n'"$ids"$'\n'
    done <<< "$PAIRS"
    if [ "$count" -gt 0 ]; then
      # cksum = POSIX (no shasum dep). Field 1 is whitespace-free for the bridge's
      # `max_id=(\S+)` parse. The bridge only compares it within one session, so the
      # checksum needn't be stable across platforms — only deterministic per run.
      max_id="$(printf '%s' "$all_ids" | sed '/^$/d' | LC_ALL=C sort | cksum | cut -d' ' -f1)"
      printf 'status=pending count=%s max_id=%s' "$count" "$max_id"
      if [ "$oversized" = true ]; then printf ' oversized=1'; fi
      printf '\n'
      exit 0
    fi
    if [ "$oversized" = true ] && [ "$OVERSIZED_REPORTED" = false ]; then
      printf 'status=oversized\n'
      exit 3
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
