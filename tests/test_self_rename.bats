#!/usr/bin/env bats
#
# Self-rename on action (scripts/lib/self-rename.sh, #1081): a seat types the
# type's rename command into ITS OWN pane, once, early, and only when it can
# verify. The guard that matters most (and the one #1096 was missing): the
# keystroke reaches the seat's own pane and NO OTHER pane. A test that only
# checks "my name changed" passes even when every pane is typed into.

setup() {
  load 'test_helper'
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"; mkdir -p "$RUN_DIR"
  export AGMSG_AGENT_PID=""
  FAKEBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$FAKEBIN"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"; : > "$ARGV_LOG"
  export FAKEBIN ARGV_LOG
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
  unset AGMSG_SELF_NAME AGMSG_SELF_RENAME
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-rename.sh"
}
teardown() { teardown_test_env; }

# A fake tmux that logs argv, answers the title query with $FAKE_TITLE, and takes
# send-keys (the poke) as a logged no-op.
_install_fake_tmux() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
# real tmux takes an optional leading -S <socket>, so the subcommand is NOT
# always \$1: scan the args for it and for the pane after -t.
prev=""; pane=""; is_dm=0
for a in "\$@"; do
  [ "\$prev" = "-t" ] && pane="\$a"
  [ "\$a" = display-message ] && is_dm=1
  prev="\$a"
done
# display-message answers "<pane_id>|<title>"; terminal_team_observe co-observes
# the id, so it must echo the queried pane back verbatim.
[ "\$is_dm" = 1 ] && printf '%s|%s\n' "\$pane" "\${FAKE_TITLE:-unknown}"
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"; export PATH="$FAKEBIN:$PATH"
}

_under_tmux() { export TMUX="$1,$2,0" TMUX_PANE="$3"; }   # <socket> <pid> <pane>
_mark() { agmsg_role_session_renamed "$1" "$2"; }         # -> ref<TAB>epoch<TAB>result
# every send-keys target pane in the log, deduped
_poked_panes() { grep -oE '\[send-keys\].*\[-t\] \[[^]]+\]' "$ARGV_LOG" | grep -oE '\[-t\] \[[^]]+\]' | sed -E 's/.*\[(.*)\]/\1/' | sort -u; }

@test "the rename is typed into the seat's OWN pane, and no other pane is touched (#1096)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'   # not team-alice -> must rename
  agmsg_self_rename_on_action team alice claude-code
  # (a) the seat's pane got the /rename
  grep -q '\[send-keys\] \[-l\] \[-t\] \[%3\] \[--\] \[/rename team-alice\]' "$ARGV_LOG"
  # (b) THE POINT: every send-keys went to %3 and to nothing else
  [ "$(_poked_panes)" = '%3' ]
  # and it recorded the attempt (so it will not poke again)
  [ "$(_mark team alice | cut -f3)" = attempted ]
}

@test "already correctly named: nothing is typed at all" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='team-alice'
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = ok ]
}

@test "a type with no rename_cmd types nothing (the datum, not the type)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_rename_on_action team alice gemini   # gemini has no rename_cmd
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ -z "$(_mark team alice)" ]   # no attempt recorded at all
}

@test "AGMSG_SELF_RENAME=off types nothing, and the stop is VISIBLE on the mark" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name' AGMSG_SELF_RENAME=off
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = skipped:self_rename_off ]
}

@test "AGMSG_SELF_NAME=off also stops the keystroke, visibly" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name' AGMSG_SELF_NAME=off
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = skipped:self_rename_off ]
}

@test "one attempt only: after it has poked, a second action does not poke again" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_rename_on_action team alice claude-code      # phase 1: pokes, marks attempted
  [ "$(grep -c '\[send-keys\] \[-l\]' "$ARGV_LOG")" -eq 1 ]
  : > "$ARGV_LOG"
  # phase 2: the mark says attempted; it confirms, it does NOT poke again. The
  # title is still wrong -> a title name is authoritative -> failed, no re-poke.
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\] \[-l\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = failed ]
}

@test "the verify window: after a poke, the name took -> ok, still no second poke" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_rename_on_action team alice claude-code      # pokes, marks attempted
  : > "$ARGV_LOG"
  export FAKE_TITLE='team-alice'                          # the rename landed
  agmsg_self_rename_on_action team alice claude-code      # confirm
  refute grep -q '\[send-keys\] \[-l\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = ok ]
}
