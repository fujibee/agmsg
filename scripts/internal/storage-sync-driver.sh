#!/usr/bin/env bash
# Private adapter between the Node polling engine and sourced storage drivers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/storage.sh"
agmsg_storage_load

op="${1:-}"; shift || true
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
esac
