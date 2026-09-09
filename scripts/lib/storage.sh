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

# agmsg_db_path turns the team selector into a path segment, so it cannot do its
# job without the shared name validator. Sourced here rather than left to each
# caller: watch.sh already reached the store without validate.sh in scope, and a
# caller that forgets it would build an unchecked path rather than fail.
# validate.sh guards against double-sourcing, so a caller that sources it too is
# unaffected. If neither locator resolves, the validator is simply absent and
# agmsg_db_path fails on the call — never silently unvalidated.
if ! declare -F agmsg_validate_team_name >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/validate.sh"
  elif [ -n "${SKILL_DIR:-}" ]; then
    # BASH_SOURCE empty — see agmsg_storage_dir for when that happens.
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/validate.sh"
  fi
fi

# Built-in storage drivers use the shared UUIDv7 generator. Keep it available
# through the storage facade so direct and registry-driven loads use one
# implementation on every platform.
if ! declare -F compat_uuid7 >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE[0]:-}" ]; then
    # shellcheck disable=SC1091
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/compat.sh"
  elif [ -n "${SKILL_DIR:-}" ]; then
    # shellcheck disable=SC1091
    source "$SKILL_DIR/scripts/lib/compat.sh"
  fi
fi

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

# Echo the full path to a team's message store, in a form sqlite3 can open.
#
# Echo the full path to a team's message store, in a form sqlite3 can open.
#
# WHICH store depends on the team's partition driver, and teams choose separately:
# `shared` (the default) puts every team in one file, `per-team` gives the team
# its own. A team only leaves the default when connecting requires it, because
# external programs read the shared store directly and lose sight of any team
# that moves out. See scripts/drivers/partition/.
#
# The argument is required rather than optional on purpose. An optional one
# leaves two ways to reach the store, and a caller that forgot the selector
# would silently read a different team's messages instead of failing.
#
# The selector reaches the filesystem as a path segment under per-team, so it is
# validated here rather than in the driver: this is the last point that can
# refuse to build a path it cannot vouch for.
agmsg_db_path() {
  local team="${1-}"
  if [ -z "$team" ]; then
    echo "Error: agmsg_db_path requires a team selector" >&2
    return 1
  fi
  agmsg_validate_team_name "$team" || return 1
  _agmsg_partition_load "$team" || return 1
  _agmsg_db_file "$(partition_store_relpath "$team")"
}

# Source the partition driver this team uses, memoized so repeated resolution in
# one process costs nothing. Re-sources when a caller moves between teams on
# different partitions — watch.sh loops over a subscription that can contain both.
_AGMSG_PARTITION_LOADED=""
_agmsg_partition_load() {
  # The registry may not be sourced yet — agmsg_db_path is reachable without
  # going through agmsg_storage_load. Same guarded pull-in that uses.
  if ! command -v agmsg_driver_for_team >/dev/null 2>&1; then
    local _lib
    _lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    # shellcheck disable=SC1091
    [ -n "$_lib" ] && . "$_lib/driver-registry.sh"
  fi
  local name
  name="$(agmsg_driver_for_team partition "$1" shared)"
  [ "$name" = "$_AGMSG_PARTITION_LOADED" ] && return 0
  local base kind file found=""
  while IFS="$(printf '\t')" read -r kind base; do
    [ -n "$base" ] || continue
    file="$base/partition/$name.sh"
    [ -f "$file" ] || continue
    # Externals stay gated by the same opt-in every other axis uses.
    if [ "$kind" = external ] && ! agmsg_driver_is_trusted partition "$name" "$file"; then
      continue
    fi
    found="$file"
  done <<EOF
$(agmsg_driver_bases)
EOF
  if [ -z "$found" ]; then
    # Loud rather than falling back to shared: a team recorded a partition, and
    # quietly reading a different store than the one it names is the exact
    # failure this axis exists to make impossible.
    echo "Error: no partition driver '$name' for team '$1'" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  . "$found" || return 1
  _AGMSG_PARTITION_LOADED="$name"
}

# The store that is NOT team-scoped, and the only resolver allowed to take no
# selector. Two things live here that are not message data: the runtime `locks`
# table (its resources are project-scoped — there is no team to pass), and the
# pre-split store that migration reads from.
#
# Runtime state deliberately did not follow the messages when they split: a lock
# on a project is not a fact about any one team, and per-team lock files would
# let two teams in the same project take the same lock.
_agmsg_runtime_db_path() { _agmsg_db_file; }

# Join a store-relative path onto the storage directory. Defaults to the
# pre-split shared file, which is what the runtime store still is.
#
# On Windows, sqlite3.exe is a native binary that cannot open a Git Bash path
# like /c/Users/.../db/messages.db: open() fails, so inbox/send/watch all fail
# to reach the store and the team goes silent (#197, reported by vhsvhafmwf).
# cygpath -m converts to the mixed C:/Users/.../db/messages.db form that BOTH
# the shell's `[ -f "$db" ]` test AND sqlite3.exe accept — unlike -w's backslash
# form (C:\Users\...), which the surrounding shell quoting/tests mishandle.
# No-op off Windows (cygpath absent). Mirrors agmsg_sql_readfile_path's pattern.
_agmsg_db_file() {
  local db
  db="$(agmsg_storage_dir)/${1:-messages.db}"
  if command -v cygpath >/dev/null 2>&1; then
    db=$(cygpath -m "$db" 2>/dev/null || printf '%s' "$db")
  fi
  printf '%s\n' "$db"
}

# The storage selector for a list of <team>:<agent> pairs, shared by every
# driver so one rule has one implementation.
#
# All pairs must name the SAME team. That is not a limitation being introduced
# here — the only production caller has always passed exactly one pair — but it
# is enforced rather than assumed, because the multi-team form has no answer
# once stores are actually split: a per-team store has no single monotonic
# cursor for a watch call to return. Choosing between a single-team ABI and a
# composite cursor belongs to that change, and failing loudly here stops a
# multi-team caller from appearing meanwhile and settling it by default.
agmsg_pair_team() {
  local p first="" t
  for p in "$@"; do
    t="${p%%:*}"
    [ -n "$t" ] && [ "$t" != "$p" ] || { echo "storage: not a team:agent pair: $p" >&2; return 1; }
    if [ -z "$first" ]; then first="$t"
    elif [ "$t" != "$first" ]; then
      echo "storage: one call cannot span teams ($first, $t)" >&2
      return 1
    fi
  done
  [ -n "$first" ] || { echo "storage: no team:agent pair given" >&2; return 1; }
  printf '%s' "$first"
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

# Run the escape probe in THIS shell, before a pipeline starts.
#
# `agmsg_sqlite` memoises the probe so it costs one sqlite3 process per shell
# rather than one per call (#462). The right-hand side of a pipeline is a
# subshell: it inherits the memo, but a memo it sets there dies with it. So a
# process whose FIRST database access is piped records nothing, and every piped
# call after it probes again -- measured at two sqlite3 processes per call, and
# it never converges.
#
# A REDIRECTION IS NOT A PIPE. `agmsg_sqlite db < file` runs in the current
# shell and memoises normally; only `... | agmsg_sqlite ...` needs this. Call it
# on the line before the pipeline, not inside it.
agmsg_sqlite_warm() {
  [ -n "$_AGMSG_ESCAPE_PROBED" ] || _agmsg_escape_flag >/dev/null
}

agmsg_sqlite() {
  # Probe in THIS shell, not in a command substitution. `$(_agmsg_escape_flag)`
  # ran the function in a subshell, so the memo it set was discarded on exit and
  # the probe re-ran on every call — two sqlite3 processes per database access
  # instead of one (#462). The memo now survives, so the probe runs once per
  # shell. Note it is once per SHELL, not once per machine: a call made from
  # inside a command substitution still probes in that subshell.
  [ -n "$_AGMSG_ESCAPE_PROBED" ] || _agmsg_escape_flag >/dev/null
  if [ -n "${AGMSG_SQLITE_OUTCOME_FILE:-}" ]; then
    _agmsg_sqlite_recording "$@"
    return
  fi
  # shellcheck disable=SC2086  # intentional split: "-escape off" → two args, or none
  local _agmsg_sqlite_rc=0
  sqlite3 $_AGMSG_ESCAPE_FLAG -cmd ".timeout ${AGMSG_BUSY_TIMEOUT:-5000}" "$@" || _agmsg_sqlite_rc=$?
  # SQLITE_BUSY after the full timeout used to pass in silence: the caller saw
  # a non-zero it often swallowed, and the operator saw a command that hung
  # for the timeout and said nothing (#1001 -- two people diagnosed two
  # different commands as broken). One line on stderr turns "hung" into
  # "waited and gave up", names the likely writer, and costs nothing when
  # there is no contention.
  if [ "$_agmsg_sqlite_rc" -eq 5 ]; then
    echo "agmsg: the message store is busy: this call waited ${AGMSG_BUSY_TIMEOUT:-5000}ms behind another writer (a sync engine cycle may be running) and gave up (#1001)" >&2
  fi
  return "$_agmsg_sqlite_rc"
}

# The same call, recording how it ended. With AGMSG_SQLITE_OUTCOME_FILE set,
# every call overwrites that file with one word: `ok`; `busy` when the busy
# timeout above ran out (sqlite3 said "database is locked"); `failed` for
# anything else.
#
# Only the sync driver adapter sets it (scripts/internal/storage-sync-driver.sh),
# and this is what it is for: the driver's functions return 13 for every failed
# check with the statement's stderr discarded at the call site, so their caller
# could not tell "the input was refused" from "another writer held the store past
# the timeout". The second is the one failure that is a fact about the moment
# rather than about the input -- the same call succeeds once that writer is done
# -- and the adapter reports it as its own exit status so the engine can wait
# and retry instead of giving up (#910). The word is the LAST call's outcome on
# purpose: a check-failing function returns right after the statement that
# failed, so "the operation failed and the last statement was busy" names it.
#
# stderr is captured to classify it and re-emitted unchanged, so a caller that
# reads or silences it sees what it saw before; stdout is the data stream and
# is not touched; the exit status is passed through. Written as an `if` so a
# caller running under `set -e` is not exited by the assignment itself.
_agmsg_sqlite_recording() {
  local err rc
  # shellcheck disable=SC2086  # same intentional split as above
  if { err=$(sqlite3 $_AGMSG_ESCAPE_FLAG -cmd ".timeout ${AGMSG_BUSY_TIMEOUT:-5000}" "$@" 2>&1 >&3 3>&-); } 3>&1; then
    rc=0
  else
    rc=$?
  fi
  [ -z "$err" ] || printf '%s\n' "$err" >&2
  if [ "$rc" -eq 0 ]; then
    printf 'ok\n' > "$AGMSG_SQLITE_OUTCOME_FILE"
  else
    case "$err" in
      *"database is locked"*) printf 'busy\n' > "$AGMSG_SQLITE_OUTCOME_FILE" ;;
      *) printf 'failed\n' > "$AGMSG_SQLITE_OUTCOME_FILE" ;;
    esac
  fi
  return "$rc"
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
  db="$(_agmsg_runtime_db_path)"
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
  agmsg_sqlite "$(_agmsg_runtime_db_path)" \
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
  agmsg_sqlite "$(_agmsg_runtime_db_path)" \
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

# agmsg_sql_readfile_path lives in lib/sqlpath.sh — one definition, so the rule
# "a path bound for SQL goes through this function" has one answer. It used to
# be defined here and again in hooks-json.sh, and a third caller wrote its own
# escaper rather than reach for either (#669).
if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/sqlpath.sh"
fi

# Escape an arbitrary scalar for safe interpolation into a SQL string literal
# (double every single quote). Same semantics as the sqlite driver's internal
# _sqlite_lit / storage_send escaping, but driver-agnostic and available to the
# registry scripts that still write the legacy messages table directly
# (rename.sh / rename-team.sh). A team or agent name may legitimately contain a
# single quote (validate.sh only blocks path traversal), which would otherwise
# break the INSERT/UPDATE and is an injection surface (#223, #87).
agmsg_sqlesc() {
  printf '%s' "$1" | sed "s/'/''/g"
}

# ── Storage driver facade (storage axis) ─────────────────────────────────────
# The helpers above resolve the legacy sqlite path and run raw SQL; call sites
# keep using them until #206 migrates them onto the contract below. The facade
# resolves the *active* storage driver, sources it, and makes the storage_*
# contract (docs/spec/driver-interface.md §2 / ADR 0003) available. Driver
# discovery + trust reuse the axis-generic registry (ADR 0002, driver-registry.sh).

# Path to the machine-wide driver config (spec §4). Overridable for tests.
_agmsg_storage_config_path() {
  printf '%s\n' "${AGMSG_CONFIG:-$HOME/.agents/agmsg/config.json}"
}

# Active storage driver name: env override > config "storage" key > built-in.
agmsg_storage_driver() {
  if [ -n "${AGMSG_STORAGE_DRIVER:-}" ]; then
    printf '%s\n' "$AGMSG_STORAGE_DRIVER"
    return 0
  fi
  local cfg name
  cfg="$(_agmsg_storage_config_path)"
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then
    name="$(sqlite3 :memory: \
      "SELECT COALESCE(json_extract(readfile('$(agmsg_sql_readfile_path "$cfg")'), '\$.storage'), '')" \
      2>/dev/null | tr -d '\r')"
    if [ -n "$name" ] && [ "$name" != "null" ]; then
      printf '%s\n' "$name"
      return 0
    fi
  fi
  printf 'sqlite\n'
}

# Locate and source the active storage driver's storage_* functions. Idempotent.
# Resolution reuses the registry search bases (in-tree builtins always trusted;
# external plugin dirs gated by the opt-in trustfile, ADR 0002).
_AGMSG_STORAGE_LOADED=""
agmsg_storage_load() {
  [ -n "$_AGMSG_STORAGE_LOADED" ] && return 0
  # Pull in the axis-generic registry once (its functions may not be sourced yet).
  if ! command -v agmsg_driver_bases >/dev/null 2>&1; then
    local _lib
    _lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    # shellcheck disable=SC1091
    [ -n "$_lib" ] && . "$_lib/driver-registry.sh"
  fi
  local name file kind base
  name="$(agmsg_storage_driver)"
  while IFS="$(printf '\t')" read -r kind base; do
    [ -n "$base" ] || continue
    file="$base/storage/$name.sh"
    [ -f "$file" ] || continue
    if [ "$kind" = external ] && ! agmsg_driver_is_trusted storage "$name" "$file"; then
      continue
    fi
    # shellcheck disable=SC1090
    . "$file" || return 1
    . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bridge-read-guard.sh" || return 1
    agmsg_bridge_guard_install || return 1
    _AGMSG_STORAGE_LOADED="$name"
    return 0
  done < <(agmsg_driver_bases)
  printf 'agmsg: no trusted storage driver "%s" found\n' "$name" >&2
  return 1
}
