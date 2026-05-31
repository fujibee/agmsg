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

# Read the owner session_id of a lock file. Empty if no lock or unreadable.
actas_lock_owner() {
  local lock; lock="$(actas_lock_path "$1" "$2")"
  [ -f "$lock" ] || { printf ''; return 0; }
  head -1 "$lock" 2>/dev/null
}

# Return 0 if the given session_id is alive — that is, some live
# cc-instance.<pid> currently contains it. Empty sid → not alive.
actas_lock_sid_alive() {
  local sid="$1"
  [ -n "$sid" ] || return 1
  local run; run="$(_actas_lock_dir)"
  [ -d "$run" ] || return 1
  # All loop variables are local — this function gets called from inside other
  # loops (gc_stale, watch.sh subscription resolution), so leaking $f or $pid
  # would corrupt the caller's iteration.
  local f pid s
  for f in "$run"/cc-instance.*; do
    [ -f "$f" ] || continue
    pid=${f##*.}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    s="$(cat "$f" 2>/dev/null || true)"
    [ "$s" = "$sid" ] && return 0
  done
  return 1
}

# Internal: attempt one atomic claim. Echoes "ok" on success, "held:<sid>"
# when another sid currently owns it, or "stale" when the existing lock's
# owner is dead (caller should retry after removing).
_actas_lock_try_claim() {
  local team="$1" agent="$2" sid="$3"
  local lock dir tmp existing
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

  existing="$(actas_lock_owner "$team" "$agent")"
  if [ "$existing" = "$sid" ]; then
    echo "ok"
    return 0
  fi
  if [ -z "$existing" ] || ! actas_lock_sid_alive "$existing"; then
    echo "stale"
    return 0
  fi
  printf 'held:%s\n' "$existing"
  return 0
}

# Claim (team, agent) for session_id.
# Exit codes:
#   0  — claimed (now owned by this sid, was already ours, or stale-replaced).
#   1  — held by another live session. Stdout: "held:<other_sid>".
actas_lock_claim() {
  local team="$1" agent="$2" sid="$3"
  local attempts=0 result lock_path reclaim_dir _owner
  lock_path="$(actas_lock_path "$team" "$agent")"
  reclaim_dir="${lock_path}.reclaim.d"
  while [ "$attempts" -lt 3 ]; do
    result="$(_actas_lock_try_claim "$team" "$agent" "$sid")"
    case "$result" in
      ok) return 0 ;;
      stale)
        # Stale removal needs a re-check-under-mutex. A naked rm (or even an
        # atomic mv) reads-then-removes whatever sits at lock_path, with no
        # guard that the contents are still the stale value we decided on
        # earlier. So two concurrent callers can both see stale, A can
        # successfully install a live lock, and B's later rm/mv would delete
        # A's fresh lock — the original blocker from #65 review finding 1,
        # and the same hazard the mv-only variant inherited.
        #
        # Per-lock mutex via `mkdir` (atomic on POSIX). Re-check inside it:
        # only remove the lock if its current owner is still dead. If a peer
        # snuck a live owner in between our stale decision and the mutex,
        # leave it — the next try_claim observes it as held.
        if mkdir "$reclaim_dir" 2>/dev/null; then
          _owner="$(actas_lock_owner "$team" "$agent")"
          if [ -z "$_owner" ] || ! actas_lock_sid_alive "$_owner"; then
            rm -f "$lock_path"
          fi
          rmdir "$reclaim_dir" 2>/dev/null
        fi
        # If mkdir failed, another caller is mid-reclaim. Loop without
        # touching anything; the next try_claim sees whichever state they
        # end up in (live → held, or empty → we ln-claim).
        attempts=$((attempts + 1))
        continue
        ;;
      held:*)
        printf '%s\n' "$result"
        return 1
        ;;
    esac
    return 1
  done
  return 1
}

# Release a lock if we own it. Idempotent.
actas_lock_release() {
  local team="$1" agent="$2" sid="$3"
  local lock owner
  lock="$(actas_lock_path "$team" "$agent")"
  [ -f "$lock" ] || return 0
  owner="$(actas_lock_owner "$team" "$agent")"
  [ "$owner" = "$sid" ] && rm -f "$lock"
  return 0
}

# Release every lock currently owned by the given session_id. Used by
# session-end.sh when a CC session exits.
actas_lock_release_all() {
  local sid="$1"
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || return 0
  local f owner
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    owner="$(head -1 "$f" 2>/dev/null || true)"
    [ "$owner" = "$sid" ] && rm -f "$f"
  done
  return 0
}

# Garbage-collect locks whose owner session_id is no longer alive.
# Returns the number of locks reclaimed on stdout (for observability).
actas_lock_gc_stale() {
  local dir; dir="$(_actas_lock_dir)"
  [ -d "$dir" ] || { echo 0; return 0; }
  local f owner count=0
  for f in "$dir"/actas.*.session; do
    [ -f "$f" ] || continue
    owner="$(head -1 "$f" 2>/dev/null || true)"
    if [ -z "$owner" ] || ! actas_lock_sid_alive "$owner"; then
      rm -f "$f"
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# Classify a (team, agent) pair relative to the calling session.
# Echoes one of: free | mine | other:<sid>
actas_lock_state() {
  local team="$1" agent="$2" sid="$3"
  local owner
  owner="$(actas_lock_owner "$team" "$agent")"
  if [ -z "$owner" ]; then
    echo "free"; return 0
  fi
  if [ "$owner" = "$sid" ]; then
    echo "mine"; return 0
  fi
  if actas_lock_sid_alive "$owner"; then
    printf 'other:%s\n' "$owner"
  else
    echo "free"  # stale owner — effectively free, GC will remove it later
  fi
}
