#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/registry-lock.sh"
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/roster-journal.sh"
# For `_agmsg_pid_alive_local`, which is where liveness is OWNED. A bare
# `kill -0` here would be a second answer to "is it running?" beside the one
# that file exists to give -- and a repo-wide check refuses one, correctly.
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/instance-id.sh"
# For `compat_get_cmdline`, which is how `scripts/remote.sh` already answers
# "is this pid still the process I started?" on every platform this ships to.
# shellcheck disable=SC1091
source "$SKILL_DIR/scripts/lib/compat.sh"

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

ROSTER_SYNC_BUDGET_S="${AGMSG_ROSTER_SYNC_TIMEOUT_S:-120}"
# A BOUND THAT CANNOT BE READ IS NOT A BOUND. `read -t` rejects a zero, a
# negative or a non-numeric budget by failing immediately, and its failure is
# indistinguishable here from "the writer is gone" — so a mistyped setting
# would turn the ceiling off and leave the wait unbounded, silently, which is
# the defect this file is closing (raised in review). Checked before anything
# is started — and before the lock is taken, because refusing after the lock
# and after `agmsg_roster_ensure` would mean a setting error had already moved
# the team's state and taken the critical section (raised in review).
# The length is checked with the digits, because a value can be all digits and
# still be unusable: `[ "$x" -le 0 ]` on a thirty-digit number is beyond what
# the shell's integers hold, and it errors — under `set -e` that ends this
# script with the shell's own status and none of the sentence below, which is
# the silent refusal this guard exists to remove (raised in review). Nine
# digits is over thirty years in seconds; nothing legitimate reaches it.
case "$ROSTER_SYNC_BUDGET_S" in
  ''|*[!0-9]*|??????????*)
    echo "agmsg: roster sync $operation failed for team '$team': AGMSG_ROSTER_SYNC_TIMEOUT_S must be a positive whole number of seconds, at most nine digits, got '${AGMSG_ROSTER_SYNC_TIMEOUT_S:-}'" >&2
    exit 15 ;;
esac
if [ "$ROSTER_SYNC_BUDGET_S" -le 0 ]; then
  echo "agmsg: roster sync $operation failed for team '$team': AGMSG_ROSTER_SYNC_TIMEOUT_S must be greater than zero, got '$ROSTER_SYNC_BUDGET_S'" >&2
  exit 15
fi


agmsg_lock_acquire "$team_dir"
# agmsg_lock_acquire already installs EXIT cleanup and exit-on-INT/TERM traps.
# Keep those handlers: replacing them with release-only handlers would let a
# signal return into this critical section after the lock had been dropped.
trap 'agmsg_lock_release; exit 129' HUP
agmsg_roster_ensure "$team_dir" "$config"

node_bin="${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"

# "Is the recorded pid still the process this operation started?" — asked in
# ONE place, so the signalling path and the release decision cannot come to
# different answers. Two questions with one wording is how a gate ends up
# guarding something narrower than the thing it authorises.
#
# A NUMBER IN A FILE IS NOT AN IDENTITY (raised as BLOCKING, and the answer
# was already in this repo). A pid is recycled the moment its process is
# reaped, so between the wrapper writing that number and the timeout path
# reading it, it can belong to something else entirely.
# `_remote_sync_engine_status` in `scripts/remote.sh` had already been here:
# "A live PID is not enough: PID reuse can make an unrelated process pass
# kill -0, so running requires the exact engine script/team suffix in argv."
#
# Both halves are required. Liveness alone reads a recycled number as our
# child; argv alone would accept a match on a pid that is already gone. The
# suffix is specific rather than convenient: `$config` is per-team, so a
# roster sync for a DIFFERENT team cannot satisfy it.
# THREE ANSWERS, AND A BOOLEAN CANNOT CARRY THEM (raised in review, twice).
#
# The first version of this returned true/false, so every caller had to read
# "false" as "gone" — and false covered two very different things: the process
# really has exited, and the process is alive but we could not establish that
# it is ours. Releasing the lock is only safe for the first. Collapsing them
# put the unsafe reading on the default path, which is the same shape as every
# other defect in this PR.
#
# So it prints one of three words:
#
#   ours     alive, and still carrying this operation's argv
#   gone     not alive — the only answer that authorises a release
#   unknown  everything else, and it is NOT a residual category:
#              * no pid recorded at all (the wrapper never got that far, so
#                whether node started is not known — this used to read as
#                "gone" and release)
#              * alive, argv does not match — a recycled number, OR our child
#                with an argv this platform would not hand over
_roster_inner_state() {
  if [ -z "${_roster_inner:-}" ]; then
    printf 'unknown\n'
    return
  fi
  # "UNUSABLE" AND "DEAD" ARE NOT THE SAME ANSWER (raised in review).
  #
  # `_agmsg_pid_alive_local` starts by rejecting a pid outside the POSIX
  # ceiling and returns 1 for it — the same 1 it returns for "no such
  # process". A digits-only value can be unusable: `2147483648` passes the
  # crude filter at the call site and is refused here, and reading that
  # refusal as `gone` releases the lock on a question that could not be asked.
  # So the validator is consulted FIRST, and its refusal is `unknown`.
  if ! _agmsg_pid_valid "$_roster_inner" 2147483647; then
    printf 'unknown\n'
    return
  fi
  if ! _agmsg_pid_alive_local "$_roster_inner"; then
    printf 'gone\n'
    return
  fi
  local cmd
  cmd="$(compat_get_cmdline "$_roster_inner" 2>/dev/null || true)"
  # THE WHOLE QUESTION LIVES IN `agmsg_roster_argv_is_ours`, and it lives in
  # `scripts/lib/roster-journal.sh` rather than here so that its cases can
  # drive IT rather than a copy of it. Inline, the only way to reach it was to
  # run the driver, so the tests re-implemented the comparison and then
  # asserted on this file with `grep` -- which measures a duplicate and a
  # spelling, never the thing production calls (raised in review).
  #
  # What it holds, and why, is documented beside it: the quoted forms are
  # enumerated rather than the quotes removed, because a quote is an argument
  # boundary and deleting it lets a quoted DATA argument that merely contains
  # the triple pass as an invocation; both path alphabets, because
  # `/c/Users/...` and `C:/Users/...` are the same path; the ordered triple
  # with argument boundaries, because three separate `contains` checks are
  # three questions and an ordered substring is still a substring.
  if agmsg_roster_argv_is_ours "$cmd" "$SCRIPT_DIR/roster-sync.mjs" "$operation" "$config"; then
    printf 'ours\n'
    return
  fi
  printf 'unknown\n'
}

# Signalling has exactly one safe answer, so it gets its own name rather than
# every call site re-deriving it from the word.
_roster_inner_still_ours() {
  [ "$(_roster_inner_state)" = "ours" ]
}

# THE CRITICAL SECTION IS BOUNDED IN TIME, NOT ONLY IN SCOPE (#821).
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
# THE BOUND ADDS NO PROCESS THAT OUTLIVES THE CALL (#821).
#
# The first version put a watchdog beside the child: one more process per
# roster operation. The leading explanation for the field failure is process
# pressure — a spawn refused with a Windows DLL-initialisation status — so a
# guard against hanging that raises the number of spawns can make the thing it
# guards against more likely. Raised in review, and it is the right objection.
#
# So the wait is bounded by a READ, not by a second process. The child is given
# one end of a FIFO it never writes to; when it exits, that end closes and the
# read here returns end-of-file.
#
# This USED TO SAY that `read -t` then distinguishes the two outcomes by
# status — above 128 for the budget, anything else for a departed writer — AND
# THAT WAS WRONG WHERE IT RUNS. The correction and its measurement are below;
# the sentence is kept in the past tense so this file does not appear to state
# two contracts at once.
#
# What this does NOT claim is "no extra process at all": `mktemp`, `mkfifo` and
# `rm` are external commands and each is a spawn (raised in review; an earlier
# version of this comment said "one process runs, exactly as before", which is
# false). They are short-lived and sequential, where a watchdog is concurrent
# and lives as long as the operation — and on a machine that is refusing
# spawns, a process held open beside every roster call is the shape that
# matters. What happens when one of them fails is NOT "fall back to the
# unbounded path" — that is what this used to do, and it is the defect. See
# the mode table below: no FIFO still bounds by polling, and no temp file at
# all refuses.
# A FIFO to notice the child's exit by, and a SENTINEL to say what happened.
#
# Two files, because one of them cannot answer both questions on the shell
# this actually runs under. `read -t` returns 1 for a timeout AND 1 for
# end-of-file on Bash 3.2 — measured on 3.2.57, which is what the macOS
# runners use — so a bound written as `status > 128` is simply never taken
# there. That is what happened: a two-second budget waited twenty-five
# minutes, on the one platform whose bash cannot tell the two apart, while
# every Linux leg stayed green because Bash 5 does distinguish them.
#
# So the ANSWER IS NOT THE RETURN CODE. The wrapper writes its child's exit
# status to a sentinel as its last act; this side reads the sentinel. Present
# means the wrapper finished — including when the command could not be exec'd
# at all, because a failed exec sets `$?` in the wrapper and the wrapper still
# reaches the write. Absent after the wait means the wrapper is still there,
# which is the only case a bound is for.
_roster_fifo="$(mktemp -u 2>/dev/null)" || _roster_fifo=""
_roster_sentinel="$(mktemp 2>/dev/null)" || _roster_sentinel=""
_roster_pidfile="$(mktemp 2>/dev/null)" || _roster_pidfile=""

# FAILING TO BUILD THE BOUND MUST NOT RUN WITHOUT ONE (raised by three
# reviewers, and they are right).
#
# This used to fall back to the foreground, unbounded call — the exact state
# #821 forbids — and printed `running without a time bound` while doing it.
# That is not a fallback. "The instrument could not be built, so the property
# is dropped" reproduces the defect on precisely the machines least able to
# afford it: a temp directory that is full or unwritable is the same condition
# that makes a child hang, so the two arrive together.
#
# There are two ways to wait with a ceiling, and only the faster one needs a
# FIFO:
#
#   fifo  a blocking read on a descriptor the wrapper holds. No polling, so no
#         spawn while waiting — which is why it is preferred on a machine that
#         is refusing spawns.
#   poll  the sentinel is looked for on a timer. Costs one `sleep` per second
#         of waiting, and needs nothing but the two temp files.
#
# Both bound the wait. Only when even `mktemp` fails is there no bound to be
# had, and then this REFUSES: releases the lock and says why, rather than
# taking the critical section for an unlimited time.
_roster_wait=none
if [ -n "$_roster_sentinel" ] && [ -n "$_roster_pidfile" ]; then
  if [ -n "$_roster_fifo" ] && mkfifo "$_roster_fifo" 2>/dev/null; then
    _roster_wait=fifo
  else
    _roster_fifo=""
    _roster_wait=poll
  fi
fi

# A PARTIAL SETUP LEAVES PART OF ITSELF BEHIND, AND `none` IS WHERE IT SHOWS
# (raised in review).
#
# The three `mktemp` calls above run independently, so "could not build a
# bound" is not one state: the sentinel can exist while the pidfile failed, or
# the other way round. Both routes out of `none` — the override and the
# refusal — used to walk past whatever had already been created, and the
# failure that sends a run down here is *a temp directory that is full*. A
# feature that responds to a full filesystem by adding a file to it is the
# wrong shape, and it is the same self-defeating loop `sync-autostart.sh`
# already carries a comment about.
#
# Swept once, here, before either route is taken. `rm -f` on an empty name is
# a no-op, so the three cases (none created, one, two) need no branching, and
# `|| true` because nothing below may hang on a failed unlink.
if [ "$_roster_wait" = "none" ]; then
  rm -f "$_roster_sentinel" "$_roster_pidfile" 2>/dev/null || true
fi

# THE WAY OUT, because a refusal with no override is a wall. An operator who
# knows their filesystem cannot hold a temp file, and would rather risk the
# lock than not sync at all, can say so — deliberately, by name, in the
# environment. What is removed is the SILENT return to the old behaviour.
if [ "$_roster_wait" = "none" ] && [ "${AGMSG_ROSTER_SYNC_UNBOUNDED:-0}" = "1" ]; then
  echo "agmsg: roster sync $operation for team '$team': AGMSG_ROSTER_SYNC_UNBOUNDED=1 — running the local roster child with NO time bound; if it hangs it holds the team lock until this process is killed" >&2
  "$node_bin" "$SCRIPT_DIR/roster-sync.mjs" "$operation" "$config" \
    "$server" "$remote" "$protocol" "$@"
  case "$operation" in
    reconcile|apply) agmsg_roster_project_config "$team_dir" "$config" ;;
  esac
  exit 0
fi

if [ "$_roster_wait" = "none" ]; then
  agmsg_lock_release
  echo "agmsg: roster sync $operation failed for team '$team': cannot create the temporary files needed to bound the local roster child (is TMPDIR set to a path that exists and is writable, and is the filesystem full?); refusing rather than holding the team lock for an unlimited time. To run it anyway, set AGMSG_ROSTER_SYNC_UNBOUNDED=1." >&2
  exit 16
fi

# One spawn, whichever wait follows: when there is no FIFO the wrapper's fd 8
# goes to /dev/null, so the line that starts the child is the same in both
# modes and its descriptor closing cannot drift between them.
_roster_write_target="/dev/null"
if [ "$_roster_wait" = "fifo" ]; then
  _roster_write_target="$_roster_fifo"
fi

# Both remaining modes are bounded; `none` has already left, one way or the
# other. The block is kept so the two waits sit inside one spawn/teardown.
if [ "$_roster_wait" != "none" ]; then
  # fd 9 is this shell's stdin, kept for the child: a shell with job control
  # off gives an asynchronous command /dev/null for stdin, and backgrounding
  # the child silently took away the records the engine had already written to
  # fd 0. Measured, as every operation failing with "input is invalid".
  exec 9<&0
  # The wrapper records the READ CHILD'S pid before waiting on it, because the
  # thing that has to be stopped on a timeout is the command, not the shell
  # around it. Signalling the wrapper alone leaves the command orphaned, still
  # holding this shell's stdout — and a caller that captures output then waits
  # for an end-of-file that never comes. That is the same "an abandoned child
  # keeps the caller's streams" defect fixed twice tonight, and it reappeared
  # here: measured, as a three-second budget that had not returned after
  # seventeen minutes.
  {
    # `3>&- 4>&-` HERE AS WELL AS ON THE GROUP, and the repetition is the point.
    # The enclosing group already closes both, so node's descriptors were never
    # actually at risk — but `tests/test_spawn_fd_guard.bats` reads the spawn
    # LINE, deliberately: an exemption keyed on "something upstream closes them"
    # accepts an `exec` inside a branch that never runs, or after the spawn it
    # was supposed to cover. Redundancy is the cheaper mistake, and the same
    # belt-and-braces pattern is already in `scripts/lib/sync-autostart.sh`.
    "$node_bin" "$SCRIPT_DIR/roster-sync.mjs" "$operation" "$config" \
      "$server" "$remote" "$protocol" "$@" <&9 9<&- 3>&- 4>&- &
    _rs_node=$!
    # THE WRAPPER'S OWN COPY, AND IT IS A THIRD ONE. Introducing this shell to
    # carry the pid put a process between the driver and node that inherits
    # fd 9 and was closing it nowhere — so the caller's stdin was held for the
    # whole operation by something neither the child's `9<&-` nor the parent's
    # `exec 9<&-` reaches. The same class as the two closes around it, made
    # reachable again by the shell added to fix a different one.
    #
    # CI found this, and the case that found it is the behavioural half whose
    # comment said `$PPID` is the driver. It stopped being the driver when this
    # brace group appeared; the assertion then read THIS shell's table and
    # reported fd 9 open, which was the truth.
    #
    # Closed here rather than in the group's redirection list, because node
    # above still needs it: `<&9` is read when that command starts.
    exec 9<&-
    printf '%s\n' "$_rs_node" > "$_roster_pidfile"
    _rs_rc=0
    wait "$_rs_node" || _rs_rc=$?
    printf '%s\n' "$_rs_rc" > "$_roster_sentinel"
  } 3>&- 4>&- 8> "$_roster_write_target" &
  _roster_child=$!
  # BOTH COPIES GO. `<&9` duplicates the caller's stdin onto fd 0 and leaves
  # fd 9 open beside it, so node would hold that stream twice and this shell
  # would hold it until its own exit — the same "a child keeps the caller's
  # streams" class fixed twice tonight, reintroduced by the descriptor used to
  # fix it (raised in review). The child closes its saved copy in the
  # redirection above; this closes ours the moment it is no longer needed.
  exec 9<&-
  if [ "$_roster_wait" = "fifo" ]; then
    # The two opens rendezvous: a writer's `8>` does not complete until a reader
    # arrives, so this cannot be left waiting for a writer that has already gone.
    exec 8< "$_roster_fifo"
    # `|| true` because this file runs under `set -e` and `rm` is an external
    # command: a spawn refused, or a filesystem that will not unlink, would end
    # this shell HERE — while the child is still running — and the EXIT trap
    # would release the lock beside a live writer. That is worse than the leak
    # being fixed, and it is the one place this fix could create it (raised in
    # review). The FIFO is already open on fd 8; unlinking it is tidiness, and
    # tidiness may not decide whether the lock is held.
    rm -f "$_roster_fifo" || true

    # The read's own status is DELIBERATELY DISCARDED. It cannot be trusted to
    # separate "the budget expired" from "the writer is gone" on Bash 3.2, and
    # trusting it there is the defect this replaces.
    read -r -t "$ROSTER_SYNC_BUDGET_S" _roster_ignored <&8 || true
    exec 8<&-
  else
    # NO FIFO, AND STILL BOUNDED. The wrapper's fd 8 went to /dev/null, so
    # there is nothing to read; what is watched instead is the sentinel the
    # wrapper writes as its last act — the same fact, asked on a timer rather
    # than by blocking.
    #
    # `-s` and not `-e`: the file was created empty by `mktemp`, so its mere
    # existence says nothing. It is non-empty exactly once the status is in it.
    #
    # The cost is one `sleep` per second of waiting, and that is why this is
    # the second choice rather than the only one — on a machine refusing
    # spawns, a wait that spawns is the wrong shape. It is still the right
    # trade against no bound at all.
    #
    # `SECONDS` is the shell's own counter, so the deadline needs no `date`.
    #
    # `|| true` ON THE SLEEP, for the same reason the `rm` above has one, and
    # it is sharper here (raised in review). `sleep` is an external command
    # under `set -e`; a refused spawn would end this shell HERE — with the
    # wrapper and node already started and none of the terminate/KILL/reap
    # below reached — and the EXIT trap would drop the lock beside a live
    # writer. That is the contract this path is written to keep, broken by the
    # one command it uses to wait. And this mode is *chosen* on machines that
    # could not make a FIFO, which is the same population that refuses spawns.
    #
    # What a failing `sleep` costs instead: this loop spins on `SECONDS` until
    # the deadline. Hot, and bounded, and it still terminates — the right
    # trade against exiting mid-critical-section.
    _roster_deadline=$((SECONDS + ROSTER_SYNC_BUDGET_S))
    while [ ! -s "$_roster_sentinel" ] && [ "$SECONDS" -lt "$_roster_deadline" ]; do
      sleep 1 || true
    done
  fi

  if [ -s "$_roster_sentinel" ]; then
    _roster_status="$(cat "$_roster_sentinel" 2>/dev/null || printf '13')"
    wait "$_roster_child" 2>/dev/null || true
    rm -f "$_roster_sentinel" "$_roster_pidfile" || true
    [ "$_roster_status" = "0" ] || exit "$_roster_status"
  else
    # No sentinel: the wrapper has not reached its last act. Stop it, give it a
    # moment, insist, and REAP it — the lock is not released while the process
    # that was writing under it may still be running, because letting the next
    # caller in beside a live writer is worse than the leak being fixed.
    _roster_inner="$(cat "$_roster_pidfile" 2>/dev/null || true)"
    # A leading zero, a negative, a word, or an empty file all mean the same
    # thing here: there is no pid to work with. Cleared once, so the predicate
    # refuses it in one place rather than every caller guessing.
    case "$_roster_inner" in
      ''|*[!0-9]*|0*) _roster_inner="" ;;
    esac
    # WHAT WAS ACTUALLY ATTEMPTED IS RECORDED, because the state can change
    # under us between one signal and the next (raised in review, and it stood
    # for three rounds before I read it properly). "Attempted" is the whole
    # claim — see the note below, and do not widen this heading back to
    # "sent": the block would then state two different contracts.
    #
    # The predicate is re-asked before TERM and again before KILL, which is
    # right — but it means a pid that was `ours` at the first can be `unknown`
    # at the second, through recycling or an argv that stopped being readable.
    # The diagnostic then said "nothing was signalled on that number", which
    # would be FALSE: TERM had already gone out. An operator reading that
    # would go looking for a process nobody had touched.
    # ATTEMPTED, and the name is the claim. `kill ... || true` discards its
    # status, so what this shell can honestly record is that it CALLED kill —
    # not that a signal was accepted, and certainly not that one was
    # delivered. An earlier version set these beside the call and then the
    # diagnostic said "TERM WAS SENT", which under EPERM or ESRCH is false:
    # the same "discarded the result of kill" boundary this path exists to
    # respect, crossed again in the reporting (raised in review).
    _roster_term_attempted=0
    _roster_kill_attempted=0
    # Signalled ONLY when it is still the process we started. Anything else is
    # left alone: the cost of not signalling our own child is a lock we keep
    # and report; the cost of signalling someone else's is a process we had no
    # business touching.
    if _roster_inner_still_ours; then
      kill -TERM "$_roster_inner" 2>/dev/null || true
      _roster_term_attempted=1
    fi
    # The wrapper needs no such check — it is this shell's own child, held in
    # `$!` and not reaped until below, so its number cannot have been recycled
    # while we still hold it.
    kill -TERM "$_roster_child" 2>/dev/null || true
    # `|| true`: a failed spawn here would exit before the KILL and the reap,
    # leaving the EXIT trap to release the lock beside a child that ignored
    # TERM — the precise case this grace period exists for.
    sleep 2 || true
    # Re-asked, not remembered: the grace period is exactly the window in
    # which our child can exit and its number be handed to someone else. A
    # KILL aimed at an answer obtained two seconds ago is the same defect as
    # the TERM above, one branch later.
    # ESCALATION IS MONOTONE, and this is a safety rule rather than a tidiness
    # one (raised in review). The predicate is re-asked, so the other
    # direction of the transition is possible too: `unknown` before TERM, then
    # `ours` before KILL, through recycling or an instrument that failed once
    # and recovered. The old code would then send KILL to a number it had just
    # refused to send TERM to — escalating against something it never
    # established a claim on.
    #
    # So KILL requires BOTH: that we were entitled to TERM this number, and
    # that it is still ours now. A number once judged unidentifiable is not
    # re-adopted later in the same timeout.
    if [ "$_roster_term_attempted" = "1" ] && _roster_inner_still_ours; then
      kill -KILL "$_roster_inner" 2>/dev/null || true
      _roster_kill_attempted=1
    fi
    kill -KILL "$_roster_child" 2>/dev/null || true
    wait "$_roster_child" 2>/dev/null || true
    # Read once more AFTER the reap: a wrapper that was finishing while this
    # side gave up would otherwise be reported as a timeout it never had.
    #
    # THE SENTINEL DOES NOT SHORT-CIRCUIT THE GATE (raised in review). It is
    # written by the wrapper only after `wait` on node returned, so it *should*
    # imply the inner process is gone — but that is an argument about the
    # wrapper's code, not an observation of this machine, and the branch it
    # guards is the one that releases the lock. So the same question is asked
    # here too. It costs nothing when the inner really has exited: the
    # predicate fails on its first call and this reads exactly as it did
    # before.
    # AND IT ASKS FOR THE WORD, NOT FOR A YES/NO. Gating this on
    # `_roster_inner_still_ours` was the same collapse one layer up: "not
    # ours" released the lock, and "not ours" includes "alive, unidentifiable"
    # (raised in review). Only `gone` may pass.
    if [ -s "$_roster_sentinel" ] && [ "$(_roster_inner_state)" != "gone" ]; then
      AGMSG_HELD_LOCKS=""
      rm -f "$_roster_sentinel" "$_roster_pidfile" || true
      echo "agmsg: roster sync $operation failed for team '$team': the wrapper recorded an exit status, but process '$_roster_inner' could not be confirmed to have exited (state: $(_roster_inner_state)). The team lock is being KEPT rather than released. Check that process, then remove $team_dir/.config.lock" >&2
      exit 17
    fi
    if [ -s "$_roster_sentinel" ]; then
      _roster_status="$(cat "$_roster_sentinel" 2>/dev/null || printf '13')"
      rm -f "$_roster_sentinel" "$_roster_pidfile" || true
      [ "$_roster_status" = "0" ] || exit "$_roster_status"
    else
      # "I SENT A SIGNAL" IS NOT "THE PROCESS IS GONE" (raised as BLOCKING).
      #
      # Everything above discards its result: `kill -TERM ... || true`, then
      # `kill -KILL ... || true`. Neither says whether anything died. The inner
      # process is a GRANDCHILD, so `wait` cannot speak for it either — only
      # the wrapper is this shell's child. So the release below used to rest on
      # nothing at all: a signal refused by a sandbox, or a process wedged in an
      # uninterruptible state, and the lock came off anyway with the writer
      # still running. That is the one outcome this whole path exists to avoid,
      # and the comment two branches up says so in as many words.
      #
      # So the question is ASKED, with the repo's own instrument.
      # `_agmsg_pid_alive_local` is the right one of the two: this pid was
      # minted by `$!` in one of these shells and read back from a pidfile one
      # of them wrote. It reads EPERM as alive, treats a zombie as gone, and
      # cross-checks with `ps` so a sandbox that refuses to signal cannot be
      # mistaken for a process that is not there.
      #
      # AND IT ASKS THE SAME QUESTION THE SIGNALS DID, not a weaker one. An
      # earlier version gated on liveness alone, which reads a recycled number
      # as "our child is still running" (raised in review). The predicate is
      # the pair — alive AND still carrying this operation's argv — so the two
      # cannot drift apart.
      #
      # WHICH WAY IT FAILS MATTERS MORE THAN WHETHER IT CAN:
      #
      #   wrong "still ours"  the lock is held when it need not be — visible,
      #                       named, and fixable by hand.
      #   wrong "gone"        the lock comes off beside a live writer. Silent,
      #                       and it corrupts.
      #
      # `_agmsg_pid_alive_local` errs toward "alive"; the argv match errs
      # toward "not ours". Their conjunction therefore errs toward "gone" —
      # the WRONG direction — so a pid that is alive but unrecognisable is
      # reported as UNKNOWN below rather than folded into either answer.
      # Waited on only while the answer is `ours` — the one state in which the
      # process may still be finishing. `gone` and `unknown` are both terminal
      # here: nothing about waiting turns an unreadable argv into a readable
      # one.
      _roster_confirm_deadline=$((SECONDS + 5))
      while [ "$(_roster_inner_state)" = "ours" ] && [ "$SECONDS" -lt "$_roster_confirm_deadline" ]; do
        # `|| true` for the third time, and for the same contract: exiting
        # here would release the lock through the trap without ever reaching
        # the decision below.
        sleep 1 || true
      done

      # ONE READ OF THE WORD, THEN THREE ARMS. Taken once rather than per
      # branch so the arms cannot disagree about what was observed.
      _roster_state="$(_roster_inner_state)"

      # THE DIAGNOSTIC REPORTS WHAT WAS ATTEMPTED, once, for both exits below.
      # Computed here rather than in each branch so the two cannot describe
      # the same run differently — and worded as ATTEMPTS, because `kill`'s
      # status was discarded and delivery is not observable from this side at
      # all.
      _roster_signal_note="No signal was attempted on that number: it was never identifiable as this operation's child"
      if [ "$_roster_term_attempted" = "1" ] && [ "$_roster_kill_attempted" = "1" ]; then
        _roster_signal_note="TERM and then KILL were both ATTEMPTED on that number while it carried this operation's argv; whether either was accepted or delivered is not known here"
      elif [ "$_roster_term_attempted" = "1" ]; then
        _roster_signal_note="TERM was ATTEMPTED on that number while it carried this operation's argv, and KILL was then WITHHELD because it no longer did — so a process may have been signalled once and not stopped"
      fi

      if [ "$_roster_state" = "unknown" ]; then
        AGMSG_HELD_LOCKS=""
        rm -f "$_roster_sentinel" "$_roster_pidfile" || true
        echo "agmsg: roster sync $operation failed for team '$team': the local roster child did not finish within ${ROSTER_SYNC_BUDGET_S}s, and its fate could not be established — the recorded pid was '$_roster_inner', which is either absent or alive without this operation's argv. $_roster_signal_note. The team lock is being KEPT rather than released, since releasing it beside a writer that may still be running can corrupt the roster journal. Check that process, then remove $team_dir/.config.lock" >&2
        exit 18
      fi

      if [ "$_roster_state" = "ours" ]; then
        # THE LOCK IS KEPT, ON PURPOSE, AND THE OPERATOR IS TOLD.
        #
        # Emptying `AGMSG_HELD_LOCKS` is how the lock survives: the EXIT trap
        # calls `agmsg_lock_release`, which walks that list and does nothing
        # when it is empty. The directory stays where it is. Reaching for the
        # trap itself would fight the library that installed it; this uses the
        # library's own state.
        #
        # This does not reopen #821. That property is "a child that hangs must
        # not hold the critical section INDEFINITELY, silently" — and this
        # shell exits, now, with the pid and the path to remove. What it
        # refuses to do is claim a process was stopped when it was not.
        AGMSG_HELD_LOCKS=""
        rm -f "$_roster_sentinel" "$_roster_pidfile" || true
        echo "agmsg: roster sync $operation failed for team '$team': the local roster child did not finish within ${ROSTER_SYNC_BUDGET_S}s, and process $_roster_inner is STILL RUNNING and still carrying this operation's argv. $_roster_signal_note. The team lock is being KEPT rather than released, because releasing it beside a live writer can corrupt the roster journal. Stop that process, then remove $team_dir/.config.lock" >&2
        exit 17
      fi

      # ONLY `gone` REACHES HERE, AND IT IS SAID RATHER THAN LEFT IMPLIED.
      # The two arms above return, so falling through means the word was
      # `gone` — but a fourth state added later would fall through too, and
      # inherit a release nobody meant to give it. This refuses instead.
      if [ "$_roster_state" != "gone" ]; then
        AGMSG_HELD_LOCKS=""
        rm -f "$_roster_sentinel" "$_roster_pidfile" || true
        echo "agmsg: roster sync $operation failed for team '$team': internal error — the roster child's state was reported as '$_roster_state', which this code does not know how to act on. The team lock is being KEPT rather than released. Remove $team_dir/.config.lock once you are satisfied nothing is writing to the team" >&2
        exit 19
      fi
      rm -f "$_roster_sentinel" "$_roster_pidfile" || true
      # Released here rather than left to the EXIT trap. The trap is the
      # mechanism that is not reached when a child never returns, and a fix
      # that leans on it on the one path it exists for is not a fix. It still
      # runs afterwards and finds nothing to do.
      agmsg_lock_release
      echo "agmsg: roster sync $operation failed for team '$team': the local roster child did not finish within ${ROSTER_SYNC_BUDGET_S}s; it was stopped, confirmed gone, and the team lock released" >&2
      # Stopping between the journal write and the state write leaves the two
      # out of step. Each is written by rename, so neither is torn — but that
      # the next run converges from every such point is NOT established, and is
      # recorded on the issue rather than claimed here.
      exit 14
    fi
  fi
fi

case "$operation" in
  reconcile|apply) agmsg_roster_project_config "$team_dir" "$config" ;;
esac
