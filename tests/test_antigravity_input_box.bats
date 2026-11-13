#!/usr/bin/env bats

# antigravity's input_prompt_marker/input_prompt_boxed (type.conf): a bare
# ">" boxed between two 20+-char rule lines. Fixtures below reproduce the
# STRUCTURE of two real captured Antigravity 1.5.7 screens (tmux
# capture-pane -p -e), not their full decoration -- idle prompt, and a
# permission confirmation screen whose own options line also starts with
# "> " but is not wrapped in a rule-line pair the way the idle prompt is.
# This is exactly the case terminal-poke's real-machine round found: with no
# marker set at all, poke.sh typed straight over a live "Allow access to
# this file?" prompt (#1941 area unrelated; terminal-poke review, 2026-11-13).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/input-box.sh"
}
teardown() { teardown_test_env; }

RULE="────────────────────"

@test "antigravity idle prompt: bare > boxed between two rule lines is located" {
  local screen
  screen="$(printf '%s\n%s\n%s\n? for shortcuts\n' \
    "$RULE" \
    '>' \
    "$RULE")"
  run agmsg_input_box_locate '>' yes "$screen"
  [ "$status" -eq 0 ]
  [ "$output" = '>' ]
}

@test "antigravity confirmation screen: an option line starting with '> ' outside the last rule pair is NOT located (box_not_found)" {
  local screen
  screen="$(printf '%s\nFile access\n%s\nRead: /tmp/x/harmless.txt\n\nAllow access to this file?\n> 1. Yes, allow access\n  2. No, deny access\n' \
    "$RULE" "$RULE")"
  run agmsg_input_box_locate '>' yes "$screen"
  [ "$status" -eq 1 ]
}

@test "antigravity confirmation screen on herdr: mismatched short (scrollback) / long (box-width) rules must NOT pair, even when a prior turn's own '> ...' line sits between them" {
  # Reproduces the real herdr screen structure (measured live, 2026-11-13):
  # a short ~60-char rule separates scrollback TURNS, a long ~120-char rule
  # bounds the live input box -- both satisfy "starts with 20+ dashes", so
  # the ORIGINAL version of this check (matching on "last two rule-looking
  # lines", regardless of their own length) paired the short turn-separator
  # above a prior "> Read the file ..." request with the unrelated long
  # rule further down, and read that prior turn's own line as the live box.
  local short long screen
  short="$(printf '─%.0s' $(seq 1 60))"
  long="$(printf '─%.0s' $(seq 1 120))"
  screen="$(printf '%s\n> Read the file /tmp/x/harmless.txt and tell me its first word.\n\nFile access\n%s\n\nRead: /tmp/x/harmless.txt\n\nAllow access to this file?\n> 1. Yes, allow access\n  2. No, deny access\n' \
    "$short" "$long")"
  run agmsg_input_box_locate '>' yes "$screen"
  [ "$status" -eq 1 ]
}

@test "antigravity idle box on herdr: two SAME-length long rules still locate correctly (the mismatched-rule fix does not break the ordinary case)" {
  local long screen
  long="$(printf '─%.0s' $(seq 1 120))"
  screen="$(printf '%s\n> \n%s\n? for shortcuts\n' "$long" "$long")"
  run agmsg_input_box_locate '>' yes "$screen"
  [ "$status" -eq 0 ]
}

@test "antigravity idle prompt with styling intact still locates (style-stripped match, styled echo)" {
  local esc screen
  esc="$(printf '\033')"
  screen="$(printf '%s\n%s[94m>%s[39m\n%s\n' "$RULE" "$esc" "$esc" "$RULE")"
  run agmsg_input_box_locate '>' yes "$screen"
  [ "$status" -eq 0 ]
  [[ "$output" == *">"* ]]
}
