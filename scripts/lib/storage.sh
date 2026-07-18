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

# Echo the full path to messages.db, in a form the sqlite3 binary can open.
# On Windows, sqlite3.exe is a native binary that cannot open a Git Bash path
# like /c/Users/.../db/messages.db: open() fails, so inbox/send/watch all fail
# to reach the store and the team goes silent (#197, reported by vhsvhafmwf).
# cygpath -m converts to the mixed C:/Users/.../db/messages.db form that BOTH
# the shell's `[ -f "$db" ]` test AND sqlite3.exe accept — unlike -w's backslash
# form (C:\Users\...), which the surrounding shell quoting/tests mishandle.
# No-op off Windows (cygpath absent). Mirrors agmsg_sql_readfile_path's pattern.
agmsg_db_path() {
  local db
  db="$(agmsg_storage_dir)/messages.db"
  if command -v cygpath >/dev/null 2>&1; then
    db=$(cygpath -m "$db" 2>/dev/null || printf '%s' "$db")
  fi
  printf '%s\n' "$db"
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
# sqlite3 >= 3.50 renders control bytes in CLI output using caret notation —
# the char(31) record separator becomes the two literal chars "^_", and a CR
# becomes "^M". That breaks the `IFS=$'\x1f' read` field splitting in
# inbox/check-inbox/history and the monitor watch stream (#102), the same
# sqlite3 >= 3.50 escaping behaviour behind #143. `-escape off` restores the
# raw bytes. Older sqlite3 (< 3.50) doesn't know the option (and emits raw bytes
# anyway), so probe once and only pass the flag when the build accepts it.
_AGMSG_ESCAPE_FLAG=
_AGMSG_ESCAPE_PROBED=
_agmsg_escape_flag() {
  if [ -z "$_AGMSG_ESCAPE_PROBED" ]; then
    _AGMSG_ESCAPE_PROBED=1
    if sqlite3 -escape off :memory: "SELECT 1;" >/dev/null 2>&1; then
      _AGMSG_ESCAPE_FLAG="-escape off"
    fi
  fi
  printf '%s' "$_AGMSG_ESCAPE_FLAG"
}

agmsg_sqlite() {
  # shellcheck disable=SC2046  # intentional split: "-escape off" → two args, or none
  sqlite3 $(_agmsg_escape_flag) -cmd ".timeout ${AGMSG_BUSY_TIMEOUT:-5000}" "$@"
}

# Runtime ownership seam. This is the first run/-state-in-storage primitive for
# the storage 1.2 direction: a future remote driver can preserve these acquire /
# verify / release semantics with SETNX, WATCH, or its native equivalent.
# `locks` is intentionally resource-generic; Codex dispatchers are merely the
# first caller. Acquire prints the current owner. With expected_owner supplied,
# replacement is a transactionally serialized compare-and-swap.
_agmsg_runtime_lock_resource_sql() {
  printf '%s' "$1" | sed "s/'/''/g"
}

agmsg_storage_ensure_initialized() {
  local lib_dir init_script
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  init_script="$lib_dir/../internal/init-db.sh"
  AGMSG_STORAGE_PATH="$(agmsg_storage_dir)" bash "$init_script" >/dev/null
}

agmsg_runtime_lock_acquire() {
  local resource owner_pid expected_owner db resource_sql
  resource="$1"; owner_pid="$2"; expected_owner="${3:-}"
  case "$owner_pid:$expected_owner" in *[!0-9:]*) return 1 ;; esac
  agmsg_storage_ensure_initialized || return 1
  db="$(agmsg_db_path)"
  resource_sql="$(_agmsg_runtime_lock_resource_sql "$resource")"
  agmsg_sqlite "$db" <<SQL | tr -d '\r'
CREATE TABLE IF NOT EXISTS locks (
  resource TEXT PRIMARY KEY,
  owner_pid INTEGER NOT NULL,
  acquired_at TEXT NOT NULL
);
BEGIN IMMEDIATE;
$(if [ -n "$expected_owner" ]; then printf "DELETE FROM locks WHERE resource = '%s' AND owner_pid = %s;" "$resource_sql" "$expected_owner"; fi)
INSERT OR IGNORE INTO locks(resource, owner_pid, acquired_at)
VALUES('$resource_sql', $owner_pid, strftime('%Y-%m-%dT%H:%M:%SZ','now'));
SELECT owner_pid FROM locks WHERE resource = '$resource_sql';
COMMIT;
SQL
}

agmsg_runtime_lock_owner() {
  local resource_sql
  resource_sql="$(_agmsg_runtime_lock_resource_sql "$1")"
  agmsg_sqlite "$(agmsg_db_path)" \
    "SELECT owner_pid FROM locks WHERE resource = '$resource_sql';" 2>/dev/null \
    | tr -d '\r'
}

agmsg_runtime_lock_verify() {
  case "$2" in *[!0-9]*|'') return 1 ;; esac
  [ "$(agmsg_runtime_lock_owner "$1" 2>/dev/null || true)" = "$2" ]
}

agmsg_runtime_lock_release() {
  local resource_sql
  case "$2" in *[!0-9]*|'') return 1 ;; esac
  resource_sql="$(_agmsg_runtime_lock_resource_sql "$1")"
  agmsg_sqlite "$(agmsg_db_path)" \
    "DELETE FROM locks WHERE resource = '$resource_sql' AND owner_pid = $2;" \
    >/dev/null 2>&1 || true
}

# In-memory sqlite for JSON parsing / scalar lookups whose stdout is captured in
# a command substitution ($(...)). On Windows, sqlite3.exe writes stdout in text
# mode and turns every \n into \r\n; command substitution strips the trailing \n
# but keeps the \r, so a captured "1" becomes "1\r" and string / integer
# comparisons silently fail — hooks don't get written, counts misparse, etc.
# (#130). Strip the CR; it is never a meaningful byte in a JSON or scalar result.
# No busy_timeout (a :memory: db has no file lock) and no escape flag (these
# call sites parse JSON/scalars, not the control-byte message stream).
agmsg_sqlite_mem() {
  sqlite3 :memory: "$@" | tr -d '\r'
}

# Turn a filesystem path into a form sqlite3's readfile() can open, then escape
# it as a SQL string literal. On Windows, sqlite3.exe is a native binary that
# can't open a Git Bash path like /d/a/agmsg/x.json — readfile() returns NULL
# and the surrounding json parse silently yields no rows. cygpath -w converts to
# the native D:\a\agmsg\x.json form first. No-op off Windows (cygpath absent).
# Mirrors delivery.sh's sql_readfile_path for the registry readfile() sites.
agmsg_sql_readfile_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    path=$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")
  fi
  printf '%s' "$path" | sed "s/'/''/g"
}
