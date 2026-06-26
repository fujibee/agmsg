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
# This is the same idiom the jsonl storage driver uses (_jsonl_with_lock). The
# lock is per-team (teams/<team>/.config.lock), so operations on different teams
# never serialize against each other.
#
# Callers pair agmsg_lock_acquire with a write through agmsg_write_atomic so an
# unlocked reader (whoami / identities / inbox read config.json without the lock)
# never observes a half-written file.

# Holds the lock dir currently owned by this process ("" when none). The EXIT /
# INT / TERM trap reads it so a crash mid-write can never leave a stale lock.
AGMSG_TEAM_LOCK="${AGMSG_TEAM_LOCK:-}"

# agmsg_lock_acquire <team_dir>
# Acquire the per-team lock. <team_dir> (teams/<team>) must already exist — the
# caller creates it for a brand-new team before locking, so this never resurrects
# a team dir that a concurrent leave/reset just removed. Spins with a short sleep
# up to AGMSG_LOCK_TRIES attempts (default 1000 = ~10s), then fails non-zero.
agmsg_lock_acquire() {
  local team_dir="$1" lock i=0 max="${AGMSG_LOCK_TRIES:-1000}"
  lock="$team_dir/.config.lock"
  until mkdir "$lock" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge "$max" ]; then
      echo "agmsg: timed out acquiring registry lock for $team_dir" >&2
      return 1
    fi
    sleep 0.01
  done
  AGMSG_TEAM_LOCK="$lock"
  # Idempotent: re-arming the same handler each acquire is harmless, and it stays
  # armed across a reset loop's many acquire/release cycles. It no-ops whenever no
  # lock is held (AGMSG_TEAM_LOCK empty), so a normal exit after release is fine.
  trap 'agmsg_lock_release' EXIT INT TERM
}

# agmsg_lock_release
# Release the lock held by this process (no-op if none). rmdir only removes the
# (empty) lock dir, never the team dir or its config.
agmsg_lock_release() {
  [ -n "${AGMSG_TEAM_LOCK:-}" ] || return 0
  rmdir "$AGMSG_TEAM_LOCK" 2>/dev/null || true
  AGMSG_TEAM_LOCK=""
}

# agmsg_write_atomic <dest> <content>
# Write <content> (plus a trailing newline, matching the previous `echo >`) to a
# temp file in the same directory, then rename(2) it over <dest>. The rename is
# atomic, so a concurrent unlocked reader sees either the old or the new file,
# never a truncated one.
agmsg_write_atomic() {
  local dest="$1" content="$2" tmp
  tmp="$dest.tmp.$$"
  printf '%s\n' "$content" > "$tmp"
  mv "$tmp" "$dest"
}
