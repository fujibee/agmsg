#!/usr/bin/env bash
# actas-lock.sh — per-(team, agent) exclusivity locks.
#
# Background: agmsg supports a project being registered with multiple agent
# identities of the same type (claude-code/codex/...). Without ownership
# tracking, every concurrent CC session in that project would subscribe to
# every registered identity's messages — duplicate delivery, confused mark-
# read semantics, and the `actas` "exclusive role" model breaking down.
#
# This file implements a small filesystem-based ownership protocol:
#
#   Lock file: $SKILL_DIR/run/actas.<team>__<agent>.session
#   Content  : one line — the owner session_id.
#
# A session_id is alive iff some $SKILL_DIR/run/cc-instance.<pid> file
# currently contains it AND that PID is alive. The same primitive used by
# session-start.sh's orphan-watcher cleanup. Stale locks (owner is no
# longer alive) are reclaimable.
#
# Atomic claim is implemented via `ln` of a per-call tmp file. POSIX
# guarantees the link target either appears or doesn't, even under
# concurrent claim attempts.
#
# Required caller-set variable:
#   SKILL_DIR — agmsg skill root.

: "${SKILL_DIR:?actas-lock.sh requires SKILL_DIR}"

# Owner tokens are per-process instance ids (see instance-id.sh), not bare
# session_ids — this is what keeps parallel --continue/--resume sessions that
# share a session_id from each appearing to own the other's locks (#93). The
# liveness check (actas_lock_sid_alive) delegates to agmsg_instance_alive.
# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/instance-id.sh"

_actas_lock_dir() { printf '%s/run' "$SKILL_DIR"; }

# Encode a team or agent name into a filesystem-safe form. Anything outside
# [A-Za-z0-9._-] is percent-encoded byte-by-byte (UTF-8 safe, reversible).
# An earlier underscore-replacement scheme was lossy: "foo bar" and "foo_bar"
# collided on the same lock file, as did every Japanese team name (every
# non-ASCII byte mapped to "_"). #65 review, finding 2.
_actas_lock_encode() {
  printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { for (n = 0; n < 256; n++) ord[sprintf("%c", n)] = n }
    {
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c ~ /[A-Za-z0-9._\-]/) printf "%s", c
        else printf "%%%02X", ord[c]
      }
    }
  '
}

# Compute the lock file path for (team, agent).
actas_lock_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/actas.%s__%s.session' "$(_actas_lock_dir)" "$t" "$a"
}

# Readiness sentinel path for (team, agent). watch.sh creates this when an
# exclusive (actas) watcher attaches and removes it on exit, so the file is
# present iff a live watcher is currently receiving for that role. `spawn`
# uses it to block until a freshly launched agent is actually listening,
# instead of racing the agent's first push. Same encoding as the lock path so
# both scripts agree without env plumbing. See #108.
agmsg_ready_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/ready.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# Placement record path for a spawned (team, agent). `spawn` writes the
# member's tmux target id + project + type here at launch time so that
# `despawn --force` can tear the member down (kill its pane/window, drop its
# registration) even when the member's own watcher is dead and can't respond
# to a ctrl:despawn. Same encoding as the lock path. See #109.
agmsg_spawn_path() {
  local team="$1" agent="$2"
  local t a; t="$(_actas_lock_encode "$team")"; a="$(_actas_lock_encode "$agent")"
  printf '%s/spawn.%s__%s' "$(_actas_lock_dir)" "$t" "$a"
}

# ---------------------------------------------------------------------------
# Reading a lock.
#
# There is exactly ONE reader, and it reports the read's own outcome alongside
# the owner. The function it replaces, `actas_lock_owner`, answered the empty
# string for three different worlds:
#
#     the lock file is not there            -> ""   rc 0
#     the lock file is there but unreadable -> ""   rc 0
#     the lock file is there and is empty   -> ""   rc 0
#
# and returned 0 for all three, so a caller could not separate them even by
# checking the status. Four producers then guessed, and each guessed the
# destructive way: "could not read" arrived as "nobody holds this", which became
# claim / rm / consume. Guarding at each call site is not the fix, because the
# next call site starts from the same empty string. The fold is removed HERE,
# and no owner-only form is left in the tree to fall back into.
# (#983, tl's ruling; the same shape as terminal_team_observe in #1066.)
#
# Prints "<read>\t<owner>":
#
#   ok\t<owner>    the file was read. <owner> is its first line, and an EMPTY
#                  owner here is a fact ABOUT THE FILE, not a failed read.
#   absent\t       there is no lock file, and the directory it would live in is
#                  searchable -- so "there is none" is something we established.
#   unreadable\t   the lock is there and could not be read, OR its directory
#                  cannot be searched, in which case absence is not knowable.
#                  `[ -e ]` is false for BOTH "no such file" and "cannot look
#                  inside the parent", so the directory is asked first (co3).
_actas_lock_read_path() {   # <lock-path>
  local lock="$1" owner _dir
  if owner="$(head -1 "$lock" 2>/dev/null)"; then
    printf 'ok\t%s\n' "$owner"
    return 0
  fi
  _dir="${lock%/*}"
  if [ -e "$_dir" ] && { [ ! -r "$_dir" ] || [ ! -x "$_dir" ]; }; then
    printf 'unreadable\t\n'
    return 0
  fi
  if [ -e "$lock" ]; then
    printf 'unreadable\t\n'
    return 0
  fi
  # A missing lock DIRECTORY is `absent`, not `unreadable`: it is the ordinary
  # state of a fresh install. Collapsing it the other way is just as wrong and
  # far louder -- calling it unknown made spawn refuse to start anything (58
  # tests red in one run).
  printf 'absent\t\n'
}

# Same read, addressed by (team, agent) instead of by path.
actas_lock_read() {   # <team> <agent>
  _actas_lock_read_path "$(actas_lock_path "$1" "$2")"
}

# Return 0 if the given owner token is alive. The token is a per-process
# instance id (composite "<sid>.<pid>" or bare "<sid>" fallback); liveness is
# delegated to agmsg_instance_alive (composite -> kill -0 the embedded pid; bare
# -> live cc-instance.<pid> scan, with upgrade compat). Kept as a thin wrapper
# so existing callers (gc_stale, watch.sh subscription, session-start GC) need
# no change. Three-valued: 0 alive, 1 positively dead, 2 cannot tell.
actas_lock_sid_alive() {
  agmsg_instance_alive "$1"
}

# The verdict for one lock, shared by every producer.
#
# co1 found the SAME empty lock answered `free` by actas_lock_observe and
# `unknown:owner_empty` by _actas_lock_try_claim. Both had been made three-valued
# -- separately -- so two producers disagreed about one file and nothing in the
# code said which was right. tl's axis 5: it is not enough that a path returns
# unknown; every path must return the SAME unknown for the same state. So the
# decision lives in one function and the producers translate its answer into
# their own vocabulary instead of deciding again.
#
# Prints "<verdict>\t<owner>"; the owner is empty when there is none to report.
#
#   free                          no lock, or a lock whose owner is POSITIVELY dead
#   mine                          held by the calling session
#   other:<sid>                   held by a session POSITIVELY alive
#   unknown:lock_unreadable       the lock is there and could not be read
#   unknown:owner_empty           the lock read fine and is empty. NOT free: the
#                                 file exists, and nothing in this tree ever
#                                 creates an empty one (claim writes the sid into
#                                 a tmp file BEFORE linking it into place, and
#                                 release unlinks), so an empty lock is a torn or
#                                 truncated write -- a reason to wait, not to take
#                                 the role. (cc3's #1071 trigger.)
#   unknown:liveness_undecidable  the owner is known, its liveness is not
_actas_lock_verdict() {   # <sid> <read> <owner>
  local sid="$1" rd="$2" owner="$3" arc=0
  case "$rd" in
    absent)     printf 'free\t\n';                    return 0 ;;
    unreadable) printf 'unknown:lock_unreadable\t\n'; return 0 ;;
  esac
  if [ -z "$owner" ]; then
    printf 'unknown:owner_empty\t\n'
    return 0
  fi
  if [ "$owner" = "$sid" ]; then
    printf 'mine\t%s\n' "$owner"
    return 0
  fi
  agmsg_instance_alive "$owner" || arc=$?
  case "$arc" in
    0) printf 'other:%s\t%s\n' "$owner" "$owner" ;;
    1) printf 'free\t%s\n' "$owner" ;;
    *) printf 'unknown:liveness_undecidable\t%s\n' "$owner" ;;
  esac
}

# Internal: attempt one atomic claim. Echoes "ok" on success, "held:<sid>" when
# another sid currently owns it, "stale" when the existing lock's owner is
# positively dead (caller should retry after removing), "vanished" when the lock
# went away between our failed link and our read, or "unknown:<reason>" when the
# state could not be established. Every answer comes from _actas_lock_verdict,
# so this producer and actas_lock_observe cannot disagree about one file.
_actas_lock_try_claim() {
  local team="$1" agent="$2" sid="$3"
  local lock dir tmp _r _v verdict existing
  lock="$(actas_lock_path "$team" "$agent")"
  dir="$(_actas_lock_dir)"
  mkdir -p "$dir" 2>/dev/null || true

  tmp="$(mktemp "$dir/.actas-claim.XXXXXX" 2>/dev/null)" || return 1
  printf '%s\n' "$sid" > "$tmp"

  if ln "$tmp" "$lock" 2>/dev/null; then
    rm -f "$tmp"
    echo "ok"
    return 0
  fi
  rm -f "$tmp"

  _r="$(_actas_lock_read_path "$lock")"
  _v="$(_actas_lock_verdict "$sid" "${_r%%$'\t'*}" "${_r#*$'\t'}")"
  verdict="${_v%%$'\t'*}"
  existing="${_v#*$'\t'}"
  case "$verdict" in
    mine)      echo "ok" ;;
    other:*)   printf 'held:%s\n' "$existing" ;;
    unknown:*) printf '%s\n' "$verdict" ;;
    free)
      # `free` has two sources and they need different answers here. A dead
      # owner is a lock to reclaim. NO lock at all means it went away between
      # our failed `ln` and this read -- there is nothing to reclaim, and the
      # next attempt simply links into the gap. Calling that one "stale" sent
      # the caller into the reclaim mutex to delete a file that is not there.
      if [ -n "$existing" ]; then echo "stale"; else echo "vanished"; fi
      ;;
    *) echo "unknown:unclassified" ;;
  esac
  return 0
}

# Claim (team, agent) for session_id.
# Exit codes:
#   0  -- claimed (now ours, was already ours, or stale-replaced). Stdout: "ok".
#   1  -- not claimed. Stdout: "held:<other_sid>" or "unknown:<reason>".
#
# It ALWAYS prints a verdict, and that is load-bearing. Success used to print
# nothing -- and so did every failure this case did not name: mktemp failing, the
# lock directory not being creatable, three contended reclaim rounds. The three
# call sites branch on the OUTPUT, so all of those read as "not held: and not
# unknown:" = "we got it", and a pair nobody had claimed went into the subscribed
# set. A verdict on every path is what lets a caller require an explicit success
# instead of inferring one from silence. (#983, co3/co1)
actas_lock_claim() {
  local team="$1" agent="$2" sid="$3"
  local attempts=0 result lock_path reclaim_dir _r _owner _alive_rc
  lock_path="$(actas_lock_path "$team" "$agent")"
  reclaim_dir="${lock_path}.reclaim.d"
  while [ "$attempts" -lt 3 ]; do
    if ! result="$(_actas_lock_try_claim "$team" "$agent" "$sid")"; then
      # mktemp failed, or the lock directory could not be made. Nothing was
      # claimed and nothing was learned about the holder.
      echo "unknown:claim_failed"
      return 1
    fi
    case "$result" in
      ok) echo "ok"; return 0 ;;
      vanished)
        attempts=$((attempts + 1))
        continue
        ;;
      stale)
        # Stale removal needs a re-check-under-mutex. A naked rm (or even an
        # atomic mv) reads-then-removes whatever sits at lock_path, with no
        # guard that the contents are still the stale value we decided on
        # earlier. So two concurrent callers can both see stale, A can
        # successfully install a live lock, and B's later rm/mv would delete
        # A's fresh lock -- the original blocker from #65 review finding 1,
        # and the same hazard the mv-only variant inherited.
        #
        # Per-lock mutex via `mkdir` (atomic on POSIX). Re-check inside it:
        # only remove the lock if its current owner is still dead. If a peer
        # snuck a live owner in between our stale decision and the mutex,
        # leave it -- the next try_claim observes it as held.
        if mkdir "$reclaim_dir" 2>/dev/null; then
          # Reclaim DELETES, so it needs three facts, not one: the read
          # SUCCEEDED, an owner is actually there, and that owner is POSITIVELY
          # dead. "could not read it" and "could not tell" are neither. (#983)
          _r="$(_actas_lock_read_path "$lock_path")"
          if [ "${_r%%$'\t'*}" = "ok" ]; then
            _owner="${_r#*$'\t'}"
            if [ -n "$_owner" ]; then
              _alive_rc=0
              actas_lock_sid_alive "$_owner" || _alive_rc=$?
              if [ "$_alive_rc" -eq 1 ]; then
                rm -f "$lock_path"
              fi
            fi
          fi
          rmdir "$reclaim_dir" 2>/dev/null
        fi
        # If mkdir failed, another caller is mid-reclaim. Loop without
        # touching anything; the next try_claim sees whichever state they
        # end up in (live -> held, or empty -> we ln-claim).
        attempts=$((attempts + 1))
        continue
        ;;
      held:*|unknown:*)
        printf '%s\n' "$result"
        return 1
        ;;
    esac
    # A value this function does not know. Refusing with a named verdict beats
    # falling through to a silent `return 1` that a caller reads as success.
    echo "unknown:claim_failed"
    return 1
  done
  # Three rounds of "stale, then someone else held the reclaim mutex". We never
  # got it and we never established a holder either.
  echo "unknown:reclaim_contended"
  return 1
}

# Release a lock if we own it. Idempotent.
actas_lock_release() {
  local team="$1" agent="$2" sid="$3"
  local lock _r
  lock="$(actas_lock_path "$team" "$agent")"
  # This DELETES, so it needs a read that worked AND an owner that is positively
  # us. `[ -f ] || return 0` followed by comparing a possibly-empty owner landed
  # on the same behaviour by accident (an unreadable lock compares unequal to any
  # sid); saying it outright is what keeps the next edit from breaking it.
  _r="$(_actas_lock_read_path "$lock")"
  if [ "${_r%%$'\t'*}" = "ok" ] && [ "${_r#*$'\t'}" = "$sid" ]; then
    rm -f "$lock"
  fi
  return 0
}

# Release every lock currently owned by the given session_id. Used by
# session-end.sh when a CC session exits.
actas_lock_release_all() {
  local sid="$1"
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  local f _r
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    # This was the last `head -1 ... || true` in the file. It could only ever
    # have released a lock this session did not own -- an unreadable lock
    # compares unequal to any sid -- but it left the fold in the tree for the
    # next reader to copy, and reading it properly costs nothing. (#983)
    _r="$(_actas_lock_read_path "$f")"
    if [ "${_r%%$'\t'*}" = "ok" ] && [ "${_r#*$'\t'}" = "$sid" ]; then
      rm -f "$f"
    fi
  done
  return 0
}

# Garbage-collect locks whose owner session_id is no longer alive.
# Returns the number of locks reclaimed on stdout (for observability).
actas_lock_gc_stale() {
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f owner count=0 _r _alive_rc
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    # `|| true` discarded the read's status, so an unreadable lock became an
    # empty owner, which read as "nobody owns it", which read as garbage -- and
    # this is a SWEEP, so one transient read problem did not lose a role, it lost
    # every role in the directory. Delete only what is positively abandoned: the
    # read worked, an owner is there, and its session is positively dead. (#983)
    #
    # Measured, so the next reader is not misled about which line is holding
    # this up: the two guards below OVERLAP. An unreadable read yields an empty
    # owner, so deleting the status check alone changes nothing and the mutation
    # produces no reds. It stays because "the read worked" is the fact this
    # decision rests on, and inferring it from "the owner came back non-empty"
    # is the coupling that made an unreadable lock look abandoned in the first
    # place. The empty-owner line is the one a test can redden today.
    _r="$(_actas_lock_read_path "$f")"
    [ "${_r%%$'\t'*}" = "ok" ] || continue
    owner="${_r#*$'\t'}"
    [ -n "$owner" ] || continue
    _alive_rc=0
    actas_lock_sid_alive "$owner" || _alive_rc=$?
    if [ "$_alive_rc" -eq 1 ]; then
      rm -f "$f"
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Classify a (team, agent) pair relative to the calling session.
# Prints "<state>\t<owner>"; the owner is empty when there is none to report.
# The states are _actas_lock_verdict's, documented there -- this function is the
# read plus that verdict, and nothing else, so that `observe` and `try_claim`
# cannot drift apart again (they did: tl's axis 5).
#
# Returning the owner alongside the state matters as much as the values: callers
# that need a baseline to compare against later were reading the state and then
# reading the owner in a SECOND call, and a claim landing between the two
# produced a stale state paired with a fresh owner. One read, both facts, no
# window. (#983, found by co3.)
actas_lock_observe() {
  local _r
  _r="$(actas_lock_read "$1" "$2")"
  _actas_lock_verdict "$3" "${_r%%$'\t'*}" "${_r#*$'\t'}"
}

# Classify a (team, agent) pair relative to the calling session. Thin wrapper over
# actas_lock_observe so there is exactly one place that reads and one set of rules;
# callers needing the owner as well should use actas_lock_observe and split, rather
# than calling both (that pairing is what created the window described above).
actas_lock_state() {
  local _out
  _out="$(actas_lock_observe "$1" "$2" "$3")" || return 1
  # A REAL tab, not the two characters `\t`: `${var%%\t*}` strips nothing, and
  # `actas_lock_state` then returned "free<TAB>" to every caller that compares it
  # to `free`. Measured the moment it was written, which is the only reason it is
  # not in the diff.
  printf '%s\n' "${_out%%$'\t'*}"
}
