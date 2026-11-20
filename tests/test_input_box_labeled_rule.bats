#!/usr/bin/env bats

# Claude Code's boxed input as a real pane draws it: the top rule spans the
# pane WITH the pane's label written into it ("──── <label> ─"), the bottom
# rule spans the pane unbroken. The top rule's leading run is therefore
# shorter than the bottom's by the label's width. A herdr pane read also
# ends every line in CR. The same-width pairing rule must still accept this
# box while continuing to refuse an unlabeled short turn-separator.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/input-box.sh"
}
teardown() { teardown_test_env; }

_rule() { printf '─%.0s' $(seq 1 "$1"); }

# <label> <pane width> [cr]: top rule with label, marker line, bottom rule,
# each line padded to the pane width the way Claude Code draws them.
_labeled_screen() {
  local label="$1" width="$2" eol="${3:-}" top_run
  top_run=$((width - ${#label} - 3))
  printf '%s %s ─%s\n❯ %s\n%s%s\n' \
    "$(_rule "$top_run")" "$label" "$eol" "$eol" "$(_rule "$width")" "$eol"
}

@test "labeled top rule shorter than the full-width bottom rule is located" {
  local screen
  screen="$(_labeled_screen herdrtest-probe 132)"
  run agmsg_input_box_locate '❯' yes "$screen"
  [ "$status" -eq 0 ]
  [ "$output" = '❯ ' ]
}

@test "labeled box read from herdr (CR-terminated lines) is located" {
  local screen
  screen="$(_labeled_screen herdrtest-probe 132 $'\r')"
  run agmsg_input_box_locate '❯' yes "$screen"
  [ "$status" -eq 0 ]
}

@test "labeled box with a multi-byte (CJK) label is located" {
  local screen
  screen="$(_labeled_screen 'チーム-名前' 120)"
  run agmsg_input_box_locate '❯' yes "$screen"
  [ "$status" -eq 0 ]
}

@test "an UNLABELED short rule above a long bottom rule still does not pair" {
  local screen
  screen="$(printf '%s\n❯ earlier turn\n\n%s\n' "$(_rule 60)" "$(_rule 120)")"
  run agmsg_input_box_locate '❯' yes "$screen"
  [ "$status" -eq 1 ]
}

@test "a labeled rule LONGER than the bottom rule does not pair" {
  local screen
  screen="$(printf '%s label ─\n❯ \n%s\n' "$(_rule 120)" "$(_rule 60)")"
  run agmsg_input_box_locate '❯' yes "$screen"
  [ "$status" -eq 1 ]
}

@test "rule-shape check: only '<run> <label> <run>' counts as labeled" {
  local r
  r="$(_rule 30)"
  _agmsg_input_box_rule_is_labeled "$r herdrtest-probe ─"
  _agmsg_input_box_rule_is_labeled "$r チーム-名前 ── "
  _agmsg_input_box_rule_is_labeled "$r foo bar ─"
  ! _agmsg_input_box_rule_is_labeled "$r"
  ! _agmsg_input_box_rule_is_labeled "$r  ─"
  ! _agmsg_input_box_rule_is_labeled "$r x"
  ! _agmsg_input_box_rule_is_labeled "$r ─── ─"
}
