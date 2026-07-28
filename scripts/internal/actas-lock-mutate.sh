#!/usr/bin/env bash
# Fixed destructive helper for actas lock records.
#
# Usage:
#   actas-lock-mutate.sh stale <lock-path>
#   actas-lock-mutate.sh exact <lock-path> <expected-record>
#
# Exit status contract:
#   0  rm(1) actually removed the path
#   2  invalid mode/path
#   3  current readable record must be preserved
#   4  legacy .reclaim.d transition marker present
#   5  logical mutex / SQLite unavailable
#   6  target non-regular or unreadable
#   7  target became absent while this helper waited for its reclaim mutex
# Other non-zero statuses (including rm failure) are fail-closed I/O errors.

set -u

MODE="${1:?Usage: actas-lock-mutate.sh <stale|exact> <lock-path> [expected-record]}"
LOCK_PATH="${2:?Missing lock path}"
EXPECTED="${3:-}"

SCRIPT_DIR="$(cd -P "$(dirname "$0")/.." && pwd -P)" || exit 2
SKILL_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)" || exit 2
RUN_DIR="$(cd -P "$SKILL_DIR/run" 2>/dev/null && pwd -P)" || exit 2

case "$MODE" in
  stale) [ "$#" -eq 2 ] || exit 2 ;;
  exact) [ "$#" -eq 3 ] || exit 2 ;;
  *) exit 2 ;;
esac

# Accept only a direct child of the physical run directory used to invoke this
# fixed helper. A glob such as "$RUN_DIR"/actas.*.session is insufficient: `*`
# can span slashes. Resolve the candidate parent independently (supporting a
# relative, trailing-slash, symlinked, or otherwise non-normalized SKILL_DIR),
# then require that it names this exact run directory. The destructive path is
# reconstructed from the canonical parent and validated basename, so lexical
# traversal can never select an object in another directory.
LOCK_DIR="${LOCK_PATH%/*}"
LOCK_BASENAME="${LOCK_PATH##*/}"
[ "$LOCK_DIR" != "$LOCK_PATH" ] || LOCK_DIR="."
case "$LOCK_BASENAME" in
  *$'\n'*) exit 2 ;;
esac
printf '%s\n' "$LOCK_BASENAME" \
  | LC_ALL=C grep -Eq '^actas\.([-A-Za-z0-9._]|%[0-9A-F]{2})*__([-A-Za-z0-9._]|%[0-9A-F]{2})*\.session$' \
  || exit 2

LOCK_DIR="$(cd -P "$LOCK_DIR" 2>/dev/null && pwd -P)" || exit 2
[ "$LOCK_DIR" = "$RUN_DIR" ] || exit 2
export SKILL_DIR
SCRIPT_DIR="$SKILL_DIR/scripts"
LOCK_PATH="$RUN_DIR/$LOCK_BASENAME"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-reclaim-mutex.sh"

# Old clients enter this directory while it is empty.  There is no portable
# way to distinguish that live state from a v1 crash, so never remove or work
# around it.  Upgrading this protocol requires all mutators to restart; a
# leftover legacy directory may be manually removed only after that boundary.
[ ! -d "${LOCK_PATH}.reclaim.d" ] || exit 4

# This top-level Bash pid is the mutex owner.  On the only destructive branch
# below, `exec rm` preserves it through the unlink; there is no independently
# running mutator child whose parent can die and falsely look reclaimable.
HELPER_PID="$$"
actas_reclaim_mutex_acquire "$LOCK_PATH" "$HELPER_PID" || exit 5

CURRENT=""
PATH_PRESENT=0
READ_OK=0
if [ -e "$LOCK_PATH" ] || [ -L "$LOCK_PATH" ]; then
  PATH_PRESENT=1
fi
if [ "$PATH_PRESENT" -eq 1 ] && [ -f "$LOCK_PATH" ]; then
  if CURRENT="$(head -1 "$LOCK_PATH" 2>/dev/null)"; then
    READ_OK=1
  fi
fi
if [ "$PATH_PRESENT" -ne 1 ]; then
  actas_reclaim_mutex_release || true
  # A peer may have completed the same stale reclaim while this helper waited
  # for the logical mutex. This is a normal contention outcome, not evidence
  # of an unreadable lock; the claimant retries its atomic link attempt.
  exit 7
fi
if [ "$READ_OK" -ne 1 ]; then
  actas_reclaim_mutex_release || true
  exit 6
fi

case "$MODE" in
  exact)
    if [ "$CURRENT" != "$EXPECTED" ]; then
      actas_reclaim_mutex_release || true
      exit 3
    fi
    ;;
  stale)
    OWNER="${CURRENT%%$'\t'*}"
    if [ -n "$OWNER" ] && agmsg_instance_alive "$OWNER"; then
      actas_reclaim_mutex_release || true
      exit 3
    fi
    ;;
esac

# Narrow the mixed-version window: an old client may have created its empty
# mutex while this helper was waiting.  It still cannot be made safe to remove
# automatically, so observe it again under the new mutex and fail closed.  A
# full all-mutator restart remains the protocol transition boundary because an
# old client could begin after even this final check.
if [ -d "${LOCK_PATH}.reclaim.d" ]; then
  actas_reclaim_mutex_release || true
  exit 4
fi

# This must remain the helper's final action.  Do not replace it with `rm`
# followed by mutex cleanup: Bash would fork rm, recreating the parent-death
# split that this helper exists to prevent.  The next helper/SessionStart GC
# generation-CASes the intentionally stale SQLite row.
exec rm "$LOCK_PATH"
