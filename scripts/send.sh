#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message>

TEAM="${1:?Usage: send.sh <team> <from> <to> <message>}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
BODY="${4:?Missing message body}"

DB="$(cd "$(dirname "$0")/../db" && pwd)/messages.db"

if [ ! -f "$DB" ]; then
  bash "$(dirname "$0")/init-db.sh"
fi

sqlite3 "$DB" "INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$TEAM', '$FROM', '$TO', '$(echo "$BODY" | sed "s/'/''/g")');"

echo "Sent to $TO in team $TEAM"
