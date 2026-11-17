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

SEAT="$(agmsg_grok_resolve_seat_for_session "$PROJECT" "$SESSION_ID" 2>/dev/null || true)"
if [ -n "$SEAT" ] && [ -n "$SESSION_ID" ]; then
  TEAM="${SEAT%%	*}"
  AGENT="${SEAT#*	}"
  WITNESS_PATH="$(agmsg_grok_witness_path "$TEAM" "$AGENT")"
  _pending_path="$(agmsg_grok_pending_path "$TEAM" "$AGENT")"
  _need_recovery=0
  if [ -f "$WITNESS_PATH" ]; then
    _wsid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WITNESS_PATH" 2>/dev/null | head -1)"
    if [ "$_wsid" = "$SESSION_ID" ]; then
      # The witness this Stop event is actually for: advance it. A witness
      # written with an empty leader_socket (SessionStart ran before the
      # TUI's own leader was up, or by an agmsg that could not find it)
      # gets the socket filled in here when the leader is found now.
      NEW_CONTENT="$(LC_ALL=C sed 's/"first_turn_done"[[:space:]]*:[[:space:]]*false/"first_turn_done": true/' "$WITNESS_PATH" 2>/dev/null || true)"
      case "$NEW_CONTENT" in
        *'"leader_socket": ""'*)
          _wpid="$(printf '%s' "$NEW_CONTENT" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' | head -1)"
          _sock="$(agmsg_grok_leader_socket_for "$_wpid" "${GROK_HOME:-$HOME/.grok}" 2>/dev/null || true)"
          if [ -n "$_sock" ]; then
            _sock_json="$(printf '%s' "$_sock" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g')"
            NEW_CONTENT="${NEW_CONTENT/\"leader_socket\": \"\"/\"leader_socket\": \"$_sock_json\"}"
          fi
          ;;
      esac
      [ -n "$NEW_CONTENT" ] && agmsg_write_atomic "$WITNESS_PATH" "$NEW_CONTENT" || true
    else
      # review on #1979, finding (1): a DIFFERENT session's own witness is
      # sitting there -- originally always left alone (a correct guard
      # against a late-arriving Stop from an OLD, still-live session
      # overwriting a newer one). But if SessionStart's own bounded retry
      # ran out for THIS (newer) session and left no witness of its own,
      # this stale one can also wrongly keep masking this session's real
      # state forever, with no later event ever re-trying it -- UNLESS the
      # old witness's own recorded pid is confirmed gone, in which case its
      # old owner truly cannot be delivered to anymore and recovering for
      # the current session is safe. Still never touched when that pid is
      # alive, or cannot be confirmed dead (conservative, same direction as
      # pidAlive elsewhere): that is a genuinely live different session,
      # not a stale one.
      _wpid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*"\([0-9]*\)".*/\1/p' "$WITNESS_PATH" 2>/dev/null | head -1)"
      agmsg_grok_pid_definitely_dead "$_wpid" && _need_recovery=1
    fi
  else
    _need_recovery=1
  fi
  if [ "$_need_recovery" -eq 1 ]; then
    # Linux real-machine round (2026-11-15): SessionStart can fire before
    # grok has written this session into active_sessions.json, leaving no
    # witness at all -- with nothing else ever re-trying that write, the
    # seat stayed unaddressable forever. By the end of a turn,
    # active_sessions.json is certainly populated, so Stop gets one more
    # chance: a single lookup (no bounded retry needed here, unlike
    # SessionStart) creates the witness directly as already past its
    # first turn -- this Stop event IS that first turn's own end.
    GROK_HOME_RESOLVED="${GROK_HOME:-$HOME/.grok}"
    LEADER_SOCKET=""
    _session_obj="$(agmsg_grok_active_session_lookup "$GROK_HOME_RESOLVED/active_sessions.json" "$SESSION_ID" 2>/dev/null || true)"
    _pid=""
    if [ -n "$_session_obj" ]; then
      _pid="$(printf '%s' "$_session_obj" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
    fi
    if [ -n "$_pid" ]; then
      LEADER_SOCKET="$(agmsg_grok_leader_socket_for "$_pid" "$GROK_HOME_RESOLVED" 2>/dev/null || true)"
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
      # review on #1979, finding (2): clearing the pending-reason file
      # unconditionally right after a write attempt that itself used
      # `|| true` meant a write failure (e.g. a transient mv failure) left
      # BOTH no witness AND no pending reason -- a silent regression to
      # the original bug this file exists to fix. Only clear it on an
      # actual write success; record why otherwise.
      if agmsg_write_atomic "$WITNESS_PATH" "$_content"; then
        rm -f "$_pending_path" 2>/dev/null || true
      else
        agmsg_write_atomic "$_pending_path" "Stop found session $SESSION_ID but could not write the witness to $WITNESS_PATH" || true
      fi
    else
      agmsg_write_atomic "$_pending_path" \
        "Stop could not find session $SESSION_ID in $GROK_HOME_RESOLVED/active_sessions.json either" || true
    fi
  fi
fi

exec "$SCRIPT_DIR/check-inbox.sh" grok-build "$PROJECT"
