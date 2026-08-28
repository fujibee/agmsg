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

# Which hook event fired. The Stop entry runs `check-inbox.sh <type> <project>`
# (EVENT defaults to Stop); the mid-turn PostToolUse entry (#1003) appends the
# event as a 3rd arg so this script emits the shape that event's runtime accepts,
# without branching on the type name.
EVENT="${3:-Stop}"

# Some Stop-hook runtimes (codex, copilot) want an explicit JSON status object
# even when there is nothing to deliver; others (claude-code) stay silent. This
# is the type's manifest `stop_output=` (data), not a hardcoded type list.
STOP_OUTPUT="$(agmsg_type_get "$TYPE" stop_output 2>/dev/null || true)"
# The wire shape for a PostToolUse payload, from the type manifest (#1003) — the
# same data-driven approach as stop_output. Measured on codex-cli 0.149.1:
# hookSpecificOutput. An unknown/unset value emits nothing rather than a guess.
POSTTOOL_OUTPUT="$(agmsg_type_get "$TYPE" posttooluse_output 2>/dev/null || true)"

# Status (nothing-to-deliver / cooldown) output. For PostToolUse this stays
# SILENT: codex 0.149.1 treats malformed post-tool-use JSON as a failure, and an
# empty additionalContext on every tool call would be pure noise — so a no-op
# turn emits no bytes, which every runtime reads as "hook did nothing".
emit_status_json() {
  [ "$EVENT" = "PostToolUse" ] && return 0
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

# The session id is still resolved: the actas-ownership check further down
# needs it. Only the deferral that used to follow it is gone. The field name
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
# Normalized to the per-process instance id (#93), which is the token the
# actas owner file is keyed on.
[ -n "$SESSION_ID" ] && SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"

# No deferral to a live watcher (#694).
#
# This used to exit here whenever a watcher process was alive for this session,
# to avoid double delivery in `both` mode. The condition was LIVENESS, and the
# failure `both` exists for preserves liveness exactly: a watcher that is alive
# and delivering nothing. So the one mode advertised as a safety net stood down
# in front of the one situation it was wanted for. On 2026-08-08 a session with
# a broken watcher was switched to `both` to recover delivery and nothing
# changed; what worked was `mode turn`, which stops the watcher, which removes
# the liveness signal, which lets this hook run.
#
# Removing it does not double-deliver, and that is measured rather than
# assumed. Both sides consume through the same state:
#
#   watcher      storage_read_cursor_consume -> inserts a `message_read` event
#                per delivered id AND advances read_cursors.local_position
#   this hook    storage_list_unread -> excludes rows at or below that cursor
#                AND rows with a `message_read` event
#
# So a message the watcher has emitted is not offered here. The remaining
# window is an interleave: this hook SELECTs, the watcher emits and consumes
# the same row, then this hook marks it read. Bounded by one poll interval, and
# the trade is explicit -- a rare duplicate line against a mode that silently
# delivered nothing at all.
#
# Deferral was an optimisation, not a correctness requirement. The read state
# is the correctness requirement, and it was already there.

# Resolve the invocation path to the registered project root (session marker /
# nearest ancestor / sibling worktree) before the identity lookup — the
# whoami.sh path did this resolution, and identities.sh itself is an exact
# registry lookup by design (its other callers rely on that).
PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"

# Consume exact (team, agent) TSV rows instead of independently flattened
# agent/team lists. For multiple agents, preserve the existing first-agent
# policy, but subscribe only to that agent's actual team rows.
IDENTITIES=$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE")
[ -n "$IDENTITIES" ] || exit 0

AGENT=""
TEAM_LIST=()
IDENTITIES_VALID=1
while IFS=$'\t' read -r identity_team identity_agent identity_extra; do
  if [ -z "$identity_team" ] || [ -z "$identity_agent" ] || [ -n "$identity_extra" ]; then
    IDENTITIES_VALID=0
    break
  fi

  [ -n "$AGENT" ] || AGENT="$identity_agent"
  [ "$identity_agent" = "$AGENT" ] || continue

  team_seen=0
  # ${arr[@]+...} guards the empty-array expansion: under `set -u` bash 3.2
  # (macOS default) treats "${TEAM_LIST[@]}" on an empty array as unbound.
  for selected_team in ${TEAM_LIST[@]+"${TEAM_LIST[@]}"}; do
    if [ "$selected_team" = "$identity_team" ]; then
      team_seen=1
      break
    fi
  done
  [ "$team_seen" -eq 1 ] || TEAM_LIST+=("$identity_team")
done <<< "$IDENTITIES"

if [ "$IDENTITIES_VALID" -ne 1 ] || [ -z "$AGENT" ] || [ "${#TEAM_LIST[@]}" -eq 0 ]; then
  exit 0
fi

# Cooldown check. The marker is hook runtime state, not message storage, so it
# lives in the skill's run dir — independent of AGMSG_STORAGE_PATH. Keeping it
# out of the store means an overridden/sandboxed store still gets delivery even
# when the default db dir doesn't exist.
#
# PostToolUse (#1003) uses a SEPARATE marker so the two events' cooldowns do not
# bind. This event is the UNVERIFIED path (model receipt of its output is not
# observed), and it must not be able to suppress the verified Stop path: if they
# shared one marker, a PostToolUse poll would record the cooldown and the very
# next Stop would exit at the gate without delivering. Its own marker bounds the
# per-tool-call cost to one read/minute without touching Stop's. (This one value
# was answering two questions — the same shape reviews keep flagging.)
if [ "$EVENT" = "PostToolUse" ]; then
  MARKER="$SKILL_DIR/run/.lastcheck-$AGENT.posttooluse"
else
  MARKER="$SKILL_DIR/run/.lastcheck-$AGENT"
fi

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

# Check for unread messages and mark as read. Ask the active driver whether a
# store exists (driver-level, works for jsonl too) — don't create one on a poll.
# The check is per team, inside the loop below: a store is selected per team
# now, so "this team has no store yet" is a normal state, and answering it
# once for the whole process would silently stop delivery for every OTHER
# team the moment one of them was uninitialized.
agmsg_storage_load

# Messages are marked read inside this loop; the whole batch is emitted after
# it. Under `set -e` an unguarded command substitution ends the script the
# moment it fails -- and a failure while processing a LATER team lands after
# an EARLIER team's rows were already stamped read_at, before either emit
# point. Those messages are read, undelivered, and never offered again.
# Measured on 8a2fe623: first_deliveries=0 first_read=1 second_unread=1 rc=5.
#
# So a failure stops the loop instead of ending the script, and what was
# already accumulated is delivered.
#
# The failure is reported IN THE PAYLOAD, not by the exit status. The documented
# contract is that stdout is read as control JSON only on exit 0 -- and the
# measurement disagrees with it (see the emit points below, and #658). Either
# way this is the safe shape: if a runtime does discard on non-zero, exiting
# non-zero here throws away a payload whose rows are already marked read, which
# is what the first attempt at this fix did on exactly the path that was broken.
# When there are messages to hand over the status is 0 and the text says the
# poll was partial; only when there is nothing to deliver does the status carry
# the failure.
OUTPUT=""
LOOP_RC=0
LOOP_FAILED_TEAM=""
for team in "${TEAM_LIST[@]}"; do
  storage_store_exists "$team" || continue

  # ONE guarded boundary for everything that reads or formats — and it must NOT
  # be invoked from a condition context.
  #
  # `RESULT=$(...) || _rc=$?` looks equivalent and is not. Putting the
  # substitution on the left of `||` makes the whole thing a tested command, and
  # errexit is then suppressed for what runs inside it — including the `set -e`
  # the subshell sets for itself. Measured: storage_init returned 13,
  # storage_list_unread carried on regardless, the assignment landed empty and
  # SUCCEEDED, and the `[ -n "" ] || exit 98` two lines later became the
  # subshell's status. A backend failure arrived at the caller as "this team has
  # no unread messages", and the poll reported a clean turn.
  #
  # A single non-conditional assignment with errexit lifted around it does not
  # have that property: the subshell's own `set -e` aborts at the first failure
  # and its status is what `$?` holds. The lift is two lines wide and restored
  # immediately.
  #
  # This is also why the failing operations are not listed with `|| return`
  # inside: an enumeration is short by one the next time an operation is added,
  # which is the defect this file exists to fix.
  #
  # The first attempt listed the substitutions and guarded each -- and missed
  # one (`_arr`), which is the whole failure mode this file is about: an
  # enumeration is short by one and the one it is short by is the defect. A
  # subshell with its own errexit does not need the list. Anything in here that
  # fails ends the subshell, and its status is read from `$?` below instead of
  # ending the script.
  #
  # 97 and 98 are the two ordinary reasons to skip a team, carried as statuses
  # because a subshell cannot `continue` its caller's loop.
  set +e
  RESULT=$(
    set -euo pipefail
    # Honor actas exclusivity locks. If (team, AGENT) is held by another live
    # session, that session owns that role's inbox — don't deliver here.
    # Mirrors watch.sh's per-pair filtering (#62).
    #
    # AGENT comes from identities.sh: the first registered agent for
    # (project, type), NOT the session's in-memory actas role — the Codex
    # caveat documented in README.
    state=$(actas_lock_state "$team" "$AGENT" "${SESSION_ID:-}")
    # The leading `(` is load-bearing, not style. bash 3.2 -- which is /bin/bash
    # on macOS, and what the macOS CI jobs run -- scans `$( ... )` for its
    # closing paren without understanding `case`, so an unbalanced pattern paren
    # ends the substitution early and the `;;` that follows is a syntax error.
    # The whole file failed to parse; every check-inbox test on macOS died with
    # "syntax error near unexpected token `;;'". Balancing the paren fixes it and
    # is identical under bash 5.
    case "$state" in (other:*) exit 97 ;; esac

    # Unread via the storage facade (§2.1 storage_list_unread = events ∪ legacy),
    # JSONL parsed in one pass with sqlite's JSON funcs (no jq; cf. lib/hooks-json.sh).
    # id is kept so the mark step below targets exactly the rows shown.
    UNREAD_JSONL=$(storage_list_unread "$team" "$AGENT")
    [ -n "$UNREAD_JSONL" ] || exit 98
    # The quote is held in a variable, never written as \' in the pattern: bash 3.2
    # (macOS /bin/bash) keeps the backslash of a \' REPLACEMENT, so the inline form
    # doubles a quote into \'\' there while producing '' on bash 4+. Same shape as
    # _sqlite_sync_lit_into in sqlite-sync.sh, which documents the same hazard.
    _AGMSG_SQ="'"
    _arr="[$(printf '%s' "$UNREAD_JSONL" | paste -sd, -)]"
    agmsg_sqlite ':memory:' "
      SELECT json_extract(value,'\$.from') || char(31) ||
             replace(replace(json_extract(value,'\$.body'), char(10), '\n'), char(9), '\t') || char(31) ||
             json_extract(value,'\$.at') || char(31) ||
             json_extract(value,'\$.id')
      FROM json_each('${_arr//$_AGMSG_SQ/$_AGMSG_SQ$_AGMSG_SQ}');
    "
  )
  _rc=$?
  set -e
  case "$_rc" in
    0)     ;;
    97|98) continue ;;
    *)     LOOP_RC=$_rc; LOOP_FAILED_TEAM="$team"; break ;;
  esac

  COUNT=$(printf '%s\n' "$RESULT" | grep -c . || true)
  OUTPUT+="$COUNT new message(s) in $team:"$'\n'
  IDS=()
  while IFS=$'\x1f' read -r from body ts id; do
    [ -n "$id" ] || continue
    OUTPUT+="  [$ts] $from: $body"$'\n'
    IDS+=("$id")
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
  # Mark read via the facade (§2.1 storage_mark_read_batch): recipient-scoped,
  # idempotent; a legacy id records a message_read event without mutating the
  # legacy row (§2.4). Only the ids collected from the rows actually displayed
  # above — never a blanket match — so a message that arrives after the SELECT
  # can never be marked read unseen.
  #
  # PostToolUse (#1003) does NOT mark read: read state is consumed only by a path
  # whose delivery is verified, and this event's model receipt is not observed.
  # "displayed" here means "formatted", not "received" — so consuming here would
  # be exactly "consumed and never shown", which this file already names below as
  # worse than the failure the status reports. Mid-turn delivery is therefore
  # ADDITIVE: it may show a message earlier, but Stop still fetches, shows, and
  # consumes it as before. A duplicate display is harmless; an invisible loss is
  # not.
  if [ "$EVENT" != "PostToolUse" ] && [ "${#IDS[@]}" -gt 0 ]; then
    storage_mark_read_batch "$team" "$AGENT" "${IDS[@]}" >/dev/null 2>&1 || true
  fi
done

# The exit code cannot carry both the delivery and the failure report.
#
# The DOCUMENTED contract is that stdout is read as control JSON only on exit 0.
# MEASURED (Claude Code 2.1.226, one-shot `claude -p`, a synthetic probe hook --
# not this script, not an interactive session): the stdout control JSON was
# processed on exit 0, 1, 2 and 3 alike. So this codebase depends on an area
# where the documented contract and the observed implementation disagree; the
# measurement is on #658.
#
# This fix is correct either way, which is why it does not bet on which is real.
# If a runtime DOES discard stdout on a non-zero exit, as documented, then
# emitting the messages and then exiting non-zero throws away the payload that
# already cost these rows their unread state -- consumed and never shown, worse
# than the failure the status was meant to report. If it does NOT discard it, as
# measured, the non-zero exit was never needed to preserve the delivery or to
# report the partial failure, because the payload already carries both.
#
# Delivery and the report are separated: the messages go out with exit 0, and
# the partial failure is stated inside the payload the operator actually reads.
# Nothing upstream sees a partial poll as a complete one, because the text says
# so.
if [ -n "$OUTPUT" ]; then
  if [ "$LOOP_RC" -ne 0 ]; then
    OUTPUT+="agmsg: this poll stopped early — team '$LOOP_FAILED_TEAM' could not be read (status $LOOP_RC)."$'\n'
    OUTPUT+="agmsg: teams after it were not checked; their messages stay unread and will be offered again."$'\n'
  fi
  # Escape for JSON: backslash, double-quote, newlines, tabs (macOS/Linux compatible)
  ESCAPED=$(printf '%s' "$OUTPUT" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g' | awk '{if(NR>1) printf "\\n"; printf "%s",$0}')
  if [ "$EVENT" = "PostToolUse" ]; then
    # Mid-turn delivery (#1003). The shape is data, from the manifest — not a
    # type-name branch. codex-cli 0.149.1 requires a hookSpecificOutput object
    # (hookEventName=PostToolUse, body in additionalContext) and rejects anything
    # else as "invalid post-tool-use JSON output"; an unknown/unset shape emits
    # nothing rather than a malformed guess. Reaching the model with this is the
    # unverified part (see PR): this is the shape the 0.149.1 parser accepts.
    case "$POSTTOOL_OUTPUT" in
      hookSpecificOutput)
        printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$ESCAPED"
        ;;
      *) : ;;
    esac
  else
    cat <<ENDJSON
{
  "decision": "block",
  "reason": "$ESCAPED"
}
ENDJSON
  fi
  # Exit 0 even when the poll failed part-way: this is the delivering path, and
  # a non-zero status here throws the delivery away.
  exit 0
fi

# Nothing was accumulated. There is no delivery to protect, so the status is
# free to carry the failure — and it must, because "no new messages" here would
# claim something this run never established.
[ "$LOOP_RC" -eq 0 ] || exit "$LOOP_RC"
emit_status_json "agmsg: no new messages"
exit 0
