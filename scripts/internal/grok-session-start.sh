#!/usr/bin/env bash
set -euo pipefail
# grok-build's own SessionStart hook, used ONLY in agmsgd delivery mode
# (scripts/drivers/types/grok-build/_delivery.sh writes the hook entry that
# invokes this). Grok Build's SessionStart stdout is discarded (measured
# live, 2026-11-15 -- unchanged from the existing turn/monitor rule's own
# note on Grok's passive hooks), so this records witness state for the
# grok-queue channel to read and emits nothing.
#
# Usage: grok-session-start.sh <project_path>
# Reads the hook input JSON from stdin for sessionId/cwd (best effort; GROK_*
# env vars are the measured, reliable source and win when both are present).

PROJECT="${1:?Usage: grok-session-start.sh <project_path>}"

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hash.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/registry-lock.sh"   # agmsg_write_atomic
# shellcheck disable=SC1091
source "$SCRIPT_DIR/internal/grok-session-witness.sh"

mkdir -p "$RUN_DIR" 2>/dev/null || true

INPUT="$(cat 2>/dev/null || true)"
SESSION_ID="${GROK_SESSION_ID:-}"
if [ -z "$SESSION_ID" ] && [ -n "$INPUT" ]; then
  SESSION_ID="$(printf '%s' "$INPUT" | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$SESSION_ID" ] || exit 0   # nothing to attach a witness to

GROK_HOME_RESOLVED="${GROK_HOME:-$HOME/.grok}"
# Measured live, 2026-11-15: a hook invocation DOES inherit GROK_LEADER_SOCKET
# when the TUI was actually started with --leader. NO FALLBACK to grok's
# documented default path: a plain (non-leader) TUI leaves GROK_LEADER_SOCKET
# unset, and defaulting to that path anyway recorded a leader_socket nothing
# was listening on -- the channel's own spawn of the ACP client against it
# then had the client itself START a brand-new, resident `grok agent leader`
# process there against the user's REAL ~/.grok (real-machine review, finding
# A, 2026-11-15). An empty leader_socket here is what makes the channel's own
# in-process connect probe refuse to spawn anything for this seat at all.
LEADER_SOCKET="${GROK_LEADER_SOCKET:-}"

# NG1 (2026-11-15 real-machine round): $$ is this HOOK SCRIPT's own pid,
# which is gone the instant this script exits -- the channel's pid-liveness
# check then always read the seat as process_gone. There is no
# GROK_AGENT_PID env var. The session's real process (its start time, kept
# for a future PID-reuse guard the channel does not check yet, and its own
# cwd) is in GROK_HOME/active_sessions.json, keyed by this SESSION_ID.
# Confirmed live (2026-11-15): the element's keys are exactly
# cwd, opened_at, pid, pid_start, session_id.
PID=""
PID_START=""
CWD=""
# Linux real-machine round (2026-11-15): SessionStart can fire BEFORE grok
# itself has written this session into active_sessions.json yet -- a bare
# single lookup then found nothing on 2 of 3 fresh sessions, leaving the
# seat unaddressable forever (no later event re-tries this write). Retried
# here for a bounded time instead: SessionStart is NOT in grok's own
# blockingEvents list (confirmed from its initialize response's
# x.ai/hooks.blockingEvents, which lists only pre_tool_use/stop/
# subagent_stop), so this wait never delays the user's own turn. 25
# attempts * 0.2s = ~5s outer bound; stops as soon as a match is found.
# Overridable so a test can confirm the Nth-attempt-succeeds path and the
# give-up-after-the-last-attempt path without a real suite spending ~5s
# per case; production never sets these, so the real default stays 25 *
# 0.2s = ~5s.
_lookup_retries="${AGMSG_GROK_LOOKUP_RETRIES:-25}"
_lookup_interval="${AGMSG_GROK_LOOKUP_INTERVAL:-0.2}"
_lookup_attempt=0
while [ "$_lookup_attempt" -lt "$_lookup_retries" ]; do
  _session_obj="$(agmsg_grok_active_session_lookup "$GROK_HOME_RESOLVED/active_sessions.json" "$SESSION_ID" 2>/dev/null || true)"
  if [ -n "$_session_obj" ]; then
    PID="$(printf '%s' "$_session_obj" | sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
    [ -n "$PID" ] && break
  fi
  _lookup_attempt=$((_lookup_attempt + 1))
  [ "$_lookup_attempt" -lt "$_lookup_retries" ] && sleep "$_lookup_interval"
done
if [ -n "$_session_obj" ] && [ -n "$PID" ]; then
  PID_START="$(printf '%s' "$_session_obj" | sed -n 's/.*"pid_start"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  CWD="$(printf '%s' "$_session_obj" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
fi
# Still no active_sessions.json entry after the bounded retry above
# (unexpected shape, or the lookup's own flat-object assumption did not
# hold): fail toward "no witness" rather than writing one with a wrong
# pid that would misreport as unaddressable forever. GROK_SESSION_ID was
# still confirmed non-empty above, so this is a real gap worth reporting
# back, not a routine absence -- grok-stop.sh gets one more chance to
# create this witness at the end of the first turn (active_sessions.json
# is certainly populated by then), and the reason is recorded where
# `agmsg daemon status` can show it (class D), not only to stderr, which
# grok itself discards for SessionStart.
if [ -z "$PID" ]; then
  _reason="SessionStart could not find session $SESSION_ID in $GROK_HOME_RESOLVED/active_sessions.json"
  echo "agmsg: grok-session-start.sh: $_reason; no witness written" >&2
  _seat_for_pending="$(agmsg_grok_resolve_seat "$PROJECT" 2>/dev/null || true)"
  if [ -n "$_seat_for_pending" ]; then
    agmsg_write_atomic "$(agmsg_grok_pending_path "${_seat_for_pending%%	*}" "${_seat_for_pending#*	}")" "$_reason" || true
  fi
  exit 0
fi
# NG2 follow-up (2026-11-15): session/resume's cwd must be grok's own
# recorded (already-canonical) path, not the hook's $PWD -- on macOS /tmp
# is itself a symlink to /private/tmp, so a hook running under
# /tmp/<project> sent a cwd the real leader rejected outright
# (-32603 FS_NOT_FOUND, "Path not found."), even though it was the
# project's real directory. active_sessions.json's own cwd is already
# resolved the way the leader itself expects. A still-empty CWD here
# (the matched object had no cwd field after all) falls back to a
# locally-canonicalized PWD/PROJECT as a last resort, better than sending
# nothing.
if [ -z "$CWD" ]; then
  CWD="$(cd "${PWD:-$PROJECT}" 2>/dev/null && pwd -P)"
  [ -n "$CWD" ] || CWD="${PWD:-$PROJECT}"
fi

SEAT="$(agmsg_grok_resolve_seat "$PROJECT" 2>/dev/null || true)"
[ -n "$SEAT" ] || exit 0   # ambiguous / unregistered project: nothing to attach

TEAM="${SEAT%%	*}"
AGENT="${SEAT#*	}"
WITNESS_PATH="$(agmsg_grok_witness_path "$TEAM" "$AGENT")"

# A re-fire for the SAME session_id (e.g. a hook that fires more than once
# per start) must not clobber an already-advanced first_turn_done -- only a
# NEW session_id resets it.
FIRST_TURN_DONE=false
if [ -f "$WITNESS_PATH" ]; then
  _prev_sid="$(sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WITNESS_PATH" 2>/dev/null | head -1)"
  # \| is a GNU sed extension, not POSIX BRE -- BSD/macOS sed (where this
  # also has to run) treats \(true\|false\) as a literal-backslash-pipe
  # group and never matches, so the previous value was silently read as
  # empty every time, always resetting first_turn_done. Capture any
  # lowercase run instead; the value is always exactly "true" or "false".
  _prev_done="$(sed -n 's/.*"first_turn_done"[[:space:]]*:[[:space:]]*\([a-z]*\).*/\1/p' "$WITNESS_PATH" 2>/dev/null | head -1)"
  if [ "$_prev_sid" = "$SESSION_ID" ] && [ "$_prev_done" = "true" ]; then
    FIRST_TURN_DONE=true
  fi
fi

esc() { printf '%s' "$1" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g'; }

CONTENT="$(cat <<EOF
{
  "team": "$(esc "$TEAM")",
  "agent": "$(esc "$AGENT")",
  "session_id": "$(esc "$SESSION_ID")",
  "pid": "$(esc "$PID")",
  "pid_start": "$(esc "$PID_START")",
  "cwd": "$(esc "$CWD")",
  "leader_socket": "$(esc "$LEADER_SOCKET")",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "first_turn_done": $FIRST_TURN_DONE
}
EOF
)"
# review on #1979, finding (2): clearing the pending-reason file
# unconditionally right after a write attempt that itself used `|| true`
# meant a write failure (e.g. a transient mv failure) left BOTH no
# witness AND no pending reason -- a silent regression to the original
# bug this file exists to fix. Only clear it when the write actually
# succeeded; record why it didn't otherwise, so status still shows
# something rather than reverting to an unexplained absence.
_pending_path="$(agmsg_grok_pending_path "$TEAM" "$AGENT")"
if agmsg_write_atomic "$WITNESS_PATH" "$CONTENT"; then
  rm -f "$_pending_path" 2>/dev/null || true
else
  agmsg_write_atomic "$_pending_path" "SessionStart found session $SESSION_ID but could not write the witness to $WITNESS_PATH" || true
fi
exit 0
