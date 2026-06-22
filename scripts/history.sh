#!/usr/bin/env bash
set -euo pipefail

# Usage: history.sh <team> [agent_id] [limit]
# Shows message history. If agent_id given, shows only that agent's messages.

TEAM="${1:?Usage: history.sh <team> [agent_id] [limit]}"
AGENT="${2:-}"
LIMIT="${3:-20}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

case "$LIMIT" in
  ''|*[!0-9]*)
    echo "Invalid limit: $LIMIT (must be a non-negative integer)" >&2
    exit 1
    ;;
esac

if [ ! -f "$DB" ]; then
  echo "No messages (DB not initialized)"
  exit 0
fi

TEAM_SQL=$(agmsg_sql_literal "$TEAM")
if [ -n "$AGENT" ]; then
  AGENT_SQL=$(agmsg_sql_literal "$AGENT")
  WHERE="WHERE team=$TEAM_SQL AND (from_agent=$AGENT_SQL OR to_agent=$AGENT_SQL)"
else
  WHERE="WHERE team=$TEAM_SQL"
fi

# Escape newlines/tabs in body, use unit separator between fields
RESULT=$(agmsg_sqlite "$DB" "
  SELECT from_agent || char(31) || to_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at || char(31) || CASE WHEN read_at IS NULL THEN '●' ELSE '○' END
  FROM messages $WHERE ORDER BY created_at DESC LIMIT $LIMIT;
")

if [ -z "$RESULT" ]; then
  echo "No message history."
  exit 0
fi

# Reverse order (oldest first) and display
REVERSED=$(echo "$RESULT" | tail -r 2>/dev/null || echo "$RESULT" | tac 2>/dev/null || echo "$RESULT" | awk '{a[NR]=$0} END{for(i=NR;i>=1;i--)print a[i]}')
while IFS=$'\x1f' read -r from to body ts status; do
  echo "  $status [$ts] $from → $to: $body"
done <<< "$REVERSED"
