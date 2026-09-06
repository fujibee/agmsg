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
# lock) and folds its OWN pane through the terminal driver named by its placement
# record — so tmux AND herdr members fold themselves (a plain/OS-terminal member
# has no addressable pane, so it drops its role and its window is closed by hand).
# We block until the lock is released, up to --timeout; on timeout the member
# didn't respond (dead watcher, or a monitor=no member with no watcher) — re-run
# with --force. A `free` lock with a placement record is NOT proof the member is
# gone (a monitor=no type never holds one): that reports `needs-force` and KEEPS
# the record, rather than a false `ok` (#625).
#
# --force: skip the message and tear the member down from here through the
# terminal driver named by the placement record. The teardown must be CONFIRMED
# (the ref resolves to a terminal, the driver loads, and terminal_despawn exits 0)
# BEFORE the record / registration / lock are dropped — an unconfirmed teardown
# keeps all three and reports `status=error`, so the record (the only retry
# authority) is never deleted out from under a pane that is still alive (#625, the
# --force side). For when the member's watcher can't respond.
#
# See #109.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/terminal-registry.sh"  # kill via the terminal driver

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

# Tear down the recorded placement through the terminal-driver registry, and PROVE
# it (full-head review). The record ref is <terminal>:<id> or a legacy bare
# %N/@N; an unknown/corrupt ref does NOT resolve (agmsg_terminal_ref_terminal fails
# closed). The teardown counts as confirmed only if the ref resolved, the driver
# loaded, AND terminal_despawn exited 0 — a driver reporting runtime_error/13 (a real
# possibility for tmux and herdr) means the pane may STILL be alive, and the caller
# must keep the record rather than delete the one retry authority. Returns 0 on a
# confirmed teardown, non-zero otherwise (no side effects here beyond the kill call).
# What does the terminal say about the recorded pane, RIGHT NOW? Read only —
# nothing is closed here.
#
# Prints one of: no-record / gone / present / unknown.
#
# It resolves the record the same way kill_recorded_placement does, and stops
# short of the kill. `terminal_despawn` cannot be used for this: measured on a
# throwaway tmux server, `kill-pane` returns non-zero both for a pane that is
# already gone and for one it could not close, and the driver maps both to 13.
# Asking with it would make a graceful teardown that WORKED report needs-force.
recorded_pane_state() {
  [ -f "$SPAWN_REC" ] || { printf 'no-record'; return 0; }
  local id _proj _type _term _bare _out _rc=0
  IFS=$'\t' read -r id _proj _type < "$SPAWN_REC"
  [ -n "$id" ] || { printf 'unknown'; return 0; }
  _term="$(agmsg_terminal_ref_terminal "$id")" || { printf 'unknown'; return 0; }
  _bare="$(agmsg_terminal_ref_id "$id")"       || { printf 'unknown'; return 0; }
  agmsg_terminal_load "$_term" 2>/dev/null     || { printf 'unknown'; return 0; }
  declare -F terminal_pane_state >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  _out="$(terminal_pane_state "$_bare" 2>/dev/null)" || _rc=$?
  # The token is the answer and the code says whether it is a settled one. A
  # non-zero (13 unsupported, 10 unreachable) is NOT an answer about the pane,
  # whatever was printed.
  [ "$_rc" -eq 0 ] || { printf 'unknown'; return 0; }
  case "$_out" in
    gone|present) printf '%s' "$_out" ;;
    *)            printf 'unknown' ;;
  esac
  return 0
}

kill_recorded_placement() {
  [ -f "$SPAWN_REC" ] || return 1
  local id _proj _type _term _bare
  IFS=$'\t' read -r id _proj _type < "$SPAWN_REC"
  [ -n "$id" ] || return 1
  _term="$(agmsg_terminal_ref_terminal "$id")" || return 1   # unknown/corrupt ref
  _bare="$(agmsg_terminal_ref_id "$id")"
  agmsg_terminal_load "$_term" 2>/dev/null || return 1       # driver would not load
  terminal_despawn "$_bare" >/dev/null 2>&1 || return 1      # terminal did not confirm
  return 0
}

if [ "$FORCE" = "1" ]; then
  [ -f "$SPAWN_REC" ] || die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"
  IFS=$'\t' read -r _id _proj _type < "$SPAWN_REC"
  if ! kill_recorded_placement; then
    # Teardown NOT confirmed. Keep the record (the only retry authority), the
    # registration and the lock, and say so — never claim a forced teardown that did
    # not happen (the #625 shape, on the --force side).
    echo "despawn: could not confirm '$NAME' was torn down via its placement record ($_id) — the terminal driver did not report the pane closed (unknown/corrupt ref, the driver would not load, or the terminal returned an error). The record is KEPT so you can retry; check the pane manually." >&2
    echo "status=error name=$NAME team=$TEAM note=force-teardown-unconfirmed"
    exit 1
  fi
  # Confirmed torn down: NOW drop the registration, release the (stale) lock, and
  # delete the record.
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
state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$state" in
  free)
    # #625: a free actas lock does NOT prove the member is gone. A monitor=no type
    # (cursor, codex) never runs a watcher and so NEVER holds a lock; a member whose
    # watcher merely died reads identically. So split on the placement record — the
    # positive evidence that something was spawned and may still be running.
    if [ -f "$SPAWN_REC" ]; then
      # A pane/process was placed and is likely still there. Do NOT delete the record
      # (--force reads exactly this — deleting it here is what made the advised
      # recovery impossible), and do NOT report a teardown we did not perform.
      echo "despawn: '$NAME' holds no live actas lock, but a placement record remains — graceful despawn cannot confirm a teardown (a monitor=no member such as cursor/codex never holds a lock; a watcher may have died). Retry with --force to tear it down via the record, which is kept intact." >&2
      echo "status=needs-force name=$NAME team=$TEAM note=no-live-lock-recorded"
      exit 1
    fi
    # No placement record: nothing was spawned here to tear down (a hand-joined
    # member, or one already gone). The free lock is all there is to act on.
    echo "despawn: '$NAME' holds no live actas lock and has no placement record — nothing to tear down here (if a window remains, it was not launched via spawn; close it directly)." >&2
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

# The lock going free means the watcher let go of it. It does NOT mean the pane
# was closed: the watcher releases the lock (via reset.sh) BEFORE it tries to
# close anything, and a lock whose owner has died reads as free too. Deleting the
# record on that signal is what made #1051 unrecoverable — the record is the only
# thing `--force` can work from, and it was gone before anyone knew the pane was
# still open.
#
# So ask the terminal. The record is deleted, and success reported, only when the
# answer is a settled `gone`.
_pane_state="$(recorded_pane_state)"
case "$_pane_state" in
  no-record|gone)
    rm -f "$SPAWN_REC" 2>/dev/null || true
    # Asking whether the record MAY go and checking that it WENT are two
    # different questions, and this branch used to answer only the first. A
    # record left behind (a read-only run dir, a permission failure) outlives
    # the pane it names, and the next `--force` reads it as a live placement and
    # tries to tear down a pane that is already gone — the same "reported
    # success, left the caller a wrong authority" shape this whole change is
    # about. So assert the STATE, not `rm`'s exit code.
    if [ -e "$SPAWN_REC" ]; then
      echo "despawn: '$NAME' was torn down, but its placement record at $SPAWN_REC could not be removed. The record now names a pane that is gone, and --force would act on it; delete it by hand." >&2
      echo "status=error name=$NAME team=$TEAM note=record-not-removed after=${waited}s"
      exit 1
    fi
    echo "status=ok name=$NAME team=$TEAM after=${waited}s"
    ;;
  present)
    echo "despawn: '$NAME' released its lock but the recorded pane is STILL OPEN — the teardown did not fold the window. The placement record is kept; retry with --force to tear it down through it." >&2
    echo "status=needs-force name=$NAME team=$TEAM note=pane-still-open after=${waited}s"
    exit 1
    ;;
  *)
    # Deliberately a different sentence from `present`: the operator's next move
    # differs. "Still open" says close it; "could not check" says look.
    echo "despawn: '$NAME' released its lock, but this terminal could not be asked whether the pane closed, so the teardown is unconfirmed. The placement record is kept; check the window, and use --force if it is still there." >&2
    echo "status=needs-force name=$NAME team=$TEAM note=teardown-unverified after=${waited}s"
    exit 1
    ;;
esac
