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
# `meta(schema_version, install_id)`; the Node/CLI-only columns
# (node_path, node_version) are added by whichever PR implements
# `enable`/`disable`.
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

# Ensures install.db exists with its meta row: creates the table if absent,
# and mints a fresh install_id (schema_version 1) only if the table has no
# row yet. An --update over an install.db that already has a meta row
# leaves its install_id exactly as it was -- this never overwrites an
# existing one. Prints the (possibly just-created) install_id on success;
# prints nothing and returns 1 on any sqlite failure.
agmsg_install_db_ensure_meta() {   # <install_db_path>
  local db="$1" id
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  if ! sqlite3 "$db" \
    "CREATE TABLE IF NOT EXISTS meta (schema_version INTEGER NOT NULL, install_id TEXT NOT NULL);" \
    2>/dev/null; then
    return 1
  fi
  id="$(agmsg_sqlite_capture "$db" "SELECT install_id FROM meta LIMIT 1;")" || return 1
  if [ -z "$id" ]; then
    id="$(compat_uuid7)"
    if ! sqlite3 "$db" \
      "INSERT INTO meta (schema_version, install_id) VALUES (1, '$id');" \
      2>/dev/null; then
      return 1
    fi
  fi
  printf '%s\n' "$id"
}
