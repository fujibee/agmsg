#!/usr/bin/env bash
set -euo pipefail

# Read-only, installation-wide placement collision report (#1144).
# Deliberately separate from team.sh: this command observes the fleet so an
# operator can decide which seat to contact; it never participates in a seat's
# self-repair path and never changes a placement record.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/actas-lock.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/type-registry.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/terminal-registry.sh"

if [ "$#" -ne 0 ]; then
  echo "Usage: placement-collisions.sh" >&2
  exit 2
fi

# Print rows for refs claimed by two DIFFERENT agent names. Claims are found
# through team registries and agmsg_spawn_path rather than by splitting the flat
# spawn filename: both team and agent names may legally contain `__`, so that
# filename is not reversible. The same agent registered in multiple teams is
# one seat for this report and is not a collision by itself.
_placement_collision_rows() {
  local cfg team escaped agent rec ref _project type tab
  [ -d "$SKILL_DIR/teams" ] || return 0
  tab="$(printf '\t')"
  {
    for cfg in "$SKILL_DIR"/teams/*/config.json; do
      [ -f "$cfg" ] || continue
      team="${cfg%/config.json}"; team="${team##*/}"
      escaped="$(sed "s/'/''/g" "$cfg")"
      while IFS= read -r agent; do
        [ -n "$agent" ] || continue
        rec="$(agmsg_spawn_path "$team" "$agent" 2>/dev/null)" || continue
        [ -f "$rec" ] || continue
        IFS="$tab" read -r ref _project type _fence < "$rec" 2>/dev/null || continue
        [ -n "$ref" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$ref" "$agent" "$team" "$type"
      done < <(sqlite3 -noheader :memory: \
        "SELECT key FROM json_each(json_extract('$escaped', '\$.agents')) ORDER BY key;" 2>/dev/null)
    done
  } | LC_ALL=C sort -t "$tab" -k1,1 -k2,2 -k3,3 | awk -F '\t' '
    function flush() { if (distinct > 1) printf "%s", rows }
    $1 != ref {
      flush()
      ref = $1; last_agent = ""; distinct = 0; rows = ""
    }
    {
      if ($2 != last_agent) { distinct++; last_agent = $2 }
      rows = rows $1 "\t" $3 "\t" $2 "\t" $4 "\n"
    }
    END { flush() }
  '
}

# Print `absent` only when the terminal establishes BOTH facts: the pane exists,
# and no agent resides there. rc=1 is the readiness contract's not_ready branch;
# rc=2 is unknown even if a driver's body happens to resemble a known reason.
_collision_resident() {   # <ref> <type> [<type> ...]
  local ref="$1" terminal pane state result rc type cli saw_type=0
  shift
  terminal="$(agmsg_terminal_ref_terminal "$ref" 2>/dev/null)" || return 1
  pane="$(agmsg_terminal_ref_id "$ref" 2>/dev/null)" || return 1
  agmsg_terminal_load "$terminal" >/dev/null 2>&1 || return 1
  state="$(terminal_pane_state "$pane" 2>/dev/null)" || return 1
  [ "$state" = present ] || return 1
  declare -F terminal_team_input_ready >/dev/null 2>&1 || return 1
  for type in "$@"; do
    [ -n "$type" ] || return 1
    cli="$(agmsg_type_get "$type" cli 2>/dev/null)" || return 1
    [ -n "$cli" ] || return 1
    saw_type=1
    if result="$(terminal_team_input_ready "$pane" "$cli" 2>/dev/null)"; then
      rc=0
    else
      rc=$?
    fi
    [ "$rc" -eq 1 ] && [ "$result" = not_ready:agent_not_found ] || return 1
  done
  [ "$saw_type" -eq 1 ] || return 1
  printf 'absent\n'
}

rows="$(_placement_collision_rows)"
[ -n "$rows" ] || exit 0

printf 'Placement collisions:\n'
current="" types=""
while IFS="$(printf '\t')" read -r ref team agent type; do
  [ -n "$ref" ] || continue
  if [ "$ref" != "$current" ]; then
    if [ -n "$current" ]; then
      resident="$(_collision_resident "$current" $types 2>/dev/null)" || resident=""
      [ "$resident" = absent ] && printf '    resident_agent: absent\n'
    fi
    current="$ref"; types=""
    printf '  ref: %s\n' "$ref"
  fi
  printf '    - %s/%s\n' "$team" "$agent"
  case " $types " in *" $type "*) ;; *) types="${types:+$types }$type" ;; esac
done <<EOF
$rows
EOF
if [ -n "$current" ]; then
  resident="$(_collision_resident "$current" $types 2>/dev/null)" || resident=""
  [ "$resident" = absent ] && printf '    resident_agent: absent\n'
fi
exit 0
