#!/usr/bin/env bats

# safe-poke.sh's terminal_input_draft branch (#1443 continuation): the
# verb decides the method, not the terminal's name. A driver offering
# terminal_input_draft is checked FIRST, ahead of the screen-based
# styled/unstyled choice — direct unit tests against agmsg_safe_poke
# itself (no real driver, no poke.sh subprocess), stubbing only the
# terminal_* functions this branch actually calls.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  POKE_LOG="$TEST_SKILL_DIR/poke.log"; : > "$POKE_LOG"
  # shellcheck disable=SC1091
  source "$SKILL_DIR/scripts/lib/safe-poke.sh"
  terminal_poke() { printf '%s %s\n' "$1" "$2" >> "$POKE_LOG"; return 0; }
}
teardown() { teardown_test_env; }

@test "safe-poke: a driver-capable draft hook is checked first -- content refuses without polling the screen, empty-twice pokes, unknown falls back to the screen (#1443 continuation)" {
  # (a) A real draft on the FIRST read refuses immediately (rc 14) and never
  # calls terminal_poke or any screen-reading function -- the whole point of
  # this hook existing is to never need terminal_peek_styled at all.
  terminal_input_draft() { printf 'aGVsbG8=\n'; return 0; }   # base64("hello")
  terminal_peek_styled() { echo "screen must not be read when the hook answers content" >&2; return 1; }
  run agmsg_safe_poke pane-1 "text" '>' no testteam alice
  [ "$status" -eq 14 ]
  [ ! -s "$POKE_LOG" ]

  # (b) Both reads (1s apart) empty -> safe, pokes exactly once.
  terminal_input_draft() { printf '\n'; return 0; }
  run agmsg_safe_poke pane-1 "text" '>' no testteam alice
  [ "$status" -eq 0 ]
  [ "$(cat "$POKE_LOG")" = "pane-1 text" ]

  # (c) The hook cannot tell (rc 10) -> falls back to the screen entirely,
  # unstyled (this driver has no terminal_peek_styled in this scenario
  # either -- matching orca, which needed the hook precisely because it has
  # no styled read to fall back on). The fake screen is a genuine flat-style
  # box (marker line, a blank line, a footer with a middle dot --
  # agmsg_input_box_locate's own required shape) and identical on both
  # reads -> unchanged -> safe: the fallback's own unstyled two-read
  # comparison, not the draft hook, decided this.
  : > "$POKE_LOG"
  terminal_input_draft() { return 10; }
  terminal_peek() { printf '> \n\ngpt-5 \xc2\xb7 idle\n'; }
  unset -f terminal_peek_styled
  run agmsg_safe_poke pane-1 "text" '>' no testteam alice
  [ "$status" -eq 0 ]
  [ "$(cat "$POKE_LOG")" = "pane-1 text" ]
}
