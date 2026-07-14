#!/usr/bin/env bash
set -euo pipefail

# Read-only inbox API for delivery bridges.  Emits one JSON object and never
# advances read_at; acknowledgement is a separate mark-read.sh call.
TEAM="${1:?Usage: peek-inbox.sh <team> <agent_id>}"
AGENT="${2:?Missing agent_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

if [ ! -f "$DB" ]; then
  printf '{"rows":[],"maxId":0}\n'
  exit 0
fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
TEAM_SQL="$(_agmsg_sqlesc "$TEAM")"
AGENT_SQL="$(_agmsg_sqlesc "$AGENT")"

agmsg_sqlite "$DB" "
  WITH unread AS (
    SELECT id, created_at AS ts, team, from_agent, to_agent, body
      FROM messages
     WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL' AND read_at IS NULL
     ORDER BY id ASC
  )
  SELECT json_object(
    'rows', json(COALESCE(json_group_array(json_object(
      'id', id, 'ts', ts, 'team', team, 'from', from_agent,
      'to', to_agent, 'body', body
    )), '[]')),
    'maxId', COALESCE(MAX(id), 0)
  ) FROM unread;
" | tr -d '\r'
