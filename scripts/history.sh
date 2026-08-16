#!/usr/bin/env bash
set -euo pipefail

# Usage: history.sh <team> [agent_id] [limit]
# Shows message history. If agent_id given, shows only that agent's messages.

TEAM="${1:?Usage: history.sh <team> [agent_id] [limit]}"
AGENT="${2:-}"
LIMIT="${3:-20}"
# A non-numeric limit would otherwise be interpolated straight into the SQL
# text below (e.g. "1; DELETE FROM messages; --"); fall back to the default
# rather than passing it through, mirroring the interval-validation idiom
# used elsewhere (config.sh, watch.sh).
case "$LIMIT" in ''|*[!0-9]*) LIMIT=20 ;; esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
agmsg_storage_load

# A history read must not create a store, so a team that has never been written
# to has no file yet. Since the stores split per team that is the ordinary state
# of a freshly joined team rather than a broken install, and it reads out the
# same as an empty history. Driver-level, so it works for jsonl too.
if ! storage_store_exists "$TEAM"; then
  echo "No message history."
  exit 0
fi

# History (events ∪ legacy) via the facade; <agent> optional — omitted = whole
# team (§2.1). The driver returns the most recent --limit records already in
# chronological order, so no reversal here.
HIST_JSONL=$(storage_history "$TEAM" "$AGENT" --limit "$LIMIT")

if [ -z "$HIST_JSONL" ]; then
  echo "No message history."
  exit 0
fi

# Parse to "from \x1f to \x1f body \x1f at \x1f id" rows (no jq; cf. lib/hooks-json.sh).
_arr="[$(printf '%s' "$HIST_JSONL" | paste -sd, -)]"
ROWS=$(agmsg_sqlite ':memory:' "
  SELECT json_extract(value,'\$.from') || char(31) ||
         json_extract(value,'\$.to') || char(31) ||
         replace(replace(json_extract(value,'\$.body'), char(10), '\n'), char(9), '\t') || char(31) ||
         json_extract(value,'\$.at') || char(31) ||
         json_extract(value,'\$.id')
  FROM json_each('$(printf '%s' "$_arr" | sed "s/'/''/g")');
")

# Read-state for the ●(unread)/○(read) marker (G2(c)): read-state is
# recipient-scoped and not carried on a history record, so derive it by unioning
# storage_list_unread over the distinct recipients in this slice. (Phase 1:
# mark-read still lands in legacy read_at, which the facade UNION reflects.)
RECIPIENTS=$(while IFS=$'\x1f' read -r _f to _rest; do
  [ -n "$to" ] && printf '%s\n' "$to"
done <<< "$ROWS" | sort -u)

UNREAD_IDS=""
while IFS= read -r r; do
  [ -n "$r" ] || continue
  u=$(storage_list_unread "$TEAM" "$r") || continue
  [ -n "$u" ] || continue
  uarr="[$(printf '%s' "$u" | paste -sd, -)]"
  ids=$(agmsg_sqlite ':memory:' "
    SELECT json_extract(value,'\$.id') FROM json_each('$(printf '%s' "$uarr" | sed "s/'/''/g")');
  ")
  UNREAD_IDS+="$ids"$'\n'
done <<< "$RECIPIENTS"

while IFS=$'\x1f' read -r from to body ts id; do
  [ -n "$ts$from$to$body" ] || continue
  if printf '%s\n' "$UNREAD_IDS" | grep -Fxq "$id"; then status='●'; else status='○'; fi
  echo "  $status [$ts] $from → $to: $body"
done <<< "$ROWS"
