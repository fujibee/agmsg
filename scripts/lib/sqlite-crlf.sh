#!/usr/bin/env bash
# sqlite-crlf.sh -- does this machine's sqlite3 end rows with \r\n, and the
# in-memory sqlite helper that strips them only where it does.
#
# Sourced by lib/storage.sh and by the libraries that read a config through
# sqlite3 on their own. Safe to source twice.

[ -z "${_AGMSG_SQLITE_CRLF_LIB:-}" ] || return 0
_AGMSG_SQLITE_CRLF_LIB=1

# Does this machine's sqlite3 end rows with \r\n? Only Windows' sqlite3.exe does
# (measured, see agmsg_sqlite below); on macOS and Linux the CR strip is a
# process that does nothing. Decided once per shell from the platform bash
# reports (no process; $OSTYPE is msys/cygwin under MSYS2/Git Bash), and kept in
# a variable. AGMSG_SQLITE_CRLF=1|0 overrides it (tests, an odd build).
_AGMSG_SQLITE_CRLF=
_agmsg_sqlite_crlf() {
  case "${AGMSG_SQLITE_CRLF:-}" in
    0|1) _AGMSG_SQLITE_CRLF="$AGMSG_SQLITE_CRLF" ;;
    *) case "${OSTYPE:-}" in
         msys*|cygwin*|win32*) _AGMSG_SQLITE_CRLF=1 ;;
         *) _AGMSG_SQLITE_CRLF=0 ;;
       esac ;;
  esac
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
  [ -n "$_AGMSG_SQLITE_CRLF" ] || _agmsg_sqlite_crlf
  # Leading `-separator SEP` options are passed through ahead of the database.
  local _agmsg_mem_opts=()
  while [ "${1:-}" = -separator ] && [ "$#" -ge 2 ]; do
    _agmsg_mem_opts+=("$1" "$2")
    shift 2
  done
  if [ "$_AGMSG_SQLITE_CRLF" = 1 ]; then
    sqlite3 ${_agmsg_mem_opts[@]+"${_agmsg_mem_opts[@]}"} :memory: "$@" | LC_ALL=C tr -d '\r'
  else
    # Same status as the pipeline above: sqlite3's failure is visible only to a
    # caller that runs with pipefail, and is otherwise swallowed (a failed
    # lookup here has always read as "nothing found", never as an abort).
    local _agmsg_mem_rc=0
    sqlite3 ${_agmsg_mem_opts[@]+"${_agmsg_mem_opts[@]}"} :memory: "$@" || _agmsg_mem_rc=$?
    if [ "$_agmsg_mem_rc" -ne 0 ] && [ -o pipefail ]; then return "$_agmsg_mem_rc"; fi
    return 0
  fi
}
