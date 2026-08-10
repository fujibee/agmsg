#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "$0")" && pwd)/lib/compat.sh"

# Check inbox across all teams with cooldown. Skips if last check was < 60 seconds ago.
# Usage: check-inbox.sh <type> <project_path>

TYPE="${1:?Usage: check-inbox.sh <type> <project_path>}"
PROJECT="${2:?Missing project_path}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
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
# unconditionally there blocks waiting for input. The `[ ! -t 0 ]` guard just below
# only rules out that TTY case -- a non-TTY stdin whose write end is left
# open (a hook runtime that writes the payload and then simply never closes
# the pipe) still leaves this `cat` waiting for an EOF that never arrives.
# Stop/turn hooks run synchronously, so a `cat` stuck here freezes the whole
# agent pane until the user kills it. Bound the read; a runtime that forgets
# to close its pipe still gets its payload delivered (it's already sitting in
# the command substitution buffer by the time the deadline fires), just a few
# seconds late instead of never. Fails open when `timeout` isn't on PATH
# (stock macOS) -- same unbounded read as before, no regression there. #381
INPUT=""
if [ ! -t 0 ]; then
  if command -v timeout >/dev/null 2>&1; then
    INPUT=$(timeout "${AGMSG_HOOK_STDIN_TIMEOUT:-2}" cat 2>/dev/null || true)
  else
    INPUT=$(cat 2>/dev/null || true)
  fi
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
SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID=$(printf '%s' "$INPUT" \
  | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  | head -1)
[ -z "$SESSION_ID" ] && SESSION_ID="${GROK_SESSION_ID:-}"
if [ -n "$SESSION_ID" ]; then
  # The monitor watcher keys its pidfile (and its actas owner, below) on the
  # per-process instance id (#93), not the bare session_id. Normalize to the
  # same token so this Stop-hook defers to a live watcher in `both` mode instead
  # of double-delivering.
  SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"
  PIDFILE="$SKILL_DIR/run/watch.$SESSION_ID.pid"
  if [ -f "$PIDFILE" ]; then
    WATCH_PID=$(cat "$PIDFILE" 2>/dev/null || true)
    # _agmsg_pid_alive_local: EPERM-aware, so a sandbox-unsignalable watcher is
    # still alive -- and it does not ask tasklist, which cannot see a pid watch.sh
    # minted from its own $$ (#567).
    if [ -n "$WATCH_PID" ] && _agmsg_pid_alive_local "$WATCH_PID"; then
      exit 0
    fi
  fi
fi

# Identify agent and teams
WHOAMI=$("$SCRIPT_DIR/whoami.sh" "$PROJECT" "$TYPE")
# suggest=true means this identity is registered only under a DIFFERENT
# project, so it is not joined here -> deliver nothing (mirror not_joined).
# Without this the else-branch extracts "agents=" as the agent name.
if echo "$WHOAMI" | grep -Eq "not_joined=true|suggest=true"; then
  exit 0
fi

# Handle multiple identities: use first agent name
if echo "$WHOAMI" | grep -q "multiple=true"; then
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agents=\([^,]*\).*/\1/p')
else
  # Anchor on a leading "agent=" so "agents=" (multiple/suggest) cannot match.
  AGENT=$(echo "$WHOAMI" | sed -n 's/^agent=\([^ ]*\).*/\1/p')
fi
TEAMS=$(echo "$WHOAMI" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')

if [ -z "$AGENT" ] || [ -z "$TEAMS" ]; then
  exit 0
fi

# Cooldown check. The marker is hook runtime state, not message storage, so it
# lives in the skill's run dir — independent of AGMSG_STORAGE_PATH. Keeping it
# out of the store means an overridden/sandboxed store still gets delivery even
# when the default db dir doesn't exist.
MARKER="$SKILL_DIR/run/.lastcheck-$AGENT"

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

# Check for unread messages and mark as read
DB="$(agmsg_db_path)"
if [ ! -f "$DB" ]; then exit 0; fi

_agmsg_sqlesc() { printf %s "$1" | sed "s/'/''/g"; }
AGENT_SQL="$(_agmsg_sqlesc "$AGENT")"

OUTPUT=""
# Messages are marked read per team INSIDE this loop, but emitted only AFTER
# it. Under errexit, a failure while processing a later team (either command
# substitution below) would abort between those two points: earlier teams'
# messages end up read_at-stamped yet never delivered, and never re-offered
# (#637). So loop failures stop the loop instead of the script — whatever was
# already accumulated still reaches an emit point, teams after the failing one
# stay untouched (unread), and the failure status is re-raised on exit.
CLAIM_RC=0
CLAIM_FAILED_TEAM=""
IFS=',' read -ra TEAM_LIST <<< "$TEAMS"
for team in "${TEAM_LIST[@]}"; do
  team_sql="$(_agmsg_sqlesc "$team")"
  # Honor actas exclusivity locks. If (team, AGENT) is currently held by
  # another live session, that session is the owner of that role's inbox —
  # don't deliver here. Mirrors the per-pair filtering watch.sh does for
  # CC sessions (#62), giving Stop-hook delivery (codex / claude-code
  # turn-mode) the same "respect peer locks" guarantee.
  #
  # Note: AGENT comes from whoami.sh, which returns the first registered
  # agent for (project, type). It is NOT the session's in-memory actas
  # role. That asymmetry is the Codex caveat documented in README — if a
  # Codex session actas'd into <name>, check-inbox is still polling
  # whatever whoami chose first, not <name>.
  state=$(actas_lock_state "$team" "$AGENT" "${SESSION_ID:-}") || { CLAIM_RC=$?; CLAIM_FAILED_TEAM="$team"; break; }
  case "$state" in
    other:*) continue ;;
  esac

  RESULT=$(agmsg_sqlite "$DB" "
    SELECT id || char(31) || from_agent || char(31) || replace(replace(body, char(10), '\n'), char(9), '\t') || char(31) || created_at
    FROM messages WHERE team='$team_sql' AND to_agent='$AGENT_SQL' AND read_at IS NULL
    ORDER BY created_at ASC;
  ") || { CLAIM_RC=$?; CLAIM_FAILED_TEAM="$team"; break; }
  if [ -n "$RESULT" ]; then
    COUNT=$(echo "$RESULT" | wc -l | tr -d ' ')
    OUTPUT+="$COUNT new message(s) in $team:"$'\n'
    IDS=""
    while IFS=$'\x1f' read -r id from body ts; do
      OUTPUT+="  [$ts] $from: $body"$'\n'
      case "$id" in
        ''|*[!0-9]*) ;; # defensive: never splice a non-numeric value into SQL
        *) IDS="${IDS:+$IDS,}$id" ;;
      esac
    done <<< "$RESULT"
    OUTPUT+=$'\n'
    # Test seam: a two-file barrier that lets the race regression test land a
    # message deterministically between display and mark. No-op unless set.
    if [ -n "${AGMSG_TEST_MARK_BARRIER:-}" ]; then
      : > "$AGMSG_TEST_MARK_BARRIER.reached"
      _agmsg_barrier_waited=0
      while [ ! -e "$AGMSG_TEST_MARK_BARRIER.release" ]; do
        sleep 0.05
        _agmsg_barrier_waited=$((_agmsg_barrier_waited + 1))
        [ "$_agmsg_barrier_waited" -ge 200 ] && break # 10s safety cap
      done
    fi
    # Mark as read — only the ids captured above, so a message that arrives
    # between the SELECT and this UPDATE is not marked read unseen.
    if [ -n "$IDS" ]; then
      agmsg_sqlite "$DB" "UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ','now') WHERE id IN ($IDS);" 2>/dev/null || true
    fi
  fi
done

# The two emit points are NOT the same case, and treating them alike is what
# lost messages.
#
# Nothing was accumulated: there is no delivery to protect, so the exit status
# is free to carry the failure — and it must, because "no new messages" would
# claim something this run never established. That is the half of #637 the
# original comment here was right about, and it is unchanged.
#
# The status line is emitted only when the poll actually completed. Printing
# "no new messages" and then exiting non-zero states something untrue on a
# channel that is about to be discarded anyway.
if [ -z "$OUTPUT" ]; then
  [ "$CLAIM_RC" -eq 0 ] || exit "$CLAIM_RC"
  emit_status_json "agmsg: no new messages"
  exit 0
fi

# New messages found.
#
# This is the delivering path, and the rows above were marked read INSIDE the
# loop before we got here. The documented hook contract is that stdout is read
# as control JSON only on exit 0. Measured (Claude Code 2.1.226, one-shot
# `claude -p`, a synthetic probe hook -- not this script, not an interactive
# session): the stdout control JSON was processed on exit 0, 1, 2, and 3 alike.
# So this codebase currently depends on an area where the documented contract
# and the observed implementation disagree -- see
# https://github.com/fujibee/agmsg/issues/658 for the measurement.
#
# This fix is correct either way, which is why it doesn't bet on which
# behavior is real: if a runtime DOES discard stdout on non-zero exit (as
# documented), leaving the old `exit "$CLAIM_RC"` here would throw away the
# payload that already cost these rows their unread state -- consumed and
# never shown, worse than the failure this status was meant to protect
# against. If a runtime does NOT discard it (as measured here), the old
# non-zero exit was not needed to preserve the delivery or report the
# partial failure, because the payload already carries both.
# Exiting 0 unconditionally on this path is safe under both, so delivery and
# the report are separated: the messages go out with exit 0, and the partial
# failure is stated inside the payload the operator actually reads. Nothing
# upstream mistakes a partial poll for a complete one, because the text says
# which team stopped it and that the rest are still unread.
if [ -n "$OUTPUT" ]; then
  if [ "$CLAIM_RC" -ne 0 ]; then
    OUTPUT+="agmsg: this poll stopped early — team '$CLAIM_FAILED_TEAM' could not be read (status $CLAIM_RC)."$'\n'
    OUTPUT+="agmsg: teams after it were not checked; their messages stay unread and will be offered again."$'\n'
  fi
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
