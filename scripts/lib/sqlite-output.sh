#!/usr/bin/env bash
# Capture one sqlite3 result while normalizing the CR from native Windows
# sqlite3.exe's CRLF line ending. Callers use this for scalar or JSON output.

[ -n "${_AGMSG_SQLITE_OUTPUT_SH:-}" ] && return 0
_AGMSG_SQLITE_OUTPUT_SH=1

agmsg_sqlite_capture() {
  local output
  output="$(sqlite3 "$@" 2>/dev/null)" || return $?
  output="${output%$'\r'}"
  printf '%s' "$output"
}
