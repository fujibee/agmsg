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
# member's watcher (watch.sh) sees it, drops its own role (releasing the actas
# lock) and closes its own tmux pane — ending its CLI. We block until the lock
# is released, up to --timeout (default 30s); on timeout the member didn't
# respond (dead watcher, or a codex member with no Monitor) — re-run with
# --force.
#
# --force: skip the message and tear the member down from here using the
# placement recorded at spawn time — kill its tmux pane/window and drop its
# registration. For when the member's watcher can't respond.
#
# See #109. Graceful teardown's full pane-close is tmux-only (the member needs a
# tmux pane to close); an OS-terminal member drops its role but its window must
# be closed by hand.

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

# Preserve force despawn's existing best-effort placement cleanup.  This change
# only makes lock/registration cleanup retryable: never claim the role dropped
# while its exact actas record remains, and keep the spawn record on a checked
# release or reset failure.  Placement-termination proof is outside this path.
force_locked_error() {
  local reason="$1" label="$2" detail="${3:-}"
  echo "status=error name=$NAME team=$TEAM reason=$reason locked=$label"
  [ -z "$detail" ] || echo "despawn: force teardown incomplete for $label: $detail" >&2
  exit 1
}

force_reset_error() {
  local label="$1" lock_path="$2" expected_owner="$3" detail="${4:-}"
  local field="pair" read_status current_owner
  if _actas_lock_read_path_checked "$lock_path"; then
    current_owner="${AGMSG_ACTAS_LOCK_READ_RECORD%%$'\t'*}"
    [ "$current_owner" = "$expected_owner" ] && field="locked"
  else
    read_status=$?
    [ "$read_status" -eq 2 ] && field="locked"
  fi
  echo "status=error name=$NAME team=$TEAM reason=reset-failed $field=$label"
  [ -z "$detail" ] || echo "despawn: force teardown incomplete for $label: $detail" >&2
  exit 1
}

# After a checked release, success means the original owner path is absent or
# a different owner replaced it.  A same-owner successor is the unresolved
# #519 generation boundary, so force despawn fails closed rather than reporting
# success while retaining a lock it cannot distinguish.
force_verify_lock_absent_or_replaced() {
  local lock_path="$1" expected_owner="$2" label="$3" read_status current_owner
  if _actas_lock_read_path_checked "$lock_path"; then
    current_owner="${AGMSG_ACTAS_LOCK_READ_RECORD%%$'\t'*}"
    [ "$current_owner" != "$expected_owner" ] || force_locked_error "lock-retained" "$label"
    return 0
  else
    read_status=$?
  fi
  [ "$read_status" -eq 1 ] && return 0
  force_locked_error "lock-read" "$label"
}

force_verify_lock_absent() {
  local lock_path="$1" label="$2" read_status
  if _actas_lock_read_path_checked "$lock_path"; then
    force_locked_error "lock-appeared" "$label"
  else
    read_status=$?
  fi
  [ "$read_status" -eq 1 ] && return 0
  force_locked_error "lock-read" "$label"
}

force_release_exact_owner() {
  local lock_path="$1" owner="$2" label="$3"
  if ! actas_lock_release_checked "$TEAM" "$NAME" "$owner"; then
    force_locked_error "lock-release" "$label"
  fi
  force_verify_lock_absent_or_replaced "$lock_path" "$owner" "$label"
}

if [ "$FORCE" = "1" ]; then
  [ -f "$SPAWN_REC" ] || die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"
  IFS=$'\t' read -r _id _proj _type < "$SPAWN_REC"
  kill_recorded_placement >/dev/null
  lock_path="$(actas_lock_path "$TEAM" "$NAME")"
  lock_label="$(_actas_lock_encode "$TEAM")/$(_actas_lock_encode "$NAME")"
  lock_was_present=0
  lock_owner=""
  if _actas_lock_read_path_checked "$lock_path"; then
    lock_was_present=1
    lock_owner="${AGMSG_ACTAS_LOCK_READ_RECORD%%$'\t'*}"
  else
    lock_read_status=$?
    if [ "$lock_read_status" -eq 2 ]; then
      force_locked_error "lock-read" "$lock_label"
    fi
  fi

  # The normal spawn-record path funnels the exact current lock owner through
  # reset.sh's registry-lock transaction.  It must not be normalized: a legacy
  # bare owner can differ from an instance id derived by this leader process.
  # This keeps config mutation, checked release, and restoration on failure in
  # one order, without reopening a release-before-registration peer-claim gap.
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    if [ "$lock_was_present" -eq 1 ]; then
      if ! reset_output="$("$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" "$lock_owner" --exact-owner 2>&1)"; then
        force_reset_error "$lock_label" "$lock_path" "$lock_owner" "$reset_output"
      fi
    elif ! reset_output="$("$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" 2>&1)"; then
      force_reset_error "$lock_label" "$lock_path" "" "$reset_output"
    fi

    # If this target was no longer registered, reset has no pair on which to
    # invoke checked release.  Only then use the direct exact-owner fallback;
    # successful target resets rely on their single checked release and merely
    # prove absence/replacement afterwards.
    if [[ "$reset_output" == *" for $NAME from $TEAM"* ]]; then
      if [ "$lock_was_present" -eq 1 ]; then
        force_verify_lock_absent_or_replaced "$lock_path" "$lock_owner" "$lock_label"
      else
        force_verify_lock_absent "$lock_path" "$lock_label"
      fi
    elif [ "$lock_was_present" -eq 1 ]; then
      force_release_exact_owner "$lock_path" "$lock_owner" "$lock_label"
    else
      force_verify_lock_absent "$lock_path" "$lock_label"
    fi
  elif [ "$lock_was_present" -eq 1 ]; then
    # Malformed/legacy placement metadata cannot participate in reset's team
    # transaction.  Retain the old narrow fallback, but require a checked exact
    # release and post-check before saying forced teardown succeeded.
    force_release_exact_owner "$lock_path" "$lock_owner" "$lock_label"
  else
    force_verify_lock_absent "$lock_path" "$lock_label"
  fi
  rm -f "$SPAWN_REC" 2>/dev/null || true
  echo "status=forced name=$NAME team=$TEAM"
  exit 0
fi

# --- Graceful ---
state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$state" in
  free)
    echo "despawn: '$NAME' holds no live actas lock — nothing to confirm a teardown against (a codex member has no watcher; a tmux member may already be gone). If a window remains, use --force." >&2
    rm -f "$SPAWN_REC" 2>/dev/null || true
    echo "status=ok name=$NAME team=$TEAM note=no-live-lock"
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
echo "status=ok name=$NAME team=$TEAM after=${waited}s"
