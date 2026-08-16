#!/usr/bin/env bash
# The one place a filesystem path becomes a sqlite string literal.
#
# sqlite3's readfile()/writefile() open the path with the C library, not with
# the shell's. On Windows the sqlite3 on PATH is a native binary, so a Git Bash
# path like /d/a/agmsg/x.json is not a path it can open at all: readfile()
# returns NULL, the surrounding json parse yields no rows, and the caller sees
# an empty result that is indistinguishable from an empty file. cygpath -w
# converts to the native D:\a\agmsg\x.json form first. Off Windows cygpath does
# not exist and this is an escape and nothing else.
#
# This lives in its own file because the rule is "a path bound for SQL goes
# through this function", and a rule with two copies has two answers the moment
# one of them is edited. It had two copies -- storage.sh and hooks-json.sh --
# and a third caller wrote its own escaper instead, which is #669: join.sh
# exited 1 in silence on Git Bash after creating the team, because the roster
# journal handed sqlite an MSYS path.
#
# Escaping a VALUE is a different job with a different answer -- see
# agmsg_sqlesc in storage.sh. Converting a value would corrupt it; escaping a
# path leaves it unopenable. The two are not interchangeable, which is exactly
# the substitution that caused #669.

[ -n "${_AGMSG_SQLPATH_SH:-}" ] && return 0
_AGMSG_SQLPATH_SH=1

agmsg_sql_readfile_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    path=$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")
  fi
  printf '%s' "$path" | sed "s/'/''/g"
}

# True when sqlite can actually open <path>.
#
# The second half of #669. readfile() yields NULL for a path it cannot open and
# an empty blob for a file that is genuinely empty, but every projection built
# on it collapses both into "no rows" -- so a caller testing whether its result
# is empty cannot tell "this roster has no members" from "sqlite never saw the
# file". join.sh returned 1 with nothing on stderr for hours of Windows CI
# because those two answers are the same answer.
#
# `IS NOT NULL` is the one place the distinction still exists. Ask before
# reading, so a failure can say which path could not be opened instead of
# looking like an empty file.
agmsg_sql_readfile_ok() {
  local path="$1" seen
  seen="$(sqlite3 :memory: \
    "SELECT readfile('$(agmsg_sql_readfile_path "$path")') IS NOT NULL;" \
    2>/dev/null | tr -d '\r')"
  [ "$seen" = "1" ]
}
