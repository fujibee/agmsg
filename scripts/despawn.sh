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
READY_PATH="$(agmsg_ready_path "$TEAM" "$NAME")"

# A placement record is valid for the narrowly-scoped registration guards only
# when it contains the project/type that spawn recorded. Malformed and legacy
# records retain force despawn's existing fallback behavior.
SPAWN_METADATA_VALID=0
SPAWN_PLACEMENT_ID=""
SPAWN_PROJECT=""
SPAWN_TYPE=""
read_spawn_metadata() {
  SPAWN_METADATA_VALID=0
  SPAWN_PLACEMENT_ID=""
  SPAWN_PROJECT=""
  SPAWN_TYPE=""
  [ -f "$SPAWN_REC" ] || return 1
  if ! IFS=$'\t' read -r SPAWN_PLACEMENT_ID SPAWN_PROJECT SPAWN_TYPE < "$SPAWN_REC"; then
    # read returns EOF for an otherwise valid final line without a trailing
    # newline. spawn writes one, but tolerate a hand-recovered record too.
    [ -n "$SPAWN_PLACEMENT_ID" ] && [ -n "$SPAWN_PROJECT" ] && [ -n "$SPAWN_TYPE" ] || return 1
  fi
  [ -n "$SPAWN_PLACEMENT_ID" ] && [ -n "$SPAWN_PROJECT" ] && [ -n "$SPAWN_TYPE" ] || return 1
  SPAWN_METADATA_VALID=1
  return 0
}

# List only same-name registrations outside the spawn record's exact team.
# identities.sh is read-only; a lookup error is deliberately distinguishable
# from an empty result so a destructive teardown cannot guess at its scope.
SAME_NAME_OTHER_PAIRS=""
same_name_other_pairs() {
  local pairs pair_team pair_agent encoded_team encoded_agent
  SAME_NAME_OTHER_PAIRS=""
  if ! pairs="$("$SCRIPT_DIR/identities.sh" "$SPAWN_PROJECT" "$SPAWN_TYPE" 2>/dev/null)"; then
    return 1
  fi
  while IFS=$'\t' read -r pair_team pair_agent; do
    [ -z "$pair_team" ] && continue
    [ "$pair_agent" = "$NAME" ] || continue
    [ "$pair_team" = "$TEAM" ] && continue
    if ! encoded_team="$(_actas_lock_encode "$pair_team")" \
      || ! encoded_agent="$(_actas_lock_encode "$pair_agent")"; then
      return 1
    fi
    SAME_NAME_OTHER_PAIRS="${SAME_NAME_OTHER_PAIRS:+$SAME_NAME_OTHER_PAIRS,}${encoded_team}/${encoded_agent}"
  done <<< "$pairs"
  return 0
}

other_registration_preflight() {
  [ "$SPAWN_METADATA_VALID" -eq 1 ] || return 0
  if ! same_name_other_pairs; then
    echo "status=error name=$NAME team=$TEAM reason=registration-read"
    echo "despawn: could not read same-name registrations before teardown; retry after registry access recovers" >&2
    return 1
  fi
  if [ -n "$SAME_NAME_OTHER_PAIRS" ]; then
    echo "status=error name=$NAME team=$TEAM reason=multiple-registrations remaining=$SAME_NAME_OTHER_PAIRS action=use-graceful-or-recover-registrations"
    echo "despawn: '$NAME' is also registered in $SAME_NAME_OTHER_PAIRS; use graceful teardown while its watcher is live, or recover registrations before force removal" >&2
    return 1
  fi
  return 0
}

# A readiness sentinel is best-effort: do not make a member that never created
# one impossible to despawn. If it did exist before graceful control flow (or
# appears during an early-free check), however, it must disappear before that
# placement's spawn record is discarded. A replacement sentinel is not proof
# that the recorded placement is gone, so it deliberately remains incomplete.
READY_CAPTURED=0
READY_OWNER=""
capture_target_ready() {
  READY_CAPTURED=0
  READY_OWNER=""
  if [ ! -e "$READY_PATH" ] && [ ! -L "$READY_PATH" ]; then
    return 0
  fi
  [ -f "$READY_PATH" ] || return 1
  if ! READY_OWNER="$(head -n 1 "$READY_PATH" 2>/dev/null)"; then
    return 1
  fi
  [ -n "$READY_OWNER" ] || return 1
  READY_CAPTURED=1
  return 0
}

ready_gate_satisfied() {
  [ "$READY_CAPTURED" -eq 1 ] || return 0
  if [ ! -e "$READY_PATH" ] && [ ! -L "$READY_PATH" ]; then
    return 0
  fi
  # Even a readable different owner is not a completion proof: the placement
  # record has no generation token, so deleting it could erase a successor's
  # recovery handle. Wait for absence instead of treating replacement as done.
  return 1
}

ready_read_error() {
  echo "status=error name=$NAME team=$TEAM reason=ready-read"
  echo "despawn: could not read the existing readiness sentinel for '$TEAM/$NAME'; retaining placement for recovery" >&2
  exit 1
}

# Kill the recorded tmux target. ids are self-describing: %N pane, @N window.
kill_recorded_placement() {
  [ -f "$SPAWN_REC" ] || return 1
  local id="" _proj="" _type=""
  if ! IFS=$'\t' read -r id _proj _type < "$SPAWN_REC"; then
    [ -n "$id" ] || return 1
  fi
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

# reset.sh emits a machine-readable final record. A force run with an initial
# target lock supplied its exact owner and therefore requires a checked release;
# a retry that began with no target lock deliberately made no release request,
# and may only accept the two exact no-release outcomes before its existing
# lock-absent postcheck. Never treat a no-release record as release=proven.
force_machine_outcome_ok() {
  local record="$1" encoded_team="$2" lock_was_present="$3"
  if [ "$lock_was_present" -eq 1 ]; then
    case "$record" in
      "status=ok team=$encoded_team registration=removed release=proven"|\
      "status=ok team=$encoded_team registration=removed release=proven finalize=failed"|\
      "status=ok team=$encoded_team registration=absent release=proven")
        return 0
        ;;
    esac
  else
    case "$record" in
      "status=ok team=$encoded_team registration=removed release=not-requested"|\
      "status=not-registered team=$encoded_team")
        return 0
        ;;
    esac
  fi
  return 1
}

if [ "$FORCE" = "1" ]; then
  [ -f "$SPAWN_REC" ] || die "no placement record for '$TEAM/$NAME' — nothing to force (was it launched via 'spawn'? graceful despawn does not need this)"

  # Before killing a provider placement or changing its target registration,
  # refuse an ambiguous valid spawn record that reveals the same name belongs
  # to another team too. This is a read-only guard; malformed/legacy records
  # retain the narrow fallback below.
  if read_spawn_metadata; then
    if ! other_registration_preflight; then
      exit 1
    fi
  fi
  _id=""
  _proj=""
  _type=""
  IFS=$'\t' read -r _id _proj _type < "$SPAWN_REC" || true
  kill_recorded_placement >/dev/null
  lock_path="$(actas_lock_path "$TEAM" "$NAME")"
  lock_label="$(_actas_lock_encode "$TEAM")/$(_actas_lock_encode "$NAME")"
  machine_team="$(_actas_lock_encode "$TEAM")"
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

  # The normal spawn-record path uses reset.sh's internal exact-team protocol.
  # It must not apply the target lock's raw owner to any other team: that used
  # to let a retry after the target lock vanished run a sessionless global reset
  # and remove a secondary registration while leaving its lock behind. The
  # present-lock path proves an exact release; the absent-lock retry accepts a
  # narrow no-release machine result and still proves target lock absence.
  if [ -n "${_proj:-}" ] && [ -n "${_type:-}" ]; then
    if [ "$lock_was_present" -eq 1 ]; then
      if ! reset_output="$("$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" "$lock_owner" --exact-owner --team "$TEAM" --machine 2>&1)"; then
        force_reset_error "$lock_label" "$lock_path" "$lock_owner" "$reset_output"
      fi
    elif ! reset_output="$("$SCRIPT_DIR/reset.sh" "$_proj" "$_type" "$NAME" "" --team "$TEAM" --machine 2>&1)"; then
      force_reset_error "$lock_label" "$lock_path" "" "$reset_output"
    fi

    # reset.sh's final line is the scoped machine record. Diagnostics can
    # precede it on stderr, so consume only an approved exact record — never
    # human prose whose wording or another team name could alter teardown.
    reset_status="${reset_output##*$'\n'}"
    force_machine_outcome_ok "$reset_status" "$machine_team" "$lock_was_present" \
      || force_reset_error "$lock_label" "$lock_path" "$lock_owner" "$reset_output"
    if [ "$lock_was_present" -eq 1 ]; then
      force_verify_lock_absent_or_replaced "$lock_path" "$lock_owner" "$lock_label"
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
if read_spawn_metadata; then
  :
fi
if ! capture_target_ready; then
  ready_read_error
fi
SEND_FORCE=0
state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
case "$state" in
  free)
    # A sentinel that appeared after the initial snapshot but before this
    # early-free branch is still evidence of an old live watcher. Capture and
    # gate it rather than deleting the sole placement record optimistically.
    if [ "$READY_CAPTURED" -eq 0 ] && { [ -e "$READY_PATH" ] || [ -L "$READY_PATH" ]; }; then
      capture_target_ready || ready_read_error
    fi
    if [ "$READY_CAPTURED" -eq 1 ]; then
      # Do not early-success while the old owner still advertises readiness.
      # The target registration may already be absent after a target commit
      # stalled before watcher cleanup, so intentionally bypass roster checks
      # only for this recovery control row and wait for the ready gate below.
      SEND_FORCE=1
    else
      # A free target lock normally means the old no-op path is safe. A valid
      # spawn record that names another same-name team is the exception:
      # deleting this record would erase its only recovery handle.
      other_registration_preflight || exit 1
      echo "despawn: '$NAME' holds no live actas lock — nothing to confirm a teardown against (a codex member has no watcher; a tmux member may already be gone). If a window remains, use --force." >&2
      rm -f "$SPAWN_REC" 2>/dev/null || true
      echo "status=ok name=$NAME team=$TEAM note=no-live-lock"
      exit 0
    fi
    ;;
esac

if [ "$SEND_FORCE" -eq 1 ]; then
  "$SCRIPT_DIR/send.sh" "$TEAM" "$FROM" "$NAME" "ctrl:despawn" --force >/dev/null
else
  "$SCRIPT_DIR/send.sh" "$TEAM" "$FROM" "$NAME" "ctrl:despawn" >/dev/null
fi

waited=0
while true; do
  state="$(actas_lock_state "$TEAM" "$NAME" "" 2>/dev/null || echo free)"
  if [ "$state" = "free" ] && ready_gate_satisfied; then
    break
  fi
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "status=timeout name=$NAME team=$TEAM after=${TIMEOUT}s"
    echo "despawn: '$NAME' did not tear down within ${TIMEOUT}s — its watcher may be dead. Retry graceful after watcher/registry recovery; use --force only when no other same-name registration remains." >&2
    exit 3
  fi
  sleep 1
  waited=$((waited + 1))
done

rm -f "$SPAWN_REC" 2>/dev/null || true
echo "status=ok name=$NAME team=$TEAM after=${waited}s"
