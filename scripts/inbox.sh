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

# Get unread messages — include the exact id set that was displayed.  A later
# message may arrive between this SELECT and the acknowledgement; acknowledging
# by id keeps that message unread instead of silently consuming it.
UNREAD=$(agmsg_sqlite "$DB" "
  SELECT id || char(31) || from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
  FROM messages WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL' AND read_at IS NULL
  ORDER BY id ASC;
")

if [ -z "$UNREAD" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# Display
COUNT=$(echo "$UNREAD" | wc -l | tr -d ' ')
echo "$COUNT new message(s):"
echo ""
IDS=""
while IFS=$'\x1f' read -r id from body ts; do
  echo "  [$ts] $from: $body"
  IDS+="$id"$'\n'
done <<< "$UNREAD"
echo ""

# Mark only the rows displayed above (non-fatal — a failed acknowledgement
# deliberately leaves them unread, allowing at-least-once redelivery).
printf '%s' "$IDS" | "$SCRIPT_DIR/mark-read.sh" "$TEAM" "$AGENT" >/dev/null 2>&1 || true
