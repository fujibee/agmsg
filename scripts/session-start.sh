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
# Only DEFINES agmsg_close_inherited_fds; nothing is closed here. The type
# plug calls it inside a subshell around its own long-lived spawn, so this
# shell's descriptors are untouched. See lib/close-fds.sh.
source "$SCRIPT_DIR/lib/close-fds.sh"

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

# --- Skip spawned worktree sub-sessions (.claude/worktrees checkouts). ---
# Claude Code's background-task feature runs a short-lived sub-session in an
# isolated worktree under .claude/worktrees/<name>. SessionStart still fires
# there (#92's resolve-project normalizes its cwd back to the registered
# project, so identities resolve fine), so a persistent inbox watcher was
# getting launched for it too — but that watcher keeps the sub-session's
# Monitor alive past the point its task finishes, so the parent session never
# receives the sub-session's completion notification (#367). The sub-session
# is also not normally an agmsg team member in its own right, so a watcher
# has little value there anyway. cwd may arrive as forward slashes or
# JSON-escaped backslashes depending on platform (a single escaped backslash
# decodes to two raw '\' bytes in the captured substring), so normalize both
# to '/' and squeeze doubled separators before matching. Match the exact
# ".claude/worktrees" PATH SEGMENT sequence, not a loose substring — a naive
# `*.claude*worktrees*` glob would also skip an unrelated project merely
# named e.g. ".claude-tools/my-worktrees-app".
HOOK_CWD=""
if [ -n "$INPUT" ]; then
  HOOK_CWD=$(printf '%s' "$INPUT" \
    | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -1)
fi
[ -z "$HOOK_CWD" ] && HOOK_CWD="${PWD:-}"
HOOK_CWD_NORM=$(printf '%s' "$HOOK_CWD" | tr '\\' '/' | sed 's#//*#/#g')
case "$HOOK_CWD_NORM" in
  */.claude/worktrees|*/.claude/worktrees/*|.claude/worktrees|.claude/worktrees/*) exit 0 ;;
esac

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
  if _agmsg_pid_alive "$pid"; then
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
  _agmsg_pid_alive "$pid" && continue
  dead_sid=$(cat "$f" 2>/dev/null || true)
  if [ -n "$dead_sid" ] \
      && ! printf '%s\n' "$live_sids" | tr '|' '\n' | grep -Fxq "$dead_sid"; then
    orphan_pidfile="$RUN_DIR/watch.$dead_sid.pid"
    if [ -f "$orphan_pidfile" ]; then
      orphan_pid=$(cat "$orphan_pidfile" 2>/dev/null || true)
      if [ -n "$orphan_pid" ] && _agmsg_pid_alive_local "$orphan_pid"; then
        # Defensive: only kill if the pid's command line actually matches
        # our watch.sh. Defends against pid recycling — a stale pidfile
        # could point at an unrelated process that took the same pid.
        cmd=$(compat_get_cmdline "$orphan_pid" 2>/dev/null || true)
        if agmsg_cmdline_names_path "$cmd" "$SKILL_DIR/scripts/watch.sh"; then
          kill "$orphan_pid" 2>/dev/null || true
        fi   # otherwise it is not our watcher anymore; leave it alone
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
  _agmsg_pid_alive_local "$pid" || rm -f "$f"
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

# Garbage-collect readiness sentinels (#108) whose owner session_id is no longer
# alive. Read progress is store-owned, so there is no per-session watermark to
# collect.
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
        if [ -n "$prev_pid" ] && _agmsg_pid_alive_local "$prev_pid"; then
          kill "$prev_pid" 2>/dev/null || true
        fi
      fi
    fi
  fi
  printf '%s\n' "$INSTANCE_ID" > "$STATE"
fi

# --- Start the engine for a connected team that has none (#761, #774). ---
# A reboot leaves every sync engine dead and nothing restarts one: the five
# commands that start it are all operator actions. `connected` keeps printing,
# `send` keeps succeeding locally, and the only symptom is messages not arriving
# — which reads as "nobody wrote anything". This is the first moment after a
# reboot when anything of ours runs, so it is where it gets started.
#
# #765 made the absence VISIBLE here, in this block, and that was the right
# first step and not enough: the warning appeared only when someone opened a
# session, and it asked the person for something the machine can do. Starting it
# is the same trigger doing the whole job.
#
# BEFORE the three directive blocks below rather than inside them: there are
# three ways out of this script (a watcher already streaming, the actas variant,
# and the default), and a line added to one of them is missing from the other
# two.
#
# WHICH TEAMS. `status` is asked for CONNECTED teams — the binding, not the
# engine. Whether an engine is running is `sync start`'s question, under the
# lock that makes the answer true; asking it here as well is the second answer
# that diverges (see scripts/lib/sync-autostart.sh).
#
# Best-effort, and bounded IN TIME as well as in outcome. `status` is a
# subprocess and needs python3; if it cannot run, this does nothing rather than
# guessing. A start that fails never fails the session, and a start that is SLOW
# never delays the Monitor directive below: the helper waits for a whole-call
# budget (`AGMSG_SYNC_AUTOSTART_TIMEOUT_S`, 5s) and then leaves the start
# running and moves on. An agent that will not open because a sync engine was
# thinking is worse than a sync engine that is down.
#
# Reaches `monitor` and `both` only — this hook is not installed for `turn` or
# `off`, so those modes still get the absence only from `status`.
if [ -x "$SKILL_DIR/scripts/remote.sh" ] && [ -r "$SKILL_DIR/scripts/lib/sync-autostart.sh" ]; then
  # shellcheck source=scripts/lib/sync-autostart.sh
  . "$SKILL_DIR/scripts/lib/sync-autostart.sh"
  _connected_teams="$("$SKILL_DIR/scripts/remote.sh" status 2>/dev/null \
    | awk -F'\t' '$2 ~ /^connected/ {print $1}' || true)"
  if [ -n "$_connected_teams" ]; then
    # Word splitting on newlines only: a team name may contain a space, and
    # `$(...)` unquoted would split it into two names that start nothing.
    _old_ifs="$IFS"; IFS=$'\n'
    # shellcheck disable=SC2086
    set -- $_connected_teams
    IFS="$_old_ifs"
    agmsg_sync_autostart "$SKILL_DIR/scripts/remote.sh" "$@" || true
  fi
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
  if [ -n "$existing" ] && _agmsg_pid_alive_local "$existing"; then
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
# boot prompt -- the resumed session re-arms as its role automatically. When no
# record matches, narrowing (#982) tries the actas lock this sid owns; if the
# seat still cannot be established the fallback is fail-CLOSED, not the generic
# unfiltered watcher (which would consume other seats' unread) -- see the two
# blocks below.
ROLE_NAME=""; ROLE_TEAM=""; ROLE_BASIS=""
_bare_sid="$(agmsg_instance_bare_sid "$SESSION_ID" 2>/dev/null || printf '%s' "$SESSION_ID")"
_rec="$(agmsg_role_session_lookup_by_sid "$_bare_sid" 2>/dev/null || true)"
if [ -n "$_rec" ]; then
  _r_agent="$(printf '%s\n' "$_rec" | sed -n 's/^agent=//p' | head -1)"
  _r_team="$(printf '%s\n' "$_rec" | sed -n 's/^team=//p' | head -1)"
  # Guard against a cross-project sid collision: only honor the record when its
  # (team, agent) is actually one of this project's registered pairs.
  if [ -n "$_r_agent" ] && [ -n "$_r_team" ] \
     && printf '%s\n' "$PAIRS" | grep -Fxq "$(printf '%s\t%s' "$_r_team" "$_r_agent")"; then
    ROLE_NAME="$_r_agent"; ROLE_TEAM="$_r_team"; ROLE_BASIS=record
  fi
fi

# --- Narrowing when the role-session record is missing (#982). ---
# The record above is advisory and can be absent even for a session that IS a
# seat (a resume that bypassed actas-claim, an unreadable record). The same fact
# it would carry may still be on disk: an actas.<team>__<agent>.session lock this
# very sid owns. Match the lock owner's BARE sid (stable across resume; the pid
# half changes) against ours, iterating THIS project's registered pairs rather
# than raw lock filenames (those are percent-encoded, and iterating PAIRS keeps
# us to locks that are actually registered here). Exactly one match re-seats us;
# zero leaves ROLE_NAME empty for the fail-closed decision below, and an ambiguous
# 2+ deliberately does the same — an unfiltered watcher is the one thing we must
# not fall back to (it consumes other seats' unread; see the block after the
# role-filtered emit).
if [ -z "$ROLE_NAME" ]; then
  _narrow_n=0; _narrow_agent=""; _narrow_team=""
  _tab="$(printf '\t')"
  while IFS="$_tab" read -r _p_team _p_agent; do
    [ -n "$_p_team" ] && [ -n "$_p_agent" ] || continue
    _owner="$(actas_lock_owner "$_p_team" "$_p_agent" 2>/dev/null || true)"
    [ -n "$_owner" ] || continue
    _owner_bare="$(agmsg_instance_bare_sid "$_owner" 2>/dev/null || printf '%s' "$_owner")"
    if [ "$_owner_bare" = "$_bare_sid" ]; then
      _narrow_n=$((_narrow_n + 1)); _narrow_agent="$_p_agent"; _narrow_team="$_p_team"
    fi
  done <<EOF
$PAIRS
EOF
  if [ "$_narrow_n" -eq 1 ]; then
    ROLE_NAME="$_narrow_agent"; ROLE_TEAM="$_narrow_team"; ROLE_BASIS=actas
  fi
fi

WATCH="$SKILL_DIR/scripts/watch.sh"
# Shell-quote each argv so the host can paste the command into Monitor and run
# it verbatim. A plain '...' wrap breaks on paths with an apostrophe
# (/Users/o'brien/...); printf %q escapes spaces, quotes and other metacharacters
# safely for shell re-execution (#188). A resumed role adds the 4th <agent> arg.
if [ -n "$ROLE_NAME" ]; then
  WATCH_COMMAND="$(printf '%q %q %q %q %q' "$WATCH" "$INSTANCE_ID" "$PROJECT" "$TYPE" "$ROLE_NAME")"
  # State the seat's basis honestly: the reader launches a watcher on the strength
  # of this sentence, so a recorded seat and an inferred one must not read alike
  # (#982/#993). The record path has an explicit role-session record; the narrowing
  # path has only the actas lock this sid still owns — say which, and why it stands
  # in for the record, so the reader can weigh "what if the lock is stale?".
  if [ "$ROLE_BASIS" = record ]; then
    SEAT_CLAIM="this session was recorded as that role's seat"
  else
    SEAT_CLAIM="no role record was found for this session, but it still owns that role's actas exclusivity lock — claimed by this seat and carried across the resume — which is taken to stand in for the record (so if that lock were stale, this seating would be too)"
  fi
  cat <<EOF
AGMSG monitor mode (resumed role \`$ROLE_NAME\` in team \`$ROLE_TEAM\`):
$SEAT_CLAIM, so invoke the Monitor tool now with the following parameters, before
any other action in this session.

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

# --- Fail-closed fallback (#982). ---
# No seat was established (no role-session record, and no single actas lock this
# sid owns). Emitting the generic, unfiltered watch.sh here is NOT a "receive a
# bit more" degradation: on a project with several registered pairs it subscribes
# to ALL of them, and watch.sh stamps read_at + advances every pair's read_cursor
# to the tip as it delivers — so it CONSUMES other seats' unread mail, silently,
# and irreversibly short of hand-editing the store. That is the expensive
# direction to default to. So reserve the generic watcher for a single-pair
# project, where there is no one else's mail to take; with more than one pair,
# stand down and say why (a silent no-watcher is indistinguishable from "no
# messages arriving"), naming `/agmsg actas <name>` so the seat can be set
# explicitly — which re-fires this hook down the role-filtered path above.
_pair_count="$(printf '%s\n' "$PAIRS" | grep -c '.' || true)"
if [ "${_pair_count:-0}" -le 1 ]; then
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
  exit 0
fi

# Multiple registered seats here and none identified as this session: stand down.
# Emit NO watch.sh directive — there is nothing for the host to launch, so no
# other seat's mail can be consumed — and explain the state so it is not mistaken
# for silence.
_seat_list="$(printf '%s\n' "$PAIRS" | awk -F'\t' 'NF>=2 && $2!="" {print "  - /agmsg actas "$2}')"
cat <<EOF
AGMSG monitor mode: standing down — no inbox watcher was started for this session.

This resumed session could not be matched to a seat (no role-session record, and
no actas lock it owns), and this project has more than one registered seat. An
unfiltered watcher would subscribe to every seat here and mark THEIR unread
messages read as it delivered them — consuming mail addressed to other sessions.
So no watcher is started rather than the wrong one.

No messages are lost: they remain in the store (\`history.sh <team> <agent>\`
returns them). What is paused is live delivery into THIS session.

To start receiving as your seat, claim it explicitly — this re-fires the monitor
directive on the role-filtered path:

$_seat_list

If you are not any of these seats, no watcher is the correct state.
EOF
exit 0
