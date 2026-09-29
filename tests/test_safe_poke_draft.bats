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

@test "safe-poke: a driver-capable draft hook is checked first -- content refuses without polling the screen, empty-twice pokes, unknown (rc 10) stops without writing (#1443 continuation)" {
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

  # (c) The hook cannot tell (rc 10, no agentIdentity) -> stops without
  # writing at all, even if the screen looks completely unchanged across
  # both reads. A driver whose screen never shows real draft content would
  # make "unchanged" meaningless as safety evidence, so this must never be
  # folded into a poke -- rc 10 propagates as the poke's own failure,
  # terminal_poke is never called.
  : > "$POKE_LOG"
  terminal_input_draft() { return 10; }
  terminal_peek() { printf '> \n\ngpt-5 \xc2\xb7 idle\n'; }
  unset -f terminal_peek_styled
  run agmsg_safe_poke pane-1 "text" '>' no testteam alice
  [ "$status" -eq 10 ]
  [ ! -s "$POKE_LOG" ]

  # (d) A SECOND read landing on "unknown" (identity lost mid-check) is
  # treated as a safe refusal (14), same as real content -- never a fresh
  # fallback attempt mid-poke. terminal_input_draft is invoked via command
  # substitution (a subshell), so a plain variable it sets would never be
  # seen by the next call -- a file-backed counter survives across calls.
  : > "$POKE_LOG"
  local cnt_file="$TEST_SKILL_DIR/draft-call-count"
  : > "$cnt_file"
  terminal_input_draft() {
    local c
    c="$(cat "$cnt_file")"; c=$((c + 1)); printf '%s' "$c" > "$cnt_file"
    [ "$c" -eq 1 ] && { printf '\n'; return 0; }
    return 10
  }
  run agmsg_safe_poke pane-1 "text" '>' no testteam alice
  [ "$status" -eq 14 ]
  [ ! -s "$POKE_LOG" ]
}

@test "safe-poke: the screen-check helper survives set -e on the ordinary unchanged case, and hands the SECOND read's region forward when the two differ (#1446 review, round 2)" {
  # Every real caller of this file (poke.sh, self-rename.sh, self-write.sh)
  # runs under `set -e`, and calls this helper as a bare simple command --
  # so the helper's OWN exit status matters, not just the globals it sets.
  # Round 1 of this fix ended the function with a bare
  # `[ "$snap1" != "$snapshot" ] && _AGMSG_SAFE_POKE_IB_RC=14`: on the
  # ordinary UNCHANGED case (by far the common one -- nothing being typed),
  # that test is false, so the whole bare command -- the function's own last
  # command -- returns 1, and under set -e that kills the caller's shell
  # before it ever reaches the next line. Enabling set -e here reproduces
  # that production condition directly, rather than trusting that bats'
  # own (non-errexit) subshell would happen to reveal it -- it did not: the
  # first push of that regression passed this whole suite.
  set -e

  # (a) unchanged screen, both reads identical -> must survive under set -e
  # and reach the ordinary safe poke, exactly like before this file existed.
  terminal_peek() { printf '> \n\ngpt-5 \xc2\xb7 idle\n'; }
  agmsg_safe_poke pane-1 "text" '>' no testteam alice
  [ "$(cat "$POKE_LOG")" = "pane-1 text" ]

  # (b) Direct unit test of _agmsg_safe_poke_screen_check itself (real
  # agmsg_input_box_locate, no fabricated region format): the two
  # terminal_peek reads return flat, structurally-valid boxes whose marker
  # line differs, so the change-detection branch fires (rc 14) and the
  # question is which read's region survives into
  # _AGMSG_SAFE_POKE_IB_REGION. An earlier draft of this extraction
  # reassigned it back to the FIRST read's region right here; fixed to leave
  # the second read's value (already set by the second
  # _agmsg_safe_poke_read_box call) untouched. terminal_peek is invoked via
  # command substitution (a subshell), so a plain variable it sets would
  # never be seen by the next call -- a file-backed counter survives across
  # calls.
  : > "$POKE_LOG"
  local cnt_file="$TEST_SKILL_DIR/peek-call-count"
  : > "$cnt_file"
  terminal_peek() {
    local c
    c="$(cat "$cnt_file")"; c=$((c + 1)); printf '%s' "$c" > "$cnt_file"
    if [ "$c" -eq 1 ]; then
      printf '> draft-one\n\ngpt-5 \xc2\xb7 idle\n'
    else
      printf '> draft-two\n\ngpt-5 \xc2\xb7 idle\n'
    fi
  }
  _agmsg_safe_poke_screen_check pane-1 '>' no 0 0
  [ "$_AGMSG_SAFE_POKE_IB_RC" -eq 14 ]
  [ "$_AGMSG_SAFE_POKE_IB_REGION" = "> draft-two" ]
}
