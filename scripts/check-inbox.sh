#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Check the current session's exact team/agent inbox with cooldown.
# Skips if the last check for that exact seat was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/role-session.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"  # agmsg_agent_pid, for instance-id derivation
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"

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
# unconditionally there blocks waiting for input.
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat 2>/dev/null || true)
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
HOOK_SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$HOOK_SESSION_ID" ] && HOOK_SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$HOOK_SESSION_ID" ] && HOOK_SESSION_ID="${GROK_SESSION_ID:-}"
SESSION_ID=""
if [ -n "$HOOK_SESSION_ID" ]; then
  # The monitor watcher keys its pidfile (and its actas owner, below) on the
  # per-process instance id (#93), not the bare session_id. Normalize to the
  # same token so this Stop-hook defers to a live watcher in `both` mode instead
  # of double-delivering.
  SESSION_ID="$(agmsg_normalize_instance_id "$HOOK_SESSION_ID" "$TYPE")"
  PIDFILE="$SKILL_DIR/run/watch.$SESSION_ID.pid"
  if [ -f "$PIDFILE" ]; then
    WATCH_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
      exit 0
    fi
  fi
fi

# Resolve one exact (team, agent) pair.  Never combine whoami's independent
# agent/team lists: for registrations teamA/alice + teamB/bob that creates the
# nonexistent cross-product teamB/alice and can acknowledge another seat's
# messages.  A role-session record makes a resumed/actas session unambiguous;
# otherwise turn delivery is safe only when this project has exactly one pair.
PAIRS=$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)
[ -n "$PAIRS" ] || exit 0
SELECTED_PAIR=""
if [ -n "$HOOK_SESSION_ID" ]; then
  BARE_SESSION_ID="$(agmsg_instance_bare_sid "$HOOK_SESSION_ID" 2>/dev/null || printf '%s' "$HOOK_SESSION_ID")"
  ROLE_RECORD="$(agmsg_role_session_lookup_unique_by_sid "$BARE_SESSION_ID" 2>/dev/null || true)"
  if [ -n "$ROLE_RECORD" ]; then
    ROLE_TEAM=$(printf '%s\n' "$ROLE_RECORD" | sed -n 's/^team=//p' | head -1)
    ROLE_AGENT=$(printf '%s\n' "$ROLE_RECORD" | sed -n 's/^agent=//p' | head -1)
    ROLE_TYPE=$(printf '%s\n' "$ROLE_RECORD" | sed -n 's/^type=//p' | head -1)
    ROLE_PROJECT=$(printf '%s\n' "$ROLE_RECORD" | sed -n 's/^project=//p' | head -1)
    ROLE_PROJECT_NORM=$(agmsg_normalize_project_path "$ROLE_PROJECT" 2>/dev/null || printf '%s' "$ROLE_PROJECT")
    PROJECT_NORM=$(agmsg_normalize_project_path "$PROJECT" 2>/dev/null || printf '%s' "$PROJECT")
    if { [ -z "$ROLE_TYPE" ] || [ "$ROLE_TYPE" = "$TYPE" ]; } \
       && [ "$ROLE_PROJECT_NORM" = "$PROJECT_NORM" ] \
       && printf '%s\n' "$PAIRS" | grep -Fxq "$(printf '%s\t%s' "$ROLE_TEAM" "$ROLE_AGENT")"; then
      SELECTED_PAIR="$(printf '%s\t%s' "$ROLE_TEAM" "$ROLE_AGENT")"
    fi
  fi
fi
if [ -z "$SELECTED_PAIR" ]; then
  PAIR_COUNT=$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { c++ } END { print c + 0 }')
  if [ "$PAIR_COUNT" = "1" ]; then
    SELECTED_PAIR=$(printf '%s\n' "$PAIRS" | awk 'NF >= 2 { print; exit }')
  else
    emit_status_json "agmsg: inbox check skipped (multiple identities; use actas/resume to bind this session)"
    exit 0
  fi
fi
IFS=$'\t' read -r TEAM AGENT <<EOF
$SELECTED_PAIR
EOF
[ -n "$TEAM" ] && [ -n "$AGENT" ] || exit 0

# Cooldown check. The marker is hook runtime state, not message storage, so it
# lives in the skill's run dir — independent of AGMSG_STORAGE_PATH. Keeping it
# out of the store means an overridden/sandboxed store still gets delivery even
# when the default db dir doesn't exist.
MARKER="$SKILL_DIR/run/.lastcheck-$(_actas_lock_encode "$TEAM")__$(_actas_lock_encode "$AGENT")"

if [ -f "$MARKER" ]; then
  last=$(compat_file_mtime "$MARKER")
  now=$(date +%s)
  # Prefer the new delivery.turn.check_interval; fall back to legacy
  # hook.check_interval for users who haven't migrated.
  INTERVAL=$("$SCRIPT_DIR/config.sh" get delivery.turn.check_interval "")
  [ -z "$INTERVAL" ] && INTERVAL=$("$SCRIPT_DIR/config.sh" get hook.check_interval 60)
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  if [ $(( now - last )) -lt "$INTERVAL" ]; then
    emit_status_json "agmsg: check skipped (cooldown)"
    exit 0
  fi
fi

mkdir -p "$SKILL_DIR/run"
touch "$MARKER"

# Check one exact pair for unread messages and acknowledge only the ids that
# were actually included in this hook response.
DB="$(agmsg_db_path)"
if [ ! -f "$DB" ]; then exit 0; fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
AGENT_SQL="$(_agmsg_sqlesc "$AGENT")"
TEAM_SQL="$(_agmsg_sqlesc "$TEAM")"

OUTPUT=""
IDS=""
# Honor actas exclusivity locks. If (TEAM, AGENT) is currently held by
# another live session, that session is the owner of that role's inbox —
# don't deliver here. Mirrors the per-pair filtering watch.sh does for
# CC sessions (#62), giving Stop-hook delivery (codex / claude-code
# turn-mode) the same "respect peer locks" guarantee.
state=$(actas_lock_state "$TEAM" "$AGENT" "${SESSION_ID:-}")
case "$state" in
  other:*) emit_status_json "agmsg: inbox owned by another live session"; exit 0 ;;
esac

RESULT=$(agmsg_sqlite "$DB" "
  SELECT id || char(31) || from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
  FROM messages WHERE team='$TEAM_SQL' AND to_agent='$AGENT_SQL' AND read_at IS NULL
  ORDER BY id ASC;
")
if [ -n "$RESULT" ]; then
  COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
  OUTPUT+="$COUNT new message(s) in $TEAM:"$'\n'
  while IFS=$'\x1f' read -r id from body ts; do
    OUTPUT+="  [$ts] $from: $body"$'\n'
    IDS+="$id"$'\n'
  done <<< "$RESULT"
  OUTPUT+=$'\n'
  printf '%s' "$IDS" | "$SCRIPT_DIR/mark-read.sh" "$TEAM" "$AGENT" >/dev/null 2>&1 || true
fi

# No new messages
if [ -z "$OUTPUT" ]; then
  emit_status_json "agmsg: no new messages"
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
