#!/usr/bin/env bash
set -euo pipefail
# grok-build's own Stop hook, used ONLY in agmsgd delivery mode. Two jobs,
# in order:
#
#   1. Mark this seat's witness (grok-session-start.sh's file) as past its
#      first turn -- measured live (2026-11-15): session/prompt on a session
#      before its first turn has a response replays the ENTIRE prior
#      transcript via session/update before the agent sees the new prompt
#      (session/load's own documented behavior), so the channel withholds a
#      nudge until this marker is set.
#   2. Delegate to check-inbox.sh exactly as every other type's Stop hook
#      does -- grok's {"decision":"block","reason":...} contract is honored
#      the same way Claude Code's is (measured live, 2026-11-15, up to 8
#      re-fires, fail-open), so there is nothing grok-specific to reproduce
#      here; reuse the existing per-turn inbox check verbatim, exec'd so its
#      stdout/exit code reach the hook runtime unchanged.
#
# Usage: grok-stop.sh <project_path>
# Reads the hook input JSON from stdin for sessionId (best effort; this
# script does not consume stdin further -- check-inbox.sh does not read
# stdin itself, so nothing here needs to be re-fed to it).

PROJECT="${1:?Usage: grok-stop.sh <project_path>}"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
mkdir -p "$RUN_DIR" 2>/dev/null || true
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hash.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"   # agmsg_write_atomic
# shellcheck disable=SC1091
source "$SCRIPT_DIR/internal/grok-session-witness.sh"

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="${GROK_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -n "$INPUT" ]; then
  SESSION_ID="$(printf '%s' "$INPUT" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi

SEAT="$(agmsg_grok_resolve_seat "$PROJECT" 2>/dev/null || true)"
if [ -n "$SEAT" ] && [ -n "$SESSION_ID" ]; then
  TEAM="${SEAT%%	*}"
  AGENT="${SEAT#*	}"
  WITNESS_PATH="$(agmsg_grok_witness_path "$TEAM" "$AGENT")"
  if [ -f "$WITNESS_PATH" ]; then
    _wsid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WITNESS_PATH" 2>/dev/null | head -1)"
    # Only advance the witness this Stop event is actually for; a stale
    # witness from an earlier (now-replaced) session_id is left alone, same
    # as the equivalent check in grok-session-start.sh.
    if [ "$_wsid" = "$SESSION_ID" ]; then
      NEW_CONTENT="$(LC_ALL=C sed 's/"first_turn_done"[[:space:]]*:[[:space:]]*false/"first_turn_done": true/' "$WITNESS_PATH" 2>/dev/null || true)"
      [ -n "$NEW_CONTENT" ] && agmsg_write_atomic "$WITNESS_PATH" "$NEW_CONTENT" || true
    fi
  else
    # Linux real-machine round (2026-11-15): SessionStart can fire before
    # grok has written this session into active_sessions.json, leaving no
    # witness at all -- with nothing else ever re-trying that write, the
    # seat stayed unaddressable forever. By the end of a turn,
    # active_sessions.json is certainly populated, so Stop gets one more
    # chance: a single lookup (no bounded retry needed here, unlike
    # SessionStart) creates the witness directly as already past its
    # first turn -- this Stop event IS that first turn's own end.
    GROK_HOME_RESOLVED="${GROK_HOME:-$HOME/.grok}"
    LEADER_SOCKET="${GROK_LEADER_SOCKET:-}"
    _session_obj="$(agmsg_grok_active_session_lookup "$GROK_HOME_RESOLVED/active_sessions.json" "$SESSION_ID" 2>/dev/null || true)"
    _pid=""
    if [ -n "$_session_obj" ]; then
      _pid="$(printf '%s' "$_session_obj" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
    fi
    if [ -n "$_pid" ]; then
      _pid_start="$(printf '%s' "$_session_obj" | sed -n 's/.*"pid_start"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
      _cwd="$(printf '%s' "$_session_obj" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
      if [ -z "$_cwd" ]; then
        _cwd="$(cd "${PWD:-$PROJECT}" 2>/dev/null && pwd -P)"
        [ -n "$_cwd" ] || _cwd="${PWD:-$PROJECT}"
      fi
      _esc() { printf '%s' "$1" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g'; }
      _content="$(cat <<EOF
{
  "team": "$(_esc "$TEAM")",
  "agent": "$(_esc "$AGENT")",
  "session_id": "$(_esc "$SESSION_ID")",
  "pid": "$(_esc "$_pid")",
  "pid_start": "$(_esc "$_pid_start")",
  "cwd": "$(_esc "$_cwd")",
  "leader_socket": "$(_esc "$LEADER_SOCKET")",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "first_turn_done": true
}
EOF
)"
      agmsg_write_atomic "$WITNESS_PATH" "$_content" || true
      rm -f "$(agmsg_grok_pending_path "$TEAM" "$AGENT")" 2>/dev/null || true
    else
      agmsg_write_atomic "$(agmsg_grok_pending_path "$TEAM" "$AGENT")" \
        "Stop could not find session $SESSION_ID in $GROK_HOME_RESOLVED/active_sessions.json either" || true
    fi
  fi
fi

exec "$SCRIPT_DIR/check-inbox.sh" grok-build "$PROJECT"
