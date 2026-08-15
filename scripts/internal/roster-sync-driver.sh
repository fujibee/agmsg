#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/roster-journal.sh"

operation="${1:?Missing operation}"; team="${2:?Missing team}"
server="${3:?Missing server id}"; remote="${4:?Missing remote team id}"
protocol="${5:?Missing protocol version}"; shift 5
# The caller supplies the roster path; it derives it from the connection root and
# hands over one file. The fallback below is for running this driver DIRECTLY —
# by hand, or from a test — on a single-machine install where the skill directory
# is the connection root. It is not a location this driver should be working out
# on behalf of the engine: a second machine keeps its teams somewhere else
# entirely, and guessing here is what made an existing roster look missing.
config="${AGMSG_SYNC_LOCAL_ROSTER_FILE:-$SKILL_DIR/teams/$team/config.json}"
team_dir="$(cd "$(dirname "$config")" && pwd)"

agmsg_lock_acquire "$team_dir"
# agmsg_lock_acquire already installs EXIT cleanup and exit-on-INT/TERM traps.
# Keep those handlers: replacing them with release-only handlers would let a
# signal return into this critical section after the lock had been dropped.
trap 'agmsg_lock_release; exit 129' HUP
agmsg_roster_ensure "$team_dir" "$config"

node_bin="${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"

# THE CRITICAL SECTION IS BOUNDED IN TIME, NOT ONLY IN SCOPE (#817).
#
# The scope is right and stays: `roster-sync.mjs` is the read-modify-write of
# the journal and state this lock exists to serialise. It does no network —
# measured, with a positive control on the search — and its whole input is
# handed over in one write before it starts, so nothing in here waits on a
# remote. Moving it out of the lock would move the very thing being protected.
#
# What was missing is a bound. Release was the EXIT trap alone, which is sound
# when this shell reaches its own exit: a child that fails to start, or exits
# non-zero, still gets there under `set -e`. It is not sound when the child
# neither runs nor returns — the shell waits, the trap never runs, and the lock
# is held by a live process that will never finish. The next start then fails
# on `.config.lock: File exists`, and the team is unusable until someone finds
# a directory they have no reason to know about.
#
# So the wait has a ceiling, and passing it is a failure with a name rather
# than a hang. The traps stay as the backup they always were.
ROSTER_SYNC_BUDGET_S="${AGMSG_ROSTER_SYNC_TIMEOUT_S:-120}"

# THE BOUND COSTS NO EXTRA PROCESS, and on this machine that is the point.
#
# The first version put a watchdog beside the child: one more process per
# roster operation. The leading explanation for the field failure is process
# pressure — a spawn refused with a Windows DLL-initialisation status — so a
# guard against hanging that raises the number of spawns can make the thing it
# guards against more likely. Raised in review, and it is the right objection.
#
# So the wait is bounded by a READ, not by a second process. The child is given
# one end of a FIFO it never writes to; when it exits, that end closes and the
# read here returns end-of-file. `read -t` distinguishes the two outcomes by
# status: >128 means the budget expired, and anything else means the writer is
# gone. One process runs — node — exactly as before this change.
# A path to make the FIFO at, and nothing written to it: the child never sends
# anything, and what this waits for is the moment its end closes.
_roster_fifo="$(mktemp -u 2>/dev/null)" || _roster_fifo=""
_roster_bounded=0
if [ -n "$_roster_fifo" ] && mkfifo "$_roster_fifo" 2>/dev/null; then
  _roster_bounded=1
fi

if [ "$_roster_bounded" = "1" ]; then
  # fd 9 is this shell's stdin, kept for the child: a shell with job control
  # off gives an asynchronous command /dev/null for stdin, and backgrounding
  # the child silently took away the records the engine had already written to
  # fd 0. Measured, as every operation failing with "input is invalid".
  exec 9<&0
  "$node_bin" "$SCRIPT_DIR/roster-sync.mjs" "$operation" "$config" \
    "$server" "$remote" "$protocol" "$@" <&9 3>&- 4>&- 8> "$_roster_fifo" &
  _roster_child=$!
  exec 8< "$_roster_fifo"
  rm -f "$_roster_fifo"

  _roster_read_status=0
  read -r -t "$ROSTER_SYNC_BUDGET_S" _roster_ignored <&8 || _roster_read_status=$?
  exec 8<&-

  if [ "$_roster_read_status" -gt 128 ]; then
    # The budget expired with the child still holding its end. Stop it, give it
    # a moment, insist, and REAP it — the lock is not released while the process
    # that was writing under it may still be running, because letting the next
    # caller in beside a live writer is worse than the leak being fixed.
    kill -TERM "$_roster_child" 2>/dev/null || true
    sleep 2
    kill -KILL "$_roster_child" 2>/dev/null || true
    wait "$_roster_child" 2>/dev/null || true
    # Released here rather than left to the EXIT trap. The trap is the mechanism
    # that is not reached when a child never returns, and a fix that leans on it
    # on the one path it exists for is not a fix. It still runs afterwards and
    # finds nothing to do.
    agmsg_lock_release
    echo "agmsg: roster sync $operation failed for team '$team': the local roster child did not finish within ${ROSTER_SYNC_BUDGET_S}s; it was stopped and the team lock released" >&2
    # Stopping between the journal write and the state write leaves the two out
    # of step. Each is written by rename, so neither is torn — but that the next
    # run converges from every such point is NOT established, and is recorded on
    # the issue rather than claimed here.
    exit 14
  fi

  # End of file: the child is gone, and `wait` gives its status directly.
  # `|| _roster_status=$?` because this file runs under `set -e` and `wait`
  # returns the child's code — without it a node exiting 13 would kill this
  # shell here, before anything below could report why.
  _roster_status=0
  wait "$_roster_child" || _roster_status=$?
  [ "$_roster_status" = "0" ] || exit "$_roster_status"
else
  # No FIFO — an exotic filesystem, or a temp directory that does not support
  # one. The previous behaviour is what remains: run it in the foreground and
  # wait as long as it takes. Stated rather than silently degraded, because a
  # bound that is sometimes absent is worse documentation than none.
  echo "agmsg: roster sync $operation for team '$team': cannot create a FIFO in the temp directory; running without a time bound" >&2
  "$node_bin" "$SCRIPT_DIR/roster-sync.mjs" "$operation" "$config" \
    "$server" "$remote" "$protocol" "$@"
fi

case "$operation" in
  reconcile|apply) agmsg_roster_project_config "$team_dir" "$config" ;;
esac
