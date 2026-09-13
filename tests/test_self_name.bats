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
#   - another seat in the same pane    -> NOT taken while the first seat's record
#                                         claims it (#1114 placement guard, kept
#                                         alongside #1112; was "names it for itself"
#                                         and returns to that only if the guard goes)
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

# The fakes below REMEMBER the label they are told to set, because #1130 makes
# the fast half read it back: a fake that accepts a name and then answers
# nothing when asked models a terminal that forgets, which is a different
# terminal from the one under test. Only the one format that asks for the label
# is answered; anything else stays silent, as before.
_install_fake_tmux() {
  export FAKE_TMUX_STATE="$FAKEBIN/tmux.labels"; : > "$FAKE_TMUX_STATE"
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
state='$FAKE_TMUX_STATE'
args=("\$@"); [ "\${args[0]}" = -S ] && args=("\${args[@]:2}")
case "\${args[0]}" in
  set-option)
    if [ "\${args[4]}" = '@agmsg_agent' ]; then
      grep -v "^\${args[3]}	" "\$state" > "\$state.n" 2>/dev/null || : > "\$state.n"
      printf '%s\t%s\n' "\${args[3]}" "\${args[5]}" >> "\$state.n"; mv "\$state.n" "\$state"
    fi ;;
  display-message)
    if [ "\${args[4]}" = '#{pane_id}|#{@agmsg_agent}' ]; then
      printf '%s|%s\n' "\${args[3]}" "\$(awk -F'\t' -v p="\${args[3]}" '\$1 == p { print \$2 }' "\$state" 2>/dev/null)"
    fi ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

# Clear the label the fake remembers for <pane>, touching neither the pane nor
# the server -- the state a hand rename leaves.
_clear_fake_label() {   # <pane>
  grep -v "^$1	" "$FAKE_TMUX_STATE" > "$FAKE_TMUX_STATE.n" 2>/dev/null || : > "$FAKE_TMUX_STATE.n"
  mv "$FAKE_TMUX_STATE.n" "$FAKE_TMUX_STATE"
}

_install_fake_herdr() {
  export FAKE_HERDR_STATE="$FAKEBIN/herdr.labels"; : > "$FAKE_HERDR_STATE"
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
state='$FAKE_HERDR_STATE'
if [ "\$1" = agent ] && [ "\$2" = list ]; then
  printf '{"id":"1","result":{"type":"list","agents":[]}}\n'
elif [ "\$1" = pane ] && [ "\$2" = rename ]; then
  grep -v "^\$3	" "\$state" > "\$state.n" 2>/dev/null || : > "\$state.n"
  printf '%s\t%s\n' "\$3" "\$4" >> "\$state.n"; mv "\$state.n" "\$state"
elif [ "\$1" = pane ] && [ "\$2" = list ]; then
  rows=""
  while IFS=\$'\t' read -r pid lbl; do
    [ -n "\$pid" ] || continue
    [ -n "\$rows" ] && rows="\$rows,"
    rows="\$rows{\"pane_id\":\"\$pid\",\"label\":\"\$lbl\"}"
  done < "\$state"
  printf '{"id":"1","result":{"panes":[%s]}}\n' "\$rows"
elif [ "\$1" = pane ] && [ "\$2" = get ]; then
  lbl="\$(awk -F'\t' -v p="\$3" '\$1 == p { print \$2 }' "\$state" 2>/dev/null)"
  if [ -n "\$lbl" ]; then
    printf '{"result":{"pane":{"agent_status":"idle","label":"%s","terminal_title":"t"}}}\n' "\$lbl"
  else
    printf '{"result":{"pane":{"agent_status":"idle","terminal_title":"t"}}}\n'
  fi
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

# The placement record's pane ref (its first field), or empty. This is the half
# peek/poke/despawn/team/--fix resolve through -- the half #1109 was missing.
_placement() {   # <team> <agent> -> "<terminal>:<id>" or empty
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
  local rec r
  rec="$(agmsg_spawn_path "$1" "$2")" || return 0
  [ -f "$rec" ] || return 0
  IFS=$'\t' read -r r _ < "$rec" || return 0
  printf '%s' "$r"
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

@test "mark present and matching: the action READS the pane and writes nothing (#1130)" {
  # The invariant changed with #1130, and the change is the point: the fast half
  # no longer decides from the environment alone, because a seat whose
  # environment is somebody else's pane has a mark and a record that agree with
  # it and short-circuits forever. It asks the pane which label it carries.
  #
  # "No calls at all" is therefore gone. What must still hold -- what the old
  # assertion was protecting -- is that a settled seat does no WORK: it does not
  # relabel, rekey or rewrite anything, and it does not go listing panes.
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team alice
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 0 ]
  [ "$(grep -c '\[display-message\]' "$ARGV_LOG")" -eq 2 ]
  refute grep -q '\[list-panes\]' "$ARGV_LOG"
  [ "$(_terminal_calls)" -eq 2 ]
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

@test "the name removed while pane and server are unchanged IS seen now (#1130)" {
  # This was the documented blind spot. Nothing in the ENVIRONMENT changes when
  # a label is cleared by hand, so a fast half that read only the environment
  # could not know, and the case was left to `team --fix` / `rename`. The #1130
  # read closes it for free: the pane is asked, and the pane says it carries no
  # agmsg label.
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
  : > "$ARGV_LOG"

  # Settled: nothing to do.
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 0 ]

  # Someone clears the label by hand. The pane and the server are untouched, so
  # the mark still matches, and so does the record.
  _clear_fake_label %3
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
  : > "$ARGV_LOG"

  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
  grep -q '\[-t\] \[%3\] \[@agmsg_agent\] \[team:alice\]' "$ARGV_LOG"
  # And the documentation no longer claims otherwise.
  refute grep -q 'BLIND SPOT, stated rather than papered over' "$SKILL_DIR/scripts/lib/self-name.sh"
}

@test "another seat in the same pane does NOT take it while the first seat's record claims it (#1114 placement guard)" {
  # Before the #1114 guard this test read "names it for itself": the second
  # seat relabeled the pane and marked itself there. Under the guard a pane
  # another seat's record claims is neither named, marked, nor recorded -- that
  # is the shape that stops co-located codex seats taking each other's pane, and
  # a second role acting from the SAME pane is indistinguishable from it. The
  # message says who holds the pane and how to release it (drop or despawn).
  # The guard is kept alongside #1112's label-first resolution; this test goes
  # only if the guard does, as a separate decision, and the old one returns.
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  agmsg_self_name_on_action team alice
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
  : > "$ARGV_LOG"
  run agmsg_self_name_on_action team bob
  [ "$status" -eq 0 ]
  [ "$(_name_calls)" -eq 0 ]
  refute grep -q '\[team:bob\]' "$ARGV_LOG"
  [ -z "$(_mark team bob)" ]
  [ -z "$(_placement team bob)" ]
  grep -q 'already recorded as team__alice' <<<"$output"
  grep -q 'drop or despawn' <<<"$output"
  # alice keeps everything.
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
}

# --- order independence with the existing paths -------------------------------------

@test "a boot path names first, then the action: same key, and the action makes no second call" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  # A recording boot (SessionStart / actas both pass `record`): it leaves BOTH
  # the mark and the placement record, so the action's fast half finds nothing to
  # do. Without the record the action would rightly act to write it (see the
  # hand-started #1109 test below) -- that is the point of checking both halves.
  agmsg_terminal_name_self_safe "sid-1" team alice /tmp/p claude-code record
  [ "$(_name_calls)" -eq 1 ]
  [ "$(_mark team alice)" = $'tmux:/tmp/s:%3\tpid=4242' ]
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 0 ]
  # One read per action, no writes. The old assertion here was "no terminal
  # calls at all"; #1130 makes the fast half ASK the pane which label it
  # carries, because a seat whose environment is somebody else's pane has a
  # mark and a record that agree with it and short-circuits forever. What the
  # old assertion was protecting -- a settled seat does no WORK -- is kept.
  refute grep -q '\[list-panes\]' "$ARGV_LOG"
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

# --- #1109: the action records placement, so a hand-started seat is reachable -------

@test "a hand-started seat: the action RECORDS its placement, not only the label (#1109)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  # No prior naming and no record -- a seat someone started by hand that has just
  # sent its first message.
  [ -z "$(_placement team alice)" ]
  agmsg_self_name_on_action team alice
  # The label was set AND the placement record now points at this pane -- the half
  # peek/poke/despawn/team/--fix resolve through. A test on the label alone (the
  # mark / _name_calls) passes without the fix; asserting the record is the point.
  [ "$(_name_calls)" -eq 1 ]
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
}

@test "named once but never recorded: the next action writes the missing record (#1109)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  # A mark-only prior naming (watch.sh names with five args, no record): the mark
  # matches this pane, but no placement record exists. The old fast half trusted
  # the mark alone and short-circuited past the write forever.
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  agmsg_terminal_name_self_safe "sid-1" team alice /tmp/p claude-code
  [ -n "$(_mark team alice)" ]
  [ -z "$(_placement team alice)" ]
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team alice
  # It did not short-circuit on the mark: it wrote the record. After this a
  # further action fast-paths (the no-second-call test above proves that half).
  [ "$(_placement team alice)" = 'tmux:/tmp/s:%3' ]
}

@test "no pane in the environment: nothing is recorded, so an un-named seat stays unreachable (#1109)" {
  _install_fake_tmux                                                # a tmux binary exists, but
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH    # no pane in the environment
  agmsg_self_name_on_action team seat1
  # self_env resolves nothing -> no name, no record. This is the contrast case: a
  # real seat that never named itself (neither a naming record nor a placement one)
  # must keep reading as unreachable, not be made falsely addressable. Making
  # everything reachable would turn "cannot reach" into "said it could and could
  # not", which is worse.
  [ "$(_terminal_calls)" -eq 0 ]
  [ -z "$(_placement team seat1)" ]
}

# --- herdr ---------------------------------------------------------------------------

@test "herdr: the pane comes from HERDR_PANE_ID with no session id, and the mark carries the socket generation" {
  _install_fake_herdr; _under_herdr w1:pB
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 1 ]
  grep -q '^herdr \[agent\] \[rename\] \[w1:pB\] ' "$ARGV_LOG"
  refute grep -q '\[agent\] \[list\]' "$ARGV_LOG"
  local m; m="$(_mark team alice)"
  [ "${m%%	*}" = "herdr:$HERDR_SOCKET_PATH:w1:pB" ]
  case "${m#*	}" in sock=*:*) ;; *) echo "epoch not a socket fingerprint: $m"; return 1 ;; esac
}

@test "herdr: mark matching -> no call; socket recreated (server restart) -> named again" {
  _install_fake_herdr; _under_herdr w1:pB
  agmsg_self_name_on_action team alice
  : > "$ARGV_LOG"
  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 0 ]
  # One read per action, no writes. The old assertion here was "no terminal
  # calls at all"; #1130 makes the fast half ASK the pane which label it
  # carries, because a seat whose environment is somebody else's pane has a
  # mark and a record that agree with it and short-circuits forever. What the
  # old assertion was protecting -- a settled seat does no WORK -- is kept.
  refute grep -q '\[list-panes\]' "$ARGV_LOG"
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
  export HERDR_ENV=1 HERDR_PANE_ID=w1:pB HERDR_SOCKET_PATH="$BATS_TEST_TMPDIR/herdr.sock"
  run agmsg_terminal_resolve_name ""
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\t%s:w1:pB' "$HERDR_SOCKET_PATH")" ]
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

@test "AGMSG_SELF_NAME=off turns the boot path off too, not only the hook (#1096)" {
  # spawn runs join.sh in the caller's process for the new member; join's boot
  # path calls agmsg_terminal_name_self directly, so the switch has to be
  # honoured THERE, or the caller's pane is named after the new member.
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
  AGMSG_SELF_NAME=off agmsg_terminal_name_self_safe "sid-1" team alice /tmp/p claude-code
  [ "$(_name_calls)" -eq 0 ]
  [ -z "$(_mark team alice)" ]
  # Control: the same call with the switch at its default names once.
  agmsg_terminal_name_self_safe "sid-1" team alice /tmp/p claude-code
  [ "$(_name_calls)" -eq 1 ]
}


# --- #1130: a seat that is WRONG but perfectly self-consistent -----------------

@test "the environment, the mark and the record all name the SAME wrong pane -- one action moves it (#1130)" {
  # The state measured on this fleet, reproduced through the code that creates
  # it rather than hand-written: a seat resolves its pane from an environment it
  # shares with a daemon, names THAT pane, and records it. Everything it can see
  # then agrees, so the fast half short-circuits -- forever. The seat acted for
  # eleven hours and its record never moved.
  #
  # Every existing test here starts from a CORRECT seat and asks that it stays
  # correct. All of them were green while this shipped. This one starts broken.
  _install_fake_herdr; _under_herdr w1:pDAEMON

  # Act once under the wrong environment: this is how the bad state was made.
  agmsg_self_name_on_action team alice
  [ "$(_placement team alice)" = "herdr:$HERDR_SOCKET_PATH:w1:pDAEMON" ]
  local m0; m0="$(_mark team alice)"
  [ "${m0%%	*}" = "herdr:$HERDR_SOCKET_PATH:w1:pDAEMON" ]

  # And now the truth: the daemon's pane belongs to the seat that started it,
  # and this seat's label is on a different pane. (This is what the real server
  # showed: the label was right, the record was somebody else's pane.)
  printf 'w1:pDAEMON\tteam:other\nw1:pMINE\tteam:alice\n' > "$FAKE_HERDR_STATE"
  : > "$ARGV_LOG"

  # ONE ordinary action.
  agmsg_self_name_on_action team alice

  # It moved. The record is the half peek/poke/despawn resolve through, so this
  # is the assertion that matters; a test on the label alone stays green.
  [ "$(_placement team alice)" = "herdr:$HERDR_SOCKET_PATH:w1:pMINE" ]
  local m; m="$(_mark team alice)"
  [ "${m%%	*}" = "herdr:$HERDR_SOCKET_PATH:w1:pMINE" ]
  # And it named ITS OWN pane, not the one it was squatting.
  grep -q '^herdr \[agent\] \[rename\] \[w1:pMINE\] ' "$ARGV_LOG"
  refute grep -q '\[rename\] \[w1:pDAEMON\]' "$ARGV_LOG"
}

@test "a seat whose environment IS its own pane still short-circuits (#1130 control)" {
  # The partner. "Never short-circuit" also passes the test above, and it would
  # cost every seat a full re-resolution on every action; this is what stops that
  # from being the fix.
  _install_fake_herdr; _under_herdr w1:pB
  agmsg_self_name_on_action team alice
  [ "$(_placement team alice)" = "herdr:$HERDR_SOCKET_PATH:w1:pB" ]
  : > "$ARGV_LOG"

  agmsg_self_name_on_action team alice
  [ "$(_name_calls)" -eq 0 ]
  # It asked the pane, and it did NOT go listing panes to do it.
  grep -q '^herdr \[pane\] \[get\] \[w1:pB\]' "$ARGV_LOG"
  refute grep -q '\[pane\] \[list\]' "$ARGV_LOG"
}
