#!/usr/bin/env bash
set -euo pipefail

# Usage: mark-read.sh <team> <agent_id> (--ids <csv>|--ids-file <path>)
# Marks only the supplied message ids as read.

TEAM="${1:?Usage: mark-read.sh <team> <agent_id> (--ids <csv>|--ids-file <path>)}"
AGENT="${2:?Missing agent_id}"
shift 2

IDS=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ids) IDS="${2:?--ids needs a comma-separated id list}"; shift 2 ;;
    --ids-file) IDS="$(cat "${2:?--ids-file needs a path}" 2>/dev/null || true)"; shift 2 ;;
    *) echo "mark-read: unknown option: $1" >&2; exit 2 ;;
  esac
done

case "$IDS" in
  ''|*[!0-9,]*) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"
[ -f "$DB" ] || exit 0

sql_escape() {
  printf '%s' "$1" | sed "s/'/''/g"
}

TEAM_ESC="$(sql_escape "$TEAM")"
AGENT_ESC="$(sql_escape "$AGENT")"
agmsg_sqlite "$DB" "
  UPDATE messages
  SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now')
  WHERE team='$TEAM_ESC' AND to_agent='$AGENT_ESC' AND id IN ($IDS);
" >/dev/null 2>&1 || true
