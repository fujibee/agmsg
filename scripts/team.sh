#!/usr/bin/env bash
set -euo pipefail

# Usage: team.sh <team>
# Shows team members.

TEAM="${1:?Usage: team.sh <team>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Reject team names that would escape teams/ as a path segment (#140).
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validate.sh"
agmsg_validate_team_name "$TEAM" || exit 1

CONFIG="$SCRIPT_DIR/../teams/$TEAM/config.json"

if [ ! -f "$CONFIG" ]; then
  echo "Team not found: $TEAM"
  exit 1
fi

echo "Team: $TEAM"
echo ""

COUNT=0
while IFS='	' read -r name types project registrations; do
  if [ "${registrations:-0}" -gt 1 ]; then
    echo "  $name ($types) — $project (+$((registrations - 1)) more)"
  else
    echo "  $name ($types) — $project"
  fi
  COUNT=$((COUNT + 1))
# tr -d '\r': sqlite3.exe on Windows emits CRLF rows; the trailing CR would make
# the `registrations` field "N\r" and trip the integer test in the loop (#130).
done < <(sqlite3 -separator '	' :memory: \
  ".param set :json '$(sed "s/'/''/g" "$CONFIG")'" \
  "WITH agents AS (
     SELECT
       key AS name,
       CASE
         WHEN json_type(json_extract(value, '$.registrations')) = 'array' THEN json_extract(value, '$.registrations')
         ELSE json_array(json_object('type', json_extract(value, '$.type'), 'project', json_extract(value, '$.project')))
       END AS registrations
     FROM json_each(json_extract(:json, '$.agents'))
   )
   SELECT
     name,
     group_concat(DISTINCT json_extract(r.value, '$.type')),
     COALESCE((
       SELECT json_extract(r2.value, '$.project')
       FROM json_each(agents.registrations) AS r2
       ORDER BY CAST(r2.key AS INTEGER) DESC
       LIMIT 1
     ), '?'),
     json_array_length(registrations)
   FROM agents, json_each(agents.registrations) AS r
   GROUP BY name, registrations;" | tr -d '\r')

echo ""
echo "$COUNT member(s)"
