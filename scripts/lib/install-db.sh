#!/usr/bin/env bash
# install-db.sh — install.db's `meta` table.
#
# The single source of truth for this install's install_id: a fresh UUID,
# minted once by install.sh the first time install.db's meta row is
# created, and never changed afterward -- until an uninstall removes
# install.db outright, at which point the next install starts a genuinely
# new install_id. The completion manifest (install-manifest.sh) carries
# only a COPY of this value; it is never a second place that MINTS one
# (2026-09-29 design decision -- this replaced an earlier design where the
# manifest/.prev itself was the install_id's source).
#
# schema_version starts at 1 so a later migration has a value to gate a
# table-adding ALTER on. This script initially writes only
# `meta(schema_version, install_id)`; agmsg_install_db_apply_schema below
# adds the Node/CLI-only columns (node_path, node_version) and the daemon
# tables, for both a fresh install and an --update over an older install.db.
#
# Required caller-set variable: none. Sources scripts/lib/compat.sh (for
# compat_uuid7) and scripts/lib/sqlite-output.sh (for normalized query output)
# if not already loaded.

[ -n "${_AGMSG_INSTALL_DB_SH:-}" ] && return 0
_AGMSG_INSTALL_DB_SH=1

if ! declare -F compat_uuid7 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/compat.sh"
fi
if ! declare -F agmsg_sqlite_capture >/dev/null 2>&1; then
  _agmsg_install_db_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck disable=SC1091
  . "$_agmsg_install_db_dir/sqlite-output.sh"
  unset _agmsg_install_db_dir
fi

# How long the install's own sqlite3 calls on install.db wait for another writer
# (agmsgd's shutdown, a concurrent `agmsg` command) before they give up, in ms.
# sqlite3's default is 0: a call that meets a writer fails at once, which ended an
# update with no output. AGMSG_INSTALL_DB_BUSY_MS changes it, for a test that needs a
# short bound: digits only (anything else uses 5000), 0 means no wait (sqlite3's own
# default), and a value above 600000 is 600000. sqlite3 itself cannot take more than
# 2147483647, so the cap is also what keeps a huge number from wrapping to no wait.
_agmsg_install_db_busy_ms() {
  local ms="${AGMSG_INSTALL_DB_BUSY_MS:-5000}"
  case "$ms" in ''|*[!0-9]*) ms=5000 ;; esac
  if [ "${#ms}" -gt 9 ]; then
    ms=600000
  else
    ms=$((10#$ms))
    [ "$ms" -le 600000 ] || ms=600000
  fi
  printf '%s\n' "$ms"
}

# Ensures install.db exists with its meta row: creates the table if absent,
# and mints a fresh install_id (schema_version 1) only if the table has no
# row yet. An --update over an install.db that already has a meta row
# leaves its install_id exactly as it was -- this never overwrites an
# existing one. Prints the (possibly just-created) install_id on success;
# prints nothing and returns 1 on any sqlite failure.
agmsg_install_db_ensure_meta() {   # <install_db_path>
  local db="$1" id err rc busy
  busy="$(_agmsg_install_db_busy_ms)"
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  err="$(sqlite3 -cmd ".timeout $busy" "$db" \
    "CREATE TABLE IF NOT EXISTS meta (schema_version INTEGER NOT NULL, install_id TEXT NOT NULL);" \
    2>&1)" || {
    rc=$?
    echo "  ! install.db: creating the meta table failed (sqlite3 rc=$rc${err:+: ${err%%$'\n'*}}): $db" >&2
    return 1
  }
  id="$(agmsg_sqlite_capture -cmd ".timeout $busy" "$db" "SELECT install_id FROM meta LIMIT 1;")" || {
    rc=$?
    echo "  ! install.db: reading the install id failed (sqlite3 rc=$rc): $db" >&2
    return 1
  }
  if [ -z "$id" ]; then
    id="$(compat_uuid7)"
    err="$(sqlite3 -cmd ".timeout $busy" "$db" \
      "INSERT INTO meta (schema_version, install_id) VALUES (1, '$id');" \
      2>&1)" || {
      rc=$?
      echo "  ! install.db: writing the install id failed (sqlite3 rc=$rc${err:+: ${err%%$'\n'*}}): $db" >&2
      return 1
    }
  fi
  printf '%s\n' "$id"
}

# Brings install.db up to scripts/daemon/schema.sql: adds the meta columns an
# older install.db lacks (CREATE TABLE IF NOT EXISTS never alters an existing
# table), then applies the idempotent schema. The one place both install.sh and
# `agmsg daemon enable` go through. Never touches an existing install_id.
# Returns 1 on any sqlite failure.
agmsg_install_db_apply_schema() {   # <install_db_path> <schema_sql_path>
  local db="$1" schema="$2" col present err rc busy
  busy="$(_agmsg_install_db_busy_ms)"
  # A writer elsewhere (agmsgd's own shutdown, a concurrent `agmsg` command)
  # can hold install.db for a moment -- `cmd_stop` confirms the DB row says
  # `none` before returning, not that the OS process has fully released its
  # connection, so a caller right behind it can still race that close. The
  # default busy_timeout is 0: no other writer in this codebase touches
  # install.db (or any sqlite file) without `.timeout`, and this was the one
  # gap (a CI-only "could not apply the daemon schema" failure measured
  # immediately after a prior test's agmsgd stop -- never reproduced locally,
  # consistent with a race that only a slower/more loaded machine widens
  # enough to hit). Matches this file's own writer-side convention elsewhere
  # (storage.sh's AGMSG_BUSY_TIMEOUT default) rather than the shorter reads
  # above use (daemon-state.sh etc., 100ms) -- schema apply runs once per
  # install/update, never on a hot path, so a few seconds of tolerance costs
  # nothing real.
  for col in node_path node_version codex_path; do
    # One scalar per column: a multi-line result carries a CR on every line
    # from native Windows sqlite3.exe, which a name comparison would miss.
    present="$(agmsg_sqlite_capture -cmd ".timeout $busy" "$db" "SELECT count(*) FROM pragma_table_info('meta') WHERE name = '$col';")" || {
      rc=$?
      echo "  ! install.db: checking for meta column $col failed (sqlite3 rc=$rc): $db" >&2
      return 1
    }
    [ "$present" = 1 ] && continue
    err="$(sqlite3 -cmd ".timeout $busy" "$db" "ALTER TABLE meta ADD COLUMN $col TEXT;" 2>&1)" || {
      rc=$?
      echo "  ! install.db: adding meta column $col failed (sqlite3 rc=$rc${err:+: ${err%%$'\n'*}}): $db" >&2
      return 1
    }
  done
  err="$(sqlite3 -cmd ".timeout $busy" "$db" < "$schema" 2>&1)" || {
    rc=$?
    echo "  ! install.db: applying $schema failed (sqlite3 rc=$rc${err:+: ${err%%$'\n'*}}): $db" >&2
    return 1
  }
}
