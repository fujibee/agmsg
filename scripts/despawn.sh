#!/usr/bin/env bash
set -euo pipefail

# despawn.sh — tear down a spawned crew member, the inverse of spawn.sh.
#
# Usage:
#   despawn.sh <team> <from> <name> [--force] [--timeout <secs>]
#
#   <team>   team the member is in
#   <from>   the leader's own agent name (sender of the control message)
#   <name>   the member to tear down
#
# Default (graceful): send a `ctrl:despawn` control message to <name>. The
# member's watcher (watch.sh) sees it and drops its own role (releasing the
# actas lock). A graceful watcher deliberately leaves the pane/window for manual
# close: inherited ids and legacy placement records are not generation-bound
# ownership proof; status=ok therefore means only that the role lock was
# observed free.
# We block until the lock is released, up to --timeout (default 30s); on timeout
# the member didn't respond (dead watcher, or a codex member with no Monitor) —
# re-run with --force. Graceful teardown never invokes a placement provider.
#
# --force: skip the message and tear the member down from here using the
# placement recorded at spawn time — kill its tmux pane/window and drop its
# registration. For when the member's watcher can't respond.
#
# See #109 and #514. `--force` remains a local recovery escape hatch that trusts
# the recorded placement id; it is not authenticated or generation-bound.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"

die() { echo "despawn: $*" >&2; exit 1; }

TEAM="${1:-}"; FROM="${2:-}"; NAME="${3:-}"
[ -n "$TEAM" ] && [ -n "$FROM" ] && [ -n "$NAME" ] \
  || die "Usage: despawn.sh <team> <from> <name> [--force] [--timeout <secs>]"
shift 3 || true

FORCE=0
TIMEOUT=30
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --timeout) TIMEOUT="${2:?--timeout needs seconds}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done
case "$TIMEOUT" in ''|*[!0-9]*) die "--timeout must be a whole number of seconds" ;; esac

SPAWN_REC="$(agmsg_spawn_path "$TEAM" "$NAME")"

# Kill the recorded tmux target. ids are self-describing: %N pane, @N window.
kill_recorded_placement() {
  [ -f "$SPAWN_REC" ] || return 1
  local id _proj _type
  IFS=$'\t' read -r id _proj _type < "$SPAWN_REC"
  [ -n "$id" ] || return 1
  case "$id" in
    herdr:*)
      command -v herdr >/dev/null 2>&1 && herdr pane close "${id#herdr:}" 2>/dev/null || true
      ;;
    *)
      if command -v tmux >/dev/null 2>&1; then
        case "$id" in
          %*) tmux kill-pane   -t "$id" 2>/dev/null || true ;;
          @*) tmux kill-window -t "$id" 2>/dev/null || true ;;
        esac
      fi
      ;;
  esac
  printf '%s\t%s\t%s' "$id" "$_proj" "$_type"   # echo back for the caller
}

if [ "$FORCE" = "1" ]; then
  [ -f "$SPAWN_REC" ] || die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"
  IFS=$'\t' read -r _id _proj _type < "$SPAWN_REC"
  kill_recorded_placement >/dev/null
  # Drop the member's registration, and release its (now-stale) lock.
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    "$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" >/dev/null 2>&1 || true
  fi
  owner="$(actas_lock_owner "$TEAM" "$NAME")"
  [ -n "$owner" ] && actas_lock_release "$TEAM" "$NAME" "$owner" 2>/dev/null || true
  rm -f "$SPAWN_REC" 2>/dev/null || true
  echo "status=forced name=$NAME team=$TEAM"
  exit 0
fi

# --- Graceful ---
# Snapshot only the placement record for caller-visible reporting. It is never
# used as authority to close a target, and the record is still deleted once the
# role is free so stale ids cannot be reused by a later force operation.
graceful_placed_id=""
if [ -f "$SPAWN_REC" ]; then
  IFS=$'\t' read -r graceful_placed_id _ _ < "$SPAWN_REC" || true
fi

state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$state" in
  free)
    if [ -n "$graceful_placed_id" ]; then
      echo "despawn: '$NAME' holds no live actas lock; close its recorded pane/window manually if it remains" >&2
    else
      echo "despawn: '$NAME' holds no live actas lock — nothing to confirm a teardown against (a codex member has no watcher; the member may already be gone). Close any remaining window manually." >&2
    fi
    rm -f "$SPAWN_REC" 2>/dev/null || true
    if [ -n "$graceful_placed_id" ]; then
      echo "status=ok name=$NAME team=$TEAM note=no-live-lock-close-manually"
    else
      echo "status=ok name=$NAME team=$TEAM note=no-live-lock"
    fi
    exit 0
    ;;
esac

"$SCRIPT_DIR/send.sh" "$TEAM" "$FROM" "$NAME" "ctrl:despawn" >/dev/null

waited=0
while true; do
  state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
  [ "$state" = "free" ] && break
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "status=timeout name=$NAME team=$TEAM after=${TIMEOUT}s"
    echo "despawn: '$NAME' did not tear down within ${TIMEOUT}s — its watcher may be dead. Retry with --force." >&2
    exit 3
  fi
  sleep 1
  waited=$((waited + 1))
done

rm -f "$SPAWN_REC" 2>/dev/null || true
if [ -n "$graceful_placed_id" ]; then
  echo "despawn: '$NAME' role lock is free; close its recorded pane/window manually" >&2
  echo "status=ok name=$NAME team=$TEAM after=${waited}s note=role-lock-free-close-manually"
else
  echo "status=ok name=$NAME team=$TEAM after=${waited}s"
fi
