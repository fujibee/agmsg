# Start a connected team's sync engine when an agent turns up (#774).
#
# A machine restart leaves every sync engine dead and nothing restarts one. The
# agent keeps working, `send` keeps committing locally, and nothing reaches the
# other machines until a person happens to type `remote sync start`. #765 made
# that visible; a warning still asks a person to do what the machine can do.
#
# Sourced by the two places an agent establishes what it is:
#   scripts/session-start.sh   — where the monitor is started
#   scripts/actas-claim.sh     — where a session takes on a role, and a team
#
# ONE ENGINE PER (MACHINE, TEAM) IS NOT ENFORCED HERE, AND MUST NOT BE.
#
# `cmd_sync_start` already takes `agmsg_lock_acquire "$TEAMS_DIR/<team>"`, and
# under that lock it answers `Sync engine already running (pid N).` and returns
# 0. The pidfile is per team. So the invariant holds by construction in the
# command, and this calls the command.
#
# The alternative — checking the pidfile here and starting only when it looks
# dead — puts a SECOND answer to "is it running?" in the tree, outside the lock
# that makes the first one true. Two answers to that question diverge exactly
# when several sessions open at once, which is the case this exists for: they
# race for the lock, one starts the engine, the rest are told `already running`
# and carry on. That behaviour is the command's, and it is inherited rather than
# reproduced.
#
# THE BINDING CHECK IS INHERITED TOO. `cmd_sync_start` refuses a team with no
# active binding and a disconnected team, by name, before it starts anything.
# Filtering on the binding here would be the same duplication one level up.
#
# NOTHING HERE MAY FAIL A SESSION, AND FAILING INCLUDES BEING SLOW.
#
# Returning 0 on every path is only half of it — the first version did that and
# still ran `sync start` synchronously, which means `actas` did not print
# `status=ok` and session start did not emit the Monitor directive until the
# engine was ready. `cmd_sync_start` waits for a readiness nonce (~16s of its
# own before it gives up), takes a per-team lock others may be holding, and can
# be stuck for as long as its child is. Multiplied by the number of connected
# teams, in the critical path of an agent opening. A release-blocker fix that
# can stop a session from starting is not a fix (raised in review).
#
# So each start runs in the BACKGROUND and this waits, at most, for a whole-call
# budget shared by every team. When the budget runs out the child is LEFT
# RUNNING rather than killed: it may be seconds from having started the engine,
# and killing it could leave a half-made pidfile behind. What stops is the
# WAITING. The session goes on and the line says a start is still in flight.

# Usage: agmsg_sync_autostart <remote.sh path> <team>...
#
# Prints, at most, one block: the teams whose engines this call started, and the
# teams it could not start. A team whose engine was already running produces no
# output at all — starting is a side effect the person did not ask for in this
# moment, and "nothing changed" is not news.
agmsg_sync_autostart() {
  local remote_sh="$1"; shift
  # Sourced here rather than at file scope: this file is sourced by two hooks,
  # and pulling in a second file at their top level is a cost they pay whether
  # or not anything is started.
  if ! declare -F agmsg_close_inherited_fds >/dev/null 2>&1; then
    local _lib_dir="${BASH_SOURCE[0]%/*}"
    # shellcheck source=scripts/lib/close-fds.sh
    [ -r "$_lib_dir/close-fds.sh" ] && . "$_lib_dir/close-fds.sh"
  fi
  [ -x "$remote_sh" ] || return 0
  [ $# -gt 0 ] || return 0
  if ! declare -F _agmsg_dir_take >/dev/null 2>&1; then
    # shellcheck source=registry-lock.sh
    . "${BASH_SOURCE[0]%/*}/registry-lock.sh"
  fi

  # Seconds, for the whole call. Overridable so a test can drive the deadline
  # without waiting for it, and so an operator on a slow machine can raise it.
  local budget="${AGMSG_SYNC_AUTOSTART_TIMEOUT_S:-5}"
  local elapsed_start=$SECONDS

  local team out rc tmp started="" failed="" slow=""
  for team in "$@"; do
    [ -n "$team" ] || continue
    # WHY THERE IS NO REFUSAL CHECK HERE, having had one (#773).
    #
    # The version of this that read `remote.sh status` before each start
    # existed to stop a restart loop: the engine used to EXIT when the server
    # refused, so auto-start would raise it again on the next session and it
    # would exit again.
    #
    # #792 removed that. The engine now records the refusal, backs off to its
    # longest interval and keeps the loop — `sleepCall(MAX_BACKOFF_MS);
    # continue;` — so starting a refused team costs one quiet process that
    # reports the reason through `status`, and there is no loop to prevent.
    #
    # The check was not free. It put a second command in the path where a
    # session prints its Monitor directive, and bounding it correctly took a
    # background wrapper, a watchdog, a shared deadline, a grace period and a
    # reaping rule — seven review rounds of machinery to make a lookup safe
    # that the thing it protected against no longer needs. Reading the engine
    # is what settled it, not the review count.
    # A START THAT DID NOT HAPPEN IS A FAILED START, AND IS SAID SO (#810).
    #
    # This used to `return 0` here. Three things went with it: no engine was
    # started, NOTHING was printed — the started/slow/failed blocks are all
    # built after the loop, so leaving early skips every one of them — and the
    # teams after this one were abandoned without being tried.
    #
    # The cost is specific. #761/#765 exist so that "connected, and not
    # syncing" is never silent, and #775 replaced their warning with this
    # function on the stated grounds that the warning survives whenever a start
    # fails. On this path it did not: the operator was told nothing, which is
    # the exact state those issues were opened about, reachable by another door.
    #
    # `mktemp` failing is not a missing binary — it is `TMPDIR` unset to a path
    # that does not exist, or not writable, or a full filesystem. The last one
    # is uncomfortable here, because a start that outruns its budget
    # deliberately leaves its two temp files behind, so this feature can
    # contribute to the condition that used to silence it.
    tmp="$(mktemp 2>/dev/null)" || tmp=""
    if [ -z "$tmp" ]; then
      failed="$failed$team	could not create a temporary file (is the temp filesystem full or unwritable?)"$'\n'
      continue
    fi
    # stderr folded in: `cmd_sync_start` says why it refused on stderr, and that
    # sentence is the useful half of a failure. Swallowing it would leave this
    # printing "could not start" with the reason on the floor.
    # THE QUESTION IS "HAS IT FINISHED?", NOT "IS IT ALIVE?".
    #
    # The child writes its exit status to a sentinel as its last act, and this
    # polls for the sentinel. No pid is examined, so no liveness check is made
    # — which is what `scripts/lib/instance-id.sh`'s `_agmsg_pid_alive` exists
    # to own, and what a bare `kill -0` here would have duplicated badly (a
    # repo-wide check catches that; mine reached CI before I did).
    #
    # It is also the more exact question. `kill -0` succeeds for a child that
    # has exited and not been reaped, so polling liveness would have waited
    # past the moment the answer was available.
    # DETACHED FROM THIS CALLER'S STREAMS, and that is not tidiness.
    #
    # The child is deliberately allowed to outlive this function. If it still
    # holds the caller's stdout, anything that CAPTURES that output — `run` in
    # a test, `$(...)`, a hook whose output is piped — waits for EOF, and a
    # start that hangs then hangs the session. That is the requirement this
    # whole budget exists for, broken in a way no exit code and no timeout
    # here could see: I measured it as a suite that stopped finishing.
    #
    # stdin too: a child left on a terminal can stop for input.
    (
      # EVERY INHERITED DESCRIPTOR, not just 0/1/2.
      #
      # Detaching stdin/stdout/stderr was necessary and not sufficient: bats
      # hands a harness pipe down on fd 3 and 4, and a child that keeps them
      # open holds the shard after every case has passed. `scripts/lib/close-fds.sh`
      # exists because that exact leak hung a shard once already, from a
      # different spawn path — and a repo-wide check found mine.
      #
      # Called INSIDE the subshell so it closes the child's copies and leaves
      # this shell's own descriptors alone, which is the pattern that file's
      # own comment prescribes.
      agmsg_close_inherited_fds
      "$remote_sh" sync start "$team" >"$tmp" 2>&1
      printf '%s\n' "$?" > "$tmp.rc"
      # One noclobber owner marker decides which side reached cleanup first;
      # mkdir alone can report a racing EEXIST as success on both sides.
      # If the child loses, the caller has stopped waiting and delegates cleanup
      # to this child. If the child wins, leave the results for the caller,
      # unless its fast path has already read and removed them. In that case
      # the child also removes the marker the caller may have missed.
      if _agmsg_dir_take "$tmp.gaveup" 2>/dev/null; then
        [ -f "$tmp.rc" ] || _agmsg_dir_drop "$tmp.gaveup" 2>/dev/null
      else
        rm -f "$tmp" "$tmp.rc"
        _agmsg_dir_drop "$tmp.gaveup" 2>/dev/null
      fi
    ) </dev/null >/dev/null 2>&1 3>&- 4>&- &
    # The literal `3>&- 4>&-` as well as the call inside, because the repo-wide
    # check reads the spawn LINE (tests/test_spawn_fd_guard.bats). Belt and
    # braces is the right answer here anyway: the call closes whatever the
    # runtime handed down, and the redirections say so where a reader — and
    # that check — can see it without following a function.
    while [ ! -f "$tmp.rc" ] && [ $((SECONDS - elapsed_start)) -lt "$budget" ]; do
      sleep 0.1
    done
    if [ ! -f "$tmp.rc" ]; then
      # Budget spent, but NOT necessarily "the child has not finished" --
      # the write ($tmp.rc) and this check are not atomic with each other,
      # so the child may finish in the gap between them. The owner claim below is
      # what actually answers "did the child already get here first", not
      # this -f test (see the matching one in the child above):
      if _agmsg_dir_take "$tmp.gaveup" 2>/dev/null; then
        # Got there first. The child has not reached its own owner claim
        # yet (has not finished, or has not reached that line even if it
        # has), so it still owns removing $tmp/$tmp.rc once it does.
        slow="$slow$team"$'\n'
        continue
      fi
      # The child's owner claim got there first, which only happens once it has
      # already written $tmp.rc -- so despite the budget, this reads
      # exactly like the fast path below, just a little later.
    fi
    rc="$(cat "$tmp.rc" 2>/dev/null || printf '1')"
    out="$(cat "$tmp" 2>/dev/null)"
    # Order matters here, and is NOT interchangeable with the rmdir right
    # below: this rm must run FIRST. The child's own self-correction (see
    # its ownership-succeeded branch above) only removes the marker when it
    # finds $tmp.rc already gone -- if this rm ran AFTER that rmdir instead,
    # a child that is still between its mkdir and that re-check would see
    # the marker gone, assume this side already finished, and never clean
    # up $tmp/$tmp.rc itself, leaking both.
    rm -f "$tmp" "$tmp.rc"
    # Covers BOTH ways this line is reached: the budget-exceeded branch just
    # above, where the child's owner claim winning is what sent this here instead
    # of to `continue`, and the plain fast path (the while loop above exited
    # because $tmp.rc already existed, never entering that branch at all) --
    # on the fast path the child's own owner claim almost always wins (the caller
    # never tried its own), leaving the marker owned by nobody once the
    # child's "do nothing further" half of the protocol is reached; cleaned
    # up here rather than left as a new kind of leaked empty directory. A
    # no-op either way if the child got here first and already removed it.
    _agmsg_dir_drop "$tmp.gaveup" 2>/dev/null
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'already running'; then
      continue
    fi
    if [ "$rc" -eq 0 ]; then
      started="$started$team"$'\n'
      continue
    fi
    # The team name AND what the command said. A bare "could not start <team>"
    # sends the reader to a log to find a sentence this already had.
    failed="$failed$team	$(printf '%s' "$out" | tr '\n' ' ')"$'\n'
  done

  if [ -n "$started" ]; then
    # Written as a loop rather than a joined string: a team name may contain
    # characters that make a one-line join ambiguous, and one line per team is
    # what the #765 block already established as this hook's voice.
    printf '%s\n' 'AGMSG: no sync engine was running; started one for:'
    printf '%s' "$started" | while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf '  %s\n' "$t"
    done
    printf '\n'
  fi

  if [ -n "$slow" ]; then
    printf '%s\n' "AGMSG: a sync engine start is still in flight after ${budget}s; not waiting for it:"
    printf '%s' "$slow" | while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf '  %s\n' "$t"
    done
    printf '%s\n' 'The session continues. Check it with:' ''
    printf '%s' "$slow" | while IFS= read -r t; do
      [ -n "$t" ] || continue
      printf '  bash %q status %q\n' "$remote_sh" "$t"
    done
    printf '\n'
  fi

  if [ -n "$failed" ]; then
    printf '%s\n' 'AGMSG: connected, but not syncing.' ''
    printf '%s\n' \
      'No sync engine is running for the team(s) below and starting one failed,' \
      'so messages from other machines are not arriving. The session continues.' ''
    printf '%s' "$failed" | while IFS=$'\t' read -r t reason; do
      [ -n "$t" ] || continue
      printf '  %s: %s\n' "$t" "$reason"
      # The runnable line, UNCHANGED FROM #765 — including its two-space
      # indent. That prefix is part of the contract: `test_delivery.bats`
      # extracts the command with `sed -n 's/^  bash //p'` and runs it, so a
      # deeper indent leaves the operator's remedy unrunnable by the check that
      # proves it is runnable (measured: it failed on exactly that).
      printf '  bash %q sync start %q\n' "$remote_sh" "$t"
    done
    printf '\n'
  fi

  return 0
}
