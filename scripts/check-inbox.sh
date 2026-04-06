#!/usr/bin/env bash
set -euo pipefail

# Check inbox across all teams with cooldown. Skips if last check was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Prevent infinite loop: if stop hook is already active, exit silently
INPUT=$(cat 2>/dev/null || true)
if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' 2>/dev/null; then
  exit 0
fi

# Identify agent and teams
WHOAMI=$("$SCRIPT_DIR/whoami.sh" "$PROJECT" "$TYPE")
if echo "$WHOAMI" | grep -q "not_joined=true"; then
  exit 0
fi

# Handle multiple identities: use first agent name
if echo "$WHOAMI" | grep -q "multiple=true"; then
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agents=\([^,]*\).*/\1/p')
else
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')
fi
TEAMS=$(echo "$WHOAMI" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')

if [ -z "$AGENT" ] || [ -z "$TEAMS" ]; then
  exit 0
fi

# Cooldown check
MARKER="$SKILL_DIR/db/.lastcheck-$AGENT"

if [ -f "$MARKER" ]; then
  if [ "$(uname)" = "Darwin" ]; then
    last=$(stat -f %m "$MARKER")
  else
    last=$(stat -c %Y "$MARKER")
  fi
  now=$(date +%s)
  INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
  # Fallback to default if non-numeric
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  if [ $(( now - last )) -lt "$INTERVAL" ]; then
    [ "$TYPE" = "codex" ] && echo "agmsg: check skipped (cooldown)"
    exit 0
  fi
fi

touch "$MARKER"

# Check for unread messages and mark as read
DB="$SKILL_DIR/db/messages.db"
if [ ! -f "$DB" ]; then exit 0; fi

OUTPUT=""
IFS=',' read -ra TEAM_LIST <<< "$TEAMS"
for team in "${TEAM_LIST[@]}"; do
  RESULT=$(sqlite3 "$DB" "
    SELECT from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$team' AND to_agent='$AGENT' AND read_at IS NULL
    ORDER BY created_at ASC;
  ")
  if [ -n "$RESULT" ]; then
    COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
    OUTPUT+="$COUNT new message(s) in $team:"$'\n'
    while IFS=$'\x1f' read -r from body ts; do
      OUTPUT+="  [$ts] $from: $body"$'\n'
    done <<< "$RESULT"
    OUTPUT+=$'\n'
    # Mark as read
    sqlite3 "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE team='$team' AND to_agent='$AGENT' AND read_at IS NULL;" 2>/dev/null || true
  fi
done

# No new messages
if [ -z "$OUTPUT" ]; then
  [ "$TYPE" = "codex" ] && echo "agmsg: no new messages"
  exit 0
fi

# New messages found
if [ -n "$OUTPUT" ]; then
  # Escape for JSON: backslash, double-quote, newlines, tabs (macOS/Linux compatible)
  ESCAPED=$(printf '%s' "$OUTPUT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{if(NR>1) printf "\\n"; printf "%s",$0}')
  cat <<ENDJSON
{
  "decision": "block",
  "reason": "$ESCAPED"
}
ENDJSON
  exit 0
fi
