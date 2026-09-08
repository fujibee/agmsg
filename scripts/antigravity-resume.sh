#!/usr/bin/env bash
set -euo pipefail

PROJECT="${1:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/drivers/types/antigravity/antigravity-tui-monitor.sh"
PAUSED=""
COUNT=0

while IFS=$'\t' read -r team role; do
  [ -n "$team" ] && [ -n "$role" ] || continue
  status="$(bash "$MONITOR" status --project "$PROJECT" --team "$team" --name "$role" 2>/dev/null || true)"
  if printf '%s\n' "$status" | grep -q ' tui-pty paused$'; then
    PAUSED="${PAUSED}${PAUSED:+
}$team"$'\t'"$role"
    COUNT=$((COUNT + 1))
  fi
done < <(bash "$SCRIPT_DIR/identities.sh" "$PROJECT" antigravity)

if [ "$COUNT" -eq 0 ]; then
  echo 'agmsg: paused な Antigravity TUI が見つかりません' >&2
  exit 1
fi
if [ "$COUNT" -ne 1 ]; then
  echo 'agmsg: paused な Antigravity TUI が複数あります。team と role を指定して個別に再開してください:' >&2
  printf '  %s\n' "$PAUSED" >&2
  exit 1
fi

IFS=$'\t' read -r TEAM ROLE <<< "$PAUSED"
exec bash "$MONITOR" resume --project "$PROJECT" --team "$TEAM" --name "$ROLE"
