#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# SessionStart hook for delivery modes `monitor` and `both`.
#
# Usage: session-start.sh <type> <project_path>
#
# Reads the hook input JSON from stdin to extract the session_id, then emits
# an instruction telling Claude to invoke the Monitor tool against watch.sh.
# The hook input includes session_id for SessionStart events.
#
# Before emitting the directive, this script also takes care of preventing
# duplicate watchers across `/clear` (and similar) re-fires of SessionStart
# within the same Claude Code instance. State is kept in
# `~/.agents/agmsg/run/cc-instance.<cc_pid>`, which records the last
# session_id this CC instance attached to. On each fire we kill the watcher
# for the previous session_id, then record the new one. Multiple CC
# instances of the same project get their own cc_pid, so they never step
# on each other.
#
# Quietly exits 0 when whoami says the agent isn't joined to anything yet.
# Mode is implicit: if this script is being invoked at all, it's because
# `delivery.sh set monitor` (or `both`) installed it in the project's
# settings.local.json — that fact alone is the source of truth for "should
# we emit the directive?". No separate global mode value to consult.

TYPE="${1:?Usage: session-start.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_DIR="$SKILL_DIR/run"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/node.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hash.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/role-session.sh"  # role->session reverse lookup (#339)

# Identity sanity check — no point launching a watcher with an empty pair set.
PAIRS=$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)
[ -n "$PAIRS" ] || exit 0

# Type-specific SessionStart behaviour (Template Method). A type may ship
# scripts/drivers/types/<type>/_session-start.sh defining agmsg_session_start to override the
# default no-op — codex uses it to hand the session off to the bridge. The plug
# is sourced in this script's context so it sees PROJECT / RUN_DIR / SKILL_DIR /
# PAIRS and the helpers sourced above; it may exit 0 (codex does, having no
# Monitor tool) to skip the Monitor-directive path below.
agmsg_session_start_default() { :; }

_tdir="$(agmsg_type_dir "$TYPE" 2>/dev/null || true)"
if [ -n "$_tdir" ] && [ -f "$_tdir/_session-start.sh" ]; then
  # shellcheck disable=SC1090
  . "$_tdir/_session-start.sh"
  agmsg_session_start
else
  agmsg_session_start_default
fi

# Read hook input JSON from stdin. The session id field name differs by vendor:
# Claude Code emits snake_case "session_id"; Grok Build (and Cursor) emit
# camelCase "sessionId". Try snake first (claude-code unaffected), then camel,
# then the GROK_SESSION_ID env Grok injects into every hook.
INPUT=$(cat 2>/dev/null || true)
SESSION_ID=""
if [ -n "$INPUT" ]; then
  SESSION_ID=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
  [ -z "$SESSION_ID" ] && SESSION_ID=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
fi
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"
# Fallback so the instruction is still actionable even outside a hook flow.
[ -z "$SESSION_ID" ] && SESSION_ID="unknown-$$"

mkdir -p "$RUN_DIR" 2>/dev/null || true

# --- Identify the enclosing Claude Code process. ---
# Reuse the shared agent-process resolver (#92) instead of a local ps-walk: it
# checks both the `comm` name and argv[0] basename against the type's binaries,
# which is more robust to wrapper/launch shapes than matching only "claude".
# Empty when no agent ancestor is found (detached / sandboxed) — in that case
# the instance id degrades to the bare session_id and the dedup step is skipped.
CC_PID=$(agmsg_agent_pid "$TYPE" 2>/dev/null || true)

# Per-process instance id (see instance-id.sh): "<session_id>.<cc_pid>", or the
# bare session_id when cc_pid is unresolved. This — not the bare session_id — is
# what keys the watcher pidfile / watermark / actas owner, so parallel
# --continue/--resume processes that share a session_id stay isolated (#93).
# The cc-instance dedup record and the emitted watch.sh directive both use it.
INSTANCE_ID="$(agmsg_instance_id_from_pid "$SESSION_ID" "$CC_PID")"

# --- Cleanup of stale cc-instance files and their orphan watchers. ---
# A cc-instance.<pid> whose CC pid is dead is left over from a previous CC.
# Before removing it, optionally kill the watcher bound to its last
# session_id — but only if that session_id isn't still referenced by a
# LIVE cc-instance file. The same session_id can move from one CC pid to
# another (e.g. on `claude --continue` / `--resume`), so a dead-pid record
# alone is not evidence the session is gone.

# First pass: collect session_ids that are still referenced by a LIVE CC.
live_sids=""
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  pid=${f##*.}
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  if kill -0 "$pid" 2>/dev/null; then
    s=$(cat "$f" 2>/dev/null || true)
    [ -n "$s" ] && live_sids="$live_sids|$s"
  fi
done

# Second pass: clean each dead cc-instance, killing its bound watcher only
# when no live CC still references that session_id.
for f in "$RUN_DIR"/cc-instance.*; do
  [ -f "$f" ] || continue
  pid=${f##*.}
  case "$pid" in ''|*[!0-9]*) continue ;; esac
  kill -0 "$pid" 2>/dev/null && continue
  dead_sid=$(cat "$f" 2>/dev/null || true)
  if [ -n "$dead_sid" ] \
      && ! printf '%s\n' "$live_sids" | tr '|' '\n' | grep -Fxq "$dead_sid"; then
    orphan_pidfile="$RUN_DIR/watch.$dead_sid.pid"
    if [ -f "$orphan_pidfile" ]; then
      orphan_pid=$(cat "$orphan_pidfile" 2>/dev/null || true)
      if [ -n "$orphan_pid" ] && kill -0 "$orphan_pid" 2>/dev/null; then
        # Defensive: only kill if the pid's command line actually matches
        # our watch.sh. Defends against pid recycling — a stale pidfile
        # could point at an unrelated process that took the same pid.
        cmd=$(compat_get_cmdline "$orphan_pid" 2>/dev/null || true)
        case "$cmd" in
          *"$SKILL_DIR/scripts/watch.sh"*) kill "$orphan_pid" 2>/dev/null || true ;;
          *) ;;  # not our watcher anymore; leave it alone
        esac
      fi
      rm -f "$orphan_pidfile"
    fi
  fi
  rm -f "$f"
done

# Same defensive pass for stale watcher pidfiles. A pidfile whose recorded
# pid is dead (or empty) means a watcher exited without running its EXIT
# trap — usually an edge case like SIGKILL or a synthesized session_id
# that SessionEnd's lookup couldn't match.
for f in "$RUN_DIR"/watch.*.pid; do
  [ -f "$f" ] || continue
  pid=$(cat "$f" 2>/dev/null || true)
  if [ -z "$pid" ]; then
    rm -f "$f"
    continue
  fi
  kill -0 "$pid" 2>/dev/null || rm -f "$f"
done

# Garbage-collect actas exclusivity locks whose owner session_id no longer
# maps to a live cc-instance. Must run after the dead cc-instance cleanup
# above, since the liveness check enumerates the remaining cc-instance.*
# files. See #62.
actas_lock_gc_stale >/dev/null 2>&1 || true

# --- Record this session's real project root, keyed by the agent process. ---
# Slash commands resolve the project from $(pwd), which breaks when the user
# cd's into a subdir/worktree (see #92). Persist the authoritative project (our
# $2, baked into the hook at delivery time) keyed by the enclosing agent PID so
# actas/join/whoami can recover it without a stable session_id — the key that
# makes this work for Codex too. Drop markers whose agent process has died.
agmsg_marker_gc_stale 2>/dev/null || true
AGENT_PID=$(agmsg_agent_pid "$TYPE" 2>/dev/null || true)
[ -n "$AGENT_PID" ] && agmsg_write_project_marker "$AGENT_PID" "$PROJECT" 2>/dev/null || true

# Garbage-collect stream watermarks (#107) and readiness sentinels (#108) whose
# owner session_id is no longer alive — left behind when a watcher dies without
# running its EXIT trap (SIGKILL, terminal crash). Runs after the dead
# cc-instance cleanup so actas_lock_sid_alive reflects current liveness. Both
# are advisory (a live watcher rewrites them on attach; spawn clears the
# sentinel before use), so this is hygiene, not correctness.
for f in "$RUN_DIR"/watch.*.watermark; do
  [ -f "$f" ] || continue
  wm_sid=${f##*/}; wm_sid=${wm_sid#watch.}; wm_sid=${wm_sid%.watermark}
  actas_lock_sid_alive "$wm_sid" || rm -f "$f"
done
for f in "$RUN_DIR"/ready.*; do
  [ -f "$f" ] || continue
  rd_sid=$(cat "$f" 2>/dev/null || true)
  { [ -n "$rd_sid" ] && actas_lock_sid_alive "$rd_sid"; } || rm -f "$f"
done


# --- Dedup against the previous watcher in this CC instance. ---
if [ -n "$CC_PID" ]; then
  STATE="$RUN_DIR/cc-instance.$CC_PID"
  if [ -f "$STATE" ]; then
    # Records the previous instance id this CC attached to. Comparing/killing
    # by instance id (not bare session_id) keeps the prev_pidfile lookup aligned
    # with watch.sh's pidfile key.
    prev=$(cat "$STATE" 2>/dev/null || true)
    if [ -n "$prev" ] && [ "$prev" != "$INSTANCE_ID" ]; then
      prev_pidfile="$RUN_DIR/watch.$prev.pid"
      if [ -f "$prev_pidfile" ]; then
        prev_pid=$(cat "$prev_pidfile" 2>/dev/null || true)
        if [ -n "$prev_pid" ] && kill -0 "$prev_pid" 2>/dev/null; then
          kill "$prev_pid" 2>/dev/null || true
        fi
      fi
    fi
  fi
  printf '%s\n' "$INSTANCE_ID" > "$STATE"
fi

# --- Skip directive when a watcher is already alive for this instance. ---
# /compact re-fires SessionStart within the same CC process and session_id, so
# INSTANCE_ID is identical to the already-running watcher's.  Without this
# guard the agent spawns a second Monitor whose watch.sh kills the incumbent,
# the old Monitor task emits "stream ended", and the agent loops trying to
# restart.  Mirrors emit_monitor_directive in delivery.sh.
WATCHER_PIDFILE="$RUN_DIR/watch.$INSTANCE_ID.pid"
if [ -f "$WATCHER_PIDFILE" ]; then
  existing=$(cat "$WATCHER_PIDFILE" 2>/dev/null || true)
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    cat <<EOF
AGMSG monitor mode: a watch.sh is already streaming for this session (pid $existing).
No action needed — the existing watcher is the active one.
EOF
    exit 0
  fi
fi

# --- Role-aware resume (#339). ---
# If this session's bare sid was recorded as a role's seat (by actas-claim, or
# codex actas), and that (team, agent) is registered for THIS project, emit the
# ROLE-FILTERED directive instead of the generic unfiltered one: watch.sh with a
# 4th <agent> arg restricts receive to that role AND re-claims its exclusivity
# lock. This covers a manual `claude --resume <uuid>` that bypasses spawn's actas
# boot prompt -- the resumed session re-arms as its role automatically. Fail-open:
# no record, no project match, or an unreadable record => generic directive.
ROLE_NAME=""; ROLE_TEAM=""
_bare_sid="$(agmsg_instance_bare_sid "$SESSION_ID" 2>/dev/null || printf '%s' "$SESSION_ID")"
_rec="$(agmsg_role_session_lookup_by_sid "$_bare_sid" 2>/dev/null || true)"
if [ -n "$_rec" ]; then
  _r_agent="$(printf '%s\n' "$_rec" | sed -n 's/^agent=//p' | head -1)"
  _r_team="$(printf '%s\n' "$_rec" | sed -n 's/^team=//p' | head -1)"
  # Guard against a cross-project sid collision: only honor the record when its
  # (team, agent) is actually one of this project's registered pairs.
  if [ -n "$_r_agent" ] && [ -n "$_r_team" ] \
     && printf '%s\n' "$PAIRS" | grep -Fxq "$(printf '%s\t%s' "$_r_team" "$_r_agent")"; then
    ROLE_NAME="$_r_agent"; ROLE_TEAM="$_r_team"
  fi
fi

WATCH="$SKILL_DIR/scripts/watch.sh"
# Shell-quote each argv so the host can paste the command into Monitor and run
# it verbatim. A plain '...' wrap breaks on paths with an apostrophe
# (/Users/o'brien/...); printf %q escapes spaces, quotes and other metacharacters
# safely for shell re-execution (#188). A resumed role adds the 4th <agent> arg.
if [ -n "$ROLE_NAME" ]; then
  WATCH_COMMAND="$(printf '%q %q %q %q %q' "$WATCH" "$INSTANCE_ID" "$PROJECT" "$TYPE" "$ROLE_NAME")"
  cat <<EOF
AGMSG monitor mode (resumed role \`$ROLE_NAME\` in team \`$ROLE_TEAM\`): this
session was recorded as that role's seat, so invoke the Monitor tool now with the
following parameters, before any other action in this session.

  command: $WATCH_COMMAND
  description: agmsg inbox stream (acting as $ROLE_NAME)
  persistent: true

The 4th argument restricts receive to \`$ROLE_NAME\` only and re-claims its actas
exclusivity lock — a resume restores context but not runtime state, so this
re-establishes the role. Send with \`send.sh ... $ROLE_NAME ...\` (this session's
active FROM is \`$ROLE_NAME\`). Each output line is one message:
\`<ts> | <team> | <from> → <to> | <body>\`. React as they arrive.

Note: On a /clear or --continue/--resume re-fire, you may shortly see a
"Monitor … stopped" notification for an earlier 'agmsg inbox stream'
task. That is the previous watcher being cleaned up — expected. Do NOT
relaunch it; the Monitor you invoke from this directive replaces it.
EOF
  exit 0
fi

WATCH_COMMAND="$(printf '%q %q %q %q' "$WATCH" "$INSTANCE_ID" "$PROJECT" "$TYPE")"

cat <<EOF
AGMSG monitor mode: invoke the Monitor tool now with the following parameters,
before any other action in this session.

  command: $WATCH_COMMAND
  description: agmsg inbox stream
  persistent: true

This streams incoming agmsg messages into the session in real time. Each
output line is one message: \`<ts> | <team> | <from> → <to> | <body>\`.
React to messages as they arrive; reply with \`send.sh\`.

Note: On a /clear or --continue/--resume re-fire, you may shortly see a
"Monitor … stopped" notification for an earlier 'agmsg inbox stream'
task. That is the previous watcher being cleaned up to avoid duplicates
— it is expected. Do NOT relaunch it; the Monitor you invoke from this
directive replaces it.
EOF
