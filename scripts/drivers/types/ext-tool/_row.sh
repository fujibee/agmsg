#!/usr/bin/env bash
# ext-tool row plug. Sourced into team.sh's own shell by its generic
# per-type hook loader (agmsg_type_get, _emit_row, agmsg_validate_tool_name
# are already in scope by the time this runs); this hook may not call exit.

# ext-tool's own registration (see join.sh's _join.sh plug) stores a
# synthetic placeholder in place of a real project path:
# "(ext-tool:<tool>)" -- it has no filesystem project the way every other
# type does. This is the ONE place that parses it, so every reader of a
# tool name (human display, --json's "tool" field) agrees on the same rule.
# Echoes the tool name and returns 0 on a clean match; returns 1 (echoing
# nothing) on anything else, including an empty or malformed name -- never
# guessed at, so a project string that merely happens to start the same way
# is never mistaken for one.
#
# The candidate between the parens is also run through
# agmsg_validate_tool_name (review finding) -- the SAME validator join.sh
# itself gates a --tool argument through before it ever becomes a path
# (drivers/ext-tools/<tool>/). Stripping the parens alone would display
# whatever a corrupted or hand-edited registration happened to carry between
# them, including something like "../slack" or "foo bar", as if it were a
# real tool name; its own stderr is discarded here since this is a display
# path, not the point the name is actually used as one.
_ext_tool_name() {
  local project="$1" name
  case "$project" in
    '(ext-tool:'*')')
      name="${project#(ext-tool:}"
      name="${name%)}"
      case "$name" in
        ''|*'('*|*')'*) return 1 ;;
      esac
      agmsg_validate_tool_name "$name" 2>/dev/null || return 1
      printf '%s' "$name"
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Full override of a member's row: ext-tool is a program, not a session, so
# no terminal, pane, or screen was ever going to exist for it
# (scripts/drivers/types/ext-tool/type.conf declares spawnable=no,
# readiness_sentinel=no). The generic placement-based flow this replaces
# gets here by trying to resolve a placement record and reporting exactly
# how that failed; doing the same for ext-tool would report a string of
# "unknown:no_placement_record"-shaped cells for a member that was never
# going to have one, reading as broken when it is working as designed. "-"
# in place of those fields, not a reused n/a:<reason> string, is what makes
# that visible at a glance instead of needing an explanation.
#
# Returns 0 having emitted the row itself (via _emit_row, already in scope,
# format-agnostic between human/json); returns 1 with NO output at all when
# it declines, so team.sh's caller can fall through to its own generic flow
# cleanly.
agmsg_team_row_override() {
  local team="$1" agent="$2" type="$3" project="$4"
  local tool=""
  tool="$(_ext_tool_name "$project")" || tool=""
  # Not _member_delivery: that reads a per-project settings-hooks file,
  # which does not and cannot exist for ext-tool's synthetic project
  # placeholder, and reports "unknown:delivery_status_rc_N" -- itself
  # another error-shaped string for a thing that isn't broken. Read the
  # type's own manifest instead (agmsg_type_get, already in scope) rather
  # than assuming delivery_modes=off: a missing or unreadable manifest
  # returns empty here (its own documented behavior, indistinguishable from
  # a genuinely absent key), and that case must not be reported as the
  # deliberate "off" a readable manifest would actually say -- review
  # finding.
  local delivery
  delivery="$(agmsg_type_get "$type" delivery_modes)"
  [ -n "$delivery" ] || delivery="unknown:type_manifest_unreadable"
  _emit_row "$agent" "$type" "$project" - - - \
    - "$delivery" \
    n/a:not_applicable n/a:not_applicable n/a:not_applicable \
    n/a:not_applicable n/a:not_applicable n/a:not_applicable \
    n/a:not_applicable n/a:not_applicable n/a:not_applicable \
    n/a cannot no_terminal "$tool"
  return 0
}
