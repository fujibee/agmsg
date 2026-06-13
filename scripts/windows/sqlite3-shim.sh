#!/usr/bin/env bash
set -euo pipefail

# sqlite3 compatibility shim for agmsg on native Windows / Git Bash.
#
# The winget SQLite CLI can print control characters such as char(31) using
# caret notation and can emit CRLF line endings. agmsg parses char(31) as a
# field separator and expects LF records. This wrapper restores the behavior
# the POSIX scripts expect:
#   - pass -escape off when the sqlite3 build supports it
#   - strip CR bytes from CLI output

CACHE_FILE="${AGMSG_SQLITE3_CACHE_FILE:-${HOME:-}/.agents/run/sqlite3-shim.cache}"
SUPPORTS_ESCAPE_OFF="${AGMSG_SQLITE3_ESCAPE_OFF:-}"

find_real_sqlite3() {
  local self
  self="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

  local name candidate
  for name in sqlite3.exe sqlite3; do
    while IFS= read -r candidate; do
      [ -n "$candidate" ] || continue
      [ "$candidate" = "$self" ] && continue
      [ -x "$candidate" ] || continue
      if grep -q "sqlite3 compatibility shim for agmsg" "$candidate" 2>/dev/null; then
        continue
      fi
      printf '%s\n' "$candidate"
      return 0
    done < <(type -ap "$name" 2>/dev/null || true)
  done
}

load_cache() {
  [ -n "$CACHE_FILE" ] || return 1
  [ -f "$CACHE_FILE" ] || return 1

  local cached_real cached_escape
  {
    IFS= read -r cached_real || return 1
    IFS= read -r cached_escape || cached_escape=""
  } < "$CACHE_FILE"

  [ -n "$cached_real" ] || return 1
  [ -x "$cached_real" ] || return 1
  REAL_SQLITE3="$cached_real"
  if [ -z "$SUPPORTS_ESCAPE_OFF" ]; then
    SUPPORTS_ESCAPE_OFF="$cached_escape"
  fi
  return 0
}

write_cache() {
  [ -n "$CACHE_FILE" ] || return 0
  [ -n "${REAL_SQLITE3:-}" ] || return 0

  local cache_dir tmp
  cache_dir="$(dirname "$CACHE_FILE")"
  mkdir -p "$cache_dir" 2>/dev/null || return 0
  tmp=$(mktemp "${cache_dir}/sqlite3-shim.XXXXXX" 2>/dev/null) || return 0
  {
    printf '%s\n' "$REAL_SQLITE3"
    printf '%s\n' "$SUPPORTS_ESCAPE_OFF"
  } > "$tmp"
  mv "$tmp" "$CACHE_FILE" 2>/dev/null || rm -f "$tmp"
}

REAL_SQLITE3="${AGMSG_REAL_SQLITE3:-}"
if [ -z "$REAL_SQLITE3" ]; then
  load_cache || true
fi
if [ -z "$REAL_SQLITE3" ]; then
  REAL_SQLITE3="$(find_real_sqlite3 || true)"
fi
if [ -z "$REAL_SQLITE3" ]; then
  echo "sqlite3 shim: real sqlite3 executable not found" >&2
  exit 127
fi

if [ -z "$SUPPORTS_ESCAPE_OFF" ]; then
  if "$REAL_SQLITE3" -escape off :memory: "SELECT 1;" >/dev/null 2>&1; then
    SUPPORTS_ESCAPE_OFF=1
  else
    SUPPORTS_ESCAPE_OFF=0
  fi
  write_cache
fi

if [ "$SUPPORTS_ESCAPE_OFF" = "1" ]; then
  "$REAL_SQLITE3" -escape off "$@" | tr -d '\r'
else
  "$REAL_SQLITE3" "$@" | tr -d '\r'
fi
exit "${PIPESTATUS[0]}"
