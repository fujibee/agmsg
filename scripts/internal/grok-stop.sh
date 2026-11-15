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
if [ -n "$SEAT" ]; then
  TEAM="${SEAT%%	*}"
  AGENT="${SEAT#*	}"
  WITNESS_PATH="$(agmsg_grok_witness_path "$TEAM" "$AGENT")"
  if [ -f "$WITNESS_PATH" ]; then
    _wsid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WITNESS_PATH" 2>/dev/null | head -1)"
    # Only advance the witness this Stop event is actually for; a stale
    # witness from an earlier (now-replaced) session_id is left alone, same
    # as the equivalent check in grok-session-start.sh.
    if [ -z "$SESSION_ID" ] || [ "$_wsid" = "$SESSION_ID" ]; then
      NEW_CONTENT="$(LC_ALL=C sed 's/"first_turn_done"[[:space:]]*:[[:space:]]*false/"first_turn_done": true/' "$WITNESS_PATH" 2>/dev/null || true)"
      [ -n "$NEW_CONTENT" ] && agmsg_write_atomic "$WITNESS_PATH" "$NEW_CONTENT" || true
    fi
  fi
fi

exec "$SCRIPT_DIR/check-inbox.sh" grok-build "$PROJECT"
