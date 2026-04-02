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

DB="$(cd "$(dirname "$0")/../db" && pwd)/messages.db"

if [ ! -f "$DB" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

# Get unread messages
UNREAD=$(sqlite3 -json "$DB" "SELECT id, from_agent, body, created_at FROM messages WHERE team='$TEAM' AND to_agent='$AGENT' AND read_at IS NULL ORDER BY created_at ASC;")

if [ "$UNREAD" = "[]" ] || [ -z "$UNREAD" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

# Display
echo "$UNREAD" | python3 -c '
import json, sys
msgs = json.load(sys.stdin)
print(f"{len(msgs)} new message(s):")
print()
for m in msgs:
    print(f"  [{m["created_at"]}] {m["from_agent"]}: {m["body"]}")
print()
'

# Mark as read (non-fatal — may fail in sandboxed environments)
sqlite3 "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE team='$TEAM' AND to_agent='$AGENT' AND read_at IS NULL;" 2>/dev/null || true
