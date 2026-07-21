#!/usr/bin/env bash
set -u
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

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
#   - Inbox and monitor share the driver's persistent per-(team,agent) read
#     cursor. A restart resumes from consumed state, and a fresh watcher delivers
#     existing unread messages instead of jumping over them. See ADR 0008.
#   - Polls the SQLite DB at AGMSG_WATCH_INTERVAL seconds (default 5, also
#     overridable via the delivery.monitor.poll_interval config key).
#   - Emits one line per new message:
#         <ts> | <team> | <from> → <to> | <body>
#     Newlines in body are escaped to literal "\n" so each message stays a
#     single line — easier for Monitor to deliver as one event.
#   - Writes a pidfile at ~/.agents/agmsg/run/watch.<session_id>.pid and
#     removes it on EXIT / SIGTERM / SIGINT.

# session_id is normally baked into the launch command (CLAUDE_CODE_SESSION_ID /
# GROK_SESSION_ID). An empty first arg is tolerated and resolved below (after the
# libs are sourced) rather than failing hard, so a runtime that cannot bake one
# in — notably Grok Build's `monitor` tool, where "$GROK_SESSION_ID" expands to
# empty — still starts the watcher. project_path and agent_type are required.
SESSION_ID="${1:-}"
PROJECT_PATH="${2:?Missing project_path}"
AGENT_TYPE="${3:?Missing agent_type}"
ACTIVE_NAME="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

# Resolve a session id when the launcher could not bake one in (empty first arg).
# Grok Build's `monitor` tool runs the watcher with $GROK_SESSION_ID unset, so
# neither the env var nor the instance-id ppid walk (it keys on the claude/codex
# agent binaries) yields grok's session. Bind to a composite "<session_id>.<grok
# _pid>" instead — keyed this way the watermark/pidfile are stable across watcher
# relaunches (no replay gap) and liveness-gated on the grok pid, so the watcher
# self-exits once grok dies rather than lingering as a bare-id orphan (#245).
# agmsg_grok_instance_id handles both `grok --resume <id>` and a fresh `grok`
# (no --resume). Fall back to a throwaway id only if no live grok is found, so the
# watcher still starts (#238). Uses the raw project path the watcher was launched
# with, before agmsg_resolve_project rewrites it, to match grok's session dir.
if [ -z "$SESSION_ID" ]; then
  case "$AGENT_TYPE" in
    grok-build)
      SESSION_ID="$(agmsg_grok_instance_id "$PROJECT_PATH" 2>/dev/null || true)"
      # A fresh grok watcher reaps bare-id grok watchers left behind by older
      # (pre-composite) versions whose grok has since exited (#245). Specific-PID
      # kill only — never a pattern kill.
      agmsg_reap_orphan_grok_watchers "$PROJECT_PATH" "$$" 2>/dev/null || true
      ;;
  esac
  [ -z "$SESSION_ID" ] && SESSION_ID="agmsg-$(compat_uuidgen | tr 'A-Z' 'a-z')"
fi

# Resolve the session's real project root (see #92). The actas/drop/ensure-
# monitor flows relaunch this watcher with a raw "$(pwd)"; without resolution a
# watcher started from a subdir/worktree finds no registration and exits, so
# actas would switch the from-line yet silently kill the receive side. A
# detached watcher (no agent process to walk to) degrades to the ancestor /
# git-common-dir signals, which still recover the nested/worktree cases.
PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

# Disambiguate parallel --continue/--resume sessions that share a session_id
# (#93). All per-process state below — pidfile, actas owner, ready
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
    prev_cmd=$(compat_get_cmdline "$prev_pid" 2>/dev/null || true)
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

# The read frontier lives in the storage driver, once per (team,agent). Core
# never compares its opaque local-position component. Each pair is scanned and
# consumed independently so a broad watcher cannot advance one role merely by
# delivering another role's traffic.

# DB-open healthcheck (#197). The main loop guards every query with
# `2>/dev/null || true`, so when sqlite3 cannot open the store the watcher keeps
# spinning and silently delivers nothing — a silent outage. The native
# sqlite3.exe / Git Bash path mismatch behind #197 is one trigger (now fixed in
# agmsg_db_path), but permissions, a missing binary, or a corrupt file fail the
# same way. A *missing* DB file is normal (no messages sent yet), so only flag
# the case where the file exists but a trivial query cannot run: emit one line
# on stdout (the Monitor event stream) and exit, turning the silent failure into
# a visible one. Done before the ready sentinel so we never signal "ready" for a
# watcher that cannot read the store.
if [ -f "$DB" ] && ! agmsg_sqlite "$DB" "SELECT 1;" >/dev/null 2>&1; then
  echo "ERROR: cannot open message DB $DB"
  exit 1
fi

# Signal readiness. Once the subscription is resolved and the watcher is live,
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
  if storage_store_exists; then
    while IFS=$'\t' read -r pair_team pair_agent; do
      [ -z "$pair_team" ] && continue
      READ_CURSOR="$(storage_read_cursor_get "$pair_team" "$pair_agent" 2>/dev/null || true)"
      [ -n "$READ_CURSOR" ] || READ_CURSOR=0
      OUT="$(storage_watch_after "$READ_CURSOR" "$pair_team:$pair_agent" 2>/dev/null || true)"
      if [ -n "$OUT" ]; then
      _arr="[$(printf '%s' "$OUT" | paste -sd, -)]"
      ROWS="$(agmsg_sqlite ':memory:' "
        SELECT COALESCE(json_extract(value,'\$.type'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.id'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.at'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.team'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.from'),'') || char(31) ||
               COALESCE(json_extract(value,'\$.to'),'') || char(31) ||
               replace(replace(replace(COALESCE(json_extract(value,'\$.body'),''), char(13), ''), char(10), '\\n'), char(9), '\t') || char(31) ||
               COALESCE(json_extract(value,'\$.cursor'),'')
        FROM json_each('$(printf '%s' "$_arr" | sed "s/'/''/g")');
      " 2>/dev/null || true)"

      FINAL_CURSOR=""
      DELIVERED_IDS=()
      DESPAWN_TARGET=""
      while IFS=$'\x1f' read -r kind id ts team from to body cursor; do
        [ -z "$kind" ] && continue
        if [ "$kind" = "cursor" ]; then
          FINAL_CURSOR="$cursor"
          continue
        fi
        [ "$kind" = "message_sent" ] || continue
        [ -z "$id" ] && continue
        # Control message: a leader's `despawn` sends `ctrl:despawn` to this
        # role. Tear ourselves down rather than printing it — drop the role
        # (releases the lock + registration) then close our own tmux pane,
        # which also ends the agent CLI sharing it. Deterministic teardown, no
        # dependence on the agent LLM noticing the message. See #109.
        if [ "$body" = "ctrl:despawn" ]; then
          DELIVERED_IDS+=("$id")
          # Only an EXCLUSIVE watcher dedicated to exactly this role tears
          # itself down. A broad-subscription watcher (e.g. a leader whose
          # default watcher subscribes to every project role, including the
          # despawn target) must NOT act on it — its $TMUX_PANE is the leader's
          # own pane, so killing it would take down the leader's session. The
          # spawned member's watcher runs in actas mode (ACTIVE_NAME=$to) in its
          # own pane; that's the one meant to respond. A broad watcher `continue`s
          # and consumes the control row without acting. An exclusive target
          # consumes the complete scanned batch before teardown.
          if [ -z "$ACTIVE_NAME" ] || [ "$to" != "$ACTIVE_NAME" ]; then
            continue
          fi
          DESPAWN_TARGET="$to"
          continue
        fi
        if ! printf '%s | %s | %s → %s | %s\n' "$ts" "$team" "$from" "$to" "$body"; then
          cleanup
          exit 0
        fi
        DELIVERED_IDS+=("$id")
      done <<< "$ROWS"
      if [ -n "$FINAL_CURSOR" ]; then
        storage_read_cursor_consume "$pair_team" "$pair_agent" "$FINAL_CURSOR" \
          "${DELIVERED_IDS[@]}" >/dev/null 2>&1 || true
      fi
      if [ -n "$DESPAWN_TARGET" ]; then
        "$SCRIPT_DIR/reset.sh" "$PROJECT_PATH" "$AGENT_TYPE" "$DESPAWN_TARGET" "$SESSION_ID" >/dev/null 2>&1 || true
        if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
          tmux kill-pane -t "$TMUX_PANE" 2>/dev/null || true
        else
          echo "agmsg watch: despawned '$DESPAWN_TARGET' (role dropped); close this window manually" >&2
        fi
        exit 0
      fi
      fi
    done <<< "$PAIRS"
  fi

  # Run sleep in the background and `wait` for it so signal traps fire
  # immediately. Bash defers traps while a foreground builtin like `sleep`
  # is blocking, which would otherwise delay shutdown by up to $INTERVAL.
  sleep "$INTERVAL" &
  wait $! 2>/dev/null
done
