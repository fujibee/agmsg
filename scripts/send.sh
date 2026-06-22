#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message>

TEAM="${1:?Usage: send.sh <team> <from> <to> <message>}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
BODY="${4:?Missing message body}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

TEAM_SQL=$(agmsg_sql_literal "$TEAM")
FROM_SQL=$(agmsg_sql_literal "$FROM")
TO_SQL=$(agmsg_sql_literal "$TO")
BODY_SQL=$(agmsg_sql_literal "$BODY")
INSERT="INSERT INTO messages (team, from_agent, to_agent, body) VALUES ($TEAM_SQL, $FROM_SQL, $TO_SQL, $BODY_SQL);"

# Retry once after ensuring the schema. Under a concurrent first-write fan-out
# (leader → N members against a fresh/override store), one process can see the
# DB file exist before the winning initializer has finished creating the table,
# so its INSERT would hit "no such table". init-db.sh is idempotent + uses the
# busy_timeout, so re-running it waits for the schema, then the INSERT lands.
# See #114.
if ! agmsg_sqlite "$DB" "$INSERT" 2>/dev/null; then
  bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null
  agmsg_sqlite "$DB" "$INSERT"
fi

echo "Sent to $TO in team $TEAM"
