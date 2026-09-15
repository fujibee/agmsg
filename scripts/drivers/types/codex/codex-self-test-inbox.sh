#!/usr/bin/env bash
set -euo pipefail

# Bridge-only peek/ack transport. Peek never advances the cursor. The bridge
# acknowledges exact ids only after app-server accepted the corresponding
# turn, so a queued row survives a bridge crash instead of becoming read unseen.
MODE="${1:?Usage: codex-self-test-inbox.sh <peek|ack> <team> <agent> [message-id ...]}"
TEAM="${2:?Missing team}"
AGENT="${3:?Missing agent}"
shift 3
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib/storage.sh"
agmsg_storage_load
agmsg_bridge_guard_check "$TEAM" "$AGENT" || exit $?
case "$MODE" in
  peek)
    [ "$#" -eq 0 ] || { echo "codex-self-test-inbox.sh: peek takes no ids" >&2; exit 2; }
    storage_store_exists "$TEAM" || exit 0
    storage_list_unread "$TEAM" "$AGENT"
    ;;
  ack)
    [ "$#" -gt 0 ] || { echo "codex-self-test-inbox.sh: ack requires message ids" >&2; exit 2; }
    for id in "$@"; do
      case "$id" in *[!A-Za-z0-9-]*|"") echo "codex-self-test-inbox.sh: invalid message id" >&2; exit 2 ;; esac
    done
    storage_mark_read_batch "$TEAM" "$AGENT" "$@" >/dev/null
    ;;
  *) echo "codex-self-test-inbox.sh: expected peek or ack" >&2; exit 2 ;;
esac
