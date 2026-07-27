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

# session_id is normally baked into the launch command (CLAUDE_CODE_SESSION_ID /
# GROK_SESSION_ID). An empty first arg is tolerated and resolved below (after the
# libs are sourced) rather than failing hard, so a runtime that cannot bake one
# in — notably Grok Build's `monitor` tool, where "$GROK_SESSION_ID" expands to
# empty — still starts the watcher. A literal `-` first arg is the caller-side
# sentinel for the same "no session id" case: some launcher shells re-evaluate
# the command line and DROP a quoted-but-empty argument entirely (shifting every
# later argument one slot left), so command templates pass
# "${GROK_SESSION_ID:--}" and `-` is folded into the empty-arg path here.
# project_path and agent_type are required.
SESSION_ID="${1:-}"
[ "$SESSION_ID" = "-" ] && SESSION_ID=""
PROJECT_PATH="${2:-}"
AGENT_TYPE="${3:-}"
ACTIVE_NAME="${4:-}"

# Missing required args fail on STDOUT, not via ${n:?}: bash prints the :?
# message to stderr, which the monitor tool consuming this stream never
# surfaces — the launch would die invisibly. A short arg list is also how a
# shifted three-argument launch (no active_name; empty session id dropped by
# the caller shell, see above) presents, so name that cause here too.
if [ -z "$PROJECT_PATH" ] || [ -z "$AGENT_TYPE" ]; then
  echo "ERROR: watch.sh needs <session_id> <project_path> <agent_type> [active_name]; got $# argument(s). A caller shell may have dropped an empty session_id argument and shifted the rest. Pass the sentinel '-' (e.g. \"\${GROK_SESSION_ID:--}\") instead of an empty string."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

# Fail loudly on an unknown agent_type instead of running with zero
# subscriptions. The dominant real-world cause is a shifted argument list: a
# launcher shell that drops an empty first argument (see the session_id note
# above) makes project_path land in $2 and agent_type receive whatever was in
# $4 — typically an agent/role name. identities.sh then resolves nothing and,
# without this guard, the watcher keeps polling forever while delivering
# nothing: a silent zero-subscription outage that looks alive from the
# outside. Same shape as the DB-open healthcheck (#197): one loud line on
# stdout (the monitor event stream), then exit.
#
# Hot path stays free: a built-in type is confirmed by a single manifest stat.
# A name with '/' or '..' is rejected outright — it is never a type name, and
# letting it reach the registry would concatenate it into a filesystem path
# (e.g. '../types/claude-code' would resolve to a builtin manifest and pass).
# Only a legitimate non-builtin name pays for the registry (trusted external
# plugins can add types), and the full type enumeration runs only in the
# error message.
case "$AGENT_TYPE" in
  */*|*..*)
    echo "ERROR: invalid agent type '$AGENT_TYPE' (type names never contain '/' or '..'). Arguments may have shifted: a caller shell can drop an empty session_id argument entirely. Pass the sentinel '-' (e.g. \"\${GROK_SESSION_ID:--}\") instead of an empty string."
    exit 1
    ;;
esac
if [ ! -f "$SCRIPT_DIR/drivers/types/$AGENT_TYPE/type.conf" ]; then
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/lib/type-registry.sh"
  if ! agmsg_type_dir "$AGENT_TYPE" >/dev/null 2>&1; then
    echo "ERROR: unknown agent type '$AGENT_TYPE' (supported: $(agmsg_known_types | sort -u | paste -sd, - | sed 's/,/, /g')). Arguments may have shifted: a caller shell can drop an empty session_id argument entirely. Pass the sentinel '-' (e.g. \"\${GROK_SESSION_ID:--}\") instead of an empty string."
    exit 1
  fi
fi

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
# When ps is unavailable (e.g. Claude Code sandbox), fall back to _agmsg_pid_alive
# which confirms the pid is alive but cannot validate the cmdline. It is EPERM-aware
# so a live-but-unsignalable sibling watcher isn't misread as dead and left running.
if [ -f "$PIDFILE" ]; then
  prev_pid=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$prev_pid" ] && [ "$prev_pid" != "$$" ] && _agmsg_pid_alive "$prev_pid"; then
    prev_cmd=$(compat_get_cmdline "$prev_pid" 2>/dev/null || true)
    if [ -n "$prev_cmd" ]; then
      case "$prev_cmd" in
        *"$SKILL_DIR/scripts/watch.sh"*) kill "$prev_pid" 2>/dev/null || true ;;
      esac
    else
      # ps unavailable (sandboxed) — skip cmdline validation, rely on the
      # _agmsg_pid_alive check above
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

# Mark a row's read_at so a later inbox.sh call does not re-surface it as
# unread — the watermark only stops THIS watcher from re-streaming a row, it
# never touches read_at (see the call sites below for the full rationale).
# Shared by both the normal delivery path and the ctrl:despawn control-row
# path so the two do not drift (#review finding, 2026-07-19). $1 is trusted
# to be a DB-sourced id everywhere this is called, but it is guarded anyway
# (matches inbox.sh's own defensive stance) since it is interpolated into SQL.
#
# $2/$3 (team, to) scope this to the DEFINITIVE receiver for that role:
#   - an exclusive watcher (ACTIVE_NAME set) only marks its own role's rows.
#   - a broad watcher (ACTIVE_NAME empty) subscribes to every registered role
#     in the project (see PAIRS above), so without this guard it would also
#     mark read_at for a role that has its OWN exclusive watcher — e.g. a
#     leader's default SessionStart watcher racing/clobbering the read state
#     an actas'd member's exclusive watcher is responsible for. Skip when an
#     exclusive ready sentinel for (team, to) exists; that role's own watcher
#     owns the read state (review finding, 2026-07-19).
#
# Note: this is a best-effort mark on local write success, not a delivery ack
# — there is no protocol to confirm the downstream Monitor reader actually
# consumed the line (a pipe write can succeed into a kernel buffer even if the
# reader is about to exit). A stronger guarantee needs the claim/ack redesign
# tracked in #373; out of scope for this fix (review finding, 2026-07-19).
mark_read() {
  local mid="$1" team="$2" to="$3"
  case "$mid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if [ -z "$ACTIVE_NAME" ] && [ -n "$team" ] && [ -n "$to" ]; then
    [ -e "$(agmsg_ready_path "$team" "$to")" ] && return 0
  fi
  agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id=$mid AND read_at IS NULL;" 2>/dev/null \
    || echo "agmsg watch: could not mark message $mid read (db busy/unavailable); a later inbox.sh call will re-surface it" >&2
}

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
          mark_read "$id" "$team" "$to"
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
          # Read the placement record BEFORE reset.sh. reset.sh releases the
          # actas lock, and the leader's despawn deletes the record as soon as
          # it observes that lock go free — so reading it afterwards races the
          # cleanup and would intermittently see nothing.
          placed_id=""
          spawn_rec="$(agmsg_spawn_path "$team" "$to")"
          [ -f "$spawn_rec" ] && IFS=$'\t' read -r placed_id _ _ < "$spawn_rec"
          "$SCRIPT_DIR/reset.sh" "$PROJECT_PATH" "$AGENT_TYPE" "$to" "$SESSION_ID" >/dev/null 2>&1 || true
          if [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1; then
            tmux kill-pane -t "$TMUX_PANE" 2>/dev/null || true
          # Closing a herdr pane needs more than "a pane id is in the
          # environment". HERDR_* is inherited by every descendant of a herdr
          # pane, so a watcher merely STARTED inside one — a developer running
          # the test suite, or any agent that actas'd by hand — carries the
          # HOST pane's id. Acting on that closes the host. Require both the
          # full herdr environment (matching spawn's own detection) and proof
          # that agmsg itself placed this pane: the recorded placement for this
          # (team, agent) must name exactly the pane we are sitting in.
          # Otherwise fall through to the manual branch. This is the herdr
          # counterpart of the tmux path's ACTIVE_NAME gating (#109).
          elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ] \
               && [ "$placed_id" = "herdr:$HERDR_PANE_ID" ] \
               && command -v herdr >/dev/null 2>&1; then
            herdr pane close "$HERDR_PANE_ID" 2>/dev/null || true
          else
            echo "agmsg watch: despawned '$to' (role dropped); close this window manually" >&2
          fi
          exit 0
        fi
        if ! printf '%s | %s | %s → %s | %s\n' "$ts" "$team" "$from" "$to" "$body"; then
          cleanup
          exit 0
        fi
        # Mark delivered so a later inbox.sh call (e.g. a respawned/resumed
        # session's actas re-registration) does not re-surface this message as
        # unread. Without this, every message ever streamed live stays
        # read_at IS NULL forever, and a single inbox.sh call replays the
        # entire history as "new".
        mark_read "$id" "$team" "$to"
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
