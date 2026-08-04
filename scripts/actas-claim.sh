#!/usr/bin/env bash
set -euo pipefail

# Pre-flight claim used by the `actas` skill-command flow.
#
# Usage: actas-claim.sh <project> <type> <name> <session_id>
#
# Looks up which team(s) <name> is registered in for (project, type) and
# attempts to claim the actas exclusivity lock for each matching (team, name)
# pair against <session_id>. The intended call order from the skill template:
#
#   1. join.sh (if <name> is not yet registered)
#   2. actas-claim.sh — this script
#   3. TaskStop the existing Monitor and invoke the new one with <name>
#
# Output (stdout, key=value lines):
#   status=ok team=<team> [team=<team2> ...]              everything claimed
#   status=held team=<team> owner=<owner_sid> [rollback=incomplete locked=<pairs>]
#                                                            refused — another live session owns it
#   status=not_registered                                  name is not joined to any team in this project/type
#   status=error team=<team> reason=<reason> [rollback=incomplete locked=<pairs>]
# On held or error, `locked` is the exact comma-separated set of percent-encoded
# team/agent pairs that the checked best-effort rollback could not prove released.
#
# Exit code:
#   0 — status=ok
#   1 — status=held (callers should NOT proceed with the actas flow)
#   2 — status=not_registered (callers should run join.sh first)
#   3 — status=error (claim/reclaim infrastructure failed; do not proceed)

PROJECT="${1:?Usage: actas-claim.sh <project> <type> <name> <session_id>}"
TYPE="${2:?Missing type}"
NAME="${3:?Missing name}"
SESSION_ID="${4:?Missing session_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC2034  # consumed by sourced actas/role-session libraries
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"  # actas-lock.sh requires SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/role-session.sh"  # role->session record (#339)

# Resolve the session's real project root (see #92) before any lookup, so an
# actas issued from a subdir/worktree claims against the registered project
# rather than missing it as not_registered.
PROJECT="$(agmsg_resolve_project "$PROJECT" "$TYPE")"

# Claim the lock under the per-process instance id (#93), the same token the
# watcher (re)launched by this actas flow keys its pidfile on. The template
# passes a bare $CLAUDE_CODE_SESSION_ID; normalize self-derives the composite so
# a parallel --continue/--resume session can't appear to already own the role.
SESSION_ID="$(agmsg_normalize_instance_id "$SESSION_ID" "$TYPE")"

# Find the team(s) this name is registered to for the given project/type.
TEAMS=""
while IFS=$'\t' read -r team agent; do
  [ -z "$team" ] && continue
  [ "$agent" = "$NAME" ] || continue
  TEAMS="${TEAMS:+$TEAMS$'\n'}$team"
done < <("$SCRIPT_DIR/identities.sh" "$PROJECT" "$TYPE")

if [ -z "$TEAMS" ]; then
  echo "status=not_registered"
  exit 2
fi

# Attempt claim for each matching team. First failure aborts and reports the
# offending team — callers should resolve that before retrying. Rollback is
# checked but necessarily best-effort: if the same infrastructure is down, the
# exact retained pairs are reported rather than deleted unsafely. Only locks
# that were free before this attempt are included; a pre-existing lock already
# owned by this session is not disturbed.
newly_claimed=""

while IFS= read -r team; do
  [ -z "$team" ] && continue
  pre_state="$(actas_lock_state "$team" "$NAME" "$SESSION_ID")"
  claim_status=0
  if result=$(actas_lock_claim "$team" "$NAME" "$SESSION_ID" 2>/dev/null); then
    claim_status=0
  else
    claim_status=$?
  fi

  if [ "$claim_status" -eq 0 ] && [ -z "$result" ]; then
    [ "$pre_state" = "free" ] \
      && newly_claimed="${newly_claimed:+$newly_claimed$'\n'}${team}"$'\t'"${NAME}"
    continue
  fi

  rollback="$newly_claimed"
  # A write may have linked the record before a later temp-cleanup failure.
  # Releasing a free-before-attempt pair is safe: release compares our exact
  # owner, so it cannot remove a peer that won the race.
  [ "$pre_state" = "free" ] \
    && rollback="${rollback:+$rollback$'\n'}${team}"$'\t'"${NAME}"
  rollback_incomplete=0
  if rollback_locked="$(actas_lock_rollback_pairs "$rollback" "$SESSION_ID")"; then
    rollback_incomplete=0
  else
    rollback_incomplete=1
  fi

  if [ "$claim_status" -eq 1 ]; then
    case "$result" in
      held:*)
        printf 'status=held team=%s owner=%s' "$team" "${result#held:}"
        [ "$rollback_incomplete" -eq 1 ] \
          && printf ' rollback=incomplete locked=%s' "$rollback_locked"
        printf '\n'
        exit 1
        ;;
    esac
  fi

  case "$result" in
    error:*) reason="${result#error:}" ;;
    *) reason="claim-protocol" ;;
  esac
  printf 'status=error team=%s reason=%s' "$team" "$reason"
  [ "$rollback_incomplete" -eq 1 ] \
    && printf ' rollback=incomplete locked=%s' "$rollback_locked"
  printf '\n'
  exit 3
done <<< "$TEAMS"

# All teams claimed. Record (team, agent) -> bare session id for each, so this
# role is resumable back into its context (#339). Keyed on the BARE sid (stable
# across resume generations), not the composite lock token. Best-effort: a
# failed record write must never fail the claim, and the record is written only
# on full success — the held/rollback path above writes none.
BARE_SID="$(agmsg_instance_bare_sid "$SESSION_ID")"
# Record the canonical (physical) project form -- the same spelling
# codex-record-session.sh writes -- so role-session records carry one path
# form across agent types (consumers canonicalize on read either way).
PROJECT_PHYS="$(agmsg_canonical_path "$PROJECT")"
while IFS= read -r team; do
  [ -z "$team" ] && continue
  agmsg_role_session_record "$team" "$NAME" "$BARE_SID" "$PROJECT_PHYS" "$TYPE" || true
done <<< "$TEAMS"

# Print a line describing each claimed team. One team per most projects but
# the underlying model allows multi-team same-name registrations.
printf 'status=ok'
while IFS= read -r team; do
  [ -z "$team" ] && continue
  printf ' team=%s' "$team"
done <<< "$TEAMS"
printf '\n'
exit 0
