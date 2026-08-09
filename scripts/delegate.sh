#!/usr/bin/env bash
set -euo pipefail

# Start or continue a session-scoped conversation with another agmsg agent.
#
# Usage:
#   delegate.sh <project> <from-type> <to-type> <message>
#               [--conversation <id>] [--new] [--team <team>]
#               [--from-agent <name>] [--fresh] [--model <id>] [--no-wait]
#               [--no-delivery]

PROJECT="${1:?Usage: delegate.sh <project> <from-type> <to-type> <message> [options]}"
FROM_TYPE="${2:?Missing source agent type}"
TO_TYPE="${3:?Missing target agent type}"
MESSAGE="${4:?Missing task or question}"
shift 4

CONVERSATION=""
NEW=0
TEAM=""
FROM_AGENT=""
FRESH=0
MODEL=""
NO_WAIT=0
SESSION_ID=""
NO_DELIVERY=0

while (($#)); do
  case "$1" in
    --conversation) CONVERSATION="${2:?--conversation needs an id}"; shift 2 ;;
    --new) NEW=1; shift ;;
    --team) TEAM="${2:?--team needs a name}"; shift 2 ;;
    --from-agent) FROM_AGENT="${2:?--from-agent needs a name}"; shift 2 ;;
    --session-id)
      [ "$#" -ge 2 ] || { echo "delegate: --session-id needs an id" >&2; exit 2; }
      SESSION_ID="$2"
      shift 2
      ;;
    --fresh) FRESH=1; shift ;;
    --model) MODEL="${2:?--model needs an id}"; shift 2 ;;
    --no-wait) NO_WAIT=1; shift ;;
    --no-delivery) NO_DELIVERY=1; shift ;;
    -h|--help)
      sed -n '4,10p' "$0"
      exit 0
      ;;
    *) echo "delegate: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hash.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

agmsg_is_known_type "$FROM_TYPE" || { echo "delegate: unknown source type '$FROM_TYPE'" >&2; exit 2; }
agmsg_is_known_type "$TO_TYPE" || { echo "delegate: unknown target type '$TO_TYPE'" >&2; exit 2; }

bootstrap_args=("$PROJECT" "$FROM_TYPE")
[ "$NO_DELIVERY" -eq 1 ] && bootstrap_args+=(--no-delivery)
[ -n "$SESSION_ID" ] && bootstrap_args+=(--session-id "$SESSION_ID")
[ -n "$TEAM" ] && bootstrap_args+=(--team "$TEAM")
[ -n "$FROM_AGENT" ] && bootstrap_args+=(--agent "$FROM_AGENT")
BOOTSTRAP_OUTPUT="$("$SCRIPT_DIR/bootstrap.sh" "${bootstrap_args[@]}")"
BOOTSTRAP_LINE="$(printf '%s\n' "$BOOTSTRAP_OUTPUT" | head -n 1)"
BOOTSTRAP_EXTRA="$(printf '%s\n' "$BOOTSTRAP_OUTPUT" | sed -n '2,$p')"

read_field() {
  local key="$1" token
  for token in $BOOTSTRAP_LINE; do
    case "$token" in "$key"=*) printf '%s' "${token#*=}"; return 0 ;; esac
  done
  return 1
}

TEAM="${TEAM:-$(read_field team)}"
FROM_AGENT="${FROM_AGENT:-$(read_field agent)}"
PROJECT="$(agmsg_canonical_path "$PROJECT")"
PROJECT="$(agmsg_normalize_project_path "$PROJECT")"

short_type() {
  case "$1" in
    claude-code) printf 'claude' ;;
    grok-build) printf 'grok' ;;
    *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' ;;
  esac
}

if [ "$NEW" -eq 1 ]; then
  [ -z "$CONVERSATION" ] || { echo "delegate: --new and --conversation are mutually exclusive" >&2; exit 2; }
  CONVERSATION="conv-$(compat_uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-16)"
elif [ -z "$CONVERSATION" ]; then
  conv_hash="$(printf '%s' "$TEAM|$FROM_AGENT|$TO_TYPE" | agmsg_sha1)"
  CONVERSATION="conv-${conv_hash:0:16}"
fi

agmsg_validate_agent_name "$CONVERSATION" || exit 2
conv_hash="$(printf '%s' "$CONVERSATION" | agmsg_sha1)"
TO_AGENT="$(short_type "$TO_TYPE")-${conv_hash:0:12}"
agmsg_validate_agent_name "$TO_AGENT" || exit 2

STATE_DIR="$SKILL_DIR/run/delegations"
mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/$CONVERSATION"
LOCK="$STATE.lock"

# NOTE: serialize updates to one conversation so two callers cannot allocate
# the same generation or race a send against a replacement spawn. mkdir is the
# portable atomic primitive (macOS has no flock). The owner pid lets a later
# call reclaim a lock left by SIGKILL instead of permanently stopping the
# conversation.
acquire_conversation_lock() {
  local i=0 owner reclaim="${LOCK}.reclaim"
  while [ "$i" -lt 1000 ]; do
    if mkdir "$LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCK/owner"
      return 0
    fi
    owner="$(cat "$LOCK/owner" 2>/dev/null || true)"
    if [ -z "$owner" ] || ! _agmsg_pid_alive "$owner"; then
      if mkdir "$reclaim" 2>/dev/null; then
        owner="$(cat "$LOCK/owner" 2>/dev/null || true)"
        if [ -z "$owner" ] || ! _agmsg_pid_alive "$owner"; then
          rm -f "$LOCK/owner" 2>/dev/null || true
          rmdir "$LOCK" 2>/dev/null || true
        fi
        rmdir "$reclaim" 2>/dev/null || true
      fi
    fi
    i=$((i + 1))
    sleep 0.01
  done
  echo "delegate: timed out waiting for conversation '$CONVERSATION'" >&2
  return 1
}

release_conversation_lock() {
  local owner
  owner="$(cat "$LOCK/owner" 2>/dev/null || true)"
  if [ "$owner" = "$$" ]; then
    rm -f "$LOCK/owner" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
  fi
}

acquire_conversation_lock || exit 3
trap 'release_conversation_lock' EXIT
trap 'release_conversation_lock; exit 130' INT
trap 'release_conversation_lock; exit 143' TERM

GENERATION=0
if [ -f "$STATE" ]; then
  while IFS='=' read -r key value; do
    case "$key" in generation) GENERATION="$value" ;; esac
  done < "$STATE"
fi

TASK_ID="task-$(compat_uuidgen | tr -d '-' | tr '[:upper:]' '[:lower:]' | cut -c1-16)"
TARGET_STATE="$(actas_lock_state "$TEAM" "$TO_AGENT" "" 2>/dev/null || echo free)"

write_state() {
  local tmp
  tmp="$(mktemp "$STATE_DIR/.delegation.XXXXXX")"
  {
    printf 'conversation=%s\n' "$CONVERSATION"
    printf 'team=%s\n' "$TEAM"
    printf 'project=%s\n' "$PROJECT"
    printf 'from_type=%s\n' "$FROM_TYPE"
    printf 'from_agent=%s\n' "$FROM_AGENT"
    printf 'to_type=%s\n' "$TO_TYPE"
    printf 'to_agent=%s\n' "$TO_AGENT"
    printf 'generation=%s\n' "$GENERATION"
    printf 'last_task=%s\n' "$TASK_ID"
    printf 'updated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  } > "$tmp"
  mv -f "$tmp" "$STATE"
}

MARKER="[agmsg-delegate conversation=$CONVERSATION generation=$GENERATION task=$TASK_ID]"
REPLY_COMMAND="$(printf '%q %q %q %q' "$SCRIPT_DIR/send.sh" "$TEAM" "$TO_AGENT" "$FROM_AGENT")"

if [[ "$TARGET_STATE" == other:* ]]; then
  BODY="$MARKER
$MESSAGE

Reply to this exact task with the same conversation, generation, and task marker."
  "$SCRIPT_DIR/send.sh" "$TEAM" "$FROM_AGENT" "$TO_AGENT" "$BODY" >/dev/null
  write_state
  printf 'status=sent conversation=%s task=%s generation=%s team=%s from=%s to=%s\n' \
    "$CONVERSATION" "$TASK_ID" "$GENERATION" "$TEAM" "$FROM_AGENT" "$TO_AGENT"
  [ -z "$BOOTSTRAP_EXTRA" ] || printf '%s\n' "$BOOTSTRAP_EXTRA"
  exit 0
fi

GENERATION=$((GENERATION + 1))
MARKER="[agmsg-delegate conversation=$CONVERSATION generation=$GENERATION task=$TASK_ID]"

# The message database is the durable handoff source. Include only this target
# role's recent history, and cap it so a long-lived conversation cannot overflow
# a CLI argument or bury the current task.
HISTORY="$("$SCRIPT_DIR/api.sh" get teams "$TEAM" messages --agent "$TO_AGENT" --limit 30 2>/dev/null || true)"
if [ "${#HISTORY}" -gt 12000 ]; then
  HISTORY="${HISTORY: -12000}"
fi
[ -n "$HISTORY" ] || HISTORY="(no prior messages recorded)"

BOOT_PROMPT="You are the agmsg peer '$TO_AGENT' for conversation '$CONVERSATION' (generation $GENERATION).

Current task:
$MARKER
$MESSAGE

When you have progress, need clarification, or finish, send a message back to '$FROM_AGENT' in team '$TEAM' using:
  $REPLY_COMMAND \"$MARKER <your message>\"

Recent durable handoff history follows. Use it only to recover context; inspect the current project state before changing files, and do not repeat work already completed:
$HISTORY"

# A terminal/tmux launch is preferred because it leaves a peer available for
# follow-up messages. If that launch is impossible, a one-shot CLI call still
# completes the current request and its answer is persisted in agmsg, so a UI
# or resume failure cannot strand the caller's conversation.
run_direct_fallback() {
  local direct_prompt direct_args=()
  direct_prompt="$BOOT_PROMPT

This is a one-shot direct fallback. Do not run the reply command above. Return the complete result as your final output; the caller will persist and deliver it."

  case "$TO_TYPE" in
    claude-code)
      command -v claude >/dev/null 2>&1 || return 127
      direct_args=(claude --print)
      [ -z "$MODEL" ] || direct_args+=(--model "$MODEL")
      (cd "$PROJECT" && "${direct_args[@]}" "$direct_prompt")
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || return 127
      direct_args=(codex exec --cd "$PROJECT" --skip-git-repo-check --color never)
      [ -z "$MODEL" ] || direct_args+=(--model "$MODEL")
      "${direct_args[@]}" "$direct_prompt"
      ;;
    *)
      return 127
      ;;
  esac
}

spawn_args=("$TO_TYPE" "$TO_AGENT" --project "$PROJECT" --team "$TEAM" --boot-prompt "$BOOT_PROMPT")
[ "$FRESH" -eq 1 ] && spawn_args+=(--fresh)
[ -n "$MODEL" ] && spawn_args+=(--model "$MODEL")
[ "$NO_WAIT" -eq 1 ] && spawn_args+=(--no-wait)

if ! SPAWN_OUTPUT="$("$SCRIPT_DIR/spawn.sh" "${spawn_args[@]}" 2>&1)"; then
  echo "$SPAWN_OUTPUT" >&2
  TARGET_AFTER_FAILURE="$(actas_lock_state "$TEAM" "$TO_AGENT" "" 2>/dev/null || echo free)"
  if [[ "$TARGET_AFTER_FAILURE" == other:* ]]; then
    # spawn may report a readiness timeout after the peer has already claimed
    # its role. The boot prompt already contains this task, so sending it again
    # or launching a direct copy would duplicate work.
    write_state
    printf 'status=spawned-unconfirmed conversation=%s task=%s generation=%s team=%s from=%s to=%s\n' \
      "$CONVERSATION" "$TASK_ID" "$GENERATION" "$TEAM" "$FROM_AGENT" "$TO_AGENT"
    [ -z "$BOOTSTRAP_EXTRA" ] || printf '%s\n' "$BOOTSTRAP_EXTRA"
    exit 0
  fi

  echo "delegate: agmsg spawn failed; running one-shot direct fallback" >&2
  if ! DIRECT_OUTPUT="$(run_direct_fallback 2>&1)"; then
    [ -z "$DIRECT_OUTPUT" ] || printf '%s\n' "$DIRECT_OUTPUT" >&2
    echo "delegate: both agmsg spawn and direct fallback failed" >&2
    exit 4
  fi
  [ -n "$DIRECT_OUTPUT" ] || DIRECT_OUTPUT="(direct fallback completed without textual output)"
  "$SCRIPT_DIR/send.sh" "$TEAM" "$TO_AGENT" "$FROM_AGENT" "$MARKER
$DIRECT_OUTPUT" >/dev/null
  write_state
  printf 'status=fallback conversation=%s task=%s generation=%s team=%s from=%s to=%s\n' \
    "$CONVERSATION" "$TASK_ID" "$GENERATION" "$TEAM" "$FROM_AGENT" "$TO_AGENT"
  printf '%s\n' "$DIRECT_OUTPUT"
  [ -z "$BOOTSTRAP_EXTRA" ] || printf '%s\n' "$BOOTSTRAP_EXTRA"
  exit 0
fi

write_state
printf 'status=spawned conversation=%s task=%s generation=%s team=%s from=%s to=%s\n' \
  "$CONVERSATION" "$TASK_ID" "$GENERATION" "$TEAM" "$FROM_AGENT" "$TO_AGENT"
printf '%s\n' "$SPAWN_OUTPUT"
[ -z "$BOOTSTRAP_EXTRA" ] || printf '%s\n' "$BOOTSTRAP_EXTRA"
