#!/usr/bin/env bats
#
# Self-naming on action (scripts/lib/self-name.sh): a seat that sends or reads
# names its own pane if it is not named, from its environment, at the cost of
# one file read in the common case. Pinned here, each with a control the other
# way, and every terminal call counted through a fake that logs its argv:
#
#   - mark present and matching       -> the terminal is not called at all
#   - mark present, pane differs       -> named again, mark rewritten
#   - mark present, server restarted   -> named again (the epoch changed)
#   - mark present, name gone, nothing else changed -> NOT seen (blind spot,
#                                         pinned as such)
#   - no mark                          -> named once, mark written
#   - another seat in the same pane    -> names it for itself
#   - order independence: a boot path first, then the action; the action
#     first, then a boot path -- same key, one terminal call in total
#   - herdr identifies its pane from HERDR_PANE_ID with no session id
#   - the action commands (send / inbox / history) run the hook, and a failure
#     to name never fails the command

setup() {
  load 'test_helper'
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  export AGMSG_AGENT_PID=""
  FAKEBIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$FAKEBIN"
  ARGV_LOG="$BATS_TEST_TMPDIR/argv.log"; : > "$ARGV_LOG"
  export FAKEBIN ARGV_LOG
  # No terminal by default: each test sets the environment it wants.
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-name.sh"
}
teardown() { teardown_test_env; }

_install_fake_tmux() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

_install_fake_herdr() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = agent ] && [ "\$2" = list ]; then
  printf '{"id":"1","result":{"type":"list","agents":[]}}\n'
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

_under_tmux() {   # <socket> <pid> <pane>
  export TMUX="$1,$2,0" TMUX_PANE="$3"
}

_under_herdr() {  # <pane> [<socket file>]
  local sock="${2:-$BATS_TEST_TMPDIR/herdr.sock}"
  [ -e "$sock" ] || : > "$sock"
  export HERDR_ENV=1 HERDR_PANE_ID="$1" HERDR_SOCKET_PATH="$sock"
}

_terminal_calls() { grep -c . "$ARGV_LOG"; }
# The tmux driver addresses the pane's server first (`tmux -S <socket> ...`),
# so the naming call is not at the start of the line.
_name_calls() { grep -cE '\[set-option\] \[-p\]|^herdr \[agent\] \[rename\]' "$ARGV_LOG"; }
# join the fixture seats with NO terminal in the environment, so the join
# path (which names too) leaves no mark and the action under test is the
# first thing that names.
_join_unnamed() {   # <team> <agent>
  env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    bash "$SKILL_DIR/scripts/join.sh" "$1" "$2" claude-code /tmp/p >/dev/null
}

_mark() {   # <team> <agent> -> "ref<TAB>epoch" or empty
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_named "$1" "$2"
}

# --- the three directions, tmux -----------------------------------------------------

@test "no mark: the first action names the pane once and leaves a mark with the pane and the server pid" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
  # Addressed to the pane's OWN server (the socket from $TMUX), not to whatever
  # `tmux` would pick by default.
  grep -q 'tmux \[-S\] \[/tmp/s\] \[set-option\] \[-p\] \[-t\] \[%3\] \[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
}

@test "mark present and matching: the action does not call the terminal at all" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team alice
  agmsg_self_name_on_action team alice
  [ "$(_terminal_calls)" -eq 0 ]
}

@test "mark present, but I am in another pane: named again, and the mark follows" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  _under_tmux /tmp/s 4242 %7
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
  grep -q '\[-t\] \[%7\]' "$ARGV_LOG"
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%7\tpid=4242' ]
}

@test "mark present, same pane, but the tmux server restarted: named again (the pid in \$TMUX changed)" {
  # The case where the pane reference survives unchanged and the name did not.
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  _under_tmux /tmp/s 5151 %3
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=5151' ]
}

@test "blind spot, pinned: the name removed while pane and server are unchanged is not seen" {
  # Nothing in the environment changes when a name is cleared by hand, so the
  # hook cannot know; it is documented as the case team --fix / rename repair.
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  # (the fake tmux has no state to clear; the point is that the hook makes no call)
  agmsg_self_name_on_action team alice
  [ "$(_terminal_calls)" -eq 0 ]
  grep -q 'BLIND SPOT' "$SKILL_DIR/scripts/lib/self-name.sh"
}

@test "another seat in the same pane names it for itself: its own record has no mark for that pane" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team bob
  [ "$(_name_calls)" -eq 1 ]
  grep -q '\[@agmsg_agent\] \[team:bob\]' "$ARGV_LOG"
  [ "$(_mark team bob)" = $'tmux:/tmp/s:%3\tpid=4242' ]
  # alice's mark still names %3; when alice acts from elsewhere she is renamed there.
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
}

# --- order independence with the existing paths -------------------------------------

@test "a boot path names first, then the action: same key, and the action makes no second call" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  agmsg_terminal_name_self_safe "sid-1" team alice /tmp/p claude-code
  [ "$(_name_calls)" -eq 1 ]
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team alice
  [ "$(_terminal_calls)" -eq 0 ]
}

@test "the action names first, then a boot path: same key both times" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  first="$(grep 'set-option' "$ARGV_LOG")"
  : > "$ARGV_LOG"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  agmsg_terminal_name_self_safe "sid-1" team alice /tmp/p claude-code
  [ "$(grep 'set-option' "$ARGV_LOG")" = "$first" ]
}

# --- herdr ---------------------------------------------------------------------------

@test "herdr: the pane comes from HERDR_PANE_ID with no session id, and the mark carries the socket generation" {
  _install_fake_herdr; _under_herdr w1:pB
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
  grep -q '^herdr \[agent\] \[rename\] \[w1:pB\] ' "$ARGV_LOG"
  refute grep -q '\[agent\] \[list\]' "$ARGV_LOG"
  local m; m="$(_mark team alice)"
  [ "${m%%	*}" = 'herdr:w1:pB' ]
  case "${m#*	}" in sock=*:*) ;; *) echo "epoch not a socket fingerprint: $m"; return 1 ;; esac
}

@test "herdr: mark matching -> no call; socket recreated (server restart) -> named again" {
  _install_fake_herdr; _under_herdr w1:pB
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team alice
  [ "$(_terminal_calls)" -eq 0 ]
  # A restarted server recreates its socket. The fingerprint is inode:ctime
  # with ctime in whole seconds, and ext4 hands a just-freed inode straight
  # back (measured on the ubuntu runner: recreate within the same second and
  # the fingerprint did not move), so a recreation is only visible across a
  # second boundary -- which a real server restart always crosses. Cross it.
  rm -f "$HERDR_SOCKET_PATH"; sleep 1; : > "$HERDR_SOCKET_PATH"
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
}

@test "herdr: a seat moved to another herdr session (a different socket path) is named again" {
  # Not a restart: a different server altogether, whose socket is another
  # file. The inode differs regardless of timing, so this holds on every
  # filesystem; the restart case above is the one that needs the second.
  _install_fake_herdr; _under_herdr w1:pB "$BATS_TEST_TMPDIR/herdr-a.sock"
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  _under_herdr w1:pB "$BATS_TEST_TMPDIR/herdr-b.sock"
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
}

@test "setup_test_env strips the developer's terminal from the environment (regression guard)" {
  # The tests in this file unset these themselves, so without this guard the
  # helper's unset could be removed and nothing here would go red -- while a
  # suite run from inside a real pane would name the developer's pane again.
  run bash -c '
    cd "$1" && load() { source "./test_helper.bash"; }; load
    export TMUX="/tmp/s,1,0" TMUX_PANE="%1" HERDR_ENV=1 HERDR_PANE_ID="w1:p1" HERDR_SOCKET_PATH=/tmp/x
    setup_test_env
    rc=0
    for v in TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH; do
      [ -z "$(eval "printf %s \"\${$v:-}\"")" ] || { echo "still set: $v"; rc=1; }
    done
    teardown_test_env; exit $rc
  ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "herdr driver: terminal_detect answers from HERDR_PANE_ID, falls back to the session lookup without it, and rejects a malformed value" {
  _install_fake_herdr
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  export HERDR_ENV=1 HERDR_PANE_ID=w1:pB
  run agmsg_terminal_resolve_name ""
  [ "$status" -eq 0 ]
  [ "$output" = $'herdr\tw1:pB' ]
  refute grep -q '\[agent\] \[list\]' "$ARGV_LOG"
  unset HERDR_PANE_ID
  run agmsg_terminal_resolve_name ""
  [ "$status" -eq 1 ]
  export HERDR_PANE_ID='not a pane'
  run agmsg_terminal_resolve_name ""
  [ "$status" -eq 1 ]
}

# --- the commands ----------------------------------------------------------------------

@test "send.sh names the sender's pane, and a naming failure does not fail the send" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  _join_unnamed team alice
  _join_unnamed team bob
  [ -z "$(_mark team alice)" ]
  : > "$ARGV_LOG"
  run bash "$SKILL_DIR/scripts/send.sh" team alice bob 'hello'
  [ "$status" -eq 0 ]
  grep -q '\[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
  # Order independence end to end: a boot path (join, kept as it was: it
  # names unconditionally) writes the SAME key, and the send after it finds
  # the mark and makes no call of its own.
  : > "$ARGV_LOG"
  bash "$SKILL_DIR/scripts/join.sh" team alice claude-code /tmp/p >/dev/null
  [ "$(_name_calls)" -eq 1 ]
  grep -q '\[-t\] \[%3\] \[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  run bash "$SKILL_DIR/scripts/send.sh" team alice bob 'hello twice'
  [ "$status" -eq 0 ]
  [ "$(_name_calls)" -eq 0 ]
  # A tmux that fails the option write: the send still succeeds.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/tmux"
  _under_tmux /tmp/s 4242 %9
  run bash "$SKILL_DIR/scripts/send.sh" team alice bob 'hello again'
  [ "$status" -eq 0 ]
}

@test "inbox.sh and history.sh (with an agent) name the reader's pane; history without an agent does not" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  _join_unnamed team alice
  : > "$ARGV_LOG"
  bash "$SKILL_DIR/scripts/inbox.sh" team alice >/dev/null 2>&1 || true
  [ "$(_name_calls)" -eq 1 ]
  grep -q '\[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  _under_tmux /tmp/s 4242 %4
  bash "$SKILL_DIR/scripts/history.sh" team alice 5 >/dev/null 2>&1 || true
  grep -q '\[-t\] \[%4\] \[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  bash "$SKILL_DIR/scripts/history.sh" team >/dev/null 2>&1 || true
  [ "$(_terminal_calls)" -eq 0 ]
}

@test "AGMSG_SELF_NAME=off turns the hook off, and no terminal means no call" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  AGMSG_SELF_NAME=off agmsg_self_name_on_action team alice
  [ "$(_terminal_calls)" -eq 0 ]
  unset TMUX TMUX_PANE
  agmsg_self_name_on_action team alice
  [ "$(_terminal_calls)" -eq 0 ]
}

@test "the record writer keeps the mark, and the mark writer keeps the record" {
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/role-session.sh"
  agmsg_role_session_record team alice sid-1 /tmp/p claude-code
  agmsg_role_session_mark_named team alice tmux:/tmp/s:%3 pid=4242
  agmsg_role_session_record team alice sid-2 /tmp/p claude-code
  [ "$(agmsg_role_session_uuid team alice)" = sid-2 ]
  [ "$(agmsg_role_session_named team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
  # A seat with no record yet (started by hand) gets a minimal one from the mark.
  agmsg_role_session_mark_named team carol herdr:w1:pC sock=1:2 /tmp/p codex
  [ "$(agmsg_role_session_named team carol)" = $'herdr:w1:pC\tsock=1:2' ]
  [ "$(agmsg_role_session_get team carol type)" = codex ]
  [ -z "$(agmsg_role_session_uuid team carol)" ]
}
