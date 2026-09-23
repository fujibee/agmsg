#!/usr/bin/env bats
# Self-locate-by-token matching core (#1124). Interface only -- these tests
# feed the classifier pane text the caller already collected; none of them
# poke a real seat or peek a real pane. See scripts/lib/token-locate.sh for
# what is deliberately NOT covered here (scan-depth bound, serializing
# concurrent probes, waiting for the seat's own completion signal).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
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

# --- agmsg_token_locate_emit / agmsg_token_locate_observe: the #1157
# fallback wiring, split into two calls (#1386) ------------------------------
#
# Fakes stand in for terminal-registry.sh (agmsg_terminal_enumerate /
# agmsg_terminal_load / terminal_peek / agmsg_locator_compose), so each test
# controls exactly what the "pane text" says without touching a real
# terminal. This is the same fixture style #1155's own tests use for
# agmsg_terminal_enumerate's row shapes.
#
# observe reads a token a PRIOR, separate emit call already persisted -- these
# tests seed that record directly (the same fixture style test_self_fix.bats
# uses for actas locks) rather than calling emit first, since emit's own
# behavior (the token line, the persisted record, no observing) is covered
# separately below by its own tests.
OWNER=owner-A

_seed_token() {   # <team> <agent> <token> [witness] [emitted_at]
  local path; path="$(_agmsg_token_locate_path "$1" "$2")"
  mkdir -p "$(dirname "$path")"
  {
    printf 'token=%s\n' "$3"
    printf 'emitted_at=%s\n' "${5:-$(date -u +%s)}"
    printf 'witness=%s\n' "${4:-$OWNER}"
  } > "$path"
}

@test "observe: no_pending_token when nothing was emitted for this seat (#1386)" {
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [ "$output" = "$(printf 'undetermined\tno_pending_token')" ]
}

@test "observe: no_pending_token when the record is older than the TTL, and it is removed (#1386)" {
  local path; path="$(_agmsg_token_locate_path myteam alice)"
  _seed_token myteam alice stale-token "$OWNER" "$(($(date -u +%s) - _AGMSG_TOKEN_LOCATE_TTL - 5))"
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [ "$output" = "$(printf 'undetermined\tno_pending_token')" ]
  [ ! -e "$path" ]
}

# #1397: a record whose emitted_at is AHEAD of the clock (a stepped-back
# wall clock, or a corrupt future value) must not read as live just because
# `now - emitted_at` comes out negative -- age has to be checked >= 0, not
# only < TTL, or a record like this would stay "live" indefinitely.
@test "observe: no_pending_token when emitted_at is in the future (never reads as live) (#1397)" {
  local path; path="$(_agmsg_token_locate_path myteam alice)"
  _seed_token myteam alice future-token "$OWNER" "$(($(date -u +%s) + 3600))"
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [ "$output" = "$(printf 'undetermined\tno_pending_token')" ]
  [ ! -e "$path" ]
}

# #1397: `date -u +%s` failing outright (now empty) against a real,
# well-formed emitted_at must not read as live either. A DIFFERENT guard
# from the future-timestamp test above: that one relies on age >= 0
# rejecting a negative age once the arithmetic runs; this one never
# reaches the arithmetic at all -- an empty `now` is caught by
# _agmsg_token_locate_read's own non-empty check first. Pinned
# separately because either guard could regress without the other
# catching it.
@test "observe: no_pending_token when the clock itself cannot be read (#1397)" {
  local path; path="$(_agmsg_token_locate_path myteam alice)"
  _seed_token myteam alice fixed-test-token "$OWNER" "$(date -u +%s)"
  date() { return 1; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [ "$output" = "$(printf 'undetermined\tno_pending_token')" ]
  [ ! -e "$path" ]
}

# #1397: the role this token was emitted for can be restarted, resumed,
# or handed to a different session inside the TTL window. A bare (team,
# agent) key cannot tell that seat's own fresh call apart from a claim that
# has since been superseded -- observing the stale record would hand this
# seat a location an EARLIER occupant's pane produced. Requiring the
# caller's current owner token to match the one the record was written
# with is what makes that record unusable, not merely a mismatch this
# fixture is unlikely to hit.
@test "observe: no_pending_token when the caller's owner does not match who emitted it, and the record is left for its rightful owner (#1397)" {
  local path; path="$(_agmsg_token_locate_path myteam alice)"
  _seed_token myteam alice fixed-test-token owner-OLD
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [ "$output" = "$(printf 'undetermined\tno_pending_token')" ]
  # NOT deleted: a mismatch is not the same as garbage. owner-OLD's own
  # observe call, still inside the TTL, must still find it.
  [ -e "$path" ]
  run agmsg_token_locate_observe myteam alice owner-OLD
  # No census primitive faked in this test -- what matters here is only that
  # the token itself was read (past "no_pending_token") and the record is
  # gone afterward, not which of observe's later branches it then took.
  [ "$output" != "$(printf 'undetermined\tno_pending_token')" ]
  [ ! -e "$path" ]
}

@test "observe: unsupported when there is no census primitive at all (#1124)" {
  _seed_token myteam alice fixed-test-token
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 3 ]
  [ "$output" = "$(printf 'unsupported\tcensus_primitive_unavailable')" ]
}

@test "observe: undetermined when the census enumeration itself fails (#1124)" {
  _seed_token myteam alice fixed-test-token
  agmsg_terminal_enumerate() { return 1; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	census_enumerate_failed"* ]]
}

@test "observe: undetermined when the census observed nothing at all (#1124)" {
  _seed_token myteam alice fixed-test-token
  agmsg_terminal_enumerate() { :; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	no_panes_observed"* ]]
}

@test "observe: undetermined when every row is unreadable, never read as none observed (#1124)" {
  _seed_token myteam alice fixed-test-token
  agmsg_terminal_enumerate() { printf '!\therdr\tsockA\n!!\ttmux\n?\tplain\n'; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	no_panes_readable"* ]]
}

@test "observe: undetermined when panes are enumerated but none are peekable (#1124)" {
  _seed_token myteam alice fixed-test-token
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() { return 12; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"undetermined	no_panes_readable"* ]]
}

@test "observe: proved when the persisted token matches exactly one peeked pane, and the record is consumed (#1124, #1386)" {
  _seed_token myteam alice fixed-test-token
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\nherdr\tsockA\tw1:p2\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() {
    case "$1" in
      sockA:w1:p1) printf 'nothing here\n' ;;
      sockA:w1:p2) printf 'prompt\nfixed-test-token\nmore\n' ;;
    esac
  }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'proved\therdr:sockA:w1:p2')" ]
  # Single-use: consumed whether found or not (this one WAS found).
  [ ! -e "$(_agmsg_token_locate_path myteam alice)" ]
}

@test "observe: undetermined (ambiguous), never proved, when two panes match (#1124)" {
  _seed_token myteam alice fixed-test-token
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\nherdr\tsockA\tw1:p2\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() { printf 'fixed-test-token\n'; }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [ "$output" = "$(printf 'undetermined\tambiguous')" ]
}

@test "observe: never emits disproved: not_found is undetermined instead, and the record is consumed (#1124, #1386)" {
  _seed_token myteam alice fixed-test-token
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\n'; }
  agmsg_terminal_load() { :; }
  terminal_peek() { printf 'nothing at all here\n'; }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 2 ]
  [ "$output" = "$(printf 'undetermined\tnot_found')" ]
  [ ! -e "$(_agmsg_token_locate_path myteam alice)" ]
}

# --- agmsg_token_locate_emit / agmsg_token_locate_pending (#1386) -----------

@test "emit: prints the token on its own line, to stderr, and persists a pending record; observe then finds it" {
  local out; out="$(agmsg_token_locate_emit myteam alice "$OWNER" 2>&1 1>/dev/null)"
  case "$out" in
    "AGMSG_LOCATE_TOKEN(myteam/alice): "*) ;;
    *) false ;;
  esac
  run agmsg_token_locate_pending myteam alice "$OWNER"
  [ "$status" -eq 0 ]
  agmsg_terminal_enumerate() { printf 'herdr\tsockA\tw1:p1\n'; }
  agmsg_terminal_load() { :; }
  local token="${out#AGMSG_LOCATE_TOKEN(myteam/alice): }"
  terminal_peek() { printf 'prompt\n%s\nmore\n' "$token"; }
  agmsg_locator_compose() { printf '%s:%s:%s\n' "$1" "$2" "$3"; }
  run agmsg_token_locate_observe myteam alice "$OWNER"
  [ "$status" -eq 0 ]
  [[ "$output" == proved* ]]
}

@test "emit writes NOTHING to stdout: the token line cannot be captured by a caller's \$(...) and lost before it reaches the screen (#1386)" {
  local out; out="$(agmsg_token_locate_emit myteam alice "$OWNER" 2>/dev/null)"
  [ -z "$out" ]
}

@test "pending: false with no record, true right after emit, false again after observe consumes it (#1386)" {
  run agmsg_token_locate_pending myteam alice "$OWNER"
  [ "$status" -eq 1 ]
  agmsg_token_locate_emit myteam alice "$OWNER" 2>/dev/null
  run agmsg_token_locate_pending myteam alice "$OWNER"
  [ "$status" -eq 0 ]
  agmsg_terminal_enumerate() { :; }   # any observe outcome consumes the record
  agmsg_token_locate_observe myteam alice "$OWNER" >/dev/null || true
  run agmsg_token_locate_pending myteam alice "$OWNER"
  [ "$status" -eq 1 ]
}

# #1397: emit persists the CURRENT caller's own owner as the record's
# witness -- pending (and therefore observe) for the SAME role under a
# DIFFERENT owner (a restart/resume/handoff that re-claimed it) must not
# see this one as reusable, even though it is fresh and well within the TTL.
@test "pending: a fresh record is not reusable by a different owner (#1397)" {
  agmsg_token_locate_emit myteam alice owner-OLD 2>/dev/null
  run agmsg_token_locate_pending myteam alice owner-NEW
  [ "$status" -eq 1 ]
  # The original owner can still observe it -- this is a witness check, not
  # an accidental corruption of the record itself.
  run agmsg_token_locate_pending myteam alice owner-OLD
  [ "$status" -eq 0 ]
}
