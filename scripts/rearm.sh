#!/usr/bin/env bash
set -euo pipefail

# rearm.sh — poke every claude-code seat in a team whose delivery mode is
# monitor or both, asking it to re-arm its own agmsg Monitor watch.
#
# Usage: rearm.sh <team>
#
# Scope is the whole team by default. This script does not check reachability
# itself: poke.sh resolves each target's own driver and refuses a seat it
# cannot reach, printing why on its own stderr, and that refusal is reported
# here per seat rather than silently skipped. Never pokes a seat whose type
# is not claude-code, regardless of its delivery mode.
#
# Exit 0 if at least one seat was poked successfully, or if there was no
# claude-code monitor/both seat in the team to poke at all. Exit 1 only when
# there was at least one candidate seat and every poke on it failed.

USAGE='Usage: rearm.sh <team>'
[ $# -eq 1 ] || { printf '%s\n' "$USAGE" >&2; exit 2; }
TEAM="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

MESSAGE='Your agmsg monitor may have expired. Re-arm it now with the standard command for your seat, and say nothing.'

MEMBERS_JSON="$(bash "$SCRIPT_DIR/team.sh" "$TEAM" --json)" || {
  echo "rearm: could not read team '$TEAM'" >&2
  exit 1
}

# team.sh --json's delivery field only resolves for a (type, project) pair
# whose config is readable on THIS machine -- which is exactly the
# population poke.sh can ever reach anyway, since every terminal driver
# (tmux/herdr/plain) is inherently local. A remote member simply reports an
# "unknown:..." delivery value here and is correctly excluded below, not
# specially-cased.
SEATS="$(printf '%s' "$MEMBERS_JSON" | jq -r '
  .[] | select(.type == "claude-code") | select(.delivery == "monitor" or .delivery == "both") | .member
')"

if [ -z "$SEATS" ]; then
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
done <<<"$SEATS"

echo "rearm: $SUCCEEDED/$TOTAL claude-code monitor/both seat(s) poked in team '$TEAM'"
[ "$SUCCEEDED" -gt 0 ] || exit 1
