#!/usr/bin/env bash
set -euo pipefail

# One-shot actas-completion readiness sentinel (#338 Gap 2).
#
# This protocol is intentionally separate from watch.sh's ready.* files. A
# watcher sentinel means "a live exclusive watcher is receiving" and remains
# present for the watcher's lifetime. An actas-ready sentinel means only "the
# spawned agent completed its bootstrap once"; spawn consumes it immediately.
#
# Optional <nonce>: spawn.sh generates one per launch and exports it as
# AGMSG_SPAWN_NONCE for the template to echo back on mark. Without it, a mark
# from an abandoned/timed-out earlier spawn attempt for the same (team,agent)
# can satisfy a LATER spawn's check — spawn B clears the sentinel and launches,
# but if stale process A (past its own timeout) marks before B does, B's check
# sees A's mark and reports ready before B's own agent has actually booted
# (review finding, 2026-07-19). When a nonce is given to `check`, content must
# match exactly; `mark` without a nonce (e.g. manual `/agmsg actas`, not via
# spawn) still just signals existence, unchanged from before.

usage() {
  echo "Usage: ready.sh mark|check|clear <team> <agent> [nonce]" >&2
  exit 1
}

ACTION="${1:-}"
TEAM="${2:-}"
AGENT="${3:-}"
NONCE="${4:-}"
{ [ "$#" -eq 3 ] || [ "$#" -eq 4 ]; } || usage
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
    # sentinel. Content is the caller-supplied nonce when given (diagnostic +
    # generation match), else just this process's pid (diagnostic only).
    tmp="$(mktemp "$(dirname "$READY_PATH")/.actas-ready.XXXXXX")"
    trap 'rm -f "$tmp" 2>/dev/null || true' EXIT
    printf '%s\n' "${NONCE:-$$}" > "$tmp"
    mv -f "$tmp" "$READY_PATH"
    trap - EXIT
    ;;
  check)
    [ -f "$READY_PATH" ] || exit 1
    if [ -n "$NONCE" ]; then
      [ "$(tr -d '\r\n' < "$READY_PATH" 2>/dev/null || true)" = "$NONCE" ]
    fi
    ;;
  clear)
    rm -f "$READY_PATH"
    ;;
  *)
    usage
    ;;
esac
