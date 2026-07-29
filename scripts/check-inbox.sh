#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Check inbox across all teams with cooldown. Skips if last check was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"  # agmsg_agent_pid, for instance-id derivation
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/subscription.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/delivery-cursor.sh"

# Some Stop-hook runtimes (codex, copilot) want an explicit JSON status object
# even when there is nothing to deliver; others (claude-code) stay silent. This
# is the type's manifest `stop_output=` (data), not a hardcoded type list.
STOP_OUTPUT="$(agmsg_type_get "$TYPE" stop_output 2>/dev/null || true)"
emit_status_json() {
  [ "$STOP_OUTPUT" = "json" ] || return 0
  printf '{\n  "continue": true,\n  "systemMessage": "%s"\n}\n' "$1"
}

# Hook runtimes that pass JSON do so on stdin. Interactive invocations such as
# Gemini's PostToolUse command may inherit a terminal stdin instead; reading
# unconditionally there blocks waiting for input. The `[ ! -t 0 ]` guard just below
# only rules out that TTY case -- a non-TTY stdin whose write end is left
# open (a hook runtime that writes the payload and then simply never closes
# the pipe) still leaves this `cat` waiting for an EOF that never arrives.
# Stop/turn hooks run synchronously, so a `cat` stuck here freezes the whole
# agent pane until the user kills it. Bound the read; a runtime that forgets
# to close its pipe still gets its payload delivered (it's already sitting in
# the command substitution buffer by the time the deadline fires), just a few
# seconds late instead of never. Fails open when `timeout` isn't on PATH
# (stock macOS) -- same unbounded read as before, no regression there. #381
INPUT=""
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    INPUT=$(timeout "${AGMSG_HOOK_STDIN_TIMEOUT:-2}" cat 2>/dev/null || true)
  else
    INPUT=$(cat 2>/dev/null || true)
  fi
fi

# Prevent infinite loop: if stop hook is already active, exit silently
if echo "$INPUT" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' 2>/dev/null; then
  exit 0
fi

# Defer to the monitor watcher when one is alive for this session.
# Avoids double-delivery when delivery.mode = both. The session id field name
# differs by vendor: Claude Code emits snake_case "session_id"; Grok Build (and
# Cursor) emit camelCase "sessionId". Try snake first (claude-code unaffected),
# then camel, then the GROK_SESSION_ID env Grok injects into every hook.
SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"
HOOK_SESSION_ID="$SESSION_ID"
if [ -n "$SESSION_ID" ]; then
  # The monitor watcher keys its pidfile (and its actas owner, below) on the
  # per-process instance id (#93), not the bare session_id. Normalize to the
  # same token so this Stop-hook defers to a live watcher in `both` mode instead
  # of double-delivering.
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"
  PIDFILE="$SKILL_DIR/run/watch.$SESSION_ID.pid"
  if [ -f "$PIDFILE" ]; then
    WATCH_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    # EPERM-aware liveness (_agmsg_pid_alive): a sandbox-unsignalable watcher is still alive.
    if [ -n "$WATCH_PID" ] && _agmsg_pid_alive "$WATCH_PID"; then
      exit 0
    fi
  fi
fi

PAIRS="$(agmsg_session_subscription_pairs "$PROJECT" "$TYPE" "${SESSION_ID:-}" "${HOOK_SESSION_ID:-}")"
[ -n "$PAIRS" ] || exit 0

# Prefer the new delivery.turn.check_interval; fall back to legacy
# hook.check_interval for users who haven't migrated.
INTERVAL=$("$SCRIPT_DIR/config.sh" get delivery.turn.check_interval "")
[ -z "$INTERVAL" ] && INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
mkdir -p "$SKILL_DIR/run"

# Check for unread messages and mark as read
DB="$(agmsg_db_path)"
if [ ! -f "$DB" ]; then exit 0; fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }

OUTPUT=""
CHECKED_ANY=0
SKIPPED_ANY=0
SESSION_KEY="$(_actas_lock_encode "${SESSION_ID:-turn}")"
while IFS=$'\t' read -r team agent; do
  [ -n "$team" ] && [ -n "$agent" ] || continue
  team_key="$(_actas_lock_encode "$team")"
  agent_key="$(_actas_lock_encode "$agent")"
  MARKER="$SKILL_DIR/run/.lastcheck.${SESSION_KEY}.${team_key}__${agent_key}"
  if [ -f "$MARKER" ]; then
    last=$(compat_file_mtime "$MARKER")
    now=$(date +%s)
    if [ $(( now - last )) -lt "$INTERVAL" ]; then
      SKIPPED_ANY=1
      continue
    fi
  fi
  touch "$MARKER"
  CHECKED_ANY=1
  team_sql="$(_agmsg_sqlesc "$team")"
  agent_sql="$(_agmsg_sqlesc "$agent")"

  RESULT=$(agmsg_sqlite "$DB" "
    SELECT id || char(31) || from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$team_sql' AND to_agent='$agent_sql' AND read_at IS NULL
    ORDER BY created_at ASC;
  ")
  if [ -n "$RESULT" ]; then
    COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
    OUTPUT+="$COUNT new message(s) in $team:"$'\n'
    IDS=""
    MAX_ID=""
    while IFS=$'\x1f' read -r id from body ts; do
      OUTPUT+="  [$ts] $from: $body"$'\n'
      case "$id" in
        ''|*[!0-9]*) ;; # defensive: never splice a non-numeric value into SQL
        *) IDS="${IDS:+$IDS,}$id"; MAX_ID="$id" ;;
      esac
    done <<< "$RESULT"
    OUTPUT+=$'\n'
    # Test seam: a two-file barrier that lets the race regression test land a
    # message deterministically between display and mark. No-op unless set.
    if [ -n "${AGMSG_TEST_MARK_BARRIER:-}" ]; then
      : > "$AGMSG_TEST_MARK_BARRIER.reached"
      _agmsg_barrier_waited=0
      while [ ! -e "$AGMSG_TEST_MARK_BARRIER.release" ]; do
        sleep 0.05
        _agmsg_barrier_waited=$((_agmsg_barrier_waited + 1))
        [ "$_agmsg_barrier_waited" -ge 200 ] && break # 10s safety cap
      done
    fi
    # Mark as read — only the ids captured above, so a message that arrives
    # between the SELECT and this UPDATE is not marked read unseen.
    if [ -n "$IDS" ]; then
      if agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id IN ($IDS);" 2>/dev/null; then
        agmsg_delivery_cursor_advance "$team" "$agent" "$TYPE" "$PROJECT" "$MAX_ID" 2>/dev/null || true
      fi
    fi
  fi
done <<< "$PAIRS"

# No new messages
if [ -z "$OUTPUT" ]; then
  if [ "$CHECKED_ANY" -eq 0 ] && [ "$SKIPPED_ANY" -eq 1 ]; then
    emit_status_json "agmsg: check skipped (cooldown)"
  else
    emit_status_json "agmsg: no new messages"
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
