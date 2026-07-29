#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> --stdin [--force]
#    or: send.sh <team> <from> <to> --body-file <path> [--force]
#    or: send.sh <team> <from> <to> <message> [--force]   (deprecated)
#
# #378: a message body passed positionally goes through the SENDER's shell
# before it ever reaches this script — an unescaped `$(...)` in a quoted
# body can execute, and backticks can be silently evaluated/emptied. On
# Windows/MSYS a positional body is additionally routed through MSYS's
# argv-conversion path (build_argv -> globify), which truncates silently at
# exactly 8186 bytes (fixed MAXPATHLEN 8192 buffer in glob.cc). --stdin and
# --body-file read the body verbatim from a file descriptor instead of
# argv, so a body sent that way meets neither hazard — no shell
# re-interpretation, no argv size limit.
#
# That makes --stdin/--body-file the canonical way to send; it does not
# remove the hazard, because the positional form still exists and still
# carries both. The positional form is DEPRECATED: it keeps working for now,
# but a body composed by an agent must not use it. Retiring it is a later,
# breaking stage of #378 — this stage only moves every first-party example
# onto the safe path.
#
# Four literal bodies DO break here, and `--` is their migration syntax:
# `--`, `--stdin` and `--body-file` are now consumed as a terminator or a
# mode selector, and `--force` is now rejected outright (it used to arrive as
# the body, because only argument 5 was checked for the flag). Send any of
# them as `send.sh <team> <from> <to> -- <body>` — including `-- --`. Every
# other positional body is unaffected.

USAGE="Usage: send.sh <team> <from> <to> --stdin [--force]
   or: send.sh <team> <from> <to> --body-file <path> [--force]
   or: send.sh <team> <from> <to> <message> [--force]   (deprecated, see #378)"

TEAM="${1:?$USAGE}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
shift 3

MODE="positional"
BODY=""
BODY_FILE=""
FORCE=0

if [ $# -eq 0 ]; then
  echo "Error: missing message body. Provide it positionally, via --stdin, or via --body-file <path>." >&2
  exit 1
fi

case "$1" in
  --)
    # Option terminator: everything after it is the body, verbatim. Without
    # this, adding --stdin/--body-file silently broke a body that happens to
    # BE the literal string "--stdin" (or "--body-file"/"--force"), which was
    # a perfectly valid positional body before this change. `--` is the
    # standard escape hatch and keeps that case working.
    shift
    if [ $# -eq 0 ]; then
      echo "Error: missing message body after '--'." >&2
      exit 1
    fi
    BODY="$1"
    shift
    ;;
  --stdin)
    MODE="stdin"
    shift
    ;;
  --body-file)
    shift
    if [ $# -eq 0 ]; then
      echo "Error: --body-file requires a path argument." >&2
      exit 1
    fi
    # A leading '-' means the "path" is actually another flag that got
    # swallowed here (e.g. `--body-file --stdin`, `--body-file --force`)
    # instead of tripping the ambiguity check below. Reject it the same way
    # validate.sh rejects a team/agent name starting with '-' — it would be
    # parsed as an option by downstream tools. A real file named like that
    # still works via an explicit './-foo' or absolute path.
    case "$1" in
      -*)
        echo "Error: --body-file's argument '$1' looks like a flag, not a path. To use a file whose name starts with '-', pass './$1' or an absolute path." >&2
        exit 1
        ;;
    esac
    MODE="file"
    BODY_FILE="$1"
    shift
    ;;
  --force)
    echo "Error: missing message body before --force. Provide it positionally, via --stdin, or via --body-file <path>." >&2
    exit 1
    ;;
  *)
    BODY="$1"
    shift
    ;;
esac

# Reject combining two input modes instead of silently picking one — e.g. a
# positional body followed by --stdin, or --stdin followed by --body-file.
if [ "${1:-}" = "--stdin" ] || [ "${1:-}" = "--body-file" ]; then
  echo "Error: the message body was already given (positional argument, --stdin, or --body-file) — cannot also pass $1. Provide the body exactly one way." >&2
  exit 1
fi

if [ "${1:-}" = "--force" ]; then
  FORCE=1
  shift
fi

if [ $# -gt 0 ]; then
  echo "Error: unexpected extra argument(s) after the message: $*" >&2
  exit 1
fi

if [ "$MODE" = "positional" ] && [ -z "$BODY" ]; then
  echo "Error: missing message body." >&2
  exit 1
fi

# Read the body verbatim (no word-splitting, no glob expansion). `IFS= read
# -r -d ''` slurps to EOF without stripping leading or trailing
# whitespace/newlines — deliberately: whatever bytes are on stdin or in the
# file land in the message exactly as given, including any trailing
# newline(s). If you don't want a trailing newline in the sent message,
# don't put one in the input.
#
# The exit status is load-bearing, so it is checked rather than discarded:
# `read` exits 0 only when it actually found its -d delimiter — which here
# is NUL — and non-zero when it reached EOF without one. EOF is the normal,
# complete read. A zero exit therefore means exactly one thing: the input
# carries a NUL byte, and BODY already stops there, because a bash string
# cannot hold one. Storing that shortened value and exiting 0 would tell the
# caller the whole body was sent when it was not, so a NUL-bearing body is
# refused instead. (A positional <message> cannot hit this: argv strings
# cannot carry NUL either, so such a body never reaches this script intact
# in the first place.)
if [ "$MODE" = "stdin" ]; then
  if IFS= read -r -d '' BODY; then
    echo "Error: --stdin input contains a NUL byte; a message body must be text, and everything from that byte on would be lost. Nothing was sent." >&2
    exit 1
  fi
  if [ -z "$BODY" ]; then
    echo "Error: --stdin was given but no data was read from standard input." >&2
    exit 1
  fi
elif [ "$MODE" = "file" ]; then
  if [ ! -f "$BODY_FILE" ]; then
    echo "Error: --body-file '$BODY_FILE' does not exist or is not a regular file." >&2
    exit 1
  fi
  if [ ! -r "$BODY_FILE" ]; then
    echo "Error: --body-file '$BODY_FILE' is not readable." >&2
    exit 1
  fi
  if IFS= read -r -d '' BODY < "$BODY_FILE"; then
    echo "Error: --body-file '$BODY_FILE' contains a NUL byte; a message body must be text, and everything from that byte on would be lost. Nothing was sent." >&2
    exit 1
  fi
  if [ -z "$BODY" ]; then
    echo "Error: --body-file '$BODY_FILE' is empty." >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

# #414: TEAM becomes a path segment (teams/$TEAM/config.json) below whether or
# not --force is given, so validate it unconditionally, before any config-path
# resolution or DB init. --force bypasses roster *membership* only — it must
# never bypass team-name path safety.
agmsg_validate_team_name "$TEAM" || exit 1

DB="$(agmsg_db_path)"

[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

# #355: reject a from/to that isn't registered in <team> — an unnoticed typo
# (e.g. a stray send to "dummy") used to insert successfully with exit 0,
# landing an undeliverable message and polluting history. Validation lives
# here (the front door), not in storage.sh, so other entry points (api.sh)
# can keep their own policy. --force bypasses this for intentional
# pre-registration sends (e.g. notifying a role before its own join.sh runs).
if [ "$FORCE" -ne 1 ]; then
  TEAM_CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

  _agmsg_roster_check() {
    local role="$1" name="$2"
    if [ ! -f "$TEAM_CONFIG" ]; then
      echo "Error: team '$TEAM' has no registered agents — cannot send as $role '$name' (use --force to bypass)." >&2
      return 1
    fi
    local cfg_sql name_sql found roster
    cfg_sql=$(agmsg_sql_readfile_path "$TEAM_CONFIG")
    name_sql=$(printf '%s' "$name" | sed "s/'/''/g")
    found=$(agmsg_sqlite_mem "
      WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
      cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
      SELECT value
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      WHERE key = '$name_sql';
    ")
    if [ -z "$found" ]; then
      roster=$(agmsg_sqlite_mem "
        WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
        cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
        SELECT group_concat(key, ', ')
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'));
      ")
      echo "Error: $role agent '$name' is not registered in team '$TEAM' (registered: ${roster:-none}). Use --force to bypass." >&2
      return 1
    fi
    return 0
  }

  _agmsg_roster_check "from" "$FROM" || exit 1
  _agmsg_roster_check "to" "$TO" || exit 1
fi

# Escape EVERY interpolated value as a SQL string literal, not just body: a
# team/agent name containing a single quote would otherwise break the INSERT
# (correctness) or change its meaning (injection surface).
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

# #378: a command substitution — `$(...)` — always drops ALL of its trailing
# newlines, no matter how many there are. TEAM/FROM/TO can never contain a
# newline (validate.sh rejects control characters), but BODY legitimately
# can now that --stdin/--body-file read it verbatim, and plugging it into
# the INSERT below via a plain `$(_agmsg_sqlesc "$BODY")` would silently
# eat any trailing newline(s) the caller asked to send. Appending a
# non-newline sentinel before escaping moves the trailing newline(s) into
# the middle of the captured text (where command substitution does not
# touch them), then the sentinel is stripped back off — preserving BODY's
# trailing newline(s) exactly instead of losing them the same way TEAM/
# FROM/TO's escaping still does (harmlessly, since those can't have any).
_BODY_SQL="$(_agmsg_sqlesc "${BODY}X")"
_BODY_SQL="${_BODY_SQL%X}"
INSERT="INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$(_agmsg_sqlesc "$TEAM")', '$(_agmsg_sqlesc "$FROM")', '$(_agmsg_sqlesc "$TO")', '$_BODY_SQL');"

# Retry once after ensuring the schema. Under a concurrent first-write fan-out
# (leader → N members against a fresh/override store), one process can see the
# DB file exist before the winning initializer has finished creating the table,
# so its INSERT would hit "no such table". init-db.sh is idempotent + uses the
# busy_timeout, so re-running it waits for the schema, then the INSERT lands.
# See #114.
# Pipe the SQL via stdin (not as an argv) so a large body cannot overflow the
# OS command-line limit (the "Argument list too long" crash).
if ! printf '%s
' "$INSERT" | agmsg_sqlite "$DB" 2>/dev/null; then
  bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null
  printf '%s
' "$INSERT" | agmsg_sqlite "$DB"
fi

echo "Sent to $TO in team $TEAM"
