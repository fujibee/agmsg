#!/usr/bin/env bash
# storage.sh — resolve the path to the sqlite message store (messages.db).
#
# Scope: the storage axis only — where messages are persisted. This is NOT a
# storage-driver interface; it just centralizes the path resolution that was
# previously duplicated across the script set.
#
# Resolution order:
#   1. AGMSG_STORAGE_PATH — directory that holds messages.db (env override)
#   2. SKILL_DIR env var  — set by callers before sourcing (sandbox fallback)
#   3. BASH_SOURCE[0]     — derive from this file's own path (standard case)
#
# [seam] A config-file layer is expected to slot in between the env override
# and the built-in default once the storage-driver work lands; the intended
# full order is env > config > default. Keep that logic here so call sites
# stay unchanged.

# Echo the directory that holds (or will hold) the message store.
agmsg_storage_dir() {
  if [ -n "${AGMSG_STORAGE_PATH:-}" ]; then
    # Strip a single trailing slash for a stable join with the filename.
    printf '%s\n' "${AGMSG_STORAGE_PATH%/}"
    return
  fi
  local lib_dir skill_dir
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    skill_dir="$(cd "$lib_dir/../.." && pwd)"
  elif [ -n "${SKILL_DIR:-}" ]; then
    # BASH_SOURCE empty — e.g. Claude Code sandbox runs Bash via pipe/eval
    # so BASH_SOURCE is not populated. Fall back to SKILL_DIR which the
    # calling script resolves from $0 (which IS populated correctly).
    skill_dir="$SKILL_DIR"
  else
    echo "Error: cannot resolve storage dir (BASH_SOURCE and SKILL_DIR both empty)" >&2
    return 1
  fi
  printf '%s\n' "$skill_dir/db"
}

# Echo the full path to messages.db.
agmsg_db_path() {
  printf '%s/messages.db\n' "$(agmsg_storage_dir)"
}

# Run sqlite3 against the message store with a busy_timeout, so a writer that
# finds the DB locked WAITS for it instead of failing immediately with
# SQLITE_BUSY. WAL (set at init) lets readers and a single writer coexist, but
# concurrent writers still serialize; with the default busy_timeout=0 a leader
# fanning a job out to N members would lose all but one write — and silently,
# since the failed sends just exit non-zero. All DB-backed call sites go through
# this wrapper. In-memory JSON parsing (`sqlite3 :memory:`) does not need it —
# it has no file lock to contend for. Override the timeout via
# $AGMSG_BUSY_TIMEOUT (milliseconds). See #114.
#
# Uses the `.timeout` dot-command rather than `PRAGMA busy_timeout=N`: the
# PRAGMA returns its value as a row, which sqlite3 would print to stdout and
# corrupt every SELECT's output (and the watch stream). `.timeout` sets the
# same busy timeout silently.
agmsg_sqlite() {
  sqlite3 -cmd ".timeout ${AGMSG_BUSY_TIMEOUT:-5000}" "$@"
}
