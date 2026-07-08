#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message>
#   <to> may be a single agent, a comma-separated list (alice,bob), or --all
#   (alias: @all) to broadcast to every team member except the sender.

TEAM="${1:?Usage: send.sh <team> <from> <to> <message>}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
BODY="${4:?Missing message body}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

# Resolve broadcast / multi-recipient forms into RECIPIENTS.
if [ "$TO" = "--all" ] || [ "$TO" = "@all" ]; then
  # Reject team names that would escape teams/ as a path segment (#140).
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/validate.sh"
  agmsg_validate_team_name "$TEAM" || exit 1
  CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"
  [ -f "$CONFIG" ] || { echo "Team not found: $TEAM" >&2; exit 1; }
  # tr -d '\r': sqlite3.exe on Windows emits CRLF rows (#130).
  mapfile -t RECIPIENTS < <(sqlite3 :memory: \
    ".param set :json '$(sed "s/'/''/g" "$CONFIG")'" \
    "SELECT key FROM json_each(json_extract(:json, '\$.agents')) ORDER BY key;" \
    | tr -d '\r' | grep -Fxv -- "$FROM" || true)
  if [ "${#RECIPIENTS[@]}" -eq 0 ]; then
    echo "No recipients in team $TEAM besides $FROM" >&2
    exit 1
  fi
else
  IFS=',' read -r -a RECIPIENTS <<< "$TO"
fi

[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

# Escape EVERY interpolated value as a SQL string literal, not just body: a
# team/agent name containing a single quote would otherwise break the INSERT
# (correctness) or change its meaning (injection surface).
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

# One multi-row INSERT so a broadcast is atomic: either every recipient gets
# the message or none does (no partial fan-out if a later row fails).
VALUES=""
for _to in "${RECIPIENTS[@]}"; do
  [ -n "$_to" ] || continue
  [ -n "$VALUES" ] && VALUES="$VALUES, "
  VALUES="$VALUES('$(_agmsg_sqlesc "$TEAM")', '$(_agmsg_sqlesc "$FROM")', '$(_agmsg_sqlesc "$_to")', '$(_agmsg_sqlesc "$BODY")')"
done
[ -n "$VALUES" ] || { echo "Missing to agent" >&2; exit 1; }
INSERT="INSERT INTO messages (team, from_agent, to_agent, body) VALUES $VALUES;"

# Retry once after ensuring the schema. Under a concurrent first-write fan-out
# (leader → N members against a fresh/override store), one process can see the
# DB file exist before the winning initializer has finished creating the table,
# so its INSERT would hit "no such table". init-db.sh is idempotent + uses the
# busy_timeout, so re-running it waits for the schema, then the INSERT lands.
# See #114.
# Pipe the SQL via stdin (not as an argv) so a large body cannot overflow the
# OS command-line limit (the "Argument list too long" crash).
if ! printf '%s
' "$INSERT" | agmsg_sqlite "$DB" 2>/dev/null; then
  bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null
  printf '%s
' "$INSERT" | agmsg_sqlite "$DB"
fi

for _to in "${RECIPIENTS[@]}"; do
  [ -n "$_to" ] || continue
  echo "Sent to $_to in team $TEAM"
done
