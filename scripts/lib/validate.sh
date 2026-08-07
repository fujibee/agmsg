#!/usr/bin/env bash
# validate.sh — input validation for values that become filesystem paths.
#
# Team names are used directly as path segments in the team registry
# (teams/<name>/config.json). A name containing "/", "\", or equal to "." / ".."
# can escape teams/ and create/read/move/delete files outside the agmsg state
# tree (#140). Validate at every entry point that turns a team name into a path:
# join.sh, leave.sh, team.sh, rename.sh, rename-team.sh, doctor.sh (--team).
#
# Team names are intentionally allowed to be arbitrary UTF-8 (e.g. Japanese team
# names like "testチーム" exist in the wild), so this is a deny-list of
# path-dangerous constructs, NOT an ASCII allow-list. Multibyte UTF-8 bytes are
# all >= 0x80, so they never match the control-character range below.

# Guard against double-source.
[ -n "${_AGMSG_VALIDATE_SH:-}" ] && return 0
_AGMSG_VALIDATE_SH=1

# Return 0 if <name> is safe to use as a single path segment, else print a
# specific error to stderr and return 1.
agmsg_validate_team_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "agmsg: invalid team name: must not be empty" >&2
    return 1
  fi
  case "$name" in
    .|..)
      echo "agmsg: invalid team name '$name': '.' and '..' are not allowed" >&2
      return 1 ;;
    */*|*\\*)
      echo "agmsg: invalid team name '$name': must not contain '/' or '\\' (path traversal)" >&2
      return 1 ;;
    -*)
      # Leading '-' would be parsed as an option by downstream tools.
      echo "agmsg: invalid team name '$name': must not start with '-'" >&2
      return 1 ;;
  esac
  # Reject control characters (NUL can't reach a shell var, but newline / tab /
  # other C0 + DEL can corrupt paths, configs, and row-counting output).
  case "$name" in
    *[[:cntrl:]]*)
      echo "agmsg: invalid team name: must not contain control characters" >&2
      return 1 ;;
  esac
  return 0
}

# Agent names are interpolated into a SQLite JSON path ($.agents.<name>); '.',
# '[', ']', '"' would misroute the path (silent wrong-key / array index), and
# '/' '\' / control chars are path/format hazards. UTF-8 (>= 0x80) is fine.
agmsg_validate_agent_name() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "agmsg: invalid agent name: must not be empty" >&2
    return 1
  fi
  case "$name" in
    .|..)
      echo "agmsg: invalid agent name '$name': '.' and '..' are not allowed" >&2
      return 1 ;;
    -*)
      echo "agmsg: invalid agent name '$name': must not start with '-'" >&2
      return 1 ;;
    *[./\\\"]* | *[][]* | *[[:cntrl:]]*)
      echo "agmsg: invalid agent name '$name': must not contain . / \ \" [ ] or control characters" >&2
      return 1 ;;
  esac
  return 0
}
