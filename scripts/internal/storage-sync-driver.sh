#!/usr/bin/env bash
# Private adapter between the Node polling engine and sourced storage drivers.
#
# Exit statuses this adapter itself can end with (the driver's own pass through):
#    2  usage
#   11  the store was BUSY: another writer held it past the busy timeout
#       (sqlite3 "database is locked"). Not a failed check -- the same call with
#       the same input succeeds once that writer is gone -- so the engine waits
#       and retries it (remote-sync.mjs `driver`) instead of giving up. 11 because
#       it is the hole in the storage driver's own 10-14 block (10 jq missing,
#       12 reconcile transaction failed, 13 a check failed, 14 operation
#       unsupported); 15-19 are the roster driver's, and 75 is the test-only
#       abort-after-seal injection -- 75 was the first candidate and would have
#       made that test's assertion mean two things.
#   14  the loaded storage driver has no such operation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/storage.sh"
agmsg_storage_load

# Every sqlite3 call the driver makes below records how it ended in this file
# (storage.sh `_agmsg_sqlite_recording`), so a non-zero exit can be told apart
# by its cause AFTER the fact. The driver functions return 13 for every failed
# check and discard the statement's stderr where they call it, which is where
# SQLITE_BUSY -- a condition of the moment, not of the input -- was being
# reported as a permanent refusal. That is how #910 lost 4,100 messages for
# five days: an unlock's reprocess was on page 133 of 173 when an engine's first
# prepare took the store for 63 s, the next page's `storage_init` waited out the
# 5 s busy timeout, and the 13 it returned read as "this page cannot be
# processed" rather than "not now".
AGMSG_SQLITE_OUTCOME_FILE="$(mktemp)" || exit 1
export AGMSG_SQLITE_OUTCOME_FILE
trap 'rm -f "$AGMSG_SQLITE_OUTCOME_FILE"' EXIT

op="${1:-}"; shift || true
rc=0
case "$op" in
  capabilities) command -v storage_describe >/dev/null 2>&1 || exit 14
                capabilities=$(storage_describe | sed -n 's/^capabilities=//p')
                jq -nc --arg value "$capabilities" \
                  '{type:"sync_driver_capabilities",capabilities:($value|split(",")|map(select(length>0)))}' ;;
  prepare)   command -v storage_sync_prepare_push >/dev/null 2>&1 || exit 14
             storage_sync_prepare_push "$@" ;;
  reconcile) command -v storage_sync_reconcile_push >/dev/null 2>&1 || exit 14
             storage_sync_reconcile_push "$@" ;;
  apply)     command -v storage_sync_apply_pull >/dev/null 2>&1 || exit 14
             storage_sync_apply_pull "$@" ;;
  reprocess) command -v storage_sync_reprocess >/dev/null 2>&1 || exit 14
             storage_sync_reprocess "$@" ;;
  resync-status) command -v storage_sync_resync_status >/dev/null 2>&1 || exit 14
                 storage_sync_resync_status "$@" ;;
  resync) command -v storage_sync_resync >/dev/null 2>&1 || exit 14
          storage_sync_resync "$@" ;;
  read-prepare) command -v storage_sync_prepare_read_state >/dev/null 2>&1 || exit 14
                storage_sync_prepare_read_state "$@" ;;
  read-apply) command -v storage_sync_apply_read_state >/dev/null 2>&1 || exit 14
              storage_sync_apply_read_state "$@" ;;
  read-block) command -v storage_sync_block_read_state >/dev/null 2>&1 || exit 14
              storage_sync_block_read_state "$@" ;;
  read-unblock) command -v storage_sync_unblock_read_state >/dev/null 2>&1 || exit 14
                storage_sync_unblock_read_state "$@" ;;
  *) echo "usage: storage-sync-driver.sh capabilities|prepare|reconcile|apply|reprocess|resync-status|resync|read-prepare|read-apply|read-block|read-unblock ..." >&2; exit 2 ;;
esac || rc=$?

# The operation failed and its last statement was the one that ran out of busy
# timeout: say so, on top of whatever the driver already said about the site,
# and exit 11 so the caller can tell this from a check that failed.
if [ "$rc" -ne 0 ] && [ "$(cat "$AGMSG_SQLITE_OUTCOME_FILE" 2>/dev/null)" = busy ]; then
  printf 'agmsg: sqlite-sync: %s: the store is busy -- another writer held it past the %sms busy timeout (SQLITE_BUSY); this is not a failed check, the same call succeeds once that writer is done\n' \
    "$op" "${AGMSG_BUSY_TIMEOUT:-5000}" >&2
  exit 11
fi
exit "$rc"
