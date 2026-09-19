#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   send.sh <team> <from> <to> <message> [--force]              # body as ONE quoted arg
#   send.sh <team> <from> <to> --body-file <path> [--force]     # body read from a file
#   send.sh <team> <from> <to> --body - [--force]               # body read from stdin
#
# --body-file matches poke.sh, for the same reason (#507) AND to close #1101: a caller
# who learned --body-file from poke used to have send take the literal string
# "--body-file" as the message and exit zero (the flag has different meanings on the two
# adjacent commands). A positional <message> also passes through the CALLER's shell first,
# where a backtick or $( ) executes and its span silently vanishes; send bodies are longer
# and likelier to contain them. So a message that is a bare unconsumed flag (starts with
# --, and is not --body-file/--body) is now REFUSED rather than sent, and a mistyped flag
# never lands as content. Trailing newlines are stripped from a file/stdin body, as in
# poke (command-substitution semantics).

die() { echo "send.sh: $*" >&2; exit 1; }

TEAM="${1:?Usage: send.sh <team> <from> <to> <message|--body-file PATH|--body -> [--force]}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
shift 3

# --force is historically the trailing flag AFTER the body; recognize it only as the
# last argument, so a --body-file body whose text happens to be "--force" is unaffected.
FORCE=0
if [ "$#" -gt 0 ] && [ "${!#}" = "--force" ]; then
  FORCE=1
  set -- "${@:1:$#-1}"
fi

case "${1:-}" in
  --body-file)
    [ "$#" -eq 2 ] || die "--body-file takes exactly one path"
    [ -r "${2:-}" ] || die "cannot read body file: ${2:-<missing>}"
    BODY="$(cat -- "$2")"
    ;;
  --body)
    { [ "$#" -eq 2 ] && [ "${2:-}" = "-" ]; } \
      || die "--body accepts only '-' (read stdin); for a file use --body-file <path>"
    BODY="$(cat)"
    ;;
  '')
    die "Missing message body"
    ;;
  --*)
    die "unrecognized option '${1}' — a message that starts with '-' must go through --body-file <path> or --body - (a bare flag is refused so a mistyped one is never sent as the message, #1101)"
    ;;
  *)
    [ "$#" -eq 1 ] || die "got extra arguments — quote the message as ONE argument, or use --body-file <path>"
    BODY="$1"
    ;;
esac
[ -n "$BODY" ] || die "the message body is empty — nothing to send"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

# #414: TEAM becomes a path segment (teams/$TEAM/config.json) below whether or
# not --force is given, so validate it unconditionally, before any config-path
# resolution or DB init. --force bypasses roster *membership* only — it must
# never bypass team-name path safety.
agmsg_validate_team_name "$TEAM" || exit 1

# A seat that sends names its own pane if it is not named (self-name.sh): the
# 1.3.0 rule that every live seat's terminal id/name is right in any state,
# tied to the action rather than to a CLI's boot path. Best-effort, never fails
# the send; the common case is one file read.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-name.sh"
agmsg_self_name_on_action "$TEAM" "$FROM"
# And, once and early, fix its own CLI session name by typing /rename into its own
# pane (self-rename.sh, #1081). Best-effort, never fails the send; opt out with
# AGMSG_SELF_RENAME=off (or the whole family with AGMSG_SELF_NAME=off).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-rename.sh"
agmsg_self_rename_on_action "$TEAM" "$FROM"

agmsg_storage_load
DB="$(agmsg_db_path "$TEAM")"

# Keep the full-schema bootstrap (registry + storage tables) for a first-ever
# command; the message write itself goes through the storage facade below.
[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

# Unconditional (moved ahead of the --force gate below): the ext-tool
# dispatch check after storage_send needs this path regardless of --force.
TEAM_CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

# #355: reject a from/to that isn't registered in <team> — an unnoticed typo
# (e.g. a stray send to "dummy") used to insert successfully with exit 0,
# landing an undeliverable message and polluting history. Validation lives
# here (the front door), not in storage.sh, so other entry points (api.sh)
# can keep their own policy. --force bypasses this for intentional
# pre-registration sends (e.g. notifying a role before its own join.sh runs).
if [ "$FORCE" -ne 1 ]; then
  _agmsg_roster_check() {
    local role="$1" name="$2"
    if [ ! -f "$TEAM_CONFIG" ]; then
      echo "Error: team '$TEAM' has no registered agents — cannot send as $role '$name' (use --force to bypass)." >&2
      return 1
    fi
    local cfg_sql name_sql found roster q="'"
    cfg_sql=$(agmsg_sql_readfile_path "$TEAM_CONFIG")
    name_sql=${name//$q/$q$q}
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

# Write through the storage axis (§2.1 storage_send) — the active driver now owns
# the message log (an append-only message_sent event), not a direct INSERT.
# storage_send re-inits its schema idempotently before writing, which subsumes the
# #114 concurrent first-write race the old path retried around (a process seeing
# the DB file before the table exists just creates it).
MSG_ID="$(storage_send "$TEAM" "$FROM" "$TO" "$BODY")"

echo "Sent to $TO in team $TEAM"

# ext-tool dispatch (see scripts/drivers/ext-tools/README.md): fires
# only when $TO is registered as ext-tool AND joined ON THIS MACHINE (its
# member config exists locally) -- a message that only arrived here through
# remote sync is explicitly out of scope for v1 (the tool never ran anything
# for it on the machine it was actually addressed to). Best-effort: any
# failure below is reported but never turns a successful send into a failed
# one -- the message is already saved by this point.
if [ -n "${MSG_ID:-}" ] && [ -f "$TEAM_CONFIG" ]; then
  # Quote held in a variable, not written inline in the pattern (#897): a
  # literal \' replacement disagrees between bash 3.2 (keeps the backslash,
  # doubling into \'\') and bash 4+ (doubles into ''), and this scope has no
  # $q from _agmsg_roster_check's own local above to reuse.
  q="'"
  TO_SQL=${TO//$q/$q$q}
  TO_TYPE="$(agmsg_sqlite_mem "
    WITH raw(json) AS (SELECT CAST(readfile('$(agmsg_sql_readfile_path "$TEAM_CONFIG")') AS TEXT)),
    cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw),
    agent(a) AS (SELECT value FROM cfg, json_each(json_extract(cfg.json, '\$.agents')) WHERE key = '$TO_SQL')
    SELECT CASE
      WHEN EXISTS(
        SELECT 1 FROM agent, json_each(json_extract(agent.a, '\$.registrations'))
        WHERE json_extract(value, '\$.type') = 'ext-tool'
      ) THEN 'ext-tool'
      WHEN (SELECT json_extract(agent.a, '\$.type') FROM agent) = 'ext-tool' THEN 'ext-tool'
      ELSE ''
    END;
  " 2>/dev/null)"
  if [ "$TO_TYPE" = ext-tool ]; then
    # Every branch below that cannot dispatch reports a named failure back to
    # the sender instead of silently doing nothing: a message to an ext-tool
    # member that is unconfigured, misconfigured, or names an unknown tool
    # must not just vanish with the send still reporting success (review
    # finding).
    EXT_TOOL_FAIL_REASON=""
    EXT_TOOL_NAME=""
    EXT_TOOL_CONFIG="$SCRIPT_DIR/../ext-tools/$TEAM/$TO.conf"
    if [ ! -f "$EXT_TOOL_CONFIG" ]; then
      EXT_TOOL_FAIL_REASON="not configured on this machine"
    else
      # Same defensive key=value read as ext-tool-dispatch.sh's own timeout=
      # read: never sourced, first match, empty on any miss.
      EXT_TOOL_LINE="$( { grep -E '^[[:space:]]*tool[[:space:]]*=' "$EXT_TOOL_CONFIG" 2>/dev/null || true; } | head -1)"
      EXT_TOOL_NAME="${EXT_TOOL_LINE#*=}"
      EXT_TOOL_NAME="${EXT_TOOL_NAME#"${EXT_TOOL_NAME%%[![:space:]]*}"}"
      EXT_TOOL_NAME="${EXT_TOOL_NAME%"${EXT_TOOL_NAME##*[![:space:]]}"}"
      if [ -z "$EXT_TOOL_NAME" ]; then
        EXT_TOOL_FAIL_REASON="its config names no tool"
      else
        # tool='s value flows straight into a path
        # (drivers/ext-tools/$EXT_TOOL_NAME/handle). Unlike a --tool argument
        # at join time -- which never gets this far unless the directory it
        # names already existed -- this comes from a file that could have
        # been hand-edited or corrupted, so it gets the same shared
        # character-class check as every other path built from a tool name
        # (lib/validate.sh), not just the existence check below.
        if ! agmsg_validate_tool_name "$EXT_TOOL_NAME" >/dev/null 2>&1; then
          EXT_TOOL_FAIL_REASON="its config names an invalid tool '$EXT_TOOL_NAME'"
        elif [ ! -x "$SCRIPT_DIR/drivers/ext-tools/$EXT_TOOL_NAME/handle" ]; then
          EXT_TOOL_FAIL_REASON="unknown tool '$EXT_TOOL_NAME'"
        fi
      fi
    fi

    if [ -n "$EXT_TOOL_FAIL_REASON" ]; then
      storage_send "$TEAM" "$TO" "$FROM" "$TO: processing failed ($EXT_TOOL_FAIL_REASON)" >/dev/null 2>&1 || true
    else
      mkdir -p "$SCRIPT_DIR/../run"
      EXT_TOOL_BODY_FILE="$(mktemp)"
      printf '%s' "$BODY" > "$EXT_TOOL_BODY_FILE"
      nohup bash "$SCRIPT_DIR/internal/ext-tool-dispatch.sh" \
        "$TEAM" "$FROM" "$TO" "$EXT_TOOL_NAME" "$MSG_ID" "$EXT_TOOL_BODY_FILE" \
        >>"$SCRIPT_DIR/../run/ext-tool-dispatch.$TEAM.$TO.log" 2>&1 3>&- 4>&- &
      disown 2>/dev/null || true
    fi
  fi
fi
