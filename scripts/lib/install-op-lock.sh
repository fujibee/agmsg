#!/usr/bin/env bash
# install-op-lock.sh — the install/uninstall operation lock (agmsgd beta).
#
# One lock per install, held for the whole of install.sh / uninstall.sh /
# the `enable` / `disable` / `start` CLI operations. Mechanism: SQLite's own
# BEGIN EXCLUSIVE on run/install-op.lock.db -- a SEPARATE file from
# install.db, held by a single long-running sqlite3 process bash keeps alive
# for the whole operation. Bash 4+ feeds it through a coprocess; Bash 3.2 uses
# a pair of named pipes so bash can keep working while the transaction stays
# open.
# The OS releases the file lock the moment that sqlite3 process dies, for
# any reason -- there is no stale-lock recovery step.
#
# THE LOCK FILE ITSELF IS NEVER DELETED, not even by uninstall (citing
# https://www.sqlite.org/howtocorrupt.html): removing a DB a waiter still has
# open makes a fresh file recreated under the same name a DIFFERENT lock than
# the one that waiter is holding a reference to.
#
# THE LOCK DB HOLDS NO CONTENT (2026-09-29 design decision): no
# tables, no generation, no install_id, no owner -- an empty file whose only
# job is to be BEGIN EXCLUSIVE'd. Writing anything into it would make it a
# second place recording facts install.db and the completion manifest
# already own.
#
# LOCK ORDERING (2026-09-29 design decision): a caller that also
# needs the registry lock or a team-store lock takes them in this order --
# registry lock -> this install operation lock -> team store lock -- and
# never the reverse. install.sh/uninstall.sh do not take a registry or
# team-store lock today, so this is a constraint on future callers, not a
# thing this file enforces itself.
#
# Required caller-set variables: none. Sources sqlpath.sh for native-path
# conversion and sqlite-output.sh for CRLF-safe captured output.

[ -n "${_AGMSG_INSTALL_OP_LOCK_SH:-}" ] && return 0
_AGMSG_INSTALL_OP_LOCK_SH=1

_agmsg_install_op_lock_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$_agmsg_install_op_lock_dir/sqlpath.sh"
fi
if ! declare -F agmsg_sqlite_capture >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$_agmsg_install_op_lock_dir/sqlite-output.sh"
fi
unset _agmsg_install_op_lock_dir

# A write to a pipe whose reader has already died raises SIGPIPE. Received by
# the shell's OWN write (a builtin `printf` redirected to that fd runs IN
# this process, not a forked child), the default action terminates the whole
# script -- measured: an untrapped SIGPIPE here kills install.sh outright,
# not just the one write. Every caller of this file needs a failed write to
# come back as an ordinary nonzero status instead, so this is set once, on
# source, rather than left to each call site to remember.
trap '' PIPE

# Globals set by agmsg_install_op_lock on success, cleared by
# agmsg_install_op_unlock: _AGMSG_LOCK_PID (the sqlite3 process), fd 9 (write
# into it) and fd 8 (read its output), and optionally _AGMSG_LOCK_TMPDIR (the
# Bash 3.2 FIFOs' directory). Fixed fd numbers, not `exec {fd}>`: that form
# needs bash 4.1+, and this file runs under macOS's /bin/bash 3.2.

# Acquires the lock. Prints nothing; returns 0 once BEGIN EXCLUSIVE is
# CONFIRMED open (a canary SELECT read back over the same pipe -- not merely
# "the write didn't fail"), 1 on any failure (busy past timeout_ms, the
# sqlite3 coprocess could not be started, or its output didn't confirm).
# Leaves no fd/process/tmpdir behind on failure.
agmsg_install_op_lock() {   # <lock_db_path> [timeout_ms, default 30000]
  local db="$1" timeout_ms="${2:-30000}"
  local dir="" in_fifo="" out_fifo="" line read_timeout read_fd write_fd coproc_prefix read_rc
  AGMSG_INSTALL_OP_LOCK_FAILURE_REASON=""
  coproc_prefix=AGMSG_INSTALL_OP_SQLITE
  _AGMSG_INSTALL_OP_USE_COPROC=false
  _AGMSG_LOCK_CHANNELS_READY=false
  if ! mkdir -p "$(dirname "$db")" 2>/dev/null; then
    _agmsg_install_op_lock_set_failure "preparing lock database directory"
    return 1
  fi
  if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then
    # `coproc` is syntax unknown to Bash 3.2, so keep it in an eval string
    # that is evaluated only on Bash 4+. Redirections close Bats' inherited
    # TAP descriptors in the coprocess command.
    unset AGMSG_INSTALL_OP_SQLITE AGMSG_INSTALL_OP_SQLITE_PID
    if ! eval 'coproc AGMSG_INSTALL_OP_SQLITE { exec sqlite3 "$db" 2>&1; } 3>&- 4>&-' 2>/dev/null; then
      _agmsg_install_op_lock_set_failure "starting sqlite3 coprocess"
      return 1
    fi
    _AGMSG_INSTALL_OP_USE_COPROC=true
    _AGMSG_LOCK_PID="${AGMSG_INSTALL_OP_SQLITE_PID:-}"
    eval "read_fd=\${${coproc_prefix}[0]:-}"
    eval "write_fd=\${${coproc_prefix}[1]:-}"
    case "$_AGMSG_LOCK_PID" in ''|*[!0-9]*) _agmsg_install_op_lock_set_failure "starting sqlite3 coprocess: no valid child PID"; _AGMSG_LOCK_PID=""; agmsg_install_op_unlock; return 1 ;; esac
    case "$read_fd" in ''|*[!0-9]*) _agmsg_install_op_lock_set_failure "connecting to sqlite3 coprocess: missing read pipe"; agmsg_install_op_unlock; return 1 ;; esac
    case "$write_fd" in ''|*[!0-9]*) _agmsg_install_op_lock_set_failure "connecting to sqlite3 coprocess: missing write pipe"; agmsg_install_op_unlock; return 1 ;; esac
    if ! eval "exec 8<&${read_fd} 9>&${write_fd}"; then
      _agmsg_install_op_lock_set_failure "connecting to sqlite3 coprocess: could not attach its pipes"
      agmsg_install_op_unlock
      return 1
    fi
    eval "exec ${read_fd}<&- ${write_fd}>&-"
    _AGMSG_LOCK_CHANNELS_READY=true
    unset AGMSG_INSTALL_OP_SQLITE AGMSG_INSTALL_OP_SQLITE_PID
  else
    dir="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-install-lock.XXXXXX")" || {
      _agmsg_install_op_lock_set_failure "preparing SQLite lock pipes: could not create a temporary directory"
      return 1
    }
    in_fifo="$dir/in"; out_fifo="$dir/out"
    if ! mkfifo "$in_fifo" "$out_fifo" 2>/dev/null; then
      _agmsg_install_op_lock_set_failure "preparing SQLite lock pipes: mkfifo failed"
      rm -rf "$dir" 2>/dev/null
      return 1
    fi

    # 2>&1 into the SAME out fifo: a busy/failed BEGIN EXCLUSIVE prints its
    # error there instead of the canary line, which is exactly how failure is
    # told apart from success below -- one stream, read for one exact literal.
    sqlite3 "$db" < "$in_fifo" > "$out_fifo" 2>&1 3>&- 4>&- &
    _AGMSG_LOCK_PID=$!
    exec 9> "$in_fifo"
    exec 8< "$out_fifo"
    _AGMSG_LOCK_TMPDIR="$dir"
    _AGMSG_LOCK_CHANNELS_READY=true
  fi

  # `.timeout` (a dot-command), not `PRAGMA busy_timeout=N;`: a PRAGMA that
  # returns a value is echoed back on the out fifo like a query result, which
  # would land as an extra line before the canary and make the read count
  # fragile. The dot-command sets the same busy handler with no echo.
  if ! printf '.timeout %s\nBEGIN EXCLUSIVE;\nSELECT '"'"'agmsg-lock-ok'"'"';\n' "$timeout_ms" >&9; then
    _agmsg_install_op_lock_set_failure "writing the lock request to sqlite3: the pipe closed or rejected the write"
    agmsg_install_op_unlock
    return 1
  fi

  read_timeout=$((timeout_ms / 1000 + 5))
  if IFS= read -r -t "$read_timeout" -u 8 line; then
    :
  else
    read_rc=$?
    if [ "$read_rc" -gt 128 ]; then
      _agmsg_install_op_lock_set_failure "waiting for lock confirmation from sqlite3: timed out after ${read_timeout}s"
    else
      _agmsg_install_op_lock_set_failure "waiting for lock confirmation from sqlite3: output closed before a reply"
    fi
    agmsg_install_op_unlock
    return 1
  fi
  line="${line%$'\r'}"
  if [ "$line" != "agmsg-lock-ok" ]; then
    if [ -n "$line" ]; then
      _agmsg_install_op_lock_set_failure "unexpected lock confirmation from sqlite3" "$line"
    else
      _agmsg_install_op_lock_set_failure "unexpected empty lock confirmation from sqlite3"
    fi
    agmsg_install_op_unlock
    return 1
  fi
  return 0
}

# Preserve a short, shell-escaped first response so a caller can explain which
# handshake stage failed without allowing control characters into terminal output.
_agmsg_install_op_lock_set_failure() {
  local reason="${1:-lock handshake failed}" detail="${2:-}"
  if [ -n "$detail" ]; then
    printf -v detail '%q' "$detail"
    detail="${detail:0:80}"
    if [ -n "$detail" ]; then
      reason="$reason: $detail"
    fi
  fi
  AGMSG_INSTALL_OP_LOCK_FAILURE_REASON="$reason"
}

# Load the shared liveness check when its source file is still installed. The
# recovery helper can outlive scripts/, so its canary round-trip remains the
# authoritative fallback when instance-id.sh is unavailable.
_agmsg_install_op_load_pid_helper() {
  declare -F _agmsg_pid_alive_local >/dev/null 2>&1 && return 0
  if [ -n "${SCRIPT_DIR:-}" ] && [ -r "$SCRIPT_DIR/scripts/lib/instance-id.sh" ]; then
    . "$SCRIPT_DIR/scripts/lib/instance-id.sh"
  elif [ -r "$(dirname "${BASH_SOURCE[0]}")/instance-id.sh" ]; then
    . "$(dirname "${BASH_SOURCE[0]}")/instance-id.sh"
  fi
  declare -F _agmsg_pid_alive_local >/dev/null 2>&1
}

# Re-proves the lock is still genuinely held: use the shared local-pid
# liveness check when available, then require a fresh canary round-trip. The
# canary also covers the recovery-only helper after scripts/ has been removed.
# A caller that only checked liveness at acquire time would otherwise write
# past a lock it silently no longer holds. Returns 1 (lock not provably held;
# do not proceed) without ever killing the caller, since PIPE is trapped.
agmsg_install_op_confirm() {
  local line
  [ -n "${_AGMSG_LOCK_PID:-}" ] || return 1
  if _agmsg_install_op_load_pid_helper; then
    _agmsg_pid_alive_local "$_AGMSG_LOCK_PID" || return 1
  fi
  printf "SELECT 'agmsg-lock-ok';\n" >&9 || return 1
  read -r -t 5 -u 8 line || return 1
  line="${line%$'\r'}"
  [ "$line" = "agmsg-lock-ok" ]
}

# Refuse the next protected write unless the SQLite child still proves the
# transaction is held. Phase entry checks gate each group of writes; the next
# phase or operation_finish detects a child-only death before later work starts.
agmsg_install_op_require() {
  # The incomplete-operation record excludes every later install/uninstall
  # while a phase is in flight. Within that phase, the record -- not another
  # SQLite round trip for each small write -- is what prevents overlap. The
  # phase runner proves the lock at each phase entry so a lost lock cannot
  # carry this operation into its next phase.
  [ "${AGMSG_INSTALL_OP_PHASE_ACTIVE:-false}" = true ] && return 0
  if ! agmsg_install_op_confirm; then
    echo "  ! the install lock was lost partway through; stopping before the next write (see .prev)" >&2
    return 1
  fi
}

# Run one logical group of protected writes. The operation marker remains in
# place throughout the group, so a later operation can acquire the SQLite lock
# after a child-only failure but must still refuse to write. The next phase
# checks the lock before it writes; operation_finish checks it after the last
# phase. That makes each boundary one canary round-trip, not two.
agmsg_install_op_phase_begin() {
  agmsg_install_op_require || return 1
  AGMSG_INSTALL_OP_PHASE_ACTIVE=true
}

agmsg_install_op_phase_end() {
  AGMSG_INSTALL_OP_PHASE_ACTIVE=false
  return 0
}

agmsg_install_op_run_phase() {
  local phase_rc=0
  agmsg_install_op_phase_begin || return 1
  "$@" || phase_rc=$?
  agmsg_install_op_phase_end || return 1
  return "$phase_rc"
}

_agmsg_install_op_sql_quote() {
  printf '%s' "$1" | sed "s/'/''/g"
}

_agmsg_install_op_pending_field() {
  local path="$1" field="$2" path_sql
  case "$field" in
    operation_id|operation|mode|install_path|install_id|actor_pid|started_at|state) ;;
    *) return 1 ;;
  esac
  path_sql="$(agmsg_sql_readfile_path "$path")" || return 1
  agmsg_sqlite_capture :memory: \
    "SELECT json_extract(CAST(readfile('$path_sql') AS TEXT), '\$.$field');"
}

agmsg_install_op_pending_validate() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  AGMSG_INSTALL_OP_PENDING_ID="$(_agmsg_install_op_pending_field "$path" operation_id)" || return 1
  AGMSG_INSTALL_OP_PENDING_KIND="$(_agmsg_install_op_pending_field "$path" operation)" || return 1
  AGMSG_INSTALL_OP_PENDING_MODE="$(_agmsg_install_op_pending_field "$path" mode)" || return 1
  [ -n "$AGMSG_INSTALL_OP_PENDING_MODE" ] || AGMSG_INSTALL_OP_PENDING_MODE=legacy
  AGMSG_INSTALL_OP_PENDING_PATH="$(_agmsg_install_op_pending_field "$path" install_path)" || return 1
  AGMSG_INSTALL_OP_PENDING_PID="$(_agmsg_install_op_pending_field "$path" actor_pid)" || return 1
  AGMSG_INSTALL_OP_PENDING_STARTED="$(_agmsg_install_op_pending_field "$path" started_at)" || return 1
  case "$AGMSG_INSTALL_OP_PENDING_ID" in
    ''|*[!0-9a-f]*) return 1 ;;
  esac
  [ "${#AGMSG_INSTALL_OP_PENDING_ID}" -eq 32 ] || return 1
  case "$AGMSG_INSTALL_OP_PENDING_KIND" in install|uninstall) ;; *) return 1 ;; esac
  case "$AGMSG_INSTALL_OP_PENDING_MODE" in install|update|keep-data|remove-data|legacy) ;; *) return 1 ;; esac
  case "$AGMSG_INSTALL_OP_PENDING_KIND:$AGMSG_INSTALL_OP_PENDING_MODE" in
    install:install|install:update|install:legacy|uninstall:keep-data|uninstall:remove-data|uninstall:legacy) ;;
    *) return 1 ;;
  esac
  case "$AGMSG_INSTALL_OP_PENDING_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#AGMSG_INSTALL_OP_PENDING_PID}" -le 10 ] || return 1
  [ "$AGMSG_INSTALL_OP_PENDING_PID" -gt 0 ] || return 1
  case "$(_agmsg_install_op_pending_field "$path" state)" in
    in_progress|interrupted_complete|completed) ;;
    *) return 1 ;;
  esac
  [ -n "$AGMSG_INSTALL_OP_PENDING_PATH" ] && [ -n "$AGMSG_INSTALL_OP_PENDING_STARTED" ]
}

agmsg_install_op_pending_report() {
  local path="$1"
  agmsg_install_op_pending_validate "$path" || return 1
  printf '  operation_id: %s\n' "$AGMSG_INSTALL_OP_PENDING_ID" >&2
  printf '  operation: %s\n' "$AGMSG_INSTALL_OP_PENDING_KIND" >&2
  printf '  mode: %s\n' "$AGMSG_INSTALL_OP_PENDING_MODE" >&2
  printf '  install: %s\n' "$AGMSG_INSTALL_OP_PENDING_PATH" >&2
  printf '  started_at: %s\n' "$AGMSG_INSTALL_OP_PENDING_STARTED" >&2
  printf '  actor_pid: %s (displayed only; no liveness inference)\n' "$AGMSG_INSTALL_OP_PENDING_PID" >&2
}

agmsg_install_op_pending_refuse() {
  local path="$1" recovery_prefix="$2" next_kind="$3" next_mode="$4"
  if [ -L "$path" ] || ! agmsg_install_op_pending_report "$path"; then
    echo "  ! an unreadable or malformed incomplete-operation record blocks this install; inspect $path before recovery" >&2
    return 1
  fi
  printf '  ! an earlier %s operation (%s) is incomplete; %s (%s) will not start\n' \
    "$AGMSG_INSTALL_OP_PENDING_KIND" "$AGMSG_INSTALL_OP_PENDING_MODE" "$next_kind" "$next_mode" >&2
  echo "    Verify that no writer from the recorded operation is still running before recovery." >&2
  printf '    Recovery command: %s %s\n' "$recovery_prefix" "$AGMSG_INSTALL_OP_PENDING_ID" >&2
  return 1
}

agmsg_install_op_pending_begin() {
  local path="$1" kind="$2" install_path="$3" install_id="${4:-}" mode="${5:-legacy}"
  local op_id started_at path_sql kind_sql mode_sql id_sql started_sql install_id_sql json tmp
  [ -n "$path" ] && [ -n "$kind" ] && [ -n "$install_path" ] || return 1
  case "$kind:$mode" in
    install:install|install:update|uninstall:keep-data|uninstall:remove-data) ;;
    *) return 1 ;;
  esac
  agmsg_install_op_require || return 1
  mkdir -p "$(dirname "$path")" || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    echo "  ! an incomplete-operation record already exists at $path" >&2
    return 1
  fi
  op_id="$(agmsg_sqlite_capture :memory: 'SELECT lower(hex(randomblob(16)));')" || return 1
  case "$op_id" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#op_id}" -eq 32 ] || return 1
  started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  path_sql="$(_agmsg_install_op_sql_quote "$install_path")" || return 1
  kind_sql="$(_agmsg_install_op_sql_quote "$kind")" || return 1
  mode_sql="$(_agmsg_install_op_sql_quote "$mode")" || return 1
  id_sql="$(_agmsg_install_op_sql_quote "$op_id")" || return 1
  started_sql="$(_agmsg_install_op_sql_quote "$started_at")" || return 1
  install_id_sql="$(_agmsg_install_op_sql_quote "$install_id")" || return 1
  json="$(agmsg_sqlite_capture :memory: "SELECT json_object('operation_id','$id_sql','operation','$kind_sql','mode','$mode_sql','install_path','$path_sql','install_id','$install_id_sql','actor_pid',$$,'started_at','$started_sql','state','in_progress');")" || return 1
  [ -n "$json" ] || return 1
  tmp="$(mktemp "$(dirname "$path")/.$(basename "$path").XXXXXX")" || return 1
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  agmsg_install_op_require || { rm -f "$tmp"; return 1; }
  if ! ln "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    echo "  ! an incomplete-operation record already exists at $path" >&2
    return 1
  fi
  rm -f "$tmp" || return 1
  AGMSG_INSTALL_OP_ID="$op_id"
  AGMSG_INSTALL_OP_MARKER="$path"
  agmsg_install_op_require
}

agmsg_install_op_pending_set_state() {
  local path="$1" op_id="$2" state="$3" current_id path_sql json tmp
  case "$state" in completed|interrupted_complete) ;; *) return 1 ;; esac
  agmsg_install_op_require || return 1
  agmsg_install_op_pending_validate "$path" || return 1
  current_id="$AGMSG_INSTALL_OP_PENDING_ID"
  [ "$current_id" = "$op_id" ] || return 1
  path_sql="$(agmsg_sql_readfile_path "$path")" || return 1
  op_id="$(_agmsg_install_op_sql_quote "$op_id")" || return 1
  state="$(_agmsg_install_op_sql_quote "$state")" || return 1
  json="$(agmsg_sqlite_capture :memory: "SELECT json_set(CAST(readfile('$path_sql') AS TEXT), '\$.state', '$state') WHERE json_extract(CAST(readfile('$path_sql') AS TEXT), '\$.operation_id') = '$op_id';")" || return 1
  [ -n "$json" ] || return 1
  tmp="$(mktemp "$(dirname "$path")/.$(basename "$path").XXXXXX")" || return 1
  if ! printf '%s\n' "$json" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  agmsg_install_op_require || { rm -f "$tmp"; return 1; }
  agmsg_install_op_pending_validate "$path" || { rm -f "$tmp"; return 1; }
  [ "$AGMSG_INSTALL_OP_PENDING_ID" = "$op_id" ] || { rm -f "$tmp"; return 1; }
  if ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi
  agmsg_install_op_require
}

agmsg_install_op_pending_remove() {
  local path="$1" op_id="$2"
  agmsg_install_op_require || return 1
  agmsg_install_op_pending_validate "$path" || return 1
  [ "$AGMSG_INSTALL_OP_PENDING_ID" = "$op_id" ] || return 1
  rm -f "$path" || return 1
  agmsg_install_op_require
}

agmsg_install_op_pending_complete() {
  local path="$1" op_id="$2" state="${3:-completed}"
  agmsg_install_op_pending_set_state "$path" "$op_id" "$state" || return 1
  agmsg_install_op_pending_remove "$path" "$op_id"
}

agmsg_install_op_pending_recover() {
  local path="$1" requested_id="$2" next_kind="$3" next_mode="$4"
  agmsg_install_op_require || return 1
  if ! agmsg_install_op_pending_report "$path"; then
    echo "  ! the incomplete-operation record is missing or unreadable; it cannot be recovered automatically" >&2
    return 1
  fi
  if [ "$AGMSG_INSTALL_OP_PENDING_ID" != "$requested_id" ]; then
    echo "  ! recovery operation id does not match the current record" >&2
    return 1
  fi
  printf '  Recorded operation: %s (%s)\n' \
    "$AGMSG_INSTALL_OP_PENDING_KIND" "$AGMSG_INSTALL_OP_PENDING_MODE" >&2
  printf '  Continuing requested operation: %s (%s)\n' "$next_kind" "$next_mode" >&2
  echo "  Verify that no writer from this operation can still modify the installation before continuing." >&2
  agmsg_install_op_pending_remove "$path" "$requested_id"
}

agmsg_install_op_run_writer() {
  local status=0 writer_pid
  AGMSG_INSTALL_OP_WRITER_STARTING=true
  "$@" 3>&- 4>&- &
  writer_pid=$!
  if [ -n "${AGMSG_TEST_INSTALL_OP_WRITER_PID_PUBLISH_GATE:-}" ]; then
    printf '%s\n' "$writer_pid" > "${AGMSG_TEST_INSTALL_OP_WRITER_PID_PUBLISH_GATE}.pid"
    while [ ! -e "${AGMSG_TEST_INSTALL_OP_WRITER_PID_PUBLISH_GATE}.release" ]; do sleep 0.02; done
  fi
  AGMSG_INSTALL_OP_WRITER_PID="$writer_pid"
  AGMSG_INSTALL_OP_WRITER_STARTING=false
  if wait "$writer_pid"; then
    status=0
  else
    status=$?
  fi
  AGMSG_INSTALL_OP_WRITER_PID=""
  return "$status"
}

# A caught cancellation is the only automatic path that removes an in-flight
# record before the completion manifest is published. Stop and reap the one
# tracked mutating child first; if the SQLite lock has already been lost, keep
# the record so a competing operation cannot enter while that child exits.
agmsg_install_op_handle_signal() {
  local signal="$1" exit_status=130
  [ "$signal" = TERM ] && exit_status=143
  trap - INT TERM
  AGMSG_INSTALL_OP_PHASE_ACTIVE=false
  if [ "${AGMSG_INSTALL_OP_WRITER_STARTING:-false}" = true ] && [ -z "${AGMSG_INSTALL_OP_WRITER_PID:-}" ]; then
    echo "  ! writer launch was interrupted before its pid was published; the incomplete-operation record was kept for recovery" >&2
    agmsg_install_op_unlock
    exit "$exit_status"
  fi
  if [ -n "${AGMSG_INSTALL_OP_WRITER_PID:-}" ]; then
    kill -TERM "$AGMSG_INSTALL_OP_WRITER_PID" 2>/dev/null || true
    wait "$AGMSG_INSTALL_OP_WRITER_PID" 2>/dev/null || true
    AGMSG_INSTALL_OP_WRITER_PID=""
  fi
  AGMSG_INSTALL_OP_WRITER_STARTING=false
  if [ -n "${AGMSG_INSTALL_OP_ID:-}" ] && [ -n "${AGMSG_INSTALL_OP_MARKER:-}" ] && agmsg_install_op_confirm; then
    agmsg_install_op_pending_complete "$AGMSG_INSTALL_OP_MARKER" "$AGMSG_INSTALL_OP_ID" interrupted_complete || true
  fi
  agmsg_install_op_unlock
  exit "$exit_status"
}

# Releases the lock and cleans up every resource agmsg_install_op_lock
# created, whether or not the lock was ever confirmed open (safe to call
# after a failed agmsg_install_op_lock, and safe to call twice). COMMIT is
# attempted but its failure is not itself an error here -- a coprocess that
# already died released the OS lock by dying; there is nothing left to
# commit, and this function's job is cleanup, not re-detecting that.
agmsg_install_op_unlock() {
  local coproc_read_fd="" coproc_write_fd="" coproc_prefix=AGMSG_INSTALL_OP_SQLITE
  eval "coproc_read_fd=\${${coproc_prefix}[0]:-}"
  eval "coproc_write_fd=\${${coproc_prefix}[1]:-}"
  if [ "${_AGMSG_LOCK_CHANNELS_READY:-false}" = true ] && [ -n "${_AGMSG_LOCK_PID:-}" ]; then
    printf 'COMMIT;\n' >&9 2>/dev/null || true
  fi
  # `exec` with no command applies its redirections to the CURRENT SHELL,
  # not to a single statement -- a bare `exec 9>&- 2>/dev/null` (to silence
  # a "no such file descriptor" if 9 were somehow already closed) therefore
  # redirects stderr for the REST OF THE CALLING SCRIPT, not just this line.
  # Measured: it did, and every later stderr write -- including a
  # downstream command's own error message -- went to /dev/null for good.
  # `{ exec 9>&-; } 2>/dev/null` scopes the same suppression to the group
  # instead: stderr is only silenced for the compound command inside the
  # braces, and is itself restored once the group ends.
  { exec 9>&-; } 2>/dev/null || true
  { exec 8<&-; } 2>/dev/null || true
  if [ "${_AGMSG_INSTALL_OP_USE_COPROC:-false}" = true ]; then
    case "$coproc_read_fd" in ''|*[!0-9]*) ;; *) eval "exec ${coproc_read_fd}<&-" 2>/dev/null || true ;; esac
    case "$coproc_write_fd" in ''|*[!0-9]*) ;; *) eval "exec ${coproc_write_fd}>&-" 2>/dev/null || true ;; esac
  fi
  if [ -n "${_AGMSG_LOCK_PID:-}" ]; then
    kill "$_AGMSG_LOCK_PID" 2>/dev/null || true
    wait "$_AGMSG_LOCK_PID" 2>/dev/null || true
  fi
  [ -n "${_AGMSG_LOCK_TMPDIR:-}" ] && rm -rf "$_AGMSG_LOCK_TMPDIR" 2>/dev/null
  unset _AGMSG_LOCK_PID _AGMSG_LOCK_TMPDIR _AGMSG_INSTALL_OP_USE_COPROC _AGMSG_LOCK_CHANNELS_READY
  unset AGMSG_INSTALL_OP_SQLITE AGMSG_INSTALL_OP_SQLITE_PID
  AGMSG_INSTALL_OP_PHASE_ACTIVE=false
}

# Places <src>'s CONTENT at <dest> atomically: a reader of <dest> sees either
# the old file in full or the new one in full, never a torn write --
# agmsgd-launch.sh and the agmsgd entrypoint must never be
# read half-written. The temp file lives in <dest>'s own directory so the
# final `mv` is a same-filesystem rename, not a cross-filesystem copy.
# install.sh already depends on `mktemp` elsewhere and has no join.sh-style
# minimal-PATH constraint, so this does not need registry-lock.sh's
# mkdir-only fallback. Mode is mktemp's default (0600); the caller chmod's
# <dest> afterward the same way it does for every other shipped script --
# not this helper's job, and `chmod --reference` is a GNU-only flag this
# codebase's macOS/BSD chmod does not have.
agmsg_atomic_place_file() {   # <src> <dest>
  local src="$1" dest="$2" tmp
  if [ "${AGMSG_INSTALL_OP_ACTIVE:-false}" = true ]; then
    agmsg_install_op_require || return 1
  fi
  tmp="$(mktemp "$(dirname "$dest")/.$(basename "$dest").XXXXXX")" || return 1
  if ! cp "$src" "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if [ "${AGMSG_INSTALL_OP_ACTIVE:-false}" = true ] && ! agmsg_install_op_require; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  mv "$tmp" "$dest"
  if [ "${AGMSG_INSTALL_OP_ACTIVE:-false}" = true ]; then
    agmsg_install_op_require || return 1
  fi
}
