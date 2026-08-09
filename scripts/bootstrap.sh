#!/usr/bin/env bash
set -euo pipefail

# Create or recover a deterministic, session-scoped agmsg identity without
# asking the user to choose a team or agent name.
#
# Usage:
#   bootstrap.sh <project> <type> [--session-id <id>] [--team <team>]
#                [--instance-id <id>] [--agent <agent>]
#                [--delivery <mode>|--no-delivery]
#
# The team is stable for a physical project path. The agent is stable for the
# current agent-process instance, so parallel Codex/Claude sessions share the
# project team without competing for the same inbox identity.

PROJECT="${1:?Usage: bootstrap.sh <project> <type> [options]}"
TYPE="${2:?Missing agent type}"
shift 2

SESSION_ID=""
INSTANCE_ID_OVERRIDE=""
TEAM=""
AGENT=""
AGENT_EXPLICIT=0
DELIVERY="auto"

while (($#)); do
  case "$1" in
    --session-id)
      [ "$#" -ge 2 ] || { echo "bootstrap: --session-id needs a value" >&2; exit 2; }
      SESSION_ID="$2"
      shift 2
      ;;
    --instance-id) INSTANCE_ID_OVERRIDE="${2:?--instance-id needs a value}"; shift 2 ;;
    --team) TEAM="${2:?--team needs a value}"; shift 2 ;;
    --agent) AGENT="${2:?--agent needs a value}"; AGENT_EXPLICIT=1; shift 2 ;;
    --delivery) DELIVERY="${2:?--delivery needs a mode}"; shift 2 ;;
    --no-delivery) DELIVERY="off"; shift ;;
    -h|--help)
      sed -n '4,12p' "$0"
      exit 0
      ;;
    *) echo "bootstrap: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/compat.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hash.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"

agmsg_is_known_type "$TYPE" || {
  echo "bootstrap: unknown agent type '$TYPE'" >&2
  exit 2
}
[ -d "$PROJECT" ] || { echo "bootstrap: project path does not exist: $PROJECT" >&2; exit 2; }

# NOTE: use the physical path rather than a Git remote. Two local clones may
# intentionally carry different work, while every session in one checkout must
# converge on exactly the same team.
PROJECT="$(agmsg_canonical_path "$PROJECT")"
PROJECT="$(agmsg_normalize_project_path "$PROJECT")"
PROJECT_HASH="$(printf '%s' "$PROJECT" | agmsg_sha1)"

type_label() {
  case "$1" in
    claude-code) printf 'claude' ;;
    grok-build) printf 'grok' ;;
    *) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' ;;
  esac
}

project_slug() {
  local base slug
  base="${PROJECT##*/}"
  slug="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-24)"
  printf '%s' "${slug:-project}"
}

if [ -z "$SESSION_ID" ]; then
  case "$TYPE" in
    codex) SESSION_ID="${CODEX_THREAD_ID:-}" ;;
    claude-code) SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}" ;;
    grok-build) SESSION_ID="${GROK_SESSION_ID:-}" ;;
  esac
fi

# A CLI session id is not exposed by every host. The enclosing agent PID is the
# next strongest signal and remains stable across tool calls in that session.
# A generated UUID is last-resort only; callers that need cross-process resume
# should pass --session-id explicitly.
if [ -z "$SESSION_ID" ]; then
  AGENT_PID="$(agmsg_agent_pid "$TYPE" 2>/dev/null || true)"
  if [ -n "$AGENT_PID" ]; then
    SESSION_ID="process-$AGENT_PID"
  else
    SESSION_ID="generated-$(compat_uuidgen | tr '[:upper:]' '[:lower:]')"
    echo "bootstrap: warning: no host session id or agent pid; generated identity is process-local" >&2
  fi
fi

if [ -z "$TEAM" ]; then
  TEAM="auto-$(project_slug)-${PROJECT_HASH:0:8}"
fi

if [ -z "$AGENT" ]; then
  INSTANCE_KEY="$PROJECT|$TYPE|$SESSION_ID"
  INSTANCE_HASH="$(printf '%s' "$INSTANCE_KEY" | agmsg_sha1)"
  AGENT="$(type_label "$TYPE")-${INSTANCE_HASH:0:10}"
fi

agmsg_validate_team_name "$TEAM" || exit 2
agmsg_validate_agent_name "$AGENT" || exit 2

EXISTING="$("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)"
PAIR="$(printf '%s\t%s' "$TEAM" "$AGENT")"
CREATED=0
if ! printf '%s\n' "$EXISTING" | grep -Fxq "$PAIR"; then
  AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" "$TEAM" "$AGENT" "$TYPE" "$PROJECT" >/dev/null
  CREATED=1
fi

# Prefer a stable role derived from the host session id, but never let two live
# processes share it. Claude/Codex can run parallel --resume processes with the
# same bare session id; the per-process instance token detects that case. A
# concurrent holder gets an instance-suffixed identity, while a later resume
# after the old process exits reclaims the stable name.
LOCK_ID="${INSTANCE_ID_OVERRIDE:-$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")}"
CLAIM_RESULT="$(actas_lock_claim "$TEAM" "$AGENT" "$LOCK_ID" 2>/dev/null || true)"
if [[ "$CLAIM_RESULT" == held:* ]]; then
  if [ "$AGENT_EXPLICIT" -eq 1 ]; then
    echo "bootstrap: explicit agent '$AGENT' is held by another live session (${CLAIM_RESULT#held:})" >&2
    exit 3
  fi
  INSTANCE_HASH="$(printf '%s' "$PROJECT|$TYPE|$SESSION_ID|$LOCK_ID" | agmsg_sha1)"
  AGENT="$(type_label "$TYPE")-${INSTANCE_HASH:0:10}"
  agmsg_validate_agent_name "$AGENT" || exit 2
  PAIR="$(printf '%s\t%s' "$TEAM" "$AGENT")"
  if ! printf '%s\n' "$EXISTING" | grep -Fxq "$PAIR"; then
    AGMSG_RESOLVE_PROJECT=0 "$SCRIPT_DIR/join.sh" "$TEAM" "$AGENT" "$TYPE" "$PROJECT" >/dev/null
    CREATED=1
  fi
  CLAIM_RESULT="$(actas_lock_claim "$TEAM" "$AGENT" "$LOCK_ID" 2>/dev/null || true)"
  if [[ "$CLAIM_RESULT" == held:* ]]; then
    echo "bootstrap: generated agent '$AGENT' is unexpectedly held (${CLAIM_RESULT#held:})" >&2
    exit 3
  fi
fi

if [ "$DELIVERY" = auto ]; then
  case "$TYPE" in
    claude-code) DELIVERY=monitor ;;
    # Codex monitor needs a launcher/shim. turn works immediately, while a
    # spawned Codex still receives its first task through --boot-prompt.
    codex) DELIVERY=turn ;;
    *)
      if agmsg_type_has "$TYPE" delivery_modes turn; then DELIVERY=turn; else DELIVERY=off; fi
      ;;
  esac
fi

DELIVERY_OUTPUT=""
DELIVERY_CONFIGURED=0
if [ "$DELIVERY" != off ]; then
  RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR" 2>/dev/null || true
  DELIVERY_MARKER="$RUN_DIR/auto-delivery.${PROJECT_HASH:0:16}.$(type_label "$TYPE")"
  if [ ! -f "$DELIVERY_MARKER" ]; then
    if DELIVERY_OUTPUT="$("$SCRIPT_DIR/delivery.sh" set "$DELIVERY" "$TYPE" "$PROJECT" 2>&1)"; then
      tmp="$(mktemp "$RUN_DIR/.auto-delivery.XXXXXX")"
      printf '%s\n' "$DELIVERY" > "$tmp"
      mv -f "$tmp" "$DELIVERY_MARKER"
      DELIVERY_CONFIGURED=1
    else
      printf '%s\n' "$DELIVERY_OUTPUT" >&2
      exit 1
    fi
  fi
fi

if [ "$TYPE" = claude-code ] && { [ "$DELIVERY" = monitor ] || [ "$DELIVERY" = both ]; }; then
  WATCH_COMMAND="$(printf '%q %q %q %q %q' \
    "$SCRIPT_DIR/watch.sh" "$LOCK_ID" "$PROJECT" "$TYPE" "$AGENT")"
  DELIVERY_OUTPUT="AGMSG-DIRECTIVE: Stop any running agmsg inbox Monitor task for this session, then invoke the Monitor tool with:
  command: $WATCH_COMMAND
  description: agmsg inbox stream ($AGENT)
  persistent: true

This identity filter is required so parallel sessions in the same project do not consume each other's replies."
fi

printf 'status=ready team=%s agent=%s type=%s created=%s delivery=%s delivery_configured=%s\n' \
  "$TEAM" "$AGENT" "$TYPE" "$CREATED" "$DELIVERY" "$DELIVERY_CONFIGURED"

# delivery.sh may emit an AGMSG-DIRECTIVE that the host agent must execute in
# the current session. Preserve it after the machine-readable identity line.
if [ -n "$DELIVERY_OUTPUT" ]; then
  printf '%s\n' "$DELIVERY_OUTPUT"
fi
exit 0
