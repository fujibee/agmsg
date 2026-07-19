#!/usr/bin/env bash
set -euo pipefail

# One-shot actas-completion readiness sentinel (#338 Gap 2).
#
# This protocol is intentionally separate from watch.sh's ready.* files. A
# watcher sentinel means "a live exclusive watcher is receiving" and remains
# present for the watcher's lifetime. An actas-ready sentinel means only "the
# spawned agent completed its bootstrap once"; spawn consumes it immediately.

usage() {
  echo "Usage: ready.sh mark|check|clear <team> <agent>" >&2
  exit 1
}

ACTION="${1:-}"
TEAM="${2:-}"
AGENT="${3:-}"
[ "$#" -eq 3 ] || usage
[ -n "$TEAM" ] && [ -n "$AGENT" ] || usage

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# actas-lock.sh consumes this caller-owned variable when sourced.
# shellcheck disable=SC2034
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"

READY_PATH="$(agmsg_actas_ready_path "$TEAM" "$AGENT")"

case "$ACTION" in
  mark)
    mkdir -p "$(dirname "$READY_PATH")"
    # Write then rename in the same directory so check never observes a partial
    # sentinel. Contents are diagnostic only; existence is the protocol.
    tmp="$(mktemp "$(dirname "$READY_PATH")/.actas-ready.XXXXXX")"
    trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
    printf '%s\n' "$$" > "$tmp"
    mv -f "$tmp" "$READY_PATH"
    trap - EXIT
    ;;
  check)
    [ -f "$READY_PATH" ]
    ;;
  clear)
    rm -f "$READY_PATH"
    ;;
  *)
    usage
    ;;
esac
