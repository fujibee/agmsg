#!/usr/bin/env bash
set -euo pipefail

# Acknowledge exactly the message IDs supplied on stdin (one decimal ID per
# line).  Validation completes before any SQL runs, so malformed input cannot
# cause a partial acknowledgement.
TEAM="${1:?Usage: mark-read.sh <team> <agent_id>}"
AGENT="${2:?Missing agent_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"
[ -f "$DB" ] || { echo "mark-read: message DB is not initialized" >&2; exit 1; }

ids=""
while IFS= read -r raw || [ -n "$raw" ]; do
  id="${raw%$'\r'}"
  [ -n "$id" ] || continue
  case "$id" in
    *[!0-9]*) echo "mark-read: invalid message id: $id" >&2; exit 2 ;;
  esac
  if [ -n "$ids" ]; then ids="$ids,$id"; else ids="$id"; fi
done

if [ -z "$ids" ]; then
  echo "updated=0"
  exit 0
fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
TEAM_SQL="$(_agmsg_sqlesc "$TEAM")"
AGENT_SQL="$(_agmsg_sqlesc "$AGENT")"

updated="$(agmsg_sqlite "$DB" "
  BEGIN IMMEDIATE;
  UPDATE messages
     SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
   WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL'
     AND read_at IS NULL AND id IN ($ids);
  SELECT changes();
  COMMIT;
" | tr -d '\r' | tail -1)"
case "$updated" in ''|*[!0-9]*) echo "mark-read: invalid sqlite result" >&2; exit 1 ;; esac
echo "updated=$updated"
