#!/usr/bin/env bash
# actas-reclaim-mutex.sh — crash-recoverable serialization for actas deletes.
#
# The mutex is a row in a dedicated local SQLite database:
#
#   run/actas-reclaim.db
#   (lock_key, holder_pid, holder_generation)
#
# SQLite transactions are used only to acquire, release, or generation-CAS a
# row.  They are NEVER held across filesystem work.  The process recorded in
# holder_pid must itself perform the final destructive syscall; the fixed
# mutator helper does that by `exec rm`, so killing the helper cannot release
# the mutex while an orphan rm child continues.
#
# Crash recovery is conservative: a live holder is never timed out.  A dead
# holder's row is replaced only when its complete pid+generation tuple still
# matches.  PID reuse can delay recovery (false-live), but cannot authorize
# deletion or replacement of a live generation.

: "${SKILL_DIR:?actas-reclaim-mutex.sh requires SKILL_DIR}"

# shellcheck disable=SC1091
. "$SKILL_DIR/scripts/lib/instance-id.sh"

AGMSG_ACTAS_RECLAIM_MUTEX_KEY=""
AGMSG_ACTAS_RECLAIM_MUTEX_PID=""
AGMSG_ACTAS_RECLAIM_MUTEX_GENERATION=""

_actas_reclaim_db_path() {
  local path="$SKILL_DIR/run/actas-reclaim.db"
  if command -v cygpath >/dev/null 2>&1; then
    path="$(cygpath -m "$path" 2>/dev/null || printf '%s' "$path")"
  fi
  printf '%s\n' "$path"
}

_actas_reclaim_sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

_actas_reclaim_sqlite() {
  local db
  mkdir -p "$SKILL_DIR/run" 2>/dev/null || return 1
  db="$(_actas_reclaim_db_path)"
  (
    set -o pipefail
    sqlite3 -bail -cmd '.timeout 5000' "$db" "$@" | tr -d '\r'
  )
}

_actas_reclaim_generation() {
  sqlite3 :memory: "SELECT lower(hex(randomblob(16)));" 2>/dev/null | tr -d '\r\n'
}

# The holder is the mutator helper's $$, so it remains in the shell pid
# namespace even when its value is read back from SQLite.  The local probe is
# therefore required on every platform; on Git Bash tasklist cannot see it.
_actas_reclaim_holder_alive() {
  local pid="$1"
  _agmsg_pid_alive_local "$pid"
}

_actas_reclaim_mutex_schema() {
  _actas_reclaim_sqlite <<'SQL' >/dev/null
CREATE TABLE IF NOT EXISTS actas_reclaim_mutexes (
  lock_key TEXT PRIMARY KEY,
  holder_pid INTEGER NOT NULL,
  holder_generation TEXT NOT NULL
);
SQL
}

# actas_reclaim_mutex_acquire <lock-key> <actual-helper-pid>
#
# On success, retains the exact acquired tuple in the AGMSG_* globals above.
# The caller must either release it before any later mutation, or make the
# destructive operation its final action via exec so the stale row is safely
# recovered by the next caller.
actas_reclaim_mutex_acquire() {
  local key="$1" pid="$2" generation key_sql row owner_pid owner_generation
  local attempt=0
  _agmsg_pid_valid "$pid" || return 1
  generation="$(_actas_reclaim_generation)"
  case "$generation" in ''|*[!0-9a-f]*) return 1 ;; esac
  key_sql="$(_actas_reclaim_sql_escape "$key")"
  _actas_reclaim_mutex_schema || return 1

  while [ "$attempt" -lt 100 ]; do
    row="$(_actas_reclaim_sqlite <<SQL
BEGIN IMMEDIATE;
INSERT OR IGNORE INTO actas_reclaim_mutexes(lock_key, holder_pid, holder_generation)
VALUES('$key_sql', $pid, '$generation');
SELECT holder_pid || ':' || holder_generation
FROM actas_reclaim_mutexes WHERE lock_key = '$key_sql';
COMMIT;
SQL
)" || return 1
    row="$(printf '%s\n' "$row" | tail -1)"
    if [ "$row" = "$pid:$generation" ]; then
      AGMSG_ACTAS_RECLAIM_MUTEX_KEY="$key"
      AGMSG_ACTAS_RECLAIM_MUTEX_PID="$pid"
      AGMSG_ACTAS_RECLAIM_MUTEX_GENERATION="$generation"
      return 0
    fi

    owner_pid="${row%%:*}"
    owner_generation="${row#*:}"
    if [ "$owner_pid" = "$row" ] || ! _agmsg_pid_valid "$owner_pid" \
        || [ -z "$owner_generation" ]; then
      return 1
    fi
    if _actas_reclaim_holder_alive "$owner_pid"; then
      attempt=$((attempt + 1))
      sleep 0.01
      continue
    fi

    # The stale observation above is only a hint.  This transaction replaces
    # the row iff the complete observed generation is still current.  A peer
    # that already reclaimed it wins; this caller then observes that peer on
    # the next iteration without touching its row.
    owner_generation="$(_actas_reclaim_sql_escape "$owner_generation")"
    row="$(_actas_reclaim_sqlite <<SQL
BEGIN IMMEDIATE;
DELETE FROM actas_reclaim_mutexes
WHERE lock_key = '$key_sql'
  AND holder_pid = $owner_pid
  AND holder_generation = '$owner_generation';
INSERT OR IGNORE INTO actas_reclaim_mutexes(lock_key, holder_pid, holder_generation)
VALUES('$key_sql', $pid, '$generation');
SELECT holder_pid || ':' || holder_generation
FROM actas_reclaim_mutexes WHERE lock_key = '$key_sql';
COMMIT;
SQL
)" || return 1
    row="$(printf '%s\n' "$row" | tail -1)"
    if [ "$row" = "$pid:$generation" ]; then
      AGMSG_ACTAS_RECLAIM_MUTEX_KEY="$key"
      AGMSG_ACTAS_RECLAIM_MUTEX_PID="$pid"
      AGMSG_ACTAS_RECLAIM_MUTEX_GENERATION="$generation"
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.01
  done
  return 1
}

# Release is only for a no-mutation outcome.  Delete paths must not release and
# then fork rm; they exec rm and intentionally leave a stale row instead.
actas_reclaim_mutex_release() {
  local key_sql generation_sql
  [ -n "$AGMSG_ACTAS_RECLAIM_MUTEX_KEY" ] || return 0
  key_sql="$(_actas_reclaim_sql_escape "$AGMSG_ACTAS_RECLAIM_MUTEX_KEY")"
  generation_sql="$(_actas_reclaim_sql_escape "$AGMSG_ACTAS_RECLAIM_MUTEX_GENERATION")"
  _actas_reclaim_sqlite <<SQL >/dev/null || return 1
DELETE FROM actas_reclaim_mutexes
WHERE lock_key = '$key_sql'
  AND holder_pid = $AGMSG_ACTAS_RECLAIM_MUTEX_PID
  AND holder_generation = '$generation_sql';
SQL
  AGMSG_ACTAS_RECLAIM_MUTEX_KEY=""
  AGMSG_ACTAS_RECLAIM_MUTEX_PID=""
  AGMSG_ACTAS_RECLAIM_MUTEX_GENERATION=""
}

# Best-effort hygiene for rows left by successful exec-rm helpers or crashes.
# Returns only the number of exact tuples this invocation actually deleted.
# Concurrent collectors may observe the same row; SQLite changes() credits the
# one whose generation-qualified DELETE linearizes first.
actas_reclaim_mutex_gc() {
  local rows row pid generation key_hex generation_sql count=0 removed
  _actas_reclaim_mutex_schema || { printf '0\n'; return 1; }
  rows="$(_actas_reclaim_sqlite \
    "SELECT holder_pid || ':' || holder_generation || ':' || hex(lock_key) FROM actas_reclaim_mutexes;")" \
    || { printf '0\n'; return 1; }
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    pid="${row%%:*}"
    row="${row#*:}"
    generation="${row%%:*}"
    key_hex="${row#*:}"
    _agmsg_pid_valid "$pid" || continue
    case "$generation" in ''|*[!0-9a-f]*) continue ;; esac
    case "$key_hex" in ''|*[!0-9A-F]*) continue ;; esac
    _actas_reclaim_holder_alive "$pid" && continue
    generation_sql="$(_actas_reclaim_sql_escape "$generation")"
    removed="$(_actas_reclaim_sqlite <<SQL
BEGIN IMMEDIATE;
DELETE FROM actas_reclaim_mutexes
WHERE hex(lock_key) = '$key_hex'
  AND holder_pid = $pid
  AND holder_generation = '$generation_sql';
SELECT changes();
COMMIT;
SQL
)" || continue
    removed="$(printf '%s\n' "$removed" | tail -1)"
    [ "$removed" = 1 ] && count=$((count + 1))
  done <<EOF
$rows
EOF
  printf '%s\n' "$count"
}
