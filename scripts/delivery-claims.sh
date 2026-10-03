#!/usr/bin/env bash
# Machine interface: delivery-claims.sh <claim|renew|ack|release|peek>
# Read exactly one JSON request from stdin through EOF. Record operations emit
# JSONL; controls emit ok/0 or runtime_error/13. Never pass request data as SQL
# or JavaScript arguments. This interface does not change legacy inbox output.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
source "$SCRIPT_DIR/lib/delivery-claims.sh"

operation="${1:-}"
request=""
AGMSG_CLAIM_IDS=()
invalid_request() {
  printf 'agmsg delivery: invalid_request\n' >&2
  case "$operation" in renew|ack|release) printf 'runtime_error\n' ;; esac
  exit 13
}
[ $# -eq 1 ] || invalid_request
# Bash cannot represent NUL. read -d '' detects it rather than silently
# stripping it, while EOF (status 1) preserves all other bytes and newlines.
if IFS= read -r -d '' request; then invalid_request; fi
agmsg_delivery_parse_request "$operation" "$request" || {
  case "$operation" in renew|ack|release) printf 'runtime_error\n' ;; esac
  exit 13
}
agmsg_storage_load || {
  case "$operation" in renew|ack|release) printf 'runtime_error\n' ;; esac
  exit 13
}
case "$operation" in
  claim)
    if [ -n "${AGMSG_CLAIM_MAX_BYTES:-}" ]; then
      agmsg_delivery_claim_unread_bounded "${AGMSG_CLAIM_TEAM:?missing parsed team}" "${AGMSG_CLAIM_AGENT:?missing parsed agent}" "${AGMSG_CLAIM_OWNER:?missing parsed owner}" \
        "${AGMSG_CLAIM_TTL:?missing parsed ttl}" "${AGMSG_CLAIM_LIMIT:?missing parsed limit}" "${AGMSG_CLAIM_MAX_BYTES:?missing parsed byte bound}"
      exit $?
    fi
    agmsg_delivery_claim_unread "${AGMSG_CLAIM_TEAM:?missing parsed team}" "${AGMSG_CLAIM_AGENT:?missing parsed agent}" \
      "${AGMSG_CLAIM_OWNER:?missing parsed owner}" "${AGMSG_CLAIM_TTL:?missing parsed ttl}" "${AGMSG_CLAIM_LIMIT:?missing parsed limit}" ${AGMSG_CLAIM_IDS[@]+"${AGMSG_CLAIM_IDS[@]}"} ;;
  renew)
    agmsg_delivery_claim_renew "${AGMSG_CLAIM_TEAM:?missing parsed team}" "${AGMSG_CLAIM_AGENT:?missing parsed agent}" \
      "${AGMSG_CLAIM_OWNER:?missing parsed owner}" "${AGMSG_CLAIM_TOKEN:?missing parsed token}" "${AGMSG_CLAIM_TTL:?missing parsed ttl}" ${AGMSG_CLAIM_IDS[@]+"${AGMSG_CLAIM_IDS[@]}"} ;;
  ack|release)
    "agmsg_delivery_claim_$operation" "${AGMSG_CLAIM_TEAM:?missing parsed team}" "${AGMSG_CLAIM_AGENT:?missing parsed agent}" \
      "${AGMSG_CLAIM_OWNER:?missing parsed owner}" "${AGMSG_CLAIM_TOKEN:?missing parsed token}" ${AGMSG_CLAIM_IDS[@]+"${AGMSG_CLAIM_IDS[@]}"} ;;
  peek)
    if [ -n "${AGMSG_CLAIM_MAX_BYTES:-}" ]; then
      agmsg_delivery_list_deliverable_bounded "${AGMSG_CLAIM_TEAM:?missing parsed team}" "${AGMSG_CLAIM_AGENT:?missing parsed agent}" "${AGMSG_CLAIM_LIMIT:?missing parsed limit}" "${AGMSG_CLAIM_MAX_BYTES:?missing parsed byte bound}"
      exit $?
    fi
    agmsg_delivery_list_deliverable "${AGMSG_CLAIM_TEAM:?missing parsed team}" "${AGMSG_CLAIM_AGENT:?missing parsed agent}" \
      --limit "${AGMSG_CLAIM_LIMIT:?missing parsed limit}" ;;
esac
