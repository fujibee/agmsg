#!/usr/bin/env bash
set -euo pipefail

# Usage: inbox.sh <team> <agent_id> [--quiet]
# Shows unread messages and marks them as read.
# --quiet: only output if there are unread messages (for hooks)

TEAM="${1:?Usage: inbox.sh <team> <agent_id> [--quiet]}"
AGENT="${2:?Missing agent_id}"
QUIET=false
if [ "${3:-}" = "--quiet" ]; then
  QUIET=true
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load

# A seat that reads its inbox names its own pane if it is not named
# (self-name.sh); see send.sh. Best-effort, never fails the read.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-name.sh"
agmsg_self_name_on_action "$TEAM" "$AGENT"
# Fix its own CLI session name once, early (self-rename.sh, #1081). Best-effort.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/self-rename.sh"
agmsg_self_rename_on_action "$TEAM" "$AGENT"

# An inbox check must not create the store, so a team that has never been
# written to has no file yet. Since the stores split per team that is the
# ORDINARY state of a freshly joined team, not a broken install — before the
# split one store was created for everyone at install time, so its absence
# really did mean something was wrong. Report it as what it is: no messages.
# Driver-level, so it covers jsonl's events.jsonl as well as sqlite's file.
if ! storage_store_exists "$TEAM"; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# On a capable driver, reserve before formatting and acknowledge only after
# one successful stdout write. A failed attempted write is UNKNOWN: retaining
# the lease avoids an immediate second handoff of possibly accepted bytes.
source "$SCRIPT_DIR/lib/delivery-reader.sh"
agmsg_reader_init inbox
if [ "${AGMSG_READER_CLAIMS?reader state missing}" -eq 1 ]; then
  UNREAD_JSONL="$(agmsg_reader_claim "$TEAM" "$AGENT")" || exit 13
  if [ -z "$UNREAD_JSONL" ]; then
    [ "$QUIET" = true ] || printf 'No new messages.\n'
    exit 0
  fi
  if ! agmsg_reader_parse "$UNREAD_JSONL" inbox 1 "$TEAM" "$AGENT"; then
    agmsg_reader_release "$TEAM" "$AGENT" "$UNREAD_JSONL"
    exit 13
  fi
  COUNT="${#AGMSG_READER_IDS[@]}"
  METADATA="${AGMSG_READER_METADATA?reader metadata missing}"
  PAYLOAD="$COUNT new message(s):"$'\n\n'"${AGMSG_READER_TEXT?reader state missing}"$'\n'
  if ! agmsg_reader_barrier ||
     ! agmsg_reader_control_metadata renew "$TEAM" "$AGENT" "$METADATA"; then
    agmsg_reader_release_metadata "$TEAM" "$AGENT" "$METADATA"
    exit 13
  fi
  EMIT_RC=0
  printf '%s' "$PAYLOAD" || EMIT_RC=$?
  if [ "$EMIT_RC" -ne 0 ]; then
    printf 'agmsg: delivery write outcome is unknown; reservation retained until expiry, after which redelivery is possible.\n' >&2
    exit "$EMIT_RC"
  fi
  if ! agmsg_reader_control_metadata ack "$TEAM" "$AGENT" "$METADATA"; then
    printf 'agmsg: failed to record read state for %s displayed message(s); some or all may be shown again after reservation expiry.\n' "$COUNT" >&2
  fi
  exit 0
fi

# Unread comes from the storage facade (§2.1 storage_list_unread = the event log
# UNION the legacy messages table), as one JSONL record per line in delivery
# order. Parse it with sqlite's JSON funcs in a single pass — the repo idiom, no
# jq dependency (cf. lib/hooks-json.sh).
UNREAD_JSONL=$(storage_list_unread "$TEAM" "$AGENT")

if [ -z "$UNREAD_JSONL" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# JSONL -> JSON array -> "from \x1f body \x1f at \x1f id" rows (newlines/tabs in
# the body escaped so each message stays one display line).
# The quote is held in a variable, never written as \' in the pattern: bash 3.2
# (macOS /bin/bash) keeps the backslash of a \' REPLACEMENT, so the inline form
# doubles a quote into \'\' there while producing '' on bash 4+. Same shape as
# _sqlite_sync_lit_into in sqlite-sync.sh, which documents the same hazard.
_AGMSG_SQ="'"
_arr="[$(printf '%s' "$UNREAD_JSONL" | paste -sd, -)]"
# #777/#1045: an agent's unread backlog grows with every message sent to it, so
# interpolating it into ONE argv element eventually exceeds the OS's
# per-argument ceiling (Linux MAX_ARG_STRLEN=131,072 bytes; smaller still on
# Windows/macOS) and `agmsg_sqlite` fails with "Argument list too long" --
# every single call, since the backlog that triggered it never shrinks on its
# own, and a single long body can carry it past the ceiling on its own too.
# Build the statement into a temp file and pass it on stdin instead, mirroring
# drivers/storage/sqlite-sync.sh:1301 (`_sqlite_data_stdin`, #882) and
# history.sh (#899): printf is a bash builtin, so writing a large value to a
# temp file never execs and can hit neither that ceiling nor argv's at all.
_agmsg_rows_sql=$(mktemp "${TMPDIR:-/tmp}/agmsg-inbox-rows.XXXXXX") || exit 13
trap 'rm -f "$_agmsg_rows_sql"' EXIT HUP INT TERM
{
  printf "%s\n" "SELECT json_extract(value,'\$.from') || char(31) ||"
  printf "%s\n" "       replace(replace(json_extract(value,'\$.body'), char(10), '\n'), char(9), '\t') || char(31) ||"
  printf "%s\n" "       json_extract(value,'\$.at') || char(31) ||"
  printf "%s\n" "       json_extract(value,'\$.id')"
  printf "FROM json_each('"
  printf '%s' "${_arr//$_AGMSG_SQ/$_AGMSG_SQ$_AGMSG_SQ}"
  printf "');\n"
} > "$_agmsg_rows_sql"
ROWS=$(agmsg_sqlite ':memory:' < "$_agmsg_rows_sql")
rm -f "$_agmsg_rows_sql"
trap - EXIT HUP INT TERM

COUNT=$(printf '%s\n' "$ROWS" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
IDS=()
while IFS=$'\x1f' read -r from body ts id; do
  [ -n "$id" ] || continue
  echo "  [$ts] $from: $body"
  IDS+=("$id")
done <<< "$ROWS"
echo ""

# Test seam: a two-file barrier that lets the race regression test land a
# message deterministically between display and mark. No-op unless set.
if [ -n "${AGMSG_TEST_MARK_BARRIER:-}" ]; then
  : > "$AGMSG_TEST_MARK_BARRIER.reached"
  _agmsg_barrier_waited=0
  while [ ! -e "$AGMSG_TEST_MARK_BARRIER.release" ]; do
    sleep 0.05
    _agmsg_barrier_waited=$((_agmsg_barrier_waited + 1))
    [ "$_agmsg_barrier_waited" -ge 200 ] && break # 10s safety cap
  done
fi

# Mark read via the storage facade (§2.1 storage_mark_read_batch): recipient-
# scoped and idempotent. For a legacy id it records a message_read event
# without mutating the legacy row (§2.4). Only the ids collected from the
# rows actually displayed above — never a blanket match — so a message that
# arrives after the SELECT above can never be marked read unseen. Non-fatal —
# may fail in sandboxed environments or lose to a concurrent writer — but a
# failure is reported on stderr, because the messages above were displayed
# and their read state is now unknown (#1011). "Some or all", not "they":
# only the sqlite driver marks in one transaction; the jsonl driver can have
# recorded part of the batch before the failing step. The exit status stays
# 0: the inbox did deliver.
if [ "${#IDS[@]}" -gt 0 ]; then
  if ! storage_mark_read_batch "$TEAM" "$AGENT" "${IDS[@]}" >/dev/null 2>&1; then
    echo "agmsg: failed to record read state for ${#IDS[@]} displayed message(s); some or all may be shown again (#1011)" >&2
  fi
fi
