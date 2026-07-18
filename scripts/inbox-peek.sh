#!/usr/bin/env bash
set -euo pipefail

# Usage: inbox-peek.sh <team> <agent_id> [--quiet] [--ids-file <path>]
# Shows unread messages without marking them as read.

TEAM="${1:?Usage: inbox-peek.sh <team> <agent_id> [--quiet] [--ids-file <path>]}"
AGENT="${2:?Missing agent_id}"
shift 2

QUIET=false
IDS_FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=true; shift ;;
    --ids-file) IDS_FILE="${2:?--ids-file needs a path}"; shift 2 ;;
    *) echo "inbox-peek: unknown option: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

[ -z "$IDS_FILE" ] || : > "$IDS_FILE"

if [ ! -f "$DB" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No messages (DB not initialized)"
  exit 0
fi

TEAM_ESC="$(sql_escape "$TEAM")"
AGENT_ESC="$(sql_escape "$AGENT")"
UNREAD=$(agmsg_sqlite -separator $'\037' "$DB" "
  SELECT id,
         from_agent,
         replace(replace(body, char(10), '\n'), char(9), '\t'),
         created_at
  FROM messages
  WHERE team='$TEAM_ESC' AND to_agent='$AGENT_ESC' AND read_at IS NULL
  ORDER BY created_at ASC;
")

if [ -z "$UNREAD" ]; then
  if [ "$QUIET" = true ]; then exit 0; fi
  echo "No new messages."
  exit 0
fi

if [ -n "$IDS_FILE" ]; then
  printf '%s\n' "$UNREAD" | awk -F $'\037' '$1 ~ /^[0-9]+$/ { print $1 }' | paste -sd, - > "$IDS_FILE"
fi

COUNT=$(printf '%s\n' "$UNREAD" | awk 'NF { c++ } END { print c + 0 }')
echo "$COUNT new message(s):"
echo ""
while IFS=$'\037' read -r _id from body ts; do
  [ -n "$_id" ] || continue
  echo "  [$ts] $from: $body"
done <<< "$UNREAD"
echo ""
