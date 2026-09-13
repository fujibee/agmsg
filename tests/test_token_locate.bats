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

# --- agmsg_token_locate_self: the #1157 fallback wiring ---------------------
#
# Fakes stand in for terminal-registry.sh (agmsg_terminal_enumerate /
# agmsg_terminal_load / terminal_peek / agmsg_locator_compose) and for
# agmsg_token_locate_generate itself, so each test controls exactly what the
# "pane text" says without touching a real terminal. This is the same
# fixture style #1155's own tests use for agmsg_terminal_enumerate's row
# shapes.

_fixed_token() { agmsg_token_locate_generate() { printf 'fixed-test-token\n'; }; }

@test "self: unsupported when there is no census primitive at all (#1124)" {
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf 'unsupported\tcensus_primitive_unavailable')" ]
}

@test "self: undetermined when the census enumeration itself fails (#1124)" {
  agmsg_terminal_enumerate() { return 1; }
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	census_enumerate_failed"* ]]
}

@test "self: undetermined when the census observed nothing at all (#1124)" {
  agmsg_terminal_enumerate() { :; }
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	no_panes_observed"* ]]
}

@test "self: undetermined when every row is unreadable, never read as none observed (#1124)" {
  agmsg_terminal_enumerate() { printf '!\therdr\tsockA\n!!\ttmux\n?\tplain\n'; }
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	no_panes_readable"* ]]
}

@test "self: undetermined when panes are enumerated but none are peekable (#1124)" {
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() { return 12; }
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	no_panes_readable"* ]]
}

@test "self: proved when the emitted token matches exactly one peeked pane (#1124)" {
  _fixed_token
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\nherdr\tsockA\tw1:p2\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() {
    case "$1" in
      sockA:w1:p1) printf 'nothing here\n' ;;
      sockA:w1:p2) printf 'prompt\nfixed-test-token\nmore\n' ;;
    esac
  }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 0 ]
  grep -Fq "$(printf 'proved\therdr:sockA:w1:p2')" <<< "$output"
  # The token is emitted to this process's own stdout, not silently generated.
  grep -Fq "fixed-test-token" <<< "$output"
}

@test "self: undetermined (ambiguous), never proved, when two panes match (#1124)" {
  _fixed_token
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\nherdr\tsockA\tw1:p2\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() { printf 'fixed-test-token\n'; }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 2 ]
  grep -Fq "$(printf 'undetermined\tambiguous')" <<< "$output"
  refute grep -Fq "proved" <<< "$output"
}

@test "self: never emits disproved: not_found is undetermined instead (#1124)" {
  _fixed_token
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() { printf 'nothing at all here\n'; }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_token_locate_self myteam alice
  [ "$status" -eq 2 ]
  grep -Fq "$(printf 'undetermined\tnot_found')" <<< "$output"
  refute grep -Fq disproved <<< "$output"
}
