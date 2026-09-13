#!/usr/bin/env bats
# Self-locate-by-token matching core (#1124). Interface only -- these tests
# feed the classifier pane text the caller already collected; none of them
# poke a real seat or peek a real pane. See scripts/lib/token-locate.sh for
# what is deliberately NOT covered here (scan-depth bound, serializing
# concurrent probes, waiting for the seat's own completion signal).

load test_helper

setup() {
  setup_test_env
  # shellcheck disable=SC1090
  . "$SCRIPTS/lib/token-locate.sh"
}
teardown() { teardown_test_env; }

@test "a token found in exactly one pane's text is found (#1124)" {
  run agmsg_token_locate_classify tok-1 herdr:sockA:w1:p1 "some prompt text\ntok-1\nmore text"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'found\therdr:sockA:w1:p1')" ]
}

@test "a token in none of the panes is not_found (#1124)" {
  run agmsg_token_locate_classify tok-1 herdr:sockA:w1:p1 "nothing here" herdr:sockA:w1:p2 "nor here"
  [ "$status" -eq 0 ]
  [ "$output" = not_found ]
}

@test "a token found in two panes is ambiguous, not silently the first match (#1124)" {
  run agmsg_token_locate_classify tok-1 \
    herdr:sockA:w1:p1 "line before\ntok-1\nline after" \
    herdr:sockA:w1:p2 "someone typed tok-1 by hand too"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ambiguous\therdr:sockA:w1:p1,herdr:sockA:w1:p2')" ]
}

@test "a third pane without the token does not affect a two-way ambiguity (#1124)" {
  run agmsg_token_locate_classify tok-1 \
    herdr:sockA:w1:p1 "tok-1 here" \
    herdr:sockA:w1:p2 "nothing" \
    herdr:sockA:w1:p3 "tok-1 also here"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ambiguous\therdr:sockA:w1:p1,herdr:sockA:w1:p3')" ]
}

@test "an empty token is never found: refuses to match everything (#1124)" {
  run agmsg_token_locate_classify "" herdr:sockA:w1:p1 "anything at all"
  [ "$status" -eq 0 ]
  [ "$output" = not_found ]
}

@test "no panes given is not_found (#1124)" {
  run agmsg_token_locate_classify tok-1
  [ "$status" -eq 0 ]
  [ "$output" = not_found ]
}

@test "generated tokens are short enough not to wrap a narrow pane (#1124)" {
  run agmsg_token_locate_generate
  [ "$status" -eq 0 ]
  # Measured cause of the defect this guards: a ~130-char token wrapped
  # across three lines and defeated exact matching. Comfortably under any
  # realistic terminal width.
  [ "${#output}" -le 40 ]
  [[ "$output" == agmsg-locate-* ]]
}

@test "two generated tokens are not the same value (#1124)" {
  local t1 t2
  t1="$(agmsg_token_locate_generate)"
  t2="$(agmsg_token_locate_generate)"
  [ -n "$t1" ]
  [ -n "$t2" ]
  [ "$t1" != "$t2" ]
}
