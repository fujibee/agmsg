#!/usr/bin/env bash
# Antigravity-specific read reservation guard.
_AGMSG_BRIDGE_DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agmsg_type_bridge_guard_check() {
  local reservation="$1"; shift
  [ -e "$reservation" ] || return 0
  # The transport reads the capability from fd 3 once and keeps it private.
  printf '%s' "${_AGMSG_BRIDGE_ACK_CAP:-}" | node "$_AGMSG_BRIDGE_DRIVER_DIR/bridge-read-guard.mjs" check "$reservation" "$$" "$@"
}
