#!/usr/bin/env bash
set -euo pipefail

# rearm.sh — poke every claude-code seat registered to the CALLER's own
# project, in a team, whose delivery mode is monitor or both, asking it to
# re-arm its own agmsg Monitor watch.
#
# Usage: rearm.sh <team>
#
# Scoped to $(pwd): a same-team seat registered to a different local project
# is not a candidate (#1315 review) — it works on something else, and poking
# it about a watch for a project it is not even in would be confusing, not
# helpful. Every OTHER row team.sh reports is announced too, not silently
# dropped: a registration with the wrong type, the wrong project, or a
# non-monitor delivery mode gets its own "skipped (<reason>)" line, so an
# operator reading the output never mistakes silence for "nothing else to
# say" — without this, an excluded seat and a successfully-poked one would
# look identical (absent from the output either way).
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
# poke at all. Exit 1 only when there was at least one candidate and every
# poke on it failed.

USAGE='Usage: rearm.sh <team>'
[ $# -eq 1 ] || { printf '%s\n' "$USAGE" >&2; exit 2; }
TEAM="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

PROJECT="$(pwd)"
MESSAGE='Your agmsg monitor may have expired. Re-arm it now with the standard command for your seat, and say nothing.'

MEMBERS_JSON="$(bash "$SCRIPT_DIR/team.sh" "$TEAM" --json)" || {
  echo "rearm: could not read team '$TEAM'" >&2
  exit 1
}

# One row per (member, type, project) registration -- team.sh's own
# granularity, not one row per member -- so a member with several
# registrations is judged, and reported, once per registration. "select"
# only for a claude-code registration in THIS project with delivery monitor
# or both; everything else is "skip" with a specific reason.
ROWS="$(printf '%s' "$MEMBERS_JSON" | jq -r --arg project "$PROJECT" '
  .[] | [
    .member,
    (if .type != "claude-code" then "skip"
     elif .project != $project then "skip"
     elif (.delivery == "monitor" or .delivery == "both") then "select"
     else "skip" end),
    (if .type != "claude-code" then ("not claude-code (type=" + .type + ")")
     elif .project != $project then ("registered to a different project (" + .project + ")")
     elif (.delivery == "monitor" or .delivery == "both") then .delivery
     else ("delivery=" + .delivery) end)
  ] | @tsv
')"

CANDIDATES=""
CANDIDATE_COUNT=0
while IFS=$'\t' read -r member verdict detail; do
  [ -n "$member" ] || continue
  if [ "$verdict" = "select" ]; then
    if ! grep -qxF "$member" <<<"$CANDIDATES"; then
      CANDIDATES="$CANDIDATES$member
"
      CANDIDATE_COUNT=$((CANDIDATE_COUNT + 1))
    fi
  else
    echo "$member: skipped ($detail)"
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
