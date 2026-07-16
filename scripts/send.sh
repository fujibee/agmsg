#!/usr/bin/env bash
set -euo pipefail

# Usage: send.sh <team> <from> <to> <message> [--force]

TEAM="${1:?Usage: send.sh <team> <from> <to> <message> [--force]}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent}"
BODY="${4:?Missing message body}"
FORCE=0
if [ "${5:-}" = "--force" ]; then
  FORCE=1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

[ -f "$DB" ] || bash "$SCRIPT_DIR/internal/init-db.sh" >/dev/null

# #355: reject a from/to that isn't registered in <team> — an unnoticed typo
# (e.g. a stray send to "dummy") used to insert successfully with exit 0,
# landing an undeliverable message and polluting history. Validation lives
# here (the front door), not in storage.sh, so other entry points (api.sh)
# can keep their own policy. --force bypasses this for intentional
# pre-registration sends (e.g. notifying a role before its own join.sh runs).
if [ "$FORCE" -ne 1 ]; then
  TEAM_CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

  _agmsg_roster_check() {
    local role="$1" name="$2"
    if [ ! -f "$TEAM_CONFIG" ]; then
      echo "Error: team '$TEAM' has no registered agents — cannot send as $role '$name' (use --force to bypass)." >&2
      return 1
    fi
    local cfg_sql name_sql found roster
    cfg_sql=$(agmsg_sql_readfile_path "$TEAM_CONFIG")
    name_sql=$(printf '%s' "$name" | sed "s/'/''/g")
    found=$(agmsg_sqlite_mem "
      WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
      cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
      SELECT value
      FROM cfg, json_each(json_extract(cfg.json, '\$.agents'))
      WHERE key = '$name_sql';
    ")
    if [ -z "$found" ]; then
      roster=$(agmsg_sqlite_mem "
        WITH raw(json) AS (SELECT CAST(readfile('$cfg_sql') AS TEXT)),
        cfg(json) AS (SELECT CASE WHEN json_valid(json) THEN json END FROM raw)
        SELECT group_concat(key, ', ')
        FROM cfg, json_each(json_extract(cfg.json, '\$.agents'));
      ")
      echo "Error: $role agent '$name' is not registered in team '$TEAM' (registered: ${roster:-none}). Use --force to bypass." >&2
      return 1
    fi
    return 0
  }

  _agmsg_roster_check "from" "$FROM" || exit 1
  _agmsg_roster_check "to" "$TO" || exit 1
fi

# Escape EVERY interpolated value as a SQL string literal, not just body: a
# team/agent name containing a single quote would otherwise break the INSERT
# (correctness) or change its meaning (injection surface).
_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
INSERT="INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$(_agmsg_sqlesc "$TEAM")', '$(_agmsg_sqlesc "$FROM")', '$(_agmsg_sqlesc "$TO")', '$(_agmsg_sqlesc "$BODY")');"

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

echo "Sent to $TO in team $TEAM"
