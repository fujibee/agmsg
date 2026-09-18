#!/usr/bin/env bash
set -euo pipefail

# rearm.sh — poke every claude-code seat registered to the CALLER's own
# project, in a team, whose delivery mode is monitor or both, asking it to
# re-arm its own agmsg Monitor watch.
#
# Usage: rearm.sh <team>
#
# Scoped to the caller's own project: a same-team seat registered to a
# different local project is not a candidate (#1315 review) — it works on
# something else, and poking it about a watch for a project it is not even
# in would be confusing, not helpful. "The caller's own project" is resolved
# and normalized the same way join.sh registers one (agmsg_resolve_project
# then agmsg_normalize_project_path), so a caller inside a subdirectory or a
# sibling worktree of the registered root still matches it, and each
# registration's own recorded project is further canonicalized (symlinks
# resolved) before comparing — a raw string/pwd comparison alone missed a
# same-project seat reached through a symlink or an equivalent spelling
# (#1315 review, round 2).
#
# Every OTHER row team.sh reports is announced too, not silently dropped: a
# registration with the wrong type, the wrong project, or a non-monitor
# delivery mode gets its own "skipped (<reason>)" line, so an operator
# reading the output never mistakes silence for "nothing else to say" —
# without this, an excluded seat and a successfully-poked one would look
# identical (absent from the output either way).
#
# This script does not check reachability itself: poke.sh resolves each
# target's own driver and refuses a seat it cannot reach, printing why on
# its own stderr, and that refusal is reported here per seat too. Never
# pokes a seat whose type is not claude-code, regardless of its delivery
# mode — a non-claude-code seat's own "monitor" (codex's bridge, for
# example) is a different mechanism entirely, and this message would be
# meaningless to it.
#
# A member with more than one matching registration is poked once: the
# candidate list is deduplicated by member name before poking, but every
# individual registration row that did NOT qualify still gets its own
# skipped line, even if that same member also has a qualifying row
# elsewhere.
#
# Exit 0 if at least one candidate was poked successfully, or if there was
# no claude-code monitor/both seat registered to the caller's own project to
# poke at all. Exit 1 when there was at least one candidate and every poke on
# it failed, or when the caller's own project could not be verified against
# the team's registered claude-code projects at all (see PROJECT_REGISTERED
# below) -- that case pokes no one.

USAGE='Usage: rearm.sh <team>'
[ $# -eq 1 ] || { printf '%s\n' "$USAGE" >&2; exit 2; }
TEAM="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

# Same pipeline join.sh stores a registration's project through, so the
# caller's own project resolves to the identical value a matching
# registration was recorded with -- then canonicalized (symlinks resolved)
# for the final comparison against each row below, which is canonicalized
# the same way.
PROJECT="$(agmsg_resolve_project "$(pwd)" claude-code "$TEAM")"
PROJECT="$(agmsg_normalize_project_path "$PROJECT")"
PROJECT_CANON="$(agmsg_canonical_path "$PROJECT")"

MESSAGE='Your agmsg monitor may have expired. Re-arm it now with the standard command for your seat, and say nothing.'

MEMBERS_JSON="$(bash "$SCRIPT_DIR/team.sh" "$TEAM" --json)" || {
  echo "rearm: could not read team '$TEAM'" >&2
  exit 1
}

# One row per (member, type, project) registration -- team.sh's own
# granularity, not one row per member -- so a member with several
# registrations is judged, and reported, once per registration. The project
# comparison itself happens in bash below, not here, because it needs
# agmsg_canonical_path (a real filesystem resolution jq cannot do).
ROWS="$(printf '%s' "$MEMBERS_JSON" | jq -r '.[] | [.member, .type, .project, .delivery] | @tsv')"

# agmsg_resolve_project deliberately fails OPEN: when no SessionStart marker,
# no registered ancestor and no git-common-dir match are found, it still
# prints the raw pwd and returns 0 rather than erroring. That fallback is
# indistinguishable from a genuinely verified resolution by exit status
# alone, so trusting PROJECT_CANON at face value here would let an unresolved
# caller poke a same-named-by-coincidence project. Proof instead comes from
# the team's own registry: PROJECT_CANON must match at least one existing
# claude-code registration's own canonical project (any delivery mode --
# this is a membership check, not the monitor/both filter below). No match
# means resolution could not be confirmed, so refuse rather than silently
# report "nothing to do".
PROJECT_REGISTERED=0
while IFS=$'\t' read -r reg_member reg_type reg_project _reg_delivery; do
  [ -n "$reg_member" ] || continue
  [ "$reg_type" = "claude-code" ] || continue
  reg_canon="$(agmsg_canonical_path "$(agmsg_normalize_project_path "$reg_project")")"
  if [ "$reg_canon" = "$PROJECT_CANON" ]; then
    PROJECT_REGISTERED=1
    break
  fi
done <<<"$ROWS"

if [ "$PROJECT_REGISTERED" -ne 1 ]; then
  echo "rearm: could not verify '$PROJECT' as a registered claude-code project in team '$TEAM' — refusing rather than trust an unresolved fallback path" >&2
  exit 1
fi

CANDIDATES=""
CANDIDATE_COUNT=0
while IFS=$'\t' read -r member type project delivery; do
  [ -n "$member" ] || continue
  if [ "$type" != "claude-code" ]; then
    echo "$member: skipped (not claude-code (type=$type))"
    continue
  fi
  row_canon="$(agmsg_canonical_path "$(agmsg_normalize_project_path "$project")")"
  if [ "$row_canon" != "$PROJECT_CANON" ]; then
    echo "$member: skipped (registered to a different project ($project))"
    continue
  fi
  if [ "$delivery" = monitor ] || [ "$delivery" = both ]; then
    if ! grep -qxF "$member" <<<"$CANDIDATES"; then
      CANDIDATES="$CANDIDATES$member
"
      CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
    fi
  else
    echo "$member: skipped (delivery=$delivery)"
  fi
done <<<"$ROWS"

if [ "$CANDIDATE_COUNT" -eq 0 ]; then
  echo "rearm: no claude-code seat registered to '$PROJECT' in team '$TEAM' is configured for monitor or both delivery"
  exit 0
fi

BODY_FILE="$(mktemp "${TMPDIR:-/tmp}/agmsg-rearm-body.XXXXXX")" || {
  echo "rearm: could not create a temp file for the poke body" >&2
  exit 1
}
printf '%s' "$MESSAGE" > "$BODY_FILE"
trap 'rm -f "$BODY_FILE"' EXIT

TOTAL=0
SUCCEEDED=0
while IFS= read -r seat; do
  [ -n "$seat" ] || continue
  TOTAL=$((TOTAL + 1))
  RC=0
  OUT="$(bash "$SCRIPT_DIR/poke.sh" "$TEAM" "$seat" --body-file "$BODY_FILE" 2>&1)" || RC=$?
  if [ "$RC" -eq 0 ]; then
    SUCCEEDED=$((SUCCEEDED + 1))
    echo "$seat: ok — $OUT"
  else
    echo "$seat: refused (exit $RC) — $OUT"
  fi
done <<<"$CANDIDATES"

echo "rearm: $SUCCEEDED/$TOTAL claude-code monitor/both seat(s) poked in team '$TEAM' for project '$PROJECT'"
[ "$SUCCEEDED" -gt 0 ] || exit 1
