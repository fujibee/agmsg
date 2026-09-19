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
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_storage_load

_reply() {
  local body="$1"
  [ -n "$body" ] || return 0
  storage_send "$TEAM" "$TO" "$FROM" "$body" >/dev/null 2>&1 || true
}

# Last gate before $TOOL becomes a path (drivers/ext-tools/$TOOL/...): send.sh
# and join.sh already validate any tool name that reaches them, but this
# script is also invoked directly with args it does not otherwise control, so
# it checks again rather than trusting its caller.
if ! agmsg_validate_tool_name "$TOOL" >/dev/null 2>&1; then
  _reply "$TO: processing failed (invalid tool name '$TOOL')"
  rm -f "$BODY_FILE"
  exit 0
fi

HANDLE="$SCRIPT_DIR/drivers/ext-tools/$TOOL/handle"
TOOL_CONF="$SCRIPT_DIR/drivers/ext-tools/$TOOL/tool.conf"
CONFIG_PATH="$SKILL_DIR/ext-tools/$TEAM/$TO.conf"

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
PAYLOAD_FILE="$(mktemp)"
TIMED_OUT_FILE="$(mktemp)"
DONE_FILE="$(mktemp)"
rm -f "$TIMED_OUT_FILE" "$DONE_FILE"  # existence, not content, is the signal below
trap 'rm -f "$STDOUT_FILE" "$STDERR_FILE" "$PAYLOAD_FILE" "$TIMED_OUT_FILE" "$DONE_FILE"' EXIT INT TERM
printf '%s' "$PAYLOAD" > "$PAYLOAD_FILE"

# No external `timeout` dependency: coreutils' timeout is commonly absent on
# macOS, and running handle without any bound at all on that path silently
# dropped tool.conf's timeout= entirely -- a hung handle then leaked a
# process forever and the sender never heard back, either (review finding).
#
# `set -m` gives the backgrounded job its OWN process group (pgid == the
# leader's own pid), instead of inheriting this script's, so a TERM/KILL
# addressed to the group (`kill -- -PGID`, the leading '-' means "the group",
# not "the single process") reaches handle's own grandchildren too -- a
# handle that is itself a wrapper backgrounding further work used to leave
# that work orphaned when only its own pid was signaled. `set +m` right
# after is just this script returning to its own default mode.
#
# This does NOT poll $HPID with kill -0 (an earlier version of this script
# did, and that was wrong): bash can reap a background child via its SIGCHLD
# handler before this script ever calls `wait`, at which point the kernel is
# free to hand the same pid to an unrelated process -- a poll loop watching
# $HPID across multiple `sleep`s can end up signaling that unrelated process
# instead. Two independent things happen concurrently instead: a "killer"
# subshell that, once TIMEOUT elapses, sends TERM then KILL to the group
# UNLESS handle already finished (see DONE_FILE below), and this script's own
# `wait "$HPID"`, which bash tracks correctly for its own direct child
# regardless of reap timing. The killer is started AFTER $HPID is assigned --
# it is a subshell forked from this script's own state, so it must see the
# real value, not an empty one from before handle was launched.
#
# The killer is deliberately never stopped by pid. An earlier version of
# this script called `kill "$KILLER_PID"` once wait returned, to cancel the
# killer if it hadn't fired yet -- but on the timeout path the killer
# finishes (TERM, then KILL, then exit) and gets reaped well before this
# script gets back around to that `kill`, so that `kill "$KILLER_PID"` could
# land on an unrelated process that reused the same pid (the same class of
# bug this whole rewrite exists to close, just moved one level up). Instead:
# this script creates DONE_FILE the moment wait returns, and the killer
# checks for DONE_FILE BEFORE doing anything, not after -- if handle already
# finished, the killer sees DONE_FILE and does nothing at all, and simply
# runs to completion (and exit) on its own once its own sleep ends. It is
# never left as a standing process: at worst it keeps existing, asleep, for
# up to TIMEOUT more seconds after handle already finished, then exits by
# itself with nothing left to reap it explicitly.
set -m
"$HANDLE" <"$PAYLOAD_FILE" >"$STDOUT_FILE" 2>"$STDERR_FILE" &
HPID=$!
set +m

(
  sleep "$TIMEOUT"
  if [ ! -f "$DONE_FILE" ]; then
    : > "$TIMED_OUT_FILE"
    kill -TERM -- "-$HPID" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$HPID" 2>/dev/null || true
  fi
) &

RC=0
wait "$HPID" 2>/dev/null || RC=$?
: > "$DONE_FILE"

# One more unconditional sweep of the group in case handle exited on its own
# (without timing out) but left grandchildren behind in its own group.
kill -KILL -- "-$HPID" 2>/dev/null || true

# NOT claimed safe against pid reuse. Two real, accepted gaps, neither
# solved, both narrow:
# - This sweep, and the killer's own TERM/KILL, run after handle's group is
#   already known to be ending (wait returned here; the killer's own sleep
#   elapsed there) -- in the instant right after the group empties and
#   before the OS reuses that same pgid number, a kill can land on the
#   wrong group.
# - The killer's DONE_FILE check can itself lose the race: if handle
#   finishes right at the timeout boundary, the killer may check DONE_FILE
#   a moment before this script writes it, and proceed to act on a group
#   that is already empty (or, rarer, already reused).
if [ -f "$TIMED_OUT_FILE" ]; then
  TIMED_OUT=1
else
  TIMED_OUT=0
fi

if [ "$TIMED_OUT" -eq 1 ]; then
  _reply "$TO: processing failed (timed out after ${TIMEOUT}s)"
elif [ "$RC" -ne 0 ]; then
  REASON="$(head -1 "$STDERR_FILE" 2>/dev/null)"
  [ -n "$REASON" ] || REASON="exit $RC"
  _reply "$TO: processing failed ($REASON)"
else
  _reply "$(cat "$STDOUT_FILE")"
fi
