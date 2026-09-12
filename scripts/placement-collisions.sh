#!/usr/bin/env bash
set -euo pipefail

# Read-only, installation-wide placement collision report (#1144).
# Deliberately separate from team.sh: this command observes the fleet so an
# operator can decide which seat to contact; it never participates in a seat's
# self-repair path and never changes a placement record.
#
# TWO LAYERS, kept apart on purpose (see the #1144 design note reached from
# the issue). Folding them into one pass makes "we could not look" collapse
# into "there is nothing there" -- the exact failure this report exists to
# prevent.
#
#   record-only layer (this file, ACTIVE today)
#     Duplicate consistency: do two DIFFERENT seats' records resolve to the
#     same canonical (kind, instance, pane) locator? Answered ENTIRELY from
#     records on disk. No terminal is ever asked anything -- no
#     terminal_pane_state, no agent_list, nothing that touches a live pane.
#     A ref that cannot be resolved to a locator carrying an instance
#     component (every herdr ref today; a legacy bare tmux %N/@N) is not
#     silently joined by raw string equality -- it is reported as
#     unscoped_record and excluded from both the collision count and a
#     "collisions: none" verdict, because record-only evidence genuinely
#     cannot tell such refs apart across terminal instances (measured for
#     herdr in #1155: two live instances answered the same bare pane id).
#
#   actual-location layer (interface only, NOT wired here)
#     Does an individual seat's own claimed locator match where a census
#     (#1155's agmsg_terminal_enumerate) actually observed it? This needs a
#     live enumeration and an occupant-identity resolution this script does
#     not perform, so it stays a documented interface
#     (scripts/lib/placement-actual-location.sh) until #1155 lands and is
#     wired from here. Do not make that layer report "matched" or
#     "stale_or_missing_target" against a stubbed or partial census -- an
#     interface with no real observation behind it must not be exercised
#     end-to-end, since a caller cannot tell "checked, fine" from "not
#     really checked" once it prints a verdict.

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

TAB="$(printf '\t')"

# `teams/` itself missing is a THIRD value, distinct from "walked everything
# and found nothing" and from "walked, but something along the way could not
# be read" -- there was no walk to attempt at all.
if [ ! -d "$SKILL_DIR/teams" ]; then
  printf 'collisions: not_attempted\n'
  printf 'reason: no teams directory\n'
  exit 0
fi

COV_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agmsg-placement-collisions.XXXXXX")"
trap 'rm -rf "$COV_DIR"' EXIT
: > "$COV_DIR/agent_enumeration_failed"
: > "$COV_DIR/path_resolution_failed"
: > "$COV_DIR/record_unreadable"
: > "$COV_DIR/empty_ref"
: > "$COV_DIR/rows"
: > "$COV_DIR/unscoped"

shopt -s nullglob
cfgs=("$SKILL_DIR"/teams/*/config.json)
shopt -u nullglob

for cfg in "${cfgs[@]}"; do
  [ -f "$cfg" ] || continue
  team="${cfg%/config.json}"; team="${team##*/}"
  escaped="$(sed "s/'/''/g" "$cfg")"
  # CAPTURED, not looped-over-directly: a query that fails outright must not
  # read as "this team has zero agents" (the same shape #1155 was BLOCKed on
  # in review -- an extraction failure silently becoming an empty result).
  if agents="$(sqlite3 -noheader :memory: \
      "SELECT key FROM json_each(json_extract('$escaped', '\$.agents')) ORDER BY key;" 2>/dev/null)"; then
    :
  else
    printf '%s\n' "$team" >> "$COV_DIR/agent_enumeration_failed"
    continue
  fi
  [ -n "$agents" ] || continue   # zero registered agents is a real, observed state
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    if ! rec="$(agmsg_spawn_path "$team" "$agent" 2>/dev/null)"; then
      printf '%s/%s\n' "$team" "$agent" >> "$COV_DIR/path_resolution_failed"
      continue
    fi
    # No placement record at all is the ordinary state for a registered agent
    # that has never named a pane -- not a read failure, so not a coverage gap.
    [ -f "$rec" ] || continue
    # NOT `IFS="$TAB" read -r ref _project _type < "$rec"`: tab is an "IFS
    # whitespace" character to bash's read/word-splitting, so a LEADING tab
    # (an empty ref field) is silently swallowed rather than producing an
    # empty first field -- measured, `printf '\t/tmp/proj\tx\n'` read back
    # ref="/tmp/proj". Reading the whole line and slicing it with parameter
    # expansion does not collapse anything.
    if ! IFS= read -r rec_line < "$rec" 2>/dev/null; then
      printf '%s/%s\n' "$team" "$agent" >> "$COV_DIR/record_unreadable"
      continue
    fi
    case "$rec_line" in
      *"$TAB"*) ref="${rec_line%%"$TAB"*}" ;;
      *)        ref="$rec_line" ;;
    esac
    if [ -z "$ref" ]; then
      printf '%s/%s\n' "$team" "$agent" >> "$COV_DIR/empty_ref"
      continue
    fi
    if _agmsg_placement_split "$ref" 2>/dev/null; then
      case "$_AGMSG_PS_TERM" in
        # plain's ref is always the "no addressable pane" sentinel (see
        # driver-interface.md): there is no shared resource two records could
        # be claiming, so it is neither a collision candidate nor an
        # unscoped_record -- reporting it as either would imply doubt where
        # none exists.
        plain) : ;;
        tmux)
          if [ -n "$_AGMSG_PS_SOCK" ]; then
            printf 'tmux\t%s\t%s\t%s\t%s\n' \
              "$_AGMSG_PS_SOCK" "$_AGMSG_PS_ID" "$team" "$agent" >> "$COV_DIR/rows"
          else
            printf '%s\t%s\t%s\n' "$ref" "$team" "$agent" >> "$COV_DIR/unscoped"
          fi
          ;;
        *)
          # herdr today, and any future scheme with no instance component in
          # the ref: the record alone cannot name which live instance it
          # belongs to, so it cannot be safely joined against another record.
          printf '%s\t%s\t%s\n' "$ref" "$team" "$agent" >> "$COV_DIR/unscoped"
          ;;
      esac
    else
      printf '%s\t%s\t%s\n' "$ref" "$team" "$agent" >> "$COV_DIR/unscoped"
    fi
  done <<< "$agents"
done

# --- record-only collisions: group by canonical (kind, instance, pane) -----
# Same exclusion as the original #1144 report: one agent name registered in
# more than one team is one seat, not a collision, by itself. Rows in
# $COV_DIR/rows are "<kind>\t<instance>\t<pane>\t<team>\t<agent>"; only tmux
# rows with a resolved instance (socket) ever reach this file (see the main
# walk above), so kind is always "tmux" today, but the join is written on the
# three-field locator rather than assuming that.
#
# awk prints two tagged line shapes so the shell loop below never has to
# guess which fields a line carries: "GROUP\t<kind>\t<instance>\t<pane>" once
# per colliding locator, followed by one "ROW\t<team>\t<agent>" per claimant.
collision_groups="$(LC_ALL=C sort -t "$TAB" -k1,1 -k2,2 -k3,3 -k5,5 "$COV_DIR/rows" 2>/dev/null | awk -F'\t' '
  function flush() {
    if (distinct > 1) { printf "GROUP\t%s\t%s\t%s\n%s", kind, inst, pane, rows }
  }
  ($1 SUBSEP $2 SUBSEP $3) != key {
    flush()
    key = $1 SUBSEP $2 SUBSEP $3; kind = $1; inst = $2; pane = $3
    last_agent = ""; distinct = 0; rows = ""
  }
  {
    if ($5 != last_agent) { distinct++; last_agent = $5 }
    rows = rows "ROW\t" $4 "\t" $5 "\n"
  }
  END { flush() }
')"

n_collisions=0
collision_report=""
if [ -n "$collision_groups" ]; then
  while IFS="$TAB" read -r tag a b c; do
    case "$tag" in
      GROUP)
        n_collisions=$((n_collisions + 1))
        collision_report="${collision_report}  ref: ${a}:${b}:${c}"$'\n'
        ;;
      ROW)
        collision_report="${collision_report}    - ${a}/${b}"$'\n'
        ;;
    esac
  done <<< "$collision_groups"
fi

n_unscoped="$(wc -l < "$COV_DIR/unscoped" | tr -d ' ')"

# --- coverage: never let a silent skip read as a clean answer ---------------
n_agent_enum="$(wc -l < "$COV_DIR/agent_enumeration_failed" | tr -d ' ')"
n_path="$(wc -l < "$COV_DIR/path_resolution_failed" | tr -d ' ')"
n_record="$(wc -l < "$COV_DIR/record_unreadable" | tr -d ' ')"
n_empty_ref="$(wc -l < "$COV_DIR/empty_ref" | tr -d ' ')"
total_failures=$((n_agent_enum + n_path + n_record + n_empty_ref))

printf 'Placement collisions (record-only):\n'
if [ "$n_collisions" -gt 0 ]; then
  printf '%s' "$collision_report"
  printf 'collisions: %s\n' "$n_collisions"
elif [ "$total_failures" -gt 0 ]; then
  printf 'collisions: none_observed\n'
else
  printf 'collisions: none\n'
fi

printf 'unscoped_records: %s\n' "$n_unscoped"
if [ "$n_unscoped" -gt 0 ]; then
  LC_ALL=C sort "$COV_DIR/unscoped" | awk -F'\t' '
    $1 != ref { ref = $1; printf "  ref: %s\n", ref }
    { printf "    - %s/%s\n", $2, $3 }
  '
fi

if [ "$total_failures" -gt 0 ]; then
  printf 'coverage: partial\n'
  [ "$n_agent_enum" -gt 0 ] && printf '  agent_enumeration_failed: %s (%s)\n' \
    "$n_agent_enum" "$(paste -sd, "$COV_DIR/agent_enumeration_failed")"
  [ "$n_path" -gt 0 ] && printf '  path_resolution_failed: %s (%s)\n' \
    "$n_path" "$(paste -sd, "$COV_DIR/path_resolution_failed")"
  [ "$n_record" -gt 0 ] && printf '  record_unreadable: %s (%s)\n' \
    "$n_record" "$(paste -sd, "$COV_DIR/record_unreadable")"
  [ "$n_empty_ref" -gt 0 ] && printf '  empty_ref: %s (%s)\n' \
    "$n_empty_ref" "$(paste -sd, "$COV_DIR/empty_ref")"
else
  printf 'coverage: complete\n'
fi

exit 0
