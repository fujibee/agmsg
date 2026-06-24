#!/usr/bin/env bash
set -u

# Stream new agmsg messages for the current session as they arrive.
#
# Intended to be launched by Claude Code's Monitor tool from the SessionStart
# hook (`session-start.sh`), but also works standalone as `tail -f` for
# inbox: any agent runtime that can read stdout can consume it.
#
# Usage: watch.sh <session_id> <project_path> <agent_type> [active_name]
#
# Behavior:
#   - Resolves (team, agent) pairs for (project_path, agent_type) via
#     identities.sh. By default, subscribes to messages addressed to any
#     of those pairs.
#   - When [active_name] is given, narrows the subscription to only pairs
#     whose agent name matches — useful for `actas` exclusive role mode.
#   - A fresh session sets the high-water mark to the current MAX(id) at
#     startup, so the stream begins with whatever arrives after launch — no
#     replay of historical messages. The mark is persisted per session_id, so
#     a restart of this session's watcher (actas/drop/clear/self-restart)
#     resumes from the last delivered id and does not drop messages that
#     arrived during the restart gap. See #107.
#   - Polls the SQLite DB at AGMSG_WATCH_INTERVAL seconds (default 5, also
#     overridable via the delivery.monitor.poll_interval config key).
#   - Emits one line per new message:
#         <ts> | <team> | <from> → <to> | <body>
#     Newlines in body are escaped to literal "\n" so each message stays a
#     single line — easier for Monitor to deliver as one event.
#   - Writes a pidfile at ~/.agents/agmsg/run/watch.<session_id>.pid and
#     removes it on EXIT / SIGTERM / SIGINT.

SESSION_ID="${1:?Usage: watch.sh <session_id> <project_path> <agent_type> [active_name]}"
PROJECT_PATH="${2:?Missing project_path}"
AGENT_TYPE="${3:?Missing agent_type}"
ACTIVE_NAME="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

# Resolve the session's real project root (see #92). The actas/drop/ensure-
# monitor flows relaunch this watcher with a raw "$(pwd)"; without resolution a
# watcher started from a subdir/worktree finds no registration and exits, so
# actas would switch the from-line yet silently kill the receive side. A
# detached watcher (no agent process to walk to) degrades to the ancestor /
# git-common-dir signals, which still recover the nested/worktree cases.
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

# Disambiguate parallel --continue/--resume sessions that share a session_id
# (#93). All per-process state below — pidfile, watermark, actas owner, ready
# sentinel — keys on this per-process instance id rather than the bare
# session_id, so two processes that share a session_id no longer collide on the
# same pidfile and kill each other (#66 was a within-session dedup; here it must
# not fire across sibling processes). Idempotent: the SessionStart directive
# already passes a composite id (no re-derive); the command template's manual
# monitor/actas/drop steps pass a bare session_id and we self-derive here.
SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$AGENT_TYPE")"

DB="$(agmsg_db_path)"
RUN_DIR="$SKILL_DIR/run"
PIDFILE="$RUN_DIR/watch.$SESSION_ID.pid"

# Resolve poll interval. Env var wins over config, default 5s.
INTERVAL="${AGMSG_WATCH_INTERVAL:-}"
if [ -z "$INTERVAL" ]; then
  INTERVAL="$("$SCRIPT_DIR/config.sh" get delivery.monitor.poll_interval 5 2>/dev/null || echo 5)"
fi
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac

mkdir -p "$RUN_DIR" 2>/dev/null || true

# Sequential re-invocation of Monitor for this same session_id leaves the
# previous watch.sh running but loses track of it (pidfile gets clobbered).
# Stop the prior holder before claiming the slot. ps args check defends
# against pid recycling — only touch processes whose cmdline still matches
# our watch.sh. See #66.
#
# When ps is unavailable (e.g. Claude Code sandbox), fall back to kill -0
# which confirms the pid is alive but cannot validate the cmdline.
if [ -f "$PIDFILE" ]; then
  prev_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$$" ] && kill -0 "$prev_pid" 2>/dev/null; then
    prev_cmd=$(ps -o args= -p "$prev_pid" 2>/dev/null || true)
    if [ -n "$prev_cmd" ]; then
      case "$prev_cmd" in
        *"$SKILL_DIR/scripts/watch.sh"*) kill "$prev_pid" 2>/dev/null || true ;;
      esac
    else
      # ps unavailable (sandboxed) — skip cmdline validation, rely on kill -0
      kill "$prev_pid" 2>/dev/null || true
    fi
  fi
fi

echo $$ > "$PIDFILE"
# Readiness sentinels this watcher created (see #108). Populated once the
# subscription is resolved; removed on exit so the file is present iff a live
# watcher is currently receiving for that role.
READY_FILES=""
cleanup() {
  # EXIT only removes the pidfile if it still records our pid. A successor
  # watcher (Monitor re-invoked for the same session_id) overwrites $PIDFILE
  # with its own pid before killing us; without this guard our EXIT trap
  # would erase the successor's record. See #66.
  local pidfile_pid=""
  [ -f "$PIDFILE" ] && IFS= read -r pidfile_pid < "$PIDFILE" || true
  [ "$pidfile_pid" = "$$" ] && rm -f "$PIDFILE"
  if [ -n "$READY_FILES" ]; then
    while IFS= read -r _rf; do
      [ -z "$_rf" ] && continue
      # Only remove a sentinel we still own. A successor actas watcher for the
      # same (team, name) overwrites it with its own session_id before this one
      # exits; without this guard our EXIT could delete the live successor's
      # sentinel. Mirrors the pidfile guard above. See #108 review.
      local _owner=""
      [ -f "$_rf" ] && IFS= read -r _owner < "$_rf" || true
      [ "$_owner" = "$SESSION_ID" ] && rm -f "$_rf" 2>/dev/null || true
    done <<< "$READY_FILES"
  fi
}
trap cleanup EXIT
trap 'exit 0' INT TERM HUP

# Resolve subscription set.
PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$AGENT_TYPE")"
if [ -n "$ACTIVE_NAME" ]; then
  PAIRS=$(printf '%s\n' "$PAIRS" | awk -v n="$ACTIVE_NAME" -F'\t' 'NF >= 2 && $2 == n')
fi

# Honor actas exclusivity locks. A (team, agent) pair currently owned by
# another live session is removed from this watcher's subscription so
# messages addressed to that role only reach the owning session. Pairs we
# own (or that are free) stay in. See #62.
#
# When ACTIVE_NAME is set (the watcher was launched by an `actas` flow),
# we also CLAIM the lock for each surviving pair. Implicit claim here makes
# the exclusivity take effect machine-wide on the next peer watcher cycle,
# without needing the skill cmd templates to call a separate helper. If a
# claim fails because another live session beat us to it, exit with an
# error — the user's host agent surfaces stderr and the original (broad)
# watcher was already stopped by the actas flow, so this state is recoverable
# by `drop` on the other session.
if [ -n "$PAIRS" ]; then
  filtered=""
  skipped=""
  held=""
  while IFS=$'\t' read -r _team _agent; do
    [ -z "$_team" ] && continue
    state=$(actas_lock_state "$_team" "$_agent" "$SESSION_ID")
    case "$state" in
      other:*)
        # If the caller is asking specifically for this name (actas flow),
        # treat the conflict as a hard failure. Otherwise (broad subscribe)
        # silently skip — peer owns the role, we don't need it.
        if [ -n "$ACTIVE_NAME" ]; then
          held="${held:+$held }${_team}/${_agent}(${state#other:})"
        else
          skipped="${skipped:+$skipped }${_team}/${_agent}(${state#other:})"
        fi
        continue
        ;;
    esac
    if [ -n "$ACTIVE_NAME" ]; then
      # Implicit claim — `actas` was the invoking flow. Covers the race
      # where state-check said free but a peer claimed it between then and
      # now.
      result=$(actas_lock_claim "$_team" "$_agent" "$SESSION_ID" 2>/dev/null || true)
      case "$result" in
        held:*)
          held="${held:+$held }${_team}/${_agent}(${result#held:})"
          continue
          ;;
      esac
    fi
    filtered="${filtered:+$filtered$'\n'}${_team}"$'\t'"${_agent}"
  done <<< "$PAIRS"
  PAIRS="$filtered"
  if [ -n "$skipped" ]; then
    echo "agmsg watch: skipping pairs held by other sessions: $skipped" >&2
  fi
  if [ -n "$held" ]; then
    echo "agmsg watch: cannot claim (held by other sessions): $held" >&2
    echo "agmsg watch: run \`/agmsg drop <name>\` in the owning session, then retry." >&2
    exit 1
  fi
fi

if [ -z "$PAIRS" ]; then
  if [ -n "$ACTIVE_NAME" ]; then
    echo "agmsg watch: no registration for agent '$ACTIVE_NAME' in $PROJECT_PATH ($AGENT_TYPE); nothing to do"
  else
    echo "agmsg watch: no available identities (all held by other sessions, or none joined); nothing to do"
  fi
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

# Determine the starting watermark.
#
# The watermark is persisted per session_id so that a *restart* of this
# session's watcher resumes from the last delivered id instead of jumping to
# the current MAX(id). Monitor restarts are routine — `actas`/`drop` do
# TaskStop + relaunch, `/clear`/resume re-fires the SessionStart directive, and
# a killed watcher self-restarts — and the old "start from MAX(id)" behavior
# silently dropped every message that landed in the gap between the previous
# watcher stopping and the new one taking its mark. Resuming from the persisted
# watermark closes that gap; staying strictly after the last delivered id
# avoids re-streaming anything already seen. See #107.
#
# A *fresh* session (no persisted watermark) still starts from the current
# MAX(id) — live push, no replay of history (the no-arg inbox check covers
# historical unread, not this stream).
WATERMARK_FILE="$RUN_DIR/watch.$SESSION_ID.watermark"
persist_watermark() { printf '%s\n' "$LAST" > "$WATERMARK_FILE" 2>/dev/null || true; }

LAST=""
if [ -f "$WATERMARK_FILE" ]; then
  LAST="$(cat "$WATERMARK_FILE" 2>/dev/null || true)"
  case "$LAST" in ''|*[!0-9]*) LAST="" ;; esac
fi
if [ -z "$LAST" ]; then
  LAST=0
  if [ -f "$DB" ]; then
    LAST="$(agmsg_sqlite "$DB" "SELECT COALESCE(MAX(id), 0) FROM messages WHERE $WHERE_PAIRS;" 2>/dev/null || echo 0)"
  fi
  case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
  persist_watermark
fi

# Signal readiness. Once the subscription is resolved and the watermark is set,
# this watcher will deliver anything that arrives from here on, so it is safe
# for a leader to start sending. Only exclusive (actas) watchers signal — a
# spawned agent always starts its watcher in actas mode — and the sentinel is
# removed on exit (cleanup), so it tracks "a live watcher is receiving for this
# role". `spawn --wait-ready` polls for it. See #108.
if [ -n "$ACTIVE_NAME" ]; then
  while IFS=$'\t' read -r _rt _ra; do
    [ -z "$_rt" ] && continue
    _rp="$(agmsg_ready_path "$_rt" "$_ra")"
    # Stamp our session_id so cleanup (and a successor watcher) can tell whose
    # sentinel it is — keeps "present iff a live watcher is receiving" honest
    # across a quick actas restart. See #108 review.
    printf '%s\n' "$SESSION_ID" > "$_rp" 2>/dev/null || true
    READY_FILES="${READY_FILES:+$READY_FILES$'\n'}$_rp"
  done <<< "$PAIRS"
fi

while true; do
  # Liveness guard (#67): exit promptly once the originating agent session is
  # gone. A plain pipe gives no portable way to notice a *downstream* consumer
  # that closed silently — printf '' raises no EPIPE, and macOS buffers a final
  # write into an already-dead reader — so a quiet watcher whose session died
  # would otherwise spin forever (the macOS-runner 33-min stall; #210's job
  # timeout only caps the symptom). `kill -0` on the agent pid embedded in the
  # composite instance id is portable (Git Bash falls back to tasklist; see
  # _agmsg_pid_alive). Gated on a composite id only: a bare id (degraded, no
  # resolved agent pid) keeps the prior behavior and is not liveness-gated.
  if agmsg_instance_is_composite "$SESSION_ID" && ! agmsg_instance_alive "$SESSION_ID"; then
    exit 0
  fi
  if [ -f "$DB" ]; then
    ROWS="$(agmsg_sqlite -separator $'\x1f' "$DB" "
      SELECT id, created_at, team, from_agent, to_agent,
             replace(replace(body, char(13), ''), char(10), '\\n')
      FROM messages
      WHERE id > $LAST AND ($WHERE_PAIRS)
      ORDER BY id;
    " 2>/dev/null || true)"

    if [ -n "$ROWS" ]; then
      while IFS=$'\x1f' read -r id ts team from to body; do
        [ -z "$id" ] && continue
        # Control message: a leader's `despawn` sends `ctrl:despawn` to this
        # role. Tear ourselves down rather than printing it — drop the role
        # (releases the lock + registration) then close our own tmux pane,
        # which also ends the agent CLI sharing it. Deterministic teardown, no
        # dependence on the agent LLM noticing the message. See #109.
        if [ "$body" = "ctrl:despawn" ]; then
          LAST="$id"; persist_watermark
          # Only an EXCLUSIVE watcher dedicated to exactly this role tears
          # itself down. A broad-subscription watcher (e.g. a leader whose
          # default watcher subscribes to every project role, including the
          # despawn target) must NOT act on it — its $TMUX_PANE is the leader's
          # own pane, so killing it would take down the leader's session. The
          # spawned member's watcher runs in actas mode (ACTIVE_NAME=$to) in its
          # own pane; that's the one meant to respond. See #109.
          if [ -z "$ACTIVE_NAME" ] || [ "$to" != "$ACTIVE_NAME" ]; then
            continue
          fi
          "$SCRIPT_DIR/reset.sh" "$PROJECT_PATH" "$AGENT_TYPE" "$to" "$SESSION_ID" >/dev/null 2>&1 || true
          if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
            tmux kill-pane -t "$TMUX_PANE" 2>/dev/null || true
          else
            echo "agmsg watch: despawned '$to' (role dropped); close this window manually" >&2
          fi
          exit 0
        fi
        if ! printf '%s | %s | %s → %s | %s\n' "$ts" "$team" "$from" "$to" "$body"; then
          cleanup
          exit 0
        fi
        LAST="$id"
        persist_watermark
      done <<< "$ROWS"
    fi
  fi

  # Run sleep in the background and `wait` for it so signal traps fire
  # immediately. Bash defers traps while a foreground builtin like `sleep`
  # is blocking, which would otherwise delay shutdown by up to $INTERVAL.
  sleep "$INTERVAL" &
  wait $! 2>/dev/null
done
