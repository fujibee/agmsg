#!/usr/bin/env bash
# Runs one ext-tool handle call and sends its reply. Always launched detached
# (nohup ... &) by send.sh, never waited on by the sender -- no ext-tool
# adapter runs as a standing process, so there is nothing to keep the sender
# waiting on either. Deliberately not `set -e`: a failure partway through
# must still reach the final reply send (handle failing IS a normal, expected
# outcome here, not a bug in this script) rather than exit silently, which is
# exactly the failure mode drivers/ext-tools/README.md's `handle` contract
# exists to rule out.
set -uo pipefail

TEAM="${1:?Usage: ext-tool-dispatch.sh <team> <from> <to> <tool> <message_id> <body_file>}"
FROM="${2:?Missing from}"
TO="${3:?Missing to}"
TOOL="${4:?Missing tool}"
MESSAGE_ID="${5:?Missing message_id}"
BODY_FILE="${6:?Missing body_file}"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load

HANDLE="$SCRIPT_DIR/drivers/ext-tools/$TOOL/handle"
TOOL_CONF="$SCRIPT_DIR/drivers/ext-tools/$TOOL/tool.conf"
CONFIG_PATH="$SKILL_DIR/ext-tools/$TEAM/$TO.conf"

_reply() {
  local body="$1"
  [ -n "$body" ] || return 0
  storage_send "$TEAM" "$TO" "$FROM" "$body" >/dev/null 2>&1 || true
}

if [ ! -x "$HANDLE" ]; then
  _reply "$TO: processing failed (no handle for '$TOOL')"
  rm -f "$BODY_FILE"
  exit 0
fi

# tool.conf's timeout= (seconds), default 30. Read the same defensive way
# agmsg_type_get reads type.conf: never sourced, first match, default on any
# miss so a malformed or missing tool.conf degrades to the default instead of
# hanging forever.
TIMEOUT=30
if [ -f "$TOOL_CONF" ]; then
  _line="$( { grep -E '^[[:space:]]*timeout[[:space:]]*=' "$TOOL_CONF" 2>/dev/null || true; } | head -1)"
  if [ -n "$_line" ]; then
    _val="${_line#*=}"
    _val="${_val#"${_val%%[![:space:]]*}"}"
    _val="${_val%"${_val##*[![:space:]]}"}"
    case "$_val" in ''|*[!0-9]*) ;; *) TIMEOUT="$_val" ;; esac
  fi
  unset _line _val
fi

# The payload is built with readfile() for `body` so nothing about its
# content -- quotes, backslashes, newlines -- has to be escaped by hand; see
# lib/sqlpath.sh's own rationale for why a path bound for SQL always goes
# through agmsg_sql_readfile_path rather than a caller inventing its own
# escaper (#669).
PAYLOAD="$(sqlite3 :memory: "SELECT json_object(
  'team', '$(agmsg_sqlesc "$TEAM")',
  'from', '$(agmsg_sqlesc "$FROM")',
  'to', '$(agmsg_sqlesc "$TO")',
  'body', CAST(readfile('$(agmsg_sql_readfile_path "$BODY_FILE")') AS TEXT),
  'message_id', '$(agmsg_sqlesc "$MESSAGE_ID")',
  'config_path', '$(agmsg_sqlesc "$CONFIG_PATH")'
);" 2>/dev/null)"
rm -f "$BODY_FILE"

if [ -z "$PAYLOAD" ]; then
  _reply "$TO: processing failed (could not build the request)"
  exit 0
fi

STDOUT_FILE="$(mktemp)"
STDERR_FILE="$(mktemp)"
trap 'rm -f "$STDOUT_FILE" "$STDERR_FILE"' EXIT INT TERM

RC=0
if command -v timeout >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | timeout "${TIMEOUT}s" "$HANDLE" >"$STDOUT_FILE" 2>"$STDERR_FILE" || RC=$?
else
  # No coreutils `timeout` (older macOS without it on PATH): run without one
  # rather than fail every call — a hung handle then costs this one dispatch,
  # not correctness, and it never blocks the sender either way (#4 above).
  printf '%s' "$PAYLOAD" | "$HANDLE" >"$STDOUT_FILE" 2>"$STDERR_FILE" || RC=$?
fi

if [ "$RC" -ne 0 ]; then
  REASON="$(head -1 "$STDERR_FILE" 2>/dev/null)"
  [ -n "$REASON" ] || REASON="exit $RC"
  _reply "$TO: processing failed ($REASON)"
else
  _reply "$(cat "$STDOUT_FILE")"
fi
