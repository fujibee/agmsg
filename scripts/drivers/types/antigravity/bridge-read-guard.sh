#!/usr/bin/env bash
# Antigravity-specific read reservation guard.
_AGMSG_BRIDGE_DRIVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
agmsg_type_bridge_guard_check() {
  local reservation="$1"; shift
  [ -e "$reservation" ] || return 0
  # The transport reads the capability from fd 3 once and keeps it private.
  printf '%s' "${_AGMSG_BRIDGE_ACK_CAP:-}" | node "$_AGMSG_BRIDGE_DRIVER_DIR/bridge-read-guard.mjs" check "$reservation" "$$" "$@"
}

# Ordinary takeover contention must not latch an unauthorized legacy ACK.
# Even an FD3 caller uses the separate private transport for protected claims.
agmsg_type_bridge_claim_guard_check() {
  local reservation="$1" operation="$2" team="$3" agent="$4" owner="$5" token="$6"; shift 6
  case "$operation" in ack|release) ;; *) return 13 ;; esac
  node "$_AGMSG_BRIDGE_DRIVER_DIR/bridge-read-guard.mjs" scope "$reservation" "$team" "$agent" || return 13
  declare -F _sqlite_delivery_generic_valid >/dev/null || return 13
  _sqlite_delivery_generic_valid "$operation" "$team" "$agent" "$owner" "$token" "$@" || return 13
}

# The request follows a capability line on stdin, so IDs and recovery bodies
# never enter a process argument. The direct transport shell remains the PID
# checked against the supervisor, including calls made from substitutions.
_agmsg_antigravity_authorize() {
  local reservation="$1" operation="$2" request="$3"
  printf '%s\n%s' "${_AGMSG_BRIDGE_ACK_CAP:-}" "$request" |
    node "$_AGMSG_BRIDGE_DRIVER_DIR/bridge-read-guard.mjs" protected "$reservation" "$$" "$operation"
}

# Readiness inspects durable shape only: dead owners and tokenless saved batches
# still reserve the role. This must never log a violation or inspect a process.
agmsg_type_bridge_reservation_check() {
  node "$_AGMSG_BRIDGE_DRIVER_DIR/bridge-read-guard.mjs" scope "$1" "$2" "$3" || return 13
}
