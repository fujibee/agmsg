#!/usr/bin/env bash
set -u

# Stream new agmsg messages for the current session as they arrive.
#
# Intended to be launched by Claude Code's Monitor tool from the SessionStart
# hook (`session-start.sh`), but also works standalone as `tail -f` for
# inbox: any agent runtime that can read stdout can consume it.
#
# Usage: watch.sh <session_id> <project_path> <agent_type>
#
# Behavior:
#   - Resolves all (team, agent) pairs for (project_path, agent_type) via
#     identities.sh. Subscribes to messages addressed to any of those pairs.
#   - Sets the high-water mark to the current MAX(id) at startup so the
#     stream begins with whatever arrives after launch — no replay of
#     historical messages.
#   - Polls the SQLite DB at AGMSG_WATCH_INTERVAL seconds (default 5, also
#     overridable via the delivery.monitor.poll_interval config key).
#   - Emits one line per new message:
#         <ts> | <team> | <from> → <to> | <body>
#     Newlines in body are escaped to literal "\n" so each message stays a
#     single line — easier for Monitor to deliver as one event.
#   - Writes a pidfile at ~/.agents/agmsg/run/watch.<session_id>.pid and
#     removes it on EXIT / SIGTERM / SIGINT.

SESSION_ID="${1:?Usage: watch.sh <session_id> <project_path> <agent_type>}"
PROJECT_PATH="${2:?Missing project_path}"
AGENT_TYPE="${3:?Missing agent_type}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DB="$SKILL_DIR/db/messages.db"
RUN_DIR="$SKILL_DIR/run"
PIDFILE="$RUN_DIR/watch.$SESSION_ID.pid"

# Resolve poll interval. Env var wins over config, default 5s.
INTERVAL="${AGMSG_WATCH_INTERVAL:-}"
if [ -z "$INTERVAL" ]; then
  INTERVAL="$("$SCRIPT_DIR/config.sh" get delivery.monitor.poll_interval 5 2>/dev/null || echo 5)"
fi
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac

mkdir -p "$RUN_DIR" 2>/dev/null || true
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT
trap 'exit 0' INT TERM HUP

# Resolve subscription set.
PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$AGENT_TYPE")"
if [ -z "$PAIRS" ]; then
  echo "agmsg watch: no joined teams for $PROJECT_PATH ($AGENT_TYPE); nothing to do"
  exit 0
fi

# Build the SQL WHERE clause. Each pair contributes:
#   (team='<team>' AND to_agent='<agent>')
# joined by OR. Single quotes inside team/agent names are doubled for SQL.
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

WHERE_PAIRS=""
while IFS=$'\t' read -r team agent; do
  [ -z "$team" ] && continue
  t_esc=$(sql_escape "$team")
  a_esc=$(sql_escape "$agent")
  pair="(team='$t_esc' AND to_agent='$a_esc')"
  WHERE_PAIRS="${WHERE_PAIRS:+$WHERE_PAIRS OR }$pair"
done <<< "$PAIRS"

# Get the starting watermark. Missing DB is OK — we'll just block until it appears.
LAST=0
if [ -f "$DB" ]; then
  LAST="$(sqlite3 "$DB" "SELECT COALESCE(MAX(id), 0) FROM messages WHERE $WHERE_PAIRS;" 2>/dev/null || echo 0)"
fi
case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac

while true; do
  if [ -f "$DB" ]; then
    ROWS="$(sqlite3 -separator $'\x1f' "$DB" "
      SELECT id, created_at, team, from_agent, to_agent,
             replace(replace(body, char(13), ''), char(10), '\\n')
      FROM messages
      WHERE id > $LAST AND ($WHERE_PAIRS)
      ORDER BY id;
    " 2>/dev/null || true)"

    if [ -n "$ROWS" ]; then
      while IFS=$'\x1f' read -r id ts team from to body; do
        [ -z "$id" ] && continue
        printf '%s | %s | %s → %s | %s\n' "$ts" "$team" "$from" "$to" "$body"
        LAST="$id"
      done <<< "$ROWS"
    fi
  fi

  # Run sleep in the background and `wait` for it so signal traps fire
  # immediately. Bash defers traps while a foreground builtin like `sleep`
  # is blocking, which would otherwise delay shutdown by up to $INTERVAL.
  sleep "$INTERVAL" &
  wait $! 2>/dev/null
done
