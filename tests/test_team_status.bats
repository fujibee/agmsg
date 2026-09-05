#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/team-status.sh"
}

agmsg_terminal_load() { return 0; }

@test "team location preserves a confirmed present answer" {
  agmsg_terminal_location_loaded() { printf 'w2:t1\tpresent\n'; }
  run agmsg_team_location herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'herdr\tw2:p3\tw2:t1\tpresent' ]
}

@test "team location preserves confirmed gone without inventing a container" {
  agmsg_terminal_location_loaded() { printf 'n/a:pane_gone\tgone\n'; }
  run agmsg_team_location tmux '%3'
  [ "$status" -eq 0 ]
  [ "$output" = $'tmux\t%3\tn/a:pane_gone\tgone' ]
}

@test "team location keeps a present-then-missing race present" {
  agmsg_terminal_location_loaded() {
    printf 'unknown:present_then_location_rc_10\tpresent\n'
  }
  run agmsg_team_location herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'herdr\tw2:p3\tunknown:present_then_location_rc_10\tpresent' ]
}

@test "team location reports a malformed contract without empty fields" {
  agmsg_terminal_location_loaded() { printf '\tpresent\n'; }
  run agmsg_team_location herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'herdr\tw2:p3\tunknown:location_contract_malformed\tunknown:location_contract_malformed' ]
}

@test "identity consistency treats expected n/a as verified" {
  run agmsg_identity_consistency \
    'n/a:no_independent_field' \
    'ok(actual=team:alice)' \
    'ok(actual=team-alice)'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "identity consistency gives mismatch precedence over unknown" {
  run agmsg_identity_consistency \
    'unknown:terminal_unavailable' \
    'mismatch(expected=team:alice,actual=team:bob)' \
    'ok(actual=team-alice)'
  [ "$status" -eq 0 ]
  [ "$output" = mismatch ]
}

@test "identity consistency keeps an unobserved source out of ok" {
  run agmsg_identity_consistency \
    'ok(actual=team:alice)' \
    'unknown:terminal_unavailable' \
    'n/a:no_session_name'
  [ "$status" -eq 0 ]
  [ "$output" = unverified ]
}

@test "CLI session title removes Claude state glyph without rewriting a name" {
  run agmsg_cli_session_from_title '◐ team-alice'
  [ "$status" -eq 0 ]
  [ "$output" = team-alice ]

  run agmsg_cli_session_from_title 'different session name'
  [ "$status" -eq 0 ]
  [ "$output" = 'different session name' ]
}

@test "human team row collapses verified identity details" {
  run agmsg_team_render_human_row \
    alice claude-code /repo herdr w2:p3 w2:t1 present working monitor \
    'ok(actual=team:alice)' 'ok(actual=a123)' 'ok(actual=team-alice)' ok
  [ "$status" -eq 0 ]
  [ "$output" = '  alice (claude-code) — /repo   [herdr w2:p3 @w2:t1 live=present activity=working delivery=monitor identity=ok]' ]
}

@test "human team row expands only non-ok identity observations" {
  run agmsg_team_render_human_row \
    carol claude-code /repo herdr w2:p7 w2:t2 present idle turn \
    'ok(actual=team:carol)' 'n/a:no_independent_key' \
    'mismatch(expected=team-carol,actual=carol)' mismatch
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '  carol (claude-code) — /repo   [herdr w2:p7 @w2:t2 live=present activity=idle delivery=turn identity=mismatch]' ]
  [ "${lines[1]}" = '    cli_session=mismatch(expected=team-carol,actual=carol)' ]
  [ "${#lines[@]}" -eq 2 ]
}
