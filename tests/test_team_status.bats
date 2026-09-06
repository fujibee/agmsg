#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  # shellcheck disable=SC1090
  source "$SCRIPTS/lib/team-status.sh"
}

agmsg_terminal_load() { return 0; }

install_team_fake_tmux() {
  local bindir="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$bindir"
  cat > "$bindir/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'tmux' >> "$TEAM_TMUX_LOG"
for arg in "$@"; do printf ' [%s]' "$arg" >> "$TEAM_TMUX_LOG"; done
printf '\n' >> "$TEAM_TMUX_LOG"
case "$*" in
  *pane_in_mode*) printf '0|64066|/dev/ttys066\n' ;;
  *show-options*) printf 'team:alice\n' ;;
  *pane_title*) printf '✳ team-alice\n' ;;
esac
EOF
  chmod +x "$bindir/tmux"
  export TEAM_TMUX_LOG="$BATS_TEST_TMPDIR/tmux.log"
  export PATH="$bindir:$PATH"
}

@test "team location preserves an observed container" {
  terminal_where() { printf 'w2:t1\n'; }
  run agmsg_team_location herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'herdr\tw2:p3\tw2:t1' ]
}

@test "team location keeps a failed lookup explicit" {
  terminal_where() { return 10; }
  run agmsg_team_location tmux '%3'
  [ "$status" -eq 0 ]
  [ "$output" = $'tmux\t%3\tunknown:location_rc_10' ]
}

@test "team location reports a malformed contract without empty fields" {
  terminal_where() { printf '\n'; }
  run agmsg_team_location herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'herdr\tw2:p3\tunknown:location_malformed' ]
}

@test "team observation preserves four explicit driver fields" {
  terminal_team_observe() {
    printf 'working\tteam:alice\ta123\t◐ team-alice\n'
  }
  run agmsg_team_observe_loaded w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'working\tteam:alice\ta123\t◐ team-alice' ]
}

@test "team observation does not turn an absent extension into empty success" {
  unset -f terminal_team_observe
  run agmsg_team_observe_loaded w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'unknown:observe_unsupported\tunknown:observe_unsupported\tunknown:observe_unsupported\tunknown:observe_unsupported' ]
}

@test "identity cell distinguishes n/a, unknown, match, and mismatch" {
  run agmsg_identity_cell team:alice n/a:no_independent_field
  [ "$output" = n/a:no_independent_field ]
  run agmsg_identity_cell team:alice unknown:terminal_unavailable
  [ "$output" = unknown:terminal_unavailable ]
  run agmsg_identity_cell team:alice team:alice
  [ "$output" = 'ok(actual=team:alice)' ]
  run agmsg_identity_cell team:alice team:bob
  [ "$output" = 'mismatch(expected=team:alice,actual=team:bob)' ]
}

@test "tmux identity treats its shared pane label as n/a and still verifies" {
  terminal_team_observe() {
    printf 'n/a:unsupported\tn/a:no_independent_field\tteam:alice\t✳ team-alice\n'
  }
  agmsg_type_get() { [ "$2" = name_arg ] && printf '%s\n' -n; }
  run agmsg_team_identity_loaded team alice claude-code tmux '%3'
  [ "$status" -eq 0 ]
  [ "$output" = $'n/a:unsupported\tn/a:no_independent_field\tteam:alice\tteam:alice\tteam:alice\tteam-alice\tteam-alice\tn/a:no_independent_field\tok(actual=team:alice)\tok(actual=team-alice)\tok' ]
}

@test "a type without name_arg makes CLI session expected n/a" {
  terminal_team_observe() {
    printf 'idle\tteam:alice\ta123\ttransient title\n'
  }
  _herdr_internal_key() { printf 'a123\n'; }
  agmsg_type_get() { return 0; }
  run agmsg_team_identity_loaded team alice codex herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'idle\tteam:alice\tteam:alice\ta123\ta123\tn/a:no_session_name\tn/a:no_session_name\tok(actual=team:alice)\tok(actual=a123)\tn/a:no_session_name\tok' ]
}

@test "visible pane naming off is expected n/a while the key remains checked" {
  terminal_team_observe() {
    printf 'idle\tunknown:pane_label_missing\ta123\t✳ team-alice\n'
  }
  _herdr_internal_key() { printf 'a123\n'; }
  agmsg_type_get() { [ "$2" = name_arg ] && printf '%s\n' -n; }
  AGMSG_TERMINAL_NAMING=off run agmsg_team_identity_loaded team alice claude-code herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'idle\tn/a:disabled_by_policy\tteam:alice\ta123\ta123\tteam-alice\tteam-alice\tn/a:disabled_by_policy\tok(actual=a123)\tok(actual=team-alice)\tok' ]
}

@test "identity consistency treats expected n/a as verified" {
  run agmsg_identity_consistency \
    'n/a:no_independent_field' \
    'ok(actual=team:alice)' \
    'ok(actual=team-alice)'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "identity consistency does not call an entirely unobservable identity ok" {
  run agmsg_identity_consistency \
    'n/a:no_independent_field' \
    'n/a:no_addressable_pane' \
    'n/a:no_session_name'
  [ "$status" -eq 0 ]
  [ "$output" = n/a ]
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
    alice claude-code /repo herdr w2:p3 w2:t1 working monitor \
    'ok(actual=team:alice)' 'ok(actual=a123)' 'ok(actual=team-alice)' ok
  [ "$status" -eq 0 ]
  [ "$output" = '  alice (claude-code) — /repo   [herdr w2:p3 @w2:t1 activity=working delivery=monitor identity=ok]' ]
}

@test "human team row expands only non-ok identity observations" {
  run agmsg_team_render_human_row \
    carol claude-code /repo herdr w2:p7 w2:t2 idle turn \
    'ok(actual=team:carol)' 'n/a:no_independent_key' \
    'mismatch(expected=team-carol,actual=carol)' mismatch
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = '  carol (claude-code) — /repo   [herdr w2:p7 @w2:t2 activity=idle delivery=turn identity=mismatch]' ]
  [ "${lines[1]}" = '    cli_session=mismatch(expected=team-carol,actual=carol)' ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "JSON team row keeps every field and structured mismatch evidence" {
  run agmsg_team_render_json_row \
    carol claude-code /repo herdr w2:p7 w2:t2 idle turn \
    'ok(actual=team:carol)' team:carol team:carol \
    'ok(actual=a123)' a123 a123 \
    'mismatch(expected=team-carol,actual=carol)' team-carol carol mismatch
  [ "$status" -eq 0 ]
  [ "$(sqlite3 :memory: "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")','\$.member');")" = carol ]
  [ "$(sqlite3 :memory: "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")','\$.cli_session.status');")" = mismatch ]
  [ "$(sqlite3 :memory: "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")','\$.cli_session.expected');")" = team-carol ]
  [ "$(sqlite3 :memory: "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")','\$.cli_session.actual');")" = carol ]
  [ "$(sqlite3 :memory: "SELECT json_type('$(printf '%s' "$output" | sed "s/'/''/g")','\$.live');")" = "" ]
}

@test "readiness wrapper preserves a positive driver proof" {
  agmsg_type_get() { [ "$2" = cli ] && printf 'claude\n'; }
  terminal_team_input_ready() { printf 'ready\n'; return 0; }
  run agmsg_team_input_ready_loaded claude-code w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'ready\tpositive_agent_identity' ]
}

@test "readiness wrapper fails closed when the driver cannot prove readiness" {
  agmsg_type_get() { [ "$2" = cli ] && printf 'claude\n'; }
  terminal_team_input_ready() { printf 'unknown:agent_response_incomplete\n'; return 2; }
  run agmsg_team_input_ready_loaded claude-code w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'unknown\tagent_response_incomplete' ]
}

@test "identity fix repairs names and verifies the CLI rename" {
  agmsg_type_get() { [ "$2" = cli ] && printf 'claude\n'; }
  _herdr_internal_key() { printf 'a123\n'; }
  terminal_name() { printf '%s\n' "$4" >> "$BATS_TEST_TMPDIR/names"; }
  terminal_team_input_ready() { printf 'ready\n'; }
  terminal_poke() { printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/poke"; }
  terminal_team_observe() { printf 'idle\tteam:alice\ta123\t✳ team-alice\n'; }
  run agmsg_team_fix_identity_loaded team alice claude-code herdr w2:p3 \
    'mismatch(expected=team:alice,actual=alice)' \
    'mismatch(expected=a123,actual=old)' \
    'mismatch(expected=team-alice,actual=alice)'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'pane_label\tchanged\trenamed_and_verified' ]
  [ "${lines[1]}" = $'agent_key\tchanged\trenamed_and_verified' ]
  [ "${lines[2]}" = $'cli_session\tchanged\trenamed_and_verified' ]
  [ "$(< "$BATS_TEST_TMPDIR/poke")" = '/rename team-alice' ]
}

@test "identity fix never pokes a CLI without positive readiness" {
  agmsg_type_get() { [ "$2" = cli ] && printf 'claude\n'; }
  terminal_team_input_ready() { printf 'not_ready:agent_not_found\n'; return 1; }
  terminal_poke() { printf 'called\n' > "$BATS_TEST_TMPDIR/poke"; }
  run agmsg_team_fix_identity_loaded team alice claude-code herdr w2:p3 \
    'ok(actual=team:alice)' 'ok(actual=a123)' \
    'mismatch(expected=team-alice,actual=alice)'
  [ "$status" -eq 0 ]
  [ "${lines[2]}" = $'cli_session\tskipped\tnot_ready_agent_not_found' ]
  [ ! -e "$BATS_TEST_TMPDIR/poke" ]
}

@test "herdr readiness positively identifies the expected live agent" {
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/herdr/ops.sh"
  _herdr_pane_id_ok() { return 0; }
  herdr() {
    printf '%s\n' '{"result":{"agent":{"agent":"claude","agent_status":"idle","pane_id":"w2:p3"}}}'
  }
  run terminal_team_input_ready w2:p3 claude
  [ "$status" -eq 0 ]
  [ "$output" = ready ]
}

@test "herdr readiness rejects a shell pane that has no agent" {
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/herdr/ops.sh"
  _herdr_pane_id_ok() { return 0; }
  herdr() { printf '%s\n' '{"error":{"code":"agent_not_found"}}'; return 1; }
  run terminal_team_input_ready w2:p3 claude
  [ "$status" -eq 1 ]
  [ "$output" = not_ready:agent_not_found ]
}

@test "herdr readiness rejects a different agent kind" {
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/herdr/ops.sh"
  _herdr_pane_id_ok() { return 0; }
  herdr() {
    printf '%s\n' '{"result":{"agent":{"agent":"codex","agent_status":"idle","pane_id":"w2:p3"}}}'
  }
  run terminal_team_input_ready w2:p3 claude
  [ "$status" -eq 1 ]
  [ "$output" = not_ready:agent_kind_mismatch ]
}

@test "herdr readiness rejects a non-interactive agent status" {
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/herdr/ops.sh"
  _herdr_pane_id_ok() { return 0; }
  herdr() {
    printf '%s\n' '{"result":{"agent":{"agent":"claude","agent_status":"blocked","pane_id":"w2:p3"}}}'
  }
  run terminal_team_input_ready w2:p3 claude
  [ "$status" -eq 1 ]
  [ "$output" = not_ready:agent_status_blocked ]
}

@test "herdr readiness keeps a generic query failure unknown" {
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/herdr/ops.sh"
  _herdr_pane_id_ok() { return 0; }
  herdr() { return 1; }
  run terminal_team_input_ready w2:p3 claude
  [ "$status" -eq 2 ]
  [ "$output" = unknown:agent_query_failed ]
}

@test "tmux readiness follows the bare pane to its foreground CLI" {
  install_team_fake_tmux
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/tmux/ops.sh"
  ps() {
    case "$*" in
      *tpgid*) printf '85225\n' ;;
      *command*) printf 'claude -n team-alice\n' ;;
    esac
  }
  run terminal_team_input_ready '%3' claude
  [ "$status" -eq 0 ]
  [ "$output" = ready ]
  grep -qF 'tmux [display-message] [-p] [-t] [%3]' "$TEAM_TMUX_LOG"
}

@test "tmux readiness rejects a foreground shell" {
  install_team_fake_tmux
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/tmux/ops.sh"
  ps() {
    case "$*" in
      *tpgid*) printf '64066\n' ;;
      *command*) printf '/bin/zsh\n' ;;
    esac
  }
  run terminal_team_input_ready '%3' claude
  [ "$status" -eq 1 ]
  [ "$output" = not_ready:foreground_cli_mismatch ]
}

@test "tmux observation reads the key and CLI title from a bare pane" {
  install_team_fake_tmux
  # shellcheck disable=SC1090
  source "$SCRIPTS/drivers/terminals/tmux/ops.sh"
  run terminal_team_observe '%3'
  [ "$status" -eq 0 ]
  [ "$output" = $'n/a:unsupported\tn/a:no_independent_field\tteam:alice\t✳ team-alice' ]
  grep -qF 'tmux [show-options] [-p] [-v] [-t] [%3] [@agmsg_agent]' "$TEAM_TMUX_LOG"
  grep -qF 'tmux [display-message] [-p] [-t] [%3] [#{pane_title}]' "$TEAM_TMUX_LOG"
}

# ----------------------------------------------------------------------------
# agent_key_missing is read-as-absent, not couldn't-read: it must classify as a
# fixable mismatch so `team --fix` sets the key. A codex seat lands here — its
# self-naming paths never run (all five are Claude-Code-only), so a missing key
# means the seat is nameless, and that is a mismatch to repair, not an unknown to
# leave alone.

@test "agent_key_missing classifies as a fixable mismatch, and the row is mismatch" {
  terminal_team_observe() { printf 'idle\tteam:alice\tunknown:agent_key_missing\ttransient\n'; }
  _herdr_internal_key() { printf 'a123\n'; }
  agmsg_type_get() { return 0; }   # no name_arg -> session n/a, isolates the key cell
  run agmsg_team_identity_loaded team alice codex herdr w2:p3
  [ "$status" -eq 0 ]
  # The RAW actual_key (field 4) is preserved as observed; only the CELL (field 9)
  # reclassifies to a mismatch (expected exists, observed absent), which flips the
  # row consistency (field 11) from the unverified an unknown gives to mismatch.
  [ "$output" = $'idle\tteam:alice\tteam:alice\tunknown:agent_key_missing\ta123\tn/a:no_session_name\tn/a:no_session_name\tok(actual=team:alice)\tmismatch(expected=a123,actual=absent)\tn/a:no_session_name\tmismatch' ]
}

@test "a genuine key read failure stays unknown (skipped), never rewritten to a mismatch" {
  # Contrast to agent_key_missing: an unknown that means the driver could NOT read
  # (terminal unreachable / observe errored) must stay pass-through. Rewriting it to
  # a mismatch would make --fix overwrite a key it never actually read — the "every
  # unknown becomes mismatch, overwrite" failure. The row is unverified, not mismatch.
  terminal_team_observe() { printf 'idle\tteam:alice\tunknown:terminal_unavailable\ttransient\n'; }
  _herdr_internal_key() { printf 'a123\n'; }
  agmsg_type_get() { return 0; }
  run agmsg_team_identity_loaded team alice codex herdr w2:p3
  [ "$status" -eq 0 ]
  [ "$output" = $'idle\tteam:alice\tteam:alice\tunknown:terminal_unavailable\ta123\tn/a:no_session_name\tn/a:no_session_name\tok(actual=team:alice)\tunknown:terminal_unavailable\tn/a:no_session_name\tunverified' ]
}

@test "identity fix sets a missing agent key and confirms it by reading back" {
  _herdr_internal_key() { printf 'a123\n'; }
  # terminal_name records the mode it was told to use; after it runs, observe reports
  # the key, so the fix's read-back verify sees ok -> changed (only-say-changed-after
  # -reading-back-ok, the team --fix contract).
  terminal_name() { printf '%s\n' "$4" >> "$BATS_TEST_TMPDIR/names"; }
  terminal_team_observe() { printf 'idle\tteam:alice\ta123\ttransient\n'; }
  agmsg_type_get() { return 0; }
  run agmsg_team_fix_identity_loaded team alice codex herdr w2:p3 \
    'ok(actual=team:alice)' \
    'mismatch(expected=a123,actual=absent)' \
    'n/a:no_session_name'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = $'agent_key\tchanged\trenamed_and_verified' ]
  # The key was set with mode 'key' (addressing, always set — never the visible label).
  [ "$(< "$BATS_TEST_TMPDIR/names")" = key ]
}
