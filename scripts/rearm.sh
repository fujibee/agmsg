#!/usr/bin/env bash
set -euo pipefail

# rearm.sh — poke every Claude Code seat in the team whose delivery mode is
# monitor or both, asking it to re-arm its own agmsg Monitor watch.
#
# Usage: rearm.sh <team>
#
# Whole-team scope (#1321, maintainer's original ruling): every Claude Code
# seat in the team, monitor or both, regardless of which local project it is
# registered to. An earlier revision (#1315) narrowed this to the caller's
# own project without asking the maintainer first — a review-time decision
# that should not have been made unilaterally — and agmsgd drops project
# binding entirely, so a project predicate would only have grown staler.
# There is deliberately no project comparison anywhere in this file.
#
# Every OTHER row team.sh reports is announced too, not silently dropped: a
# registration with the wrong type or a non-monitor delivery mode gets its
# own "skipped (<reason>)" line, so an operator reading the output never
# mistakes silence for "nothing else to say" — without this, an excluded
# seat and a successfully-poked one would look identical (absent from the
# output either way).
#
# This script does not check reachability itself: poke.sh resolves each
# target's own driver and refuses a seat it cannot reach, printing why on
# its own stderr, and that refusal is reported here per seat too. Never
# pokes a seat whose type is not claude-code, regardless of its delivery
# mode — a non-claude-code seat's own "monitor" (codex's bridge, for
# example) is a different mechanism entirely, and this message would be
# meaningless to it.
#
# A member with more than one matching registration (several local
# projects, most often) is poked once: the candidate list is deduplicated by
# member name before poking, but every individual registration row that did
# NOT qualify still gets its own skipped line, even if that same member also
# has a qualifying row elsewhere.
#
# Each candidate's poke carries bounded retries (#1321): a seat's own input
# box may hold a draft right when this runs, and that clears on its own once
# the person finishes typing, so poke.sh is asked to wait it out rather than
# refuse outright. A seat still busy after every retry is reported as
# "skipped: input in progress", not folded into the generic refused line,
# since retrying already happened and did not resolve it — a different fact
# than "this seat could not be reached at all".
#
# Seats are poked one at a time with a jittered gap between them (#1321): the
# maintainer measured 429 rate limits when every seat started a model turn in
# the same instant, because poking them all in a burst does exactly that.
#
# Exit 0 if at least one candidate was poked successfully, or if there was no
# claude-code monitor/both seat in the team to poke at all. Exit 1 when there
# was at least one candidate and every poke on it failed.

USAGE='Usage: rearm.sh <team>'
[ $# -eq 1 ] || { printf '%s\n' "$USAGE" >&2; exit 2; }
TEAM="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

MESSAGE='Your agmsg monitor may have expired. Re-arm it now with the standard command for your seat, and say nothing.'

MEMBERS_JSON="$(bash "$SCRIPT_DIR/team.sh" "$TEAM" --json)" || {
  echo "rearm: could not read team '$TEAM'" >&2
  exit 1
}

# One row per (member, type, project) registration -- team.sh's own
# granularity, not one row per member -- so a member with several
# registrations is judged, and reported, once per registration; the
# dedup-by-member-name step below is what turns that into one poke.
ROWS="$(printf '%s' "$MEMBERS_JSON" | jq -r '.[] | [.member, .type, .delivery] | @tsv')"

CANDIDATES=""
CANDIDATE_COUNT=0
while IFS=$'\t' read -r member type delivery; do
  [ -n "$member" ] || continue
  if [ "$type" != "claude-code" ]; then
    echo "$member: skipped (not claude-code (type=$type))"
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
  echo "rearm: no claude-code seat in team '$TEAM' is configured for monitor or both delivery"
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
FIRST=1
while IFS= read -r seat; do
  [ -n "$seat" ] || continue
  if [ "$FIRST" -eq 0 ]; then
    # Jitter, not a fixed gap, so many seats do not still line up into a
    # burst at a multiple of the interval. 2..6 seconds inclusive.
    sleep "$(( (RANDOM % 5) + 2 ))"
  fi
  FIRST=0
  TOTAL=$((TOTAL + 1))
  RC=0
  OUT="$(bash "$SCRIPT_DIR/poke.sh" "$TEAM" "$seat" \
    --retries 5 --retry-delay 2 --backoff exponential \
    --body-file "$BODY_FILE" 2>&1)" || RC=$?
  if [ "$RC" -eq 0 ]; then
    SUCCEEDED=$((SUCCEEDED + 1))
    echo "$seat: ok — $OUT"
  elif [ "$RC" -eq 14 ]; then
    echo "$seat: skipped: input in progress"
  else
    echo "$seat: refused (exit $RC) — $OUT"
  fi
done <<<"$CANDIDATES"

echo "rearm: $SUCCEEDED/$TOTAL claude-code monitor/both seat(s) poked in team '$TEAM'"
[ "$SUCCEEDED" -gt 0 ] || exit 1
