#!/usr/bin/env bash
# Per-team advisory lock for the team registry (teams/<team>/config.json).
#
# Every registry writer (join / leave / reset / rename / rename-team) does a
# read-modify-write: it reads the whole config, computes a new version, and
# overwrites the file. Run concurrently against the same team these races lost
# updates — two joins both read the old config, and whichever writes last clobbers
# the other's agent, so a registration silently disappears even though both
# commands exit 0 (#141).
#
# The fix serializes each team's read-modify-write behind a lock. A directory is
# the lock primitive: mkdir is atomic on POSIX and needs no daemon, so it works
# on macOS (where flock(1) is absent) under bash 3.2, and on Windows Git Bash.
# This is the same idiom the jsonl storage driver uses. The lock is per-team
# (teams/<team>/.config.lock), so operations on different teams never serialize
# against each other.
#
# A process may hold more than one team lock at a time (rename-team locks both the
# source and the target team), so the held locks are tracked as a set and all are
# released together by agmsg_lock_release / the cleanup trap.
#
# Callers pair the lock with a write through agmsg_write_atomic so an unlocked
# reader (whoami / identities / inbox read config.json without the lock) never
# observes a half-written file.

# Newline-separated set of lock dirs this process currently holds.
AGMSG_HELD_LOCKS="${AGMSG_HELD_LOCKS:-}"

# agmsg_lock_acquire <team_dir>
# Acquire <team_dir>'s lock. <team_dir> (teams/<team>) must already exist — the
# caller creates it for a brand-new/target team before locking, so this never
# resurrects a team dir that a concurrent leave/reset just removed. Spins with a
# short sleep until AGMSG_LOCK_SECONDS elapse (default 10), then fails non-zero
# so the caller can abort rather than silently skip the team.
#
# BUDGETED IN TIME, NOT ITERATIONS (#779). The old budget was 1000 attempts and
# the comment beside it read "= ~10s", which is arithmetic that holds only where
# an mkdir and a sleep are free. Measured on macOS: 100 attempts take 3 seconds,
# not 1 — already three times the stated figure, before Windows, where the
# report that raised this saw minutes. A wait announced in seconds has to be
# counted in seconds, or the number in the message is not about the wait.
#
# AGMSG_LOCK_TRIES still caps the attempt count and still defaults to 1000. It
# is set by four tests to make them fail fast and by nothing in production, so
# it stays as a ceiling — whichever bound is reached first ends the wait, and
# each one names itself when it does.
# Who owns the directory and what this process is, for a failure that is about
# neither the team nor the lock. `ls -ld` and `id` rather than stat(1), whose
# flags differ between BSD and GNU, and both are already required here.
_agmsg_lock_describe_dir() {
  local dir="$1"
  echo "agmsg:   $(ls -ld "$dir" 2>/dev/null || printf '%s (cannot stat)' "$dir")" >&2
  echo "agmsg:   running as: $(id 2>/dev/null || echo 'unknown')" >&2
}

agmsg_lock_acquire() {
  local team_dir="$1" lock i=0 max="${AGMSG_LOCK_TRIES:-1000}" err=""
  local budget="${AGMSG_LOCK_SECONDS:-10}" started elapsed
  started="$(date +%s)"
  lock="$team_dir/.config.lock"
  until err="$(mkdir "$lock" 2>&1)"; do
    # WHY mkdir failed decides whether waiting can help, and only one reason
    # ever clears on its own: somebody holds the lock. Everything else -- no
    # write permission on the team dir, a read-only mount -- is a standing
    # condition, and spinning ten seconds on it then reporting a timeout
    # describes contention that never existed.
    #
    # That mattered in the field. A second machine, running as a different OS
    # account, pointed at the first one's store; the team dir was 0755 and
    # owned by the other user, so mkdir could never succeed. The message named
    # a lock, so the search went to processes: an unrelated sync engine was
    # killed, and when it happened again with no engine running and no lock
    # directory present, the same sentence was still the only evidence. The
    # `2>/dev/null` had thrown away the one line that said EACCES.
    #
    # Decided from the lock's presence rather than from the error text, which
    # is locale-dependent. Checked in this order because the lock existing is
    # the common case and settles it: only when it is absent is the question
    # "can we write here at all". Absent AND writable is a lost race with a
    # holder that has already released -- genuinely transient, so it spins.
    if [ ! -d "$lock" ] && [ ! -w "$team_dir" ]; then
      echo "agmsg: cannot create the registry lock in $team_dir" >&2
      echo "agmsg: mkdir: $err" >&2
      echo "agmsg: nothing is holding the lock — this directory cannot be written to, so waiting will not clear it." >&2
      _agmsg_lock_describe_dir "$team_dir"
      return 1
    fi
    i=$((i + 1))
    elapsed=$(( $(date +%s) - started ))
    # Whichever bound arrives first, and the message says which — "1000 tries"
    # and "10 seconds" are different facts about a wait, and an operator
    # deciding whether to retry needs the one that actually stopped it.
    if [ "$elapsed" -ge "$budget" ] || [ "$i" -ge "$max" ]; then
      # ONE PHRASE, then which bound. Callers match on "timed out acquiring
      # registry lock" — `test_remote.bats` does, with a short attempt budget —
      # and inventing a second sentence for the attempt ceiling broke them
      # while telling the operator nothing they could not be told in a clause.
      if [ "$elapsed" -ge "$budget" ]; then
        echo "agmsg: timed out acquiring registry lock for $team_dir after ${elapsed}s" >&2
      else
        echo "agmsg: timed out acquiring registry lock for $team_dir after $i attempts (${elapsed}s)" >&2
      fi
      # The reason travels with the timeout too. If the wait was hopeless for
      # a cause this function did not anticipate, the errno is the only thing
      # that will say so.
      [ -n "$err" ] && echo "agmsg: last mkdir error: $err" >&2
      return 1
    fi
    sleep 0.01
  done
  # WHO HOLDS IT, written the moment it is held (#778).
  #
  # A lock directory with nothing in it can say that something is holding it and
  # nothing about what. When one leaks, the operator's only options are to guess
  # or to remove it blind — and removing a live lock is worse than the leak. The
  # pid and the command are what turn "a lock is here" into "this process, and
  # it is gone".
  #
  # Best-effort on purpose: the lock is HELD as of the mkdir above, and a failure
  # to annotate it must not undo that. An unannotated lock is exactly the lock
  # this file had before, which is worse than one that names its holder and no
  # worse than nothing.
  #
  # The token is what release checks. A pid is not enough: the directory can be
  # removed by an operator while this process still believes it holds the lock —
  # the remedy printed further down tells them to do exactly that — and a second
  # process can then take the same path. Releasing on "it is mine because I once
  # took this path" would delete the SUCCESSOR's lock and break the exclusion
  # this file exists for (raised in review). The token makes "mine" checkable.
  # PER LOCK, not per process. This library's own contract is that a process can
  # hold several locks at once — rename-team takes two — so a single global
  # token is overwritten by the second acquire, and releasing the first then
  # reads a mismatch, calls it someone else's, and leaks it (raised in review).
  #
  # Entropy: a pid and a second are not unique across hosts on a shared store,
  # and $RANDOM is 15 bits where it exists at all. /dev/urandom is the source
  # when there is one; the fallbacks degrade toward "cannot prove it is mine",
  # and an unprovable lock is one this process will refuse to delete rather
  # than one it deletes on a coincidence.
  local nonce=""
  nonce="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [ -n "$nonce" ] || nonce="${RANDOM:-}${RANDOM:-}${RANDOM:-}"
  # FAIL SAFE MEANS NO TOKEN, not a weak one. With neither /dev/urandom nor
  # $RANDOM, what is left is host.pid.second — which collides across hosts, and
  # a collision makes this process delete someone else's successor. That is the
  # hazard the token exists to close, so the degraded path must not produce a
  # token at all.
  #
  # No token recorded means release finds no match and refuses to remove
  # anything: the lock leaks, and leaking is the failure this file chose over
  # taking a live lock away. The claim "it degrades toward not deleting" was
  # written before this branch existed; it is true now (raised in review).
  if [ -n "$nonce" ]; then
    _agmsg_lock_set_token "$lock" "${HOSTNAME:-h}.$$.$(date +%s).$nonce"
  fi
  {
    printf 'token %s\n' "$(_agmsg_lock_get_token "$lock")"
    printf 'pid %s\n' "$$"
    printf 'command %s\n' "${0##*/}"
    printf 'host %s\n' "${HOSTNAME:-$(uname -n 2>/dev/null || echo unknown)}"
  } > "$lock.holder" 2>/dev/null || true
  AGMSG_HELD_LOCKS="${AGMSG_HELD_LOCKS:+$AGMSG_HELD_LOCKS
}$lock"
  # Idempotent: re-arming the same handlers each acquire is harmless. They release
  # every held lock, so a crash with one or two locks held leaves no stale lock.
  # EXIT releases only. INT/TERM release AND exit, so a signal arriving between
  # commands in a critical section can't release the lock and then let the script
  # continue into an unprotected config move/write (matters for 2-lock
  # rename-team). NOTE: no current registry writer sets its own trap; a future
  # caller that does must chain these in.
  trap 'agmsg_lock_release' EXIT
  trap 'agmsg_lock_release; exit 130' INT
  trap 'agmsg_lock_release; exit 143' TERM
}

# agmsg_lock_release
# Release every lock this process holds (no-op if none). rmdir only removes the
# (empty) lock dirs, never a team dir or its config.
# agmsg_lock_release_one <team_dir>
# Release ONE lock and leave every other held lock alone.
#
# `agmsg_lock_release` drops everything this process holds, which is right for a
# command that is finishing and wrong for anything that acquires a lock inside a
# larger operation: the caller may hold locks for other teams, and this library's
# own contract is that it can. A caller that acquired one lock and released all
# of them has taken locks away from code that is still using them.
#
# The line is matched WHOLE, not as a substring: lock paths nest (a team named
# `a` and a team named `ab` under the same root), so a substring test would let
# one team's release take another's.
# Release one lock directory, and say so when it cannot be released (#778).
#
# `rmdir … || true` treated two different events as one. A lock that is already
# gone is a released lock — nothing to report. A lock that will not go is the
# leak this file's own contract promises not to leave, and the operator learned
# about it only when the next command blocked, with nothing naming the cause.
#
# The holder file written at acquire time makes the directory non-empty, so the
# removal is two steps. Both are this process's own file and its own lock; a
# failure of either is reported rather than swallowed.
# Per-lock token storage, kept in one newline-separated variable because bash
# 3.2 has no associative arrays and this library targets it.
#
# Format: one "<lock path>\t<token>" per line. The path is matched WHOLE, for
# the reason AGMSG_HELD_LOCKS already documents: lock paths nest, so a substring
# test would let one team's entry answer for another's.
_agmsg_lock_set_token() {
  local path="$1" token="$2" kept="" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      "$path	"*) ;;
      *) kept="${kept:+$kept
}$line" ;;
    esac
  done <<EOF
${_AGMSG_LOCK_TOKENS:-}
EOF
  _AGMSG_LOCK_TOKENS="${kept:+$kept
}$path	$token"
}

_agmsg_lock_get_token() {
  local path="$1" line
  while IFS= read -r line; do
    case "$line" in
      "$path	"*) printf '%s' "${line#*	}"; return 0 ;;
    esac
  done <<EOF
${_AGMSG_LOCK_TOKENS:-}
EOF
  return 1
}

_agmsg_lock_drop() {
  local l="$1" err="" seen="" mine=""
  [ -d "$l" ] || return 0
  # OWNERSHIP FIRST. The directory being at the path this process locked is not
  # evidence that it is the same directory: an operator can remove a stuck lock
  # — the message below tells them to — and another process can take the path
  # before this one releases. Deleting then would take the exclusion away from
  # a process that is using it, which is worse than the leak this whole change
  # is about (raised in review).
  #
  # Compared against the token written at acquire, not the pid: a pid recurs.
  seen="$(sed -n 's/^token //p' "$l.holder" 2>/dev/null | head -1)"
  mine="$(_agmsg_lock_get_token "$l" || printf '')"
  # An empty recorded token means this process never proved ownership of this
  # path — refuse rather than guess. Same branch as a genuine mismatch.
  if [ -z "$mine" ] || [ "$seen" != "$mine" ]; then
    # Someone else's lock, or one whose holder file could not be written. Either
    # way this process has no standing to remove it, and saying so is the whole
    # report — there is nothing here for the operator to fix.
    if [ -z "$mine" ]; then
      # This process never recorded a token for this path: either the holder
      # could not be written, or there was no entropy to make one with. Saying
      # "another process holds it" would be a claim about someone else that
      # nothing here supports.
      echo "agmsg: not releasing $l — this process cannot prove the lock is its own" >&2
    else
      echo "agmsg: not releasing $l — it is held by another process now" >&2
    fi
    return 0
  fi
  # The holder is READ before it is removed, and restored byte for byte if the
  # directory will not go.
  #
  # Restoring only the token was the first attempt and it defeated the change:
  # pid, command and host are what "a leaked lock says who left it" MEANS, and
  # a stuck removal is exactly the moment an operator needs them. The one
  # failure this file is about would have been the one failure with no
  # diagnosis (raised in review).
  #
  # Removing the holder first is unavoidable — a directory with a file in it
  # cannot be rmdir'd — so the ordering is: read, remove, try, restore on
  # failure.
  # The holder lives BESIDE the lock, not inside it. A lock directory has to be
  # empty to be removed, and `rm` is not available on every path that takes this
  # lock — `test_local_team_ids.bats` runs the core join with an allow-listed
  # PATH that has no `rm`. A holder written inside the directory made the lock
  # unremovable there, so the one path promising to work without python3 leaked
  # a lock on every call. CI reported it first, but it is reproducible here:
  # build a directory of symlinks to the tools that test allow-lists, point
  # PATH at it, and the pre-fix library leaks while this one releases. Nothing
  # about it needs CI — the local suite simply runs with a full PATH by
  # default, which is a habit rather than a limit.
  #
  # Outside, `rmdir` succeeds and the holder is a stale file next to nothing —
  # tidied when it can be, harmless when it cannot.
  if err="$(rmdir "$l" 2>&1)"; then
    # The holder is a sibling, so removing the directory does not remove it.
    # Left behind it is a stale file in the team directory, and `rename-team`
    # ends with `rmdir "$OLD_DIR"` — which then fails, and the rename leaves the
    # old directory standing. Measured: that is what broke the quoted-team-name
    # test, on a path with no lock message anywhere in it.
    #
    # Best-effort: `rm` is not on every allow-listed PATH that takes this lock,
    # and a leftover holder beside no lock is inert. The lock itself is gone,
    # which is the part that had to succeed.
    if command -v rm >/dev/null 2>&1; then
      rm -f "$l.holder" 2>/dev/null || true
    fi
    return 0
  fi
  # NOTHING TO RESTORE. The holder is a sibling, so the rmdir above never
  # touched it — it is still on disk, with the pid, command and host intact,
  # which is what the operator reading the message below needs.
  #
  # An earlier version of this file wrote the holder INSIDE the lock, had to
  # remove it before rmdir, and restored it on failure. That restore survived
  # the move to a sibling as dead code referencing an unset `saved`: harmless
  # where `set -u` is off, an unbound-variable error where it is on, and in
  # neither case doing anything. Raised in review.
  # Still here. Say which lock, say why, and say what it costs — the next
  # acquire on this team will wait for a holder that is not coming back.
  echo "agmsg: could not release the registry lock at $l" >&2
  echo "agmsg: rmdir: $err" >&2
  echo "agmsg: until this directory is removed, commands for this team will wait" >&2
  echo "agmsg: for a lock nothing holds." >&2
  # The remedy has to work for the case that produced it. `rmdir` is what just
  # failed — printing it back is a route that ends where the operator already
  # is. Measured: the only reason release gets here with the directory present
  # is that something is inside it, and that is precisely what rmdir refuses.
  # QUOTED, because a printed command is meant to be pasted into a shell. The
  # store root and the team name can both contain a space — team names are
  # validated against empty / `.` / `..` / `/` / `\` / a leading `-` / control
  # characters, and nothing else — so an unquoted path becomes several
  # arguments, and `rm -r` then removes something the operator did not read
  # about (raised in review). Same scheme as lib/shquote.sh, inline rather than
  # sourced so this library keeps its single-file contract.
  local q
  q="$(printf "'%s'" "$(printf '%s' "$l" | sed "s/'/'\\''/g")")"
  echo "agmsg: look at what is in it, then remove the directory:" >&2
  echo "agmsg:   ls -la $q" >&2
  echo "agmsg:   rm -r $q" >&2
  echo "agmsg: nothing but this lock lives in there — it holds no team data." >&2
  return 1
}

agmsg_lock_release_one() {
  local lock="$1/.config.lock" kept="" l
  [ -n "${AGMSG_HELD_LOCKS:-}" ] || return 0
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ "$l" = "$lock" ]; then
      # `|| true` here does NOT swallow the failure: `_agmsg_lock_drop` has
      # already reported it on stderr. What it does is keep the loop going, so
      # one stuck lock does not strand the others this process holds — the
      # opposite of the `rmdir … || true` this file replaced, where the failure
      # had nowhere else to appear.
      _agmsg_lock_drop "$l" || true
    else
      kept="${kept:+$kept
}$l"
    fi
  done <<EOF
$AGMSG_HELD_LOCKS
EOF
  AGMSG_HELD_LOCKS="$kept"
}

agmsg_lock_release() {
  [ -n "${AGMSG_HELD_LOCKS:-}" ] || return 0
  local l
  while IFS= read -r l; do
    # Reported inside the helper; `|| true` only keeps the loop alive so one
    # stuck lock cannot strand the rest. See the note in release_one.
    [ -n "$l" ] && { _agmsg_lock_drop "$l" || true; }
  done <<EOF
$AGMSG_HELD_LOCKS
EOF
  AGMSG_HELD_LOCKS=""
}

# agmsg_write_atomic <dest> <content>
# Write <content> (plus a trailing newline, matching the previous `echo >`) to a
# temp file in the same directory, then rename(2) it over <dest>. The rename is
# atomic, so a concurrent unlocked reader sees either the old or the new file,
# never a truncated one.
# Best effort, and said out loud rather than assumed: `rm` is NOT on the PATH
# that `join` is required to work under, so on that path a failed write leaves
# its temp behind. The temp is 0600 and holds no more than the destination
# would have, so what is lost is tidiness, not privacy -- and this is the one
# place in here allowed to shrug, because it runs only after a failure that has
# already been reported.
_agmsg_discard_temp() {
  if command -v rm >/dev/null 2>&1; then
    rm -f "$1"
  fi
}

# Remove what a failed attempt left, and NEVER let the removal speak for the
# attempt.
#
# Both commands are neutralised with `|| :`. Many of this repository's scripts
# run under `set -e`, where a `rmdir` that fails on a directory it could not
# empty aborts the shell BEFORE the caller's diagnostic is printed and before
# its `return 1` -- turning a named failure into a silent exit. Cleanup is
# allowed to fail here. It is not allowed to decide (#804, raised in review).
_agmsg_cleanup_attempt() {
  _agmsg_discard_temp "$1" || :
  rmdir "$2" 2>/dev/null || :
}

# SAID, NOT SWALLOWED (#802). On the PATH `join` is required to work under there
# is no `rm`, so a failed write cannot be removed and the directory holding it
# cannot be removed either. What survives is 0700 with a 0600 file inside --
# privacy intact, tidiness not -- and the operator is told WHERE in the same
# breath as the failure rather than finding it later.
_agmsg_say_residue() {
  if [ -d "$1" ]; then
    printf 'agmsg: a private copy of the failed attempt is left in %s\n' "$1" >&2
  fi
}

agmsg_write_atomic() {
  local dest="$1" content="$2" tmp
  # The temp is CREATED, never adopted, using only what the minimal PATH
  # guarantees: `umask` and `printf` from the shell, and `mkdir`, `mv` and
  # `rmdir`, which are on that list. It said "only shell builtins" while calling
  # three external commands -- true of a revision that used `noclobber`, and
  # contradicted twelve lines further down by the paragraph explaining why
  # `mkdir` and `rmdir` are safe to depend on.
  #
  # `> "$dest.tmp.$$"` onto a file a killed run left behind only truncates it:
  # the redirect does not touch the mode, and `umask` applies to creation, so
  # the content would exist at whatever that leftover was set to. For a binding
  # that is a disclosure -- `remote_binding.endpoint` is the credential on a
  # hosted deployment (#804).
  #
  # `mktemp` would solve it and CANNOT BE USED HERE. `join` is required to work
  # on a PATH that carries only bash, dirname, sqlite3, sed, date, mkdir, rmdir,
  # cat, mv, head, od, tr, sort, basename and paste -- there is a test for it,
  # and it caught the first attempt at this fix. `chmod` is not on that list
  # either; the version before this one called it and only survived because its
  # failure was ignored.
  #
  # So: `umask`, plus `mkdir` and `rmdir`, which that list does carry. An
  # earlier revision of this fix used `noclobber` (`set -C`) to refuse an
  # existing file; that is gone, and the paragraph describing it went with it,
  # because a comment that explains a primitive the code no longer uses is read
  # as enforcement by whoever arrives next. What replaced it is below: the temp
  # lives inside a directory this call created, and the name carries $RANDOM so
  # a leftover does not block the write forever.
  #
  # 0600 applies to every caller of this helper -- team configs, roster
  # journals, the codex port file, migrations. That is deliberate: it is how
  # this product already treats its own state (`key.sh`, the handoff bundle).
  # THE TEMP LIVES IN A DIRECTORY THIS CALL MADE, and that is the whole point.
  #
  # Two earlier shapes were refused by review, and the second one is why this is
  # a directory:
  #
  #   - creating the temp empty under `set -C` and then opening `$tmp` AGAIN to
  #     write it. The second open resolves the name a second time, so what the
  #     exclusive creation established could be replaced in between. An
  #     exclusive create whose result is reached BY NAME is not exclusive.
  #
  #   - merging those into one `>` and testing `[ -e ]` first. That test is a
  #     filter and not a guarantee -- which the comment said -- and then the
  #     failure branch removed `$tmp` on the reading that this process must have
  #     made it. When the loser of a real race takes that branch, the file it
  #     removes belongs to the WINNER. `$$` does not rescue the reasoning: a
  #     subshell shares its parent's pid, so two concurrent calls in one process
  #     tree draw from the same `$$.$RANDOM` space. The removal was the defect,
  #     not the detection.
  #
  # `mkdir` answers both. It is atomic, it fails rather than joining an existing
  # directory, and its SUCCESS is the proof of ownership that `[ -e ]` could
  # never be: everything inside belongs to this call, so the payload is written
  # into a name nothing else can be holding, and removing that name cannot
  # remove anyone else's. It is the same primitive this file already trusts for
  # the registry lock, for the same reason.
  #
  # `mkdir` and `rmdir` are both on the PATH `join` is required to work under --
  # checked, because that list is what ruled out `mktemp` and `chmod`.
  local attempts=0 tmpdir
  while :; do
    tmpdir="$dest.tmp.$$.$RANDOM.d"
    if ( umask 077; mkdir "$tmpdir" ) 2>/dev/null; then
      break
    fi
    # Taken, by anyone, for any reason: draw another name. Nothing is removed
    # here, because nothing here was created.
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 32 ]; then
      printf 'agmsg: could not create a private temporary directory beside %s\n' "$dest" >&2
      return 1
    fi
  done
  tmp="$tmpdir/new"

  # 0700 on the directory and 0600 on the file. The content is written once,
  # into a fresh name inside a directory only this call can enter.
  if ! ( umask 077; printf '%s\n' "$content" > "$tmp" ) 2>/dev/null; then
    _agmsg_cleanup_attempt "$tmp" "$tmpdir"
    printf 'agmsg: could not write the new contents for %s\n' "$dest" >&2
    _agmsg_say_residue "$tmpdir"
    return 1
  fi

  # The `mv` is what makes a reader see the whole new file or the whole old one.
  # The gate above is what makes the CONTENT whole: a `printf` that wrote half
  # the payload and then failed would otherwise be published, indivisibly, as
  # the truncated destination.
  if ! mv "$tmp" "$dest"; then
    _agmsg_cleanup_attempt "$tmp" "$tmpdir"
    printf 'agmsg: could not move the new contents into place at %s\n' "$dest" >&2
    _agmsg_say_residue "$tmpdir"
    return 1
  fi

  # PUBLISHED. EVERYTHING BELOW IS TIDYING, AND TIDYING DOES NOT GET A VOTE.
  #
  # This function used to end on a bare `rmdir`, so the status of the tidy-up
  # became the status of the write: a `rmdir` that failed after a `mv` that
  # succeeded returned non-zero, and the caller treated a committed write as a
  # failure. That needs no `set -e` to happen -- the last command's status is
  # the function's -- and under `set -e` it is worse, because the caller aborts
  # on a write that in fact landed. Review named it (#804).
  #
  # So the removal is checked, its failure is SAID rather than swallowed (#802),
  # and the return is explicit and unconditional. After a successful `mv` the
  # directory is empty and 0700, so a failure here is close to impossible; if it
  # happens, what leaks is an empty private directory, and the operator is told
  # which one rather than left to find it.
  if ! rmdir "$tmpdir" 2>/dev/null; then
    printf 'agmsg: wrote %s, but could not remove the temporary directory %s\n' "$dest" "$tmpdir" >&2
  fi
  return 0
}
