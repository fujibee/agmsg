#!/usr/bin/env bash
set -euo pipefail

# Usage: history.sh <team> [agent_id] [limit]
# Shows message history. If agent_id given, shows only that agent's messages.

TEAM="${1:?Usage: history.sh <team> [agent_id] [limit]}"
AGENT="${2:-}"
LIMIT="${3:-20}"

DB="$(cd "$(dirname "$0")/../db" && pwd)/messages.db"

if [ ! -f "$DB" ]; then
  echo "No messages (DB not initialized)"
  exit 0
fi

if [ -n "$AGENT" ]; then
  QUERY="SELECT id, from_agent, to_agent, body, created_at, CASE WHEN read_at IS NULL THEN 'unread' ELSE 'read' END as status FROM messages WHERE team='$TEAM' AND (from_agent='$AGENT' OR to_agent='$AGENT') ORDER BY created_at DESC LIMIT $LIMIT;"
else
  QUERY="SELECT id, from_agent, to_agent, body, created_at, CASE WHEN read_at IS NULL THEN 'unread' ELSE 'read' END as status FROM messages WHERE team='$TEAM' ORDER BY created_at DESC LIMIT $LIMIT;"
fi

RESULT=$(sqlite3 -json "$DB" "$QUERY")

if [ "$RESULT" = "[]" ] || [ -z "$RESULT" ]; then
  echo "No message history."
  exit 0
fi

echo "$RESULT" | python3 -c '
import json, sys
msgs = json.load(sys.stdin)
for m in reversed(msgs):
    status = "●" if m["status"] == "unread" else "○"
    print(f"  {status} [{m["created_at"]}] {m["from_agent"]} → {m["to_agent"]}: {m["body"]}")
'
