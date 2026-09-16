#!/usr/bin/env bash
set -euo pipefail

PROJECT="${1:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/antigravity-tui-monitor.sh"
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
done < <(bash "$SCRIPT_DIR/../../../identities.sh" "$PROJECT" antigravity)

if [ "$COUNT" -eq 0 ]; then
  echo 'agmsg: no paused Antigravity TUI found' >&2
  exit 1
fi
if [ "$COUNT" -ne 1 ]; then
  echo 'agmsg: multiple paused Antigravity TUIs found; specify team and role to resume one:' >&2
  printf '  %s\n' "$PAUSED" >&2
  exit 1
fi

IFS=$'\t' read -r TEAM ROLE <<< "$PAUSED"
exec bash "$MONITOR" resume --project "$PROJECT" --team "$TEAM" --name "$ROLE"
