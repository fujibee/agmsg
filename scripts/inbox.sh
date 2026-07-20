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
DB="$(agmsg_db_path)"

if [ ! -f "$DB" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
TEAM_SQL="$(_agmsg_sqlesc "$TEAM")"
AGENT_SQL="$(_agmsg_sqlesc "$AGENT")"

# Get unread messages — id first so the mark step below targets exactly these
# rows; escape newlines/tabs in body to keep one record per line
UNREAD=$(agmsg_sqlite "$DB" "
  SELECT id || char(31) || from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
  FROM messages WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL' AND read_at IS NULL
  ORDER BY created_at ASC;
")

if [ -z "$UNREAD" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# Display, collecting the ids actually shown
COUNT=$(echo "$UNREAD" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
IDS=""
while IFS=$'\x1f' read -r id from body ts; do
  echo "  [$ts] $from: $body"
  case "$id" in
    ''|*[!0-9]*) ;; # defensive: never splice a non-numeric value into SQL
    *) IDS="${IDS:+$IDS,}$id" ;;
  esac
done <<< "$UNREAD"
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

# Mark as read (non-fatal — may fail in sandboxed environments).
# Only the ids displayed above: a blanket "WHERE read_at IS NULL" would also
# swallow messages that arrived between the SELECT and this UPDATE — they
# would be marked read without ever having been shown.
if [ -n "$IDS" ]; then
  agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id IN ($IDS);" 2>/dev/null || true
fi
