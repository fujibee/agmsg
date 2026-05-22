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

# Defer to the monitor watcher when one is alive for this session.
# Avoids double-delivery when delivery.mode = both. session_id is sent in
# the hook input JSON for Stop events.
SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
if [ -n "$SESSION_ID" ]; then
  PIDFILE="$SKILL_DIR/run/watch.$SESSION_ID.pid"
  if [ -f "$PIDFILE" ]; then
    WATCH_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
      exit 0
    fi
  fi
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
  # Prefer the new delivery.turn.check_interval; fall back to legacy
  # hook.check_interval for users who haven't migrated.
  INTERVAL=$("$SCRIPT_DIR/config.sh" get delivery.turn.check_interval "")
  [ -z "$INTERVAL" ] && INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  if [ $(( now - last )) -lt "$INTERVAL" ]; then
    if [ "$TYPE" = "codex" ]; then
      cat <<'ENDJSON'
{
  "continue": true,
  "systemMessage": "agmsg: check skipped (cooldown)"
}
ENDJSON
    fi
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
  if [ "$TYPE" = "codex" ]; then
    cat <<'ENDJSON'
{
  "continue": true,
  "systemMessage": "agmsg: no new messages"
}
ENDJSON
  fi
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
