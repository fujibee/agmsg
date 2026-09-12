# Actual-location layer of the #1144 detector (interface only).
#
# NOT WIRED from placement-collisions.sh yet, and deliberately so: this layer
# needs a live census (#1155's agmsg_terminal_enumerate, still landing) and
# this function performs no enumeration of its own -- it only classifies a
# SEAT's own claimed locator against a census snapshot the CALLER already
# collected. Wiring it means the caller takes one `agmsg_terminal_enumerate`
# snapshot, then classifies every seat's own record against that SAME
# snapshot -- not a fresh call per seat, which would let the fleet change
# mid-report and turn the answer into a mixed-time snapshot (the failure mode
# #1144's design note names for folding this into a repair sweep).
#
# Census rows are agmsg_terminal_enumerate's own TSV lines, unmodified:
#   <kind>\t<instance>\t<pane>   a pane was observed there
#   !\t<kind>\t<instance>        that instance could not be read
#   !!\t<kind>                   that terminal's instance list could not be read
#   ?\t<kind>                    that terminal cannot enumerate at all
#
# _agmsg_actual_location_classify <census_rows> <kind> <instance> <pane>
#
# Prints exactly one of:
#
#   matched                   the locator was positively observed in the census
#   stale_or_missing_target   the census reached this exact instance (or found
#                             it to hold no panes at all) and did NOT observe
#                             this pane there -- a positive absence, not a guess
#   unknown                   the census never reached this locator at all:
#                             its terminal kind could not enumerate (`?`), that
#                             kind's instance list could not be read (`!!`), or
#                             this specific instance could not be read (`!`).
#                             Never say "stale" for this case -- "could not
#                             look" must not become "not there".
#
# occupant_mismatch is deliberately NOT produced here. That needs occupant
# IDENTITY -- who is actually sitting in the pane -- and #1155's census
# proves only that a pane EXISTS, not who holds it (verified by reading its
# shipped implementation, not assumed from its PR description). A caller
# must not treat "matched" as "this seat is really there" without a separate
# identity check; enumeration success, agent-likeness, and identity are three
# different facts and this function establishes only the first.
_agmsg_actual_location_classify() {   # <census_rows> <kind> <instance> <pane>
  local census="$1" kind="$2" inst="$3" pane="$4" line
  local t; t="$(printf '\t')"
  while IFS= read -r line; do
    case "$line" in
      "?${t}${kind}")            printf 'unknown\n'; return 0 ;;
      "!!${t}${kind}")           printf 'unknown\n'; return 0 ;;
      "!${t}${kind}${t}${inst}") printf 'unknown\n'; return 0 ;;
      "${kind}${t}${inst}${t}${pane}") printf 'matched\n'; return 0 ;;
    esac
  done <<< "$census"
  printf 'stale_or_missing_target\n'
}
