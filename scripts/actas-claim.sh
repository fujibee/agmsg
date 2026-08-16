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
#   status=held team=<team> owner=<owner_sid>             refused — another live session owns it
#   status=not_registered                                  name is not joined to any team in this project/type
#
# Exit code:
#   0 — status=ok
#   1 — status=held (callers should NOT proceed with the actas flow)
#   2 — status=not_registered (callers should run join.sh first)

PROJECT="${1:?Usage: actas-claim.sh <project> <type> <name> <session_id>}"
TYPE="${2:?Missing type}"
NAME="${3:?Missing name}"
SESSION_ID="${4:?Missing session_id}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
# offending team — callers should resolve that before retrying. Releases
# already-claimed pairs in this same attempt so partial state doesn't leak.
claimed=""
while IFS= read -r team; do
  [ -z "$team" ] && continue
  result=$(actas_lock_claim "$team" "$NAME" "$SESSION_ID" 2>/dev/null || true)
  case "$result" in
    held:*)
      # Roll back any partial claims so the user can retry cleanly.
      while IFS= read -r c_team; do
        [ -z "$c_team" ] && continue
        actas_lock_release "$c_team" "$NAME" "$SESSION_ID" 2>/dev/null || true
      done <<< "$claimed"
      printf 'status=held team=%s owner=%s\n' "$team" "${result#held:}"
      exit 1
      ;;
  esac
  claimed="${claimed:+$claimed$'\n'}$team"
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

# Start the engine for each claimed team, if one is not already up (#774).
#
# The second of the two trigger points. `actas` is where a session takes on a
# role and therefore a team, and a session that arrives this way never passes
# through session-start's block with that team in hand — a spawn's boot prompt
# is `actas`, so on a rebooted machine this is the first moment the team is
# known.
#
# AFTER the claim and BEFORE the status line: the claim is the thing the caller
# is waiting on, and nothing about starting an engine may delay or fail it.
#
# DELAY IS THE HALF THAT NEEDED WORK. Returning 0 is not enough — a synchronous
# `sync start` holds `status=ok` back for as long as the engine takes to become
# ready, which is up to ~16s per team before the command even gives up. The
# helper bounds the WAIT (`AGMSG_SYNC_AUTOSTART_TIMEOUT_S`, 5s for the whole
# call) and leaves a slow start running rather than killing it. `|| true` says
# the exit-status half a second time.
#
# Whether an engine is already running is not asked here — `sync start` answers
# it under the per-team lock, and the concurrent case (several sessions claiming
# roles at once) is exactly the one a second answer gets wrong. See
# scripts/lib/sync-autostart.sh.
if [ -x "$SKILL_DIR/scripts/remote.sh" ] && [ -r "$SKILL_DIR/scripts/lib/sync-autostart.sh" ]; then
  # shellcheck source=scripts/lib/sync-autostart.sh
  . "$SKILL_DIR/scripts/lib/sync-autostart.sh"
  _autostart_teams=()
  while IFS= read -r _t; do
    [ -n "$_t" ] && _autostart_teams+=("$_t")
  done <<< "$TEAMS"
  if [ ${#_autostart_teams[@]} -gt 0 ]; then
    agmsg_sync_autostart "$SKILL_DIR/scripts/remote.sh" "${_autostart_teams[@]}" || true
  fi
fi

# Print a line describing each claimed team. One team per most projects but
# the underlying model allows multi-team same-name registrations.
printf 'status=ok'
while IFS= read -r team; do
  [ -z "$team" ] && continue
  printf ' team=%s' "$team"
done <<< "$TEAMS"
printf '\n'
exit 0
