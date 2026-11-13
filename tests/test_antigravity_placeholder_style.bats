#!/usr/bin/env bats

# agmsg_safe_poke's --placeholder-style (terminal-poke real-machine round,
# 2026-11-13): antigravity draws its idle-box placeholder in ESC[38;5;8m,
# not the plain SGR 2 (faint) every other type's own placeholder/candidate
# text uses. Without this, the existing two-snapshot styled check read that
# placeholder as a real, stationary draft and refused every idle herdr
# seat -- direct unit tests against agmsg_safe_poke itself (no real driver,
# no poke.sh subprocess), same frame as test_safe_poke_draft.bats.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  POKE_LOG="$TEST_SKILL_DIR/poke.log"; : > "$POKE_LOG"
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/safe-poke.sh"
  terminal_poke() { printf '%s %s\n' "$1" "$2" >> "$POKE_LOG"; return 0; }
  ESC="$(printf '\033')"
  RULE="────────────────────"
  # The idle box, structurally as captured live: a rule-line pair (what
  # agmsg_input_box_locate's boxed mode scopes to) around a marker ">" in
  # one color, a space, then the placeholder text in ESC[38;5;8m --
  # stationary across both of agmsg_safe_poke's own ~1s-apart reads (it
  # never changes while idle, so returning the SAME screen each call
  # reproduces that).
  IDLE_SCREEN="$(printf '%s\n%s[38;5;12m>%s[0m %s[38;5;8mAuto mode: edits & safe commands auto-approved (shift+tab to cycle)%s[0m\n%s\n' \
    "$RULE" "$ESC" "$ESC" "$ESC" "$ESC" "$RULE")"
  REAL_DRAFT_SCREEN="$(printf '%s\n%s[38;5;12m>%s[0m hello, this is really being typed\n%s\n' \
    "$RULE" "$ESC" "$ESC" "$RULE")"
}
teardown() { teardown_test_env; }

@test "antigravity idle placeholder (ESC[38;5;8m), WITH --placeholder-style: not a real draft, pokes" {
  terminal_peek_styled() { printf '%s\n' "$IDLE_SCREEN"; return 0; }
  sleep() { :; }  # skip the real 1s settle wait in this unit test
  run agmsg_safe_poke pane-1 "agmsg: you have new messages." '>' yes testteam agy1 --placeholder-style '38;5;8'
  [ "$status" -eq 0 ]
  grep -q '^pane-1 agmsg: you have new messages\.$' "$POKE_LOG"
}

@test "antigravity idle placeholder, WITHOUT --placeholder-style: misread as a real draft, refuses (the bug this fixes)" {
  terminal_peek_styled() { printf '%s\n' "$IDLE_SCREEN"; return 0; }
  sleep() { :; }
  run agmsg_safe_poke pane-1 "agmsg: you have new messages." '>' yes testteam agy1
  [ "$status" -eq 14 ]
  [ ! -s "$POKE_LOG" ]
}

@test "a genuine real draft still refuses even with --placeholder-style set (the fix does not widen what counts as empty)" {
  terminal_peek_styled() { printf '%s\n' "$REAL_DRAFT_SCREEN"; return 0; }
  sleep() { :; }
  run agmsg_safe_poke pane-1 "agmsg: you have new messages." '>' yes testteam agy1 --placeholder-style '38;5;8'
  [ "$status" -eq 14 ]
  [ ! -s "$POKE_LOG" ]
}
