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
  # self-rename.sh sources its deps lazily inside the hook, so make the registry
  # and observation helpers available up front for the tests that call them
  # directly (the codex screen-parse ones).
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/type-registry.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/team-status.sh"
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/self-rename.sh"
  # #1206: the poke is gated on agmsg_self_proof, and the gate also requires
  # the proof's own returned locator to match the pane about to be poked
  # (review finding: reading only the state word let a proof for pane X
  # authorize a poke into whatever pane the environment named, even a
  # DIFFERENT one). Every test above this one in the file is about the OTHER
  # rules around the poke (own pane only, phase, opt-out, the placement-claim
  # guard) and predates that gate, so the default here is a stub shaped like
  # what a REAL proof returns for every one of those tests' shared fixture
  # (_under_tmux /tmp/s 4242 %3): "tmux:%3", bare -- terminal_pane_process_observe
  # strips the instance before returning it (tmux/ops.sh), same as the real
  # driver would. The proof contract itself (proved/disproved/undetermined/
  # unsupported, real vs. stubbed) is test_self_proof.bats's job, not this
  # file's. The #1206 tests below override this per test to exercise the gate
  # itself, including the locator-match.
  agmsg_self_proof() { printf 'proved\ttmux:%%3\n'; return 0; }
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

@test "one attempt ACROSS PROCESSES: a fresh process reads the persisted mark, does not re-poke (#1081)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_rename_on_action team alice claude-code      # phase 1: pokes, PERSISTS attempted
  [ "$(grep -c '\[send-keys\] \[-l\]' "$ARGV_LOG")" -eq 1 ]
  : > "$ARGV_LOG"
  # A brand-new shell shares NO memory with the first call; only the on-disk
  # role-session mark can carry "attempted" across. If the mark were held in a
  # variable rather than persisted, this fresh process would poke a second time.
  # (The stopping guarantee for an invasive auto-keystroke lives in the mark.)
  FAKE_TITLE='wrong-name' bash -c '
    source "$SKILL_DIR/scripts/lib/self-rename.sh"
    agmsg_self_rename_on_action team alice claude-code
  '
  refute grep -q '\[send-keys\] \[-l\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = failed ]            # confirmed in the 2nd process
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

# --- codex screen parse: only a line BEGINNING with "Thread name:" (#1102 review)
# grep -F accepted the phrase anywhere on a line and read the rest of an unrelated
# line as the name; the header is a line that STARTS with the prefix.

@test "codex screen parse: a leading Thread name line yields the name" {
  source "$SKILL_DIR/scripts/lib/team-status.sh"
  terminal_peek() { printf 'some banner\nThread name: team-alice\ntrailing output\n'; }
  [ "$(agmsg_cli_session_observed codex '' wA:p1)" = 'team-alice' ]
}

@test "codex screen parse: the phrase appearing mid-line is NOT the name -> unknown (#1102)" {
  source "$SKILL_DIR/scripts/lib/team-status.sh"
  terminal_peek() { printf 'ordinary output Thread name: team-alice\nmore\n'; }
  [ "$(agmsg_cli_session_observed codex '' wA:p1)" = 'unknown:name_not_visible' ]
}

@test "codex screen parse: no header at all -> unknown" {
  source "$SKILL_DIR/scripts/lib/team-status.sh"
  terminal_peek() { printf 'just some conversation\nno header here\n'; }
  [ "$(agmsg_cli_session_observed codex '' wA:p1)" = 'unknown:name_not_visible' ]
}

@test "codex screen parse: an unreadable screen -> unknown, not a name" {
  source "$SKILL_DIR/scripts/lib/team-status.sh"
  terminal_peek() { return 1; }
  [ "$(agmsg_cli_session_observed codex '' wA:p1)" = 'unknown:screen_unreadable' ]
}

# The header line begins with the prefix, but the rest of it is still screen text
# (#1102 review, tl follow-up). A real session name is short and has no control
# bytes; a value carrying a TAB would corrupt the TAB-separated records this feeds,
# so a control byte reads malformed rather than being passed through as the name.
@test "codex screen parse: a value with a control byte is malformed, not a name (#1102)" {
  source "$SKILL_DIR/scripts/lib/team-status.sh"
  terminal_peek() { printf 'Thread name: bad\tname\nmore\n'; }
  [ "$(agmsg_cli_session_observed codex '' wA:p1)" = 'unknown:name_malformed' ]
}

# A screen line far longer than any session name is not a name we can trust.
@test "codex screen parse: an over-long value is malformed, not a name (#1102)" {
  source "$SKILL_DIR/scripts/lib/team-status.sh"
  local long; printf -v long 'x%.0s' {1..200}
  terminal_peek() { printf 'Thread name: %s\n' "$long"; }
  [ "$(agmsg_cli_session_observed codex '' wA:p1)" = 'unknown:name_malformed' ]
}

@test "the pane the environment names may belong to ANOTHER seat's placement record -- never poke it, never mark it (#1112)" {
  # Measured live (#1112): a seat whose own label was broken resolved, through
  # the same inherited environment every codex seat under a shared app-server
  # sees, into a DIFFERENT seat's pane. That pane's title happened not to be
  # readable, so this seat only fell into "cannot verify -> skip" -- but the
  # environment gave no other reason it would have stopped short. Had the
  # title been readable and different from its own expected name, this would
  # have typed /rename into a live pane belonging to someone else.
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  # %3 is already recorded as ANOTHER seat's placement (bob's), in the same
  # team this agent (alice) is acting in.
  mkdir -p "$RUN_DIR"
  printf 'tmux:/tmp/s:%%3\t/proj\tclaude-code\n' > "$RUN_DIR/spawn.team__bob"
  run agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ -z "$(_mark team alice)" ]   # no mark at all -- next action re-checks, never "done" on a wrong pane
}

@test "the pane the environment names, recorded as THIS seat's own placement -- renames normally (#1112 control)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  mkdir -p "$RUN_DIR"
  printf 'tmux:/tmp/s:%%3\t/proj\tclaude-code\n' > "$RUN_DIR/spawn.team__alice"
  agmsg_self_rename_on_action team alice claude-code
  grep -q '\[send-keys\] \[-l\] \[-t\] \[%3\] \[--\] \[/rename team-alice\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = attempted ]
}

@test "no placement record exists for the pane at all -- unclaimed, renames normally (#1112 control)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_rename_on_action team alice claude-code
  grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = attempted ]
}

# --- #1206: the poke itself is gated on agmsg_self_proof, the same proof `fix`
# requires before it writes. The claim guard above (#1112) only catches a pane
# already recorded as SOMEONE ELSE's; an unclaimed pane a broken environment
# happens to name is not thereby proved to be this seat's, and the two controls
# right above this ("recorded as this seat's own" / "no record at all") both
# exercise cases where the pane guard alone would let the poke through -- they
# only stayed correct here because the stub in setup() says proved. These pin
# what happens when it does not.

@test "the proof says disproved -- never poke, and the skip names it (#1206)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_proof() { printf 'disproved\tpane_process_not_ancestor\n'; return 1; }
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = skipped:unproved:disproved ]
}

@test "the proof says undetermined -- never poke (#1206)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_proof() { printf 'undetermined\towner_absent\n'; return 2; }
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = skipped:unproved:undetermined ]
}

@test "self-proof.sh is unavailable -- treated as unsupported, never poke (#1206)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  unset -f agmsg_self_proof
  # SKILL_DIR points at a full copy of the skill with self-proof.sh removed, so
  # the lazy load in self-rename.sh finds nothing and the function stays
  # undeclared -- the same shape a broken or partial install would have.
  local fixture="$BATS_TEST_TMPDIR/no-self-proof"
  cp -r "$TEST_SKILL_DIR" "$fixture"
  rm "$fixture/scripts/lib/self-proof.sh"
  export SKILL_DIR="$fixture"
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = skipped:unproved:unsupported ]
}

@test "the proof says proved -- pokes exactly as before the gate existed (#1206 control)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  agmsg_self_proof() { printf 'proved\ttmux:%%3\n'; return 0; }
  agmsg_self_rename_on_action team alice claude-code
  grep -q '\[send-keys\] \[-l\] \[-t\] \[%3\] \[--\] \[/rename team-alice\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = attempted ]
}

# --- #1206 review: `proved` alone is not proof about THIS pane. self-proof.sh
# never echoes the caller's candidate back -- it returns the DRIVER's own
# canonical id for whatever it actually re-observed, revalidated. Reading only
# the state word, as the four cases above do, would let a proof for pane X
# authorize a poke into whatever pane the environment happened to name. These
# pin that a mismatch between the proved pane and the poke target refuses,
# even though the state is proved in every one of them.

@test "proved, but for a DIFFERENT pane than the one about to be poked -- never poke (#1206 review)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  # The environment names %3, but the proof -- honestly -- says it proved %9.
  agmsg_self_proof() { printf 'proved\ttmux:%%9\n'; return 0; }
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = skipped:unproved:locator_mismatch ]
}

@test "proved, but for a DIFFERENT tmux instance than the one about to be poked -- never poke (#1206 review)" {
  _install_fake_tmux; _under_tmux /tmp/s 4242 %3
  export FAKE_TITLE='wrong-name'
  # Same bare pane id, but the proof names a server this seat is not attached
  # to -- the instance-qualified locators are still different panes.
  agmsg_self_proof() { printf 'proved\ttmux:/tmp/other-server:%%3\n'; return 0; }
  agmsg_self_rename_on_action team alice claude-code
  refute grep -q '\[send-keys\]' "$ARGV_LOG"
  [ "$(_mark team alice | cut -f3)" = skipped:unproved:locator_mismatch ]
}

