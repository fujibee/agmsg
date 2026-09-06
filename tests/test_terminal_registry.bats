#!/usr/bin/env bats

# Terminal driver axis (v1) — registry resolution, record scheme, and the three
# drivers' ops, exercised against fake `tmux`/`herdr` binaries on PATH that
# record their argv. No real tmux server is started and no real herdr pane is
# touched (frame: the machine's tmux server must not start; live-CLI argv for
# herdr agent-prompt / pane-read is verified separately by the live matrix).
#
# The ops are sourced shell functions, so env is set via export/unset in the
# test (bats runs each test in its own subshell, so it does not leak) rather than
# `env VAR=... func` (env cannot invoke a function).

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_PLUGIN_DIRS=""
  export FAKEBIN="$TEST_SKILL_DIR/fakebin"
  export ARGV_LOG="$TEST_SKILL_DIR/argv.log"
  mkdir -p "$FAKEBIN"
  : > "$ARGV_LOG"
  # A clean env baseline; individual tests opt into TMUX / HERDR_ENV.
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_WORKSPACE_ID AGMSG_TERMINAL
  # shellcheck disable=SC1090
  source "$SKILL_DIR/scripts/lib/terminal-registry.sh"
}

teardown() { teardown_test_env; }

# One definition, in test_helper.bash: the watcher and delivery suites drive the
# terminal layer too now (#1044).
_install_fake_tmux() { agmsg_install_fake_tmux; }

# A fake `herdr` that logs argv and returns canned JSON/text for session <sid>.
_install_fake_herdr() {
  local sid="${1:-}"
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = agent ] && [ "\$2" = list ]; then
  # REAL herdr 0.8.0 shape (measured read-only): a { id, result:{ type, agents:[] } }
  # wrapper; each entry has agent_session as an OBJECT whose .value is the session
  # id, and pane_id as a top-level scalar sibling. Keeping the fixture faithful to
  # this is what the drift control below pins — a scalar agent_session was green
  # while resolving nothing on the real machine.
  printf '{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"%s"},"pane_id":"wC:p4","display_agent":"team:alice","name":"a-key"}]}}\n' "$sid"
elif [ "\$1" = pane ] && [ "\$2" = split ]; then
  echo '{"result":{"pane":{"pane_id":"wC:p9"}}}'
elif [ "\$1" = tab ] && [ "\$2" = create ]; then
  echo '{"result":{"root_pane":{"pane_id":"wD:p1"}}}'
elif [ "\$1" = pane ] && [ "\$2" = read ]; then
  printf 'herdr visible text\n'
elif [ "\$1" = pane ] && [ "\$2" = rename ]; then
  exit "\${HERDR_PANE_RENAME_RC:-0}"
elif [ "\$1" = agent ] && [ "\$2" = rename ]; then
  # The key rename. Failable per test (HERDR_AGENT_RENAME_RC), because "does it
  # fire when it should" and "does it answer ok when it failed" are different
  # questions and only the first one had a control.
  exit "\${HERDR_AGENT_RENAME_RC:-0}"
elif [ "\$1" = pane ] && [ "\$2" = process-info ]; then
  # requirement 1 gate: a READY pane (foreground pgid == shell pid) so terminal_spawn
  # proceeds to type. Overridable per test via HERDR_PROCESS_INFO_RESPONSE.
  if [ -n "\${HERDR_PROCESS_INFO_RESPONSE:-}" ]; then printf '%s\n' "\$HERDR_PROCESS_INFO_RESPONSE"
  else echo '{"result":{"process_info":{"shell_pid":7,"foreground_process_group_id":7}}}'; fi
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"
  export PATH="$FAKEBIN:$PATH"
}

# A herdr whose `agent list` ERRORS (stands in for herdr-absent/errored).
_fake_herdr_list_fails() {
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && exit 1\nexit 0\n' > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` answers with a valid EMPTY agents array (real wrapper
# shape, zero live agents) — the ONLY shape that means "answered, not among agents".
_fake_herdr_list_empty() {
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[]}}'\''; exit 0; }\nexit 0\n' > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` EXITS 0 but prints NON-JSON garbage. Exit-0 bytes are
# not proof of a readable agent set: this must classify as "could not answer"
# (return 2), NOT "answered, no match".
_fake_herdr_list_garbage() {
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo "not json at all"; exit 0; }\nexit 0\n' > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` EXITS 0 with VALID JSON but an UNRECOGNIZED schema (no
# agents array at any candidate path). A successful json_each on this returns 0 rows
# — so it must NOT be downgraded to "answered, not among"; it is "could not answer".
# arg 1 selects the payload: 'obj' -> {}, 'wrap' -> {"unknown":[]}.
_fake_herdr_list_unknown_schema() {
  local payload='{}'
  [ "${1:-}" = wrap ] && payload='{"unknown":[]}'
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''%s'\''; exit 0; }\nexit 0\n' "$payload" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` MIXES a well-formed entry (session <well_sid>, pane
# wA:p1) with a MALFORMED one (agent_session as a scalar). Absence cannot be claimed
# against this array — the searched session could be the unread malformed entry — so
# a no-match must be did-not-answer, not not-among. A match on the well-formed entry
# is still decisive.
_fake_herdr_list_mixed() {
  local well_sid="${1:-sess-OTHER}"
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"%s"},"pane_id":"wA:p1"},{"agent":"codex","agent_session":"scalar-broken","pane_id":"wB:p2"}]}}'\''; exit 0; }\nexit 0\n' "$well_sid" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` MIXES a well-formed OTHER-session entry with a MALFORMED
# entry that DOES carry agent_session.value=<target_sid> but a NUMERIC pane_id (not
# text). The malformed entry is excluded from the well-formed set, so the search must
# NOT return its 123 pane — a weaker search predicate (agent_session object + value
# only) would. No match among well-formed + a malformed sibling -> did-not-answer.
_fake_herdr_list_numeric_pane() {
  local target_sid="${1:-sess-mine}"
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"sess-OTHER"},"pane_id":"wA:p1"},{"agent":"codex","agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"%s"},"pane_id":123}]}}'\''; exit 0; }\nexit 0\n' "$target_sid" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` mixes a well-formed agent entry (session <sid>, pane
# w1:p4) with a BARE PANE that has NO agent_session at all (pane w5:p3). Measured on
# the real machine: a session-less pane is a NORMAL herdr member, not schema drift.
# Its membership IS decidable (it definitely is not the target), so an absent target
# must be not-among — NOT did-not-answer.
_fake_herdr_list_bare_pane() {
  local sid="${1:-sess-OTHER}"
  # The MEASURED session-less pane (live herdr, raw JSON): the agent_session
  # KEY is ABSENT entirely. B recognizes it by STRUCTURE, not by agent_status's value:
  # the pane carries the herdr-pane identity anchor (agent, terminal_id, tab_id,
  # workspace_id — measured always-present) and every field is a SCALAR. agent_status
  # here is "working" ON PURPOSE — the old code pinned "done" and this pane, alive but
  # not finished, then fell out of B (round-8 twice); the structural predicate takes it.
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"%s"},"pane_id":"w1:p4","terminal_id":"tm0","tab_id":"t0","workspace_id":"w0"},{"agent":"codex","agent_status":"working","cwd":"/x","focused":false,"revision":3,"state_change_seq":9,"tab_id":"t1","terminal_id":"tm1","terminal_title":"x","workspace_id":"w1","pane_id":"w5:p3"}]}}'\''; exit 0; }\nexit 0\n' "$sid" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` pairs a well-formed OTHER-session entry with a raw
# caller-supplied second entry (JSON object literal). Lets a test drive the A/B
# decidability boundary: an entry that is neither a session entry (A) nor a
# positively-recognized bare pane (B) must make an absent target did-not-answer.
_fake_herdr_list_plus() {
  local raw="${1:-{\}}"
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"sess-OTHER"},"pane_id":"w1:p4"},%s]}}'\''; exit 0; }\nexit 0\n' "$raw" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` has ONE entry: well-formed agent_session (value=<sid>)
# and a caller-supplied pane_id VALUE. Lets a test drive the pane-id grammar: a
# '|' or newline pane_id must be rejected (did-not-answer, and must not corrupt the
# '|'-framed / one-line read), while a real measured form (w1:p4) resolves.
_fake_herdr_list_one_pane() {
  local sid="${1:-sess-mine}" pane="${2:-w1:p4}"
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"%s"},"pane_id":"%s"}]}}'\''; exit 0; }\nexit 0\n' "$sid" "$pane" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}
# A herdr whose `agent list` uses the OLD wrong shape: agent_session as a SCALAR.
# The real herdr nests it as an object under .value; this fixture must resolve
# NOTHING (the drift control — a scalar shape was green on the mock while resolving
# zero panes on the real machine).
_fake_herdr_list_scalar_session() {
  local sid="${1:-}"
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[{"agent_session":"%s","pane_id":"wC:p4"}]}}'\''; exit 0; }\nexit 0\n' "$sid" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

# --- resolution -------------------------------------------------------------

@test "resolve: falls back to plain when neither tmux nor herdr is present" {
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'plain\t-')" ]
}

# The self id carries the SERVER, not just the pane: `<socket>:%N`. A pane id is
# not unique across tmux servers (measured — two servers both holding %0), so an
# id without its socket cannot be asked "are you still there?" of the right
# authority, and a wrong answer deletes a live member's placement record (#1051).
# $TMUX is "<socket-path>,<pid>,<session>"; the first field is the socket.
@test "resolve: picks tmux from \$TMUX and returns socket-qualified \$TMUX_PANE (#1051)" {
  _install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4"
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tmux\t/tmp/sock:%%4')" ]
}

@test "resolve: picks herdr from HERDR_ENV and resolves the pane from the session id" {
  _install_fake_herdr "sess-abc"
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-abc"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\twC:p4')" ]
}

@test "resolve: detection order puts herdr before tmux when both env are present" {
  _install_fake_tmux
  _install_fake_herdr "sess-abc"
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4" HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-abc"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\twC:p4')" ]
}

@test "resolve: an explicit override wins over detection" {
  _install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4" AGMSG_TERMINAL_DRIVER=plain
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'plain\t-')" ]
}

@test "selection drives ops: the RESOLVED terminal is the one whose ops run" {
  # Guards the "broken but green" a fixture invites: recording argv proves a
  # binary was CALLED, not that the RIGHT driver was selected. Here both env are
  # present (herdr must win), and we don't just assert the name — we load the
  # resolved terminal and run an op, asserting it reaches the herdr binary and
  # NEVER tmux. A resolver that wrongly returned tmux would load tmux, whose
  # despawn rejects a herdr-shaped id without calling any binary, so the herdr
  # grep fails: the selection error cannot slip through as "argv as expected".
  _install_fake_tmux
  _install_fake_herdr "sess-77"
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4" HERDR_ENV=1
  local res term
  term="$(agmsg_terminal_resolve_placement sess-77)"
  [ "$term" = "herdr" ]
  : > "$ARGV_LOG"
  agmsg_terminal_load "$term"
  terminal_despawn "wC:p9" >/dev/null
  grep -q '^herdr ' "$ARGV_LOG"
  refute grep -q '^tmux ' "$ARGV_LOG"
}

# --- record scheme ----------------------------------------------------------

@test "record: ref composes, and terminal/id split handles scheme, legacy bare, and inner colon" {
  [ "$(agmsg_terminal_ref tmux '%3')" = "tmux:%3" ]
  [ "$(agmsg_terminal_ref_terminal 'tmux:%3')" = "tmux" ]
  [ "$(agmsg_terminal_ref_terminal 'herdr:wC:pN')" = "herdr" ]
  [ "$(agmsg_terminal_ref_terminal '%3')" = "tmux" ]
  [ "$(agmsg_terminal_ref_terminal '@3')" = "tmux" ]
  [ "$(agmsg_terminal_ref_id 'herdr:wC:pN')" = "wC:pN" ]
  [ "$(agmsg_terminal_ref_id '%3')" = "%3" ]
}

@test "record: an unknown or CORRUPT ref FAILS CLOSED — validates the ID, not just the scheme" {
  # A ref is handed to a terminal as a TARGET (peek/poke/despawn). A KNOWN scheme is
  # not enough — the id after it must be a well-formed id for that terminal, or a
  # corrupt id (tmux:%9;kill, tmux:alice -> a real session, herdr:junk, plain:any)
  # reaches the backend. Unknown scheme AND malformed-id-behind-a-known-scheme both
  # -> non-zero, no output, so no terminal binary is ever invoked on it.
  local bad
  for bad in 'garbage' 'wC:p4' '%' '@abc' '% rm -rf' '%9;kill' 'herdr' '' \
             'tmux:garbage' 'tmux:%9;kill' 'tmux:alice' 'tmux:' 'tmux:@' \
             'herdr:not-a-pane' 'herdr:w1:p4:x' 'herdr:' 'plain:x' 'plain:'; do
    run agmsg_terminal_ref_terminal "$bad"
    [ "$status" -ne 0 ]   || { echo "FAIL: '$bad' resolved to a terminal ($output)"; return 1; }
    [ -z "$output" ]      || { echo "FAIL: '$bad' printed '$output'"; return 1; }
  done
  # ...and the well-formed shapes (scheme + a valid id, and the legacy bare tmux id)
  # still resolve.
  [ "$(agmsg_terminal_ref_terminal 'plain:-')" = "plain" ]
  [ "$(agmsg_terminal_ref_terminal 'tmux:%42')" = "tmux" ]
  [ "$(agmsg_terminal_ref_terminal 'tmux:@7')" = "tmux" ]
  [ "$(agmsg_terminal_ref_terminal 'herdr:wC:p4')" = "herdr" ]
  [ "$(agmsg_terminal_ref_terminal '%42')" = "tmux" ]
  [ "$(agmsg_terminal_ref_terminal '@7')" = "tmux" ]
}

# --- conf reader ------------------------------------------------------------

@test "conf: get reads a key, has tests membership, absent key returns default" {
  [ "$(agmsg_terminal_get tmux capabilities)" = "spawn despawn peek poke where arrange name" ]
  agmsg_terminal_has tmux capabilities peek
  refute agmsg_terminal_has tmux capabilities nonesuch
  [ "$(agmsg_terminal_get plain capabilities)" = "spawn despawn" ]
  [ "$(agmsg_terminal_get plain nonesuch DEFLT)" = "DEFLT" ]
}

@test "tmux hint syntax_help: executes tmux list-commands" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  run terminal_describe
  grep -q '^syntax_help=tmux list-commands$' <<<"$output"
  grep -q '^intent.place_below=' <<<"$output"
  grep -q '^intent.place_right=' <<<"$output"
  tmux list-commands >/dev/null
  grep -q '^tmux \[list-commands\]$' "$ARGV_LOG"
}

@test "herdr hint syntax_help: executes herdr --help" {
  _install_fake_herdr 'sess-help'
  agmsg_terminal_load herdr
  run terminal_describe
  grep -q '^syntax_help=herdr --help$' <<<"$output"
  herdr --help >/dev/null
  grep -q '^herdr \[--help\]$' "$ARGV_LOG"
}

@test "herdr hint skill_help: executes herdr --skill" {
  _install_fake_herdr 'sess-help'
  agmsg_terminal_load herdr
  run terminal_describe
  grep -q '^skill_help=herdr --skill$' <<<"$output"
  herdr --skill >/dev/null
  grep -q '^herdr \[--skill\]$' "$ARGV_LOG"
}

# --- plain driver -----------------------------------------------------------

@test "plain: peek and poke are unsupported (exit 13, reason on stderr)" {
  agmsg_terminal_load plain
  run terminal_peek "-"
  [ "$status" -eq 13 ]
  grep -q 'unsupported' <<<"$output"
  run terminal_poke "-" "hi"
  [ "$status" -eq 13 ]
  grep -q 'unsupported' <<<"$output"
}

@test "plain: check ok, describe advertises spawn despawn" {
  agmsg_terminal_load plain
  run terminal_check
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
  run terminal_describe
  grep -q '^capabilities=spawn despawn$' <<<"$output"
}

# --- tmux driver ops (fake tmux argv) --------------------------------------

@test "tmux: spawn a pane emits split-window and returns the captured id" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  export TMUX_PANE='%1'      # a pane split targets the caller's pane (#990)
  run terminal_spawn alice /proj pane-v bash -lc boot
  [ "$status" -eq 0 ]
  [ "$output" = "%9" ]
  grep -q 'split-window' "$ARGV_LOG"
  grep -q '\[-v\]' "$ARGV_LOG"
}

@test "tmux: spawn --split targets the CALLER's pane, not the active window (#990)" {
  # With no -t, tmux splits the attached client's active window, so a spawn from one
  # agent's pane can land in another agent's window. Target $TMUX_PANE explicitly.
  _install_fake_tmux
  agmsg_terminal_load tmux
  export TMUX_PANE='%7'
  : > "$ARGV_LOG"
  run terminal_spawn alice /proj pane-v boot
  [ "$status" -eq 0 ]
  grep -q '\[split-window\] \[-v\] \[-t\] \[%7\]' "$ARGV_LOG"
}

@test "tmux: spawn --split FAILS CLOSED when \$TMUX_PANE is unset (no ambient guess, #990)" {
  # Not observing the caller's pane is not evidence the ambient target is the caller
  # A pane split must fail closed (13) rather than let tmux pick the attached
  # client's active window — and it must not call split-window at all.
  _install_fake_tmux
  agmsg_terminal_load tmux
  unset TMUX_PANE
  : > "$ARGV_LOG"
  run terminal_spawn alice /proj pane-v boot
  [ "$status" -eq 13 ]
  refute grep -q 'split-window' "$ARGV_LOG"
}

@test "tmux: spawn a WINDOW does not need \$TMUX_PANE (creates in the session)" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  unset TMUX_PANE
  run terminal_spawn alice /proj window boot
  [ "$status" -eq 0 ]
  [ "$output" = "@7" ]
}

# A tmux stub whose split-window / new-window print a caller-supplied id.
_install_fake_tmux_id() {
  local split_id="$1" win_id="$2"
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$1" in
  new-window)   printf '%s\n' '$win_id' ;;
  split-window) printf '%s\n' '$split_id' ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"; export PATH="$FAKEBIN:$PATH"
}

@test "tmux: spawn validates the id KIND — %N for a pane, @N for a window" {
  agmsg_terminal_load tmux
  export TMUX_PANE='%0'      # pane splits target the caller pane (#990)
  # normal ids of the right kind succeed
  _install_fake_tmux_id '%3' '@4'
  run terminal_spawn a /proj pane-h boot;  [ "$status" -eq 0 ]; [ "$output" = "%3" ]
  run terminal_spawn a /proj window boot;  [ "$status" -eq 0 ]; [ "$output" = "@4" ]
}

@test "tmux: spawn fails closed on a wrong-kind / garbage / newline id" {
  agmsg_terminal_load tmux
  export TMUX_PANE='%0'      # pane splits target the caller pane (#990)
  # (1) pane target but a window id, (2) window target but a pane id,
  # (3) garbage, (4) an id carrying a newline — each must be 13, no id on stdout.
  _install_fake_tmux_id '@9' '@9'          # pane split returns a window id
  run terminal_spawn a /proj pane-h boot;  [ "$status" -eq 13 ]; [ -z "$output" ]
  _install_fake_tmux_id '%9' '%9'          # window target returns a pane id
  run terminal_spawn a /proj window boot;  [ "$status" -eq 13 ]; [ -z "$output" ]
  _install_fake_tmux_id 'garbage' 'garbage'
  run terminal_spawn a /proj pane-h boot;  [ "$status" -eq 13 ]; [ -z "$output" ]
  _install_fake_tmux_id '%1 rm -rf' '%1'   # trailing junk (would break record framing)
  run terminal_spawn a /proj pane-h boot;  [ "$status" -eq 13 ]; [ -z "$output" ]
}

@test "tmux: despawn kills a pane vs a window by id shape" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  terminal_despawn '%9' >/dev/null
  grep -q '\[kill-pane\] \[-t\] \[%9\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_despawn '@7' >/dev/null
  grep -q '\[kill-window\] \[-t\] \[@7\]' "$ARGV_LOG"
}

@test "tmux: peek captures the pane, --lines adds scrollback start" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  run terminal_peek '%9'
  [ "$status" -eq 0 ]
  grep -q 'line one' <<<"$output"
  grep -q '\[capture-pane\] \[-p\] \[-t\] \[%9\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_peek '%9' --lines 50 >/dev/null
  grep -q '\[-S\] \[-50\]' "$ARGV_LOG"
}

@test "tmux: poke sends text and the Enter in SEPARATE bursts with an arrow between (#619)" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  run terminal_poke '%9' 'hello world'
  [ "$status" -eq 0 ]
  grep -q '\[send-keys\] \[-l\] \[-t\] \[%9\] \[--\] \[hello world\]' "$ARGV_LOG"
  grep -q '\[send-keys\] \[-t\] \[%9\] \[Right\] \[Enter\]' "$ARGV_LOG"
  [ "$(grep -c 'send-keys' "$ARGV_LOG")" -eq 2 ]
}

@test "tmux: name sets @agmsg_agent (resolvable) and a ':'-joined visible title" {
  _install_fake_tmux
  agmsg_terminal_load tmux
  terminal_name '%9' teamx alice >/dev/null
  grep -q '\[set-option\] \[-p\] \[-t\] \[%9\] \[@agmsg_agent\] \[teamx:alice\]' "$ARGV_LOG"
  grep -q '\[select-pane\] \[-t\] \[%9\] \[-T\] \[teamx:alice\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_name '@7' teamx alice >/dev/null
  grep -q '\[set-option\] \[-p\] \[-t\] \[@7\] \[@agmsg_agent\] \[teamx:alice\]' "$ARGV_LOG"
  grep -q '\[rename-window\] \[-t\] \[@7\] \[teamx:alice\]' "$ARGV_LOG"
}

_install_fake_tmux_layout() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1" = list-panes ]; then printf '%s\n' "\${TMUX_LAYOUT:-}"; fi
exit "\${TMUX_RC:-0}"
EOF
  chmod +x "$FAKEBIN/tmux"; export PATH="$FAKEBIN:$PATH"
}

@test "tmux: where answers the window only; a missing-after-present id is unknown, never gone" {
  _install_fake_tmux_layout
  export TMUX_LAYOUT='%1|@7|0|0|80|10'
  agmsg_terminal_load tmux
  run terminal_where '%1'
  [ "$status" -eq 0 ]
  [ "$output" = '@7' ]
  run terminal_where '@7'
  [ "$status" -eq 0 ]
  [ "$output" = '@7' ]
  run terminal_where '%9'
  [ "$status" -eq 10 ]
  printf '%s\n' "$output" | grep -q '^unknown'
  refute grep -q '^gone$' <<<"$output"
}

@test "tmux hint place_below: gates the non-idempotent move, then executes move-pane -v" {
  _install_fake_tmux_layout
  agmsg_terminal_load tmux
  terminal_describe | grep -q '^intent.place_below=tmux move-pane -s SOURCE -t TARGET -v$'
  export TMUX_LAYOUT=$'%1|@7|11|0|80|10\n%2|@7|0|0|80|10'
  run terminal_arrange '%1' place_below '%2'
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  refute grep -q '\[move-pane\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  export TMUX_LAYOUT=$'%1|@7|0|0|40|10\n%2|@7|12|0|40|10'
  run terminal_arrange '%1' place_below '%2'
  [ "$output" = moved ]
  grep -q '\[move-pane\] \[-s\] \[%1\] \[-t\] \[%2\] \[-v\]' "$ARGV_LOG"
}

@test "tmux hint place_right: gates the non-idempotent move, then executes move-pane -h" {
  _install_fake_tmux_layout
  agmsg_terminal_load tmux
  terminal_describe | grep -q '^intent.place_right=tmux move-pane -s SOURCE -t TARGET -h$'
  export TMUX_LAYOUT=$'%1|@7|0|41|39|23\n%2|@7|0|0|40|23'
  run terminal_arrange '%1' place_right '%2'
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  refute grep -q '\[move-pane\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  export TMUX_LAYOUT=$'%1|@7|12|0|40|10\n%2|@7|0|0|40|10'
  run terminal_arrange '%1' place_right '%2'
  [ "$output" = moved ]
  grep -q '\[move-pane\] \[-s\] \[%1\] \[-t\] \[%2\] \[-h\]' "$ARGV_LOG"
}

@test "tmux: arrange cannot locate a listed pane -> unknown/10, not runtime_error" {
  _install_fake_tmux_layout
  agmsg_terminal_load tmux
  export TMUX_LAYOUT='%2|@7|0|0|80|10'
  run terminal_arrange '%1' place_below '%2'
  [ "$status" -eq 10 ]
  [ "$output" = unknown ]
  refute grep -q '\[move-pane\]' "$ARGV_LOG"
}

# --- herdr driver ops (fake herdr argv; live-verified argv flagged) ---------

@test "herdr: detect resolves the pane for the session id via agent list" {
  _install_fake_herdr "sess-77"
  agmsg_terminal_load herdr
  export HERDR_ENV=1
  run terminal_detect "sess-77"
  [ "$status" -eq 0 ]
  [ "$output" = "wC:p4" ]
  grep -q '\[agent\] \[list\]' "$ARGV_LOG"
}

@test "herdr: spawn splits a pane, renames, runs boot, returns the new id" {
  _install_fake_herdr "sess-77"
  agmsg_terminal_load herdr
  export HERDR_PANE_ID='wC:p1'
  run terminal_spawn alice /proj pane-v bash -lc boot
  [ "$status" -eq 0 ]
  [ "$output" = "wC:p9" ]
  grep -q '\[pane\] \[split\]' "$ARGV_LOG"
  grep -q '\[pane\] \[rename\] \[wC:p9\] \[alice\]' "$ARGV_LOG"
  grep -q '\[pane\] \[run\] \[wC:p9\]' "$ARGV_LOG"
}

@test "herdr: terminal_spawn reaches the readiness arms under a NON-conditional set -e caller" {
  # The readiness classifier returns non-zero for NOT-READY/UNKNOWN; a bare
  # `classifier; ready_rc=$?` takes a set -e caller down BEFORE the arms classify. The
  # spawn.sh tests call terminal_spawn inside `$(...)`, where errexit is masked — so
  # prove the fix from a NON-conditional set -e caller (terminal_spawn called directly).
  # A non-integer process-info is UNKNOWN, which must reach arm 3 (type + exit 4), not
  # abort at the classifier.
  _install_fake_herdr "sess-77"
  export HERDR_PANE_ID='wC:p1'
  export HERDR_PROCESS_INFO_RESPONSE='{"result":{"process_info":{"shell_pid":"x","foreground_process_group_id":"x"}}}'
  run bash -c 'set -euo pipefail; . "'"$SKILL_DIR"'/scripts/drivers/terminals/herdr/ops.sh"; terminal_spawn alice /proj pane-v /boot'
  [ "$status" -eq 4 ]                        # arm 3 reached (typed, unverified) — did NOT die at the classifier
  [ "$output" = "wC:p9" ]                    # the pane id was printed, so the boot was typed
  grep -q '\[pane\] \[run\] \[wC:p9\]' "$ARGV_LOG"
}

@test "herdr: spawn fails closed on a non-grammar pane_id (numeric, newline, '|', bad shape)" {
  # A usable pane id must match the measured grammar, not merely be non-empty text.
  # Numeric/null (malformed/partial response) AND text values carrying a newline, a
  # '|', or a wrong shape must all make terminal_spawn return 13 and touch nothing —
  # a newline would otherwise break the <terminal>:<id> record framing downstream.
  agmsg_terminal_load herdr
  export HERDR_PANE_ID='wC:p1'
  local body
  for body in '{"result":{"pane":{"pane_id":42}}}' \
              '{"result":{"pane":{"pane_id":"w1:p|4"}}}' \
              '{"result":{"pane":{"pane_id":"w1:x:p4"}}}' \
              '{"result":{"pane":{"pane_id":"w:p"}}}' \
              '{"result":{"pane":{"pane_id":"w1:p\n4"}}}'; do
    printf '#!/usr/bin/env bash\n{ printf '\''herdr'\''; for a in "$@"; do printf '\'' [%%s]'\'' "$a"; done; printf '\''\\n'\''; } >> "%s"\nif [ "$1" = pane ] && [ "$2" = split ]; then echo '\''%s'\''; fi\nexit 0\n' "$ARGV_LOG" "$body" > "$FAKEBIN/herdr"
    chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
    : > "$ARGV_LOG"
    run terminal_spawn alice /proj pane-v bash -lc boot
    [ "$status" -eq 13 ]                       || { echo "FAIL not 13: $body"; return 1; }
    refute grep -q '\[pane\] \[rename\]' "$ARGV_LOG" || { echo "FAIL renamed: $body"; return 1; }
    refute grep -q '\[pane\] \[run\]' "$ARGV_LOG"    || { echo "FAIL ran: $body"; return 1; }
  done
}

@test "herdr: the pane-id grammar shell authority agrees with the resolver on boundary values" {
  # The resolver (SQL GLOB) and the spawn side (_herdr_pane_id_ok, bash) express
  # the SAME grammar; a drift between them would let one accept what the other rejects.
  # Cross-check both on the boundary set: the shell authority and a resolver lookup
  # (via a one-entry list whose pane_id is the value) must agree on accept/reject.
  agmsg_terminal_load herdr    # brings _herdr_pane_id_ok into scope
  export HERDR_ENV=1
  local v want
  for v in 'w1:p4:ACCEPT' 'wC:p4:ACCEPT' 'w1:pB:ACCEPT' \
           'w:p:REJECT' 'w1:p:REJECT' 'w:p4:REJECT' 'w1:x:p4:REJECT' 'w1:p|4:REJECT'; do
    local pane="${v%:*}" want="${v##*:}"
    # shell authority
    if _herdr_pane_id_ok "$pane"; then [ "$want" = ACCEPT ] || { echo "shell accepted $pane"; return 1; }
    else [ "$want" = REJECT ] || { echo "shell rejected $pane"; return 1; }; fi
    # resolver: a well-formed session entry whose pane is $pane -> ACCEPT resolves it,
    # REJECT makes the target present-but-unaddressable (did-not-answer).
    _fake_herdr_list_one_pane "sess-mine" "$pane"
    run agmsg_terminal_resolve_name "sess-mine"
    if [ "$want" = ACCEPT ]; then
      [ "$status" -eq 0 ] && [ "$output" = "$(printf 'herdr\t%s' "$pane")" ] || { echo "resolver rejected $pane"; return 1; }
    else
      [ "$status" -ne 0 ] && grep -q "did not answer" <<<"$output" || { echo "resolver accepted $pane"; return 1; }
    fi
  done
}

@test "herdr: despawn closes the pane; peek reads visible; name sets visible ':' + derived key" {
  _install_fake_herdr "sess-77"
  agmsg_terminal_load herdr
  terminal_despawn 'wC:p9' >/dev/null
  grep -q '\[pane\] \[close\] \[wC:p9\]' "$ARGV_LOG"
  run terminal_peek 'wC:p9'
  [ "$status" -eq 0 ]
  grep -q 'herdr visible text' <<<"$output"
  grep -q '\[pane\] \[read\] \[wC:p9\] \[--source\] \[visible\]' "$ARGV_LOG"
  : > "$ARGV_LOG"
  terminal_name 'wC:p9' teamx alice >/dev/null
  # VISIBLE name is the free-text '<team>:<agent>'.
  grep -q '\[pane\] \[rename\] \[wC:p9\] \[teamx:alice\]' "$ARGV_LOG"
  # RESOLVABLE key is the injective SHA-256 derivation: 'a' + 24 hex, matching
  # herdr's [a-z][a-z0-9_-]{0,31} regex. (Exact value is asserted for distinctness
  # in the injectivity test below, not pinned here.)
  grep -qE '\[agent\] \[rename\] \[wC:p9\] \[a[0-9a-f]{24}\]' "$ARGV_LOG"
}

_install_fake_herdr_layout() {
  cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
{ printf 'herdr'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
if [ "\$1 \$2" = 'pane layout' ]; then
  if [ -n "\${HERDR_SOURCE_LAYOUT:-}" ] && [ "\${4:-}" = 'wA:p1' ]; then printf '%s\n' "\$HERDR_SOURCE_LAYOUT"
  else printf '%s\n' "\$HERDR_LAYOUT"
  fi
elif [ "\$1 \$2" = 'pane move' ]; then
  case " \$* " in *' --tab '*) [ "\${HERDR_SECOND_RC:-0}" -eq 0 ] || exit "\$HERDR_SECOND_RC" ;; esac
  case " \$* " in
    *' --new-tab '*)
      if [ "\${HERDR_FIRST_CHANGED:-true}" = true ]; then printf '%s\n' '{"result":{"move_result":{"changed":true,"created_tab":{"tab_id":"wA:t9"}}}}'
      else printf '%s\n' '{"result":{"move_result":{"changed":false}}}'
      fi
      ;;
    *) printf '%s\n' '{"result":{"move_result":{"changed":true}}}' ;;
  esac
fi
exit 0
EOF
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

@test "herdr: where answers the tab only and never becomes a second gone authority" {
  _install_fake_herdr_layout
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t2","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":0,"width":10,"height":10}}],"splits":[]}}}'
  agmsg_terminal_load herdr
  run terminal_where 'wA:p1'
  [ "$status" -eq 0 ]
  [ "$output" = 'wA:t2' ]
  run terminal_where 'wA:p9'
  [ "$status" -eq 10 ]
  printf '%s\n' "$output" | grep -q '^unknown'
  refute grep -q '^gone$' <<<"$output"
}

@test "herdr hint place_below: gates the move, then executes new-tab and split down" {
  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  terminal_describe | grep -q '^intent.place_below=herdr pane move SOURCE --new-tab; herdr pane move SOURCE --tab CONTAINER --split down --target-pane TARGET$'
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":10,"width":20,"height":10}},{"pane_id":"wA:p2","rect":{"x":0,"y":0,"width":20,"height":10}}],"splits":[{"id":"opaque","direction":"down","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":20}}]}}}'
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  refute grep -q '\[pane\] \[move\]' "$ARGV_LOG"
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":0,"width":10,"height":20}},{"pane_id":"wA:p2","rect":{"x":10,"y":0,"width":10,"height":20}}],"splits":[{"id":"opaque","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":20}}]}}}'
  : > "$ARGV_LOG"
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$output" = moved ]
  grep -q '\[pane\] \[move\] \[wA:p1\] \[--new-tab\] \[--no-focus\]' "$ARGV_LOG"
  grep -q '\[--tab\] \[wA:t1\] \[--split\] \[down\] \[--target-pane\] \[wA:p2\]' "$ARGV_LOG"
}

@test "herdr hint place_right: gates the move, then executes new-tab and split right" {
  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  terminal_describe | grep -q '^intent.place_right=herdr pane move SOURCE --new-tab; herdr pane move SOURCE --tab CONTAINER --split right --target-pane TARGET$'
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":10,"y":0,"width":10,"height":20}},{"pane_id":"wA:p2","rect":{"x":0,"y":0,"width":10,"height":20}}],"splits":[{"id":"opaque","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":20}}]}}}'
  run terminal_arrange 'wA:p1' place_right 'wA:p2'
  [ "$status" -eq 0 ]
  [ "$output" = unchanged ]
  refute grep -q '\[pane\] \[move\]' "$ARGV_LOG"
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":0,"width":20,"height":10}},{"pane_id":"wA:p2","rect":{"x":0,"y":10,"width":20,"height":10}}],"splits":[{"id":"opaque","direction":"down","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":20}}]}}}'
  : > "$ARGV_LOG"
  run terminal_arrange 'wA:p1' place_right 'wA:p2'
  [ "$output" = moved ]
  grep -q '\[pane\] \[move\] \[wA:p1\] \[--new-tab\] \[--no-focus\]' "$ARGV_LOG"
  grep -q '\[--split\] \[right\]' "$ARGV_LOG"
}

@test "herdr: equal-area direction-compatible split candidates fail closed" {
  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":1,"width":10,"height":1}},{"pane_id":"wA:p2","rect":{"x":0,"y":0,"width":10,"height":1}}],"splits":[{"id":"opaque-a","direction":"down","ratio":0.5,"rect":{"x":0,"y":0,"width":10,"height":2}},{"id":"opaque-b","direction":"down","ratio":0.5,"rect":{"x":0,"y":0,"width":10,"height":2}}]}}}'
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 12 ]
  [ "$output" = ambiguous_layout ]
  refute grep -q '\[pane\] \[move\]' "$ARGV_LOG"
}

@test "herdr: a pane below an intervening pane is different, not directly place_below" {
  agmsg_terminal_load herdr
  local layout='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":20,"width":20,"height":10}},{"pane_id":"wA:pX","rect":{"x":0,"y":10,"width":20,"height":10}},{"pane_id":"wA:p2","rect":{"x":0,"y":0,"width":20,"height":10}}],"splits":[{"id":"outer","direction":"down","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":30}},{"id":"inner","direction":"down","ratio":0.5,"rect":{"x":0,"y":10,"width":20,"height":20}}]}}}'
  run _herdr_arrange_state "$layout" 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 0 ]
  [ "$output" = different ]
}

@test "herdr: second arrange step failure says the source may be stranded in a temporary tab" {
  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  export HERDR_SECOND_RC=1
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":0,"width":10,"height":20}},{"pane_id":"wA:p2","rect":{"x":10,"y":0,"width":10,"height":20}}],"splits":[{"id":"opaque","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":20}}]}}}'
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 12 ]
  printf '%s\n' "$output" | grep -q '^runtime_error'
  printf '%s\n' "$output" | grep -q "left in temporary tab 'wA:t9'"
  printf '%s\n' "$output" | grep -q "placing it back in tab 'wA:t1'"
}

@test "herdr: an unchanged temporary-tab move fails before the second step" {
  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  export HERDR_FIRST_CHANGED=false
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":0,"width":10,"height":20}},{"pane_id":"wA:p2","rect":{"x":10,"y":0,"width":10,"height":20}}],"splits":[{"id":"opaque","direction":"right","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":20}}]}}}'
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 12 ]
  printf '%s\n' "$output" | grep -q '^runtime_error'
  printf '%s\n' "$output" | grep -q 'did not report changed=true'
  [ "$(grep -c '\[pane\] \[move\]' "$ARGV_LOG")" -eq 1 ]
}

@test "herdr: arrange cannot locate a layout pane -> unknown/10, not runtime_error" {
  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p2","rect":{"x":0,"y":0,"width":20,"height":20}}],"splits":[]}}}'
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 10 ]
  [ "$output" = unknown ]
  refute grep -q '\[pane\] \[move\]' "$ARGV_LOG"
}

@test "herdr: arrange moves a source proven present in a different tab" {
  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p2","rect":{"x":0,"y":0,"width":20,"height":20}}],"splits":[]}}}'
  export HERDR_SOURCE_LAYOUT='{"result":{"layout":{"tab_id":"wA:t2","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":0,"width":20,"height":20}}],"splits":[]}}}'
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 0 ]
  [ "$output" = moved ]
  [ "$(grep -c '\[pane\] \[layout\]' "$ARGV_LOG")" -eq 2 ]
  grep -q '\[pane\] \[move\] \[wA:p1\] \[--new-tab\]' "$ARGV_LOG"
  grep -q '\[--tab\] \[wA:t1\] \[--split\] \[down\] \[--target-pane\] \[wA:p2\]' "$ARGV_LOG"
}

@test "arrange meaning: both tmux and herdr move when another pane separates source from target" {
  _install_fake_tmux_layout
  agmsg_terminal_load tmux
  export TMUX_LAYOUT=$'%1|@7|22|0|80|10\n%X|@7|11|0|80|10\n%2|@7|0|0|80|10'
  run terminal_arrange '%1' place_below '%2'
  [ "$status" -eq 0 ]
  [ "$output" = moved ]
  grep -q '\[move-pane\]' "$ARGV_LOG"

  _install_fake_herdr_layout
  agmsg_terminal_load herdr
  export HERDR_LAYOUT='{"result":{"layout":{"tab_id":"wA:t1","panes":[{"pane_id":"wA:p1","rect":{"x":0,"y":20,"width":20,"height":10}},{"pane_id":"wA:pX","rect":{"x":0,"y":10,"width":20,"height":10}},{"pane_id":"wA:p2","rect":{"x":0,"y":0,"width":20,"height":10}}],"splits":[{"id":"outer","direction":"down","ratio":0.5,"rect":{"x":0,"y":0,"width":20,"height":30}},{"id":"inner","direction":"down","ratio":0.5,"rect":{"x":0,"y":10,"width":20,"height":20}}]}}}'
  : > "$ARGV_LOG"
  run terminal_arrange 'wA:p1' place_below 'wA:p2'
  [ "$status" -eq 0 ]
  [ "$output" = moved ]
  grep -q '\[pane\] \[move\]' "$ARGV_LOG"
}

@test "herdr peek: an error body is NOT returned as content, and the single 13 is split" {
  agmsg_terminal_load herdr
  # (1) herdr answers but the pane is GONE: it exits non-zero AND writes an error JSON
  # to STDOUT. peek must NOT hand that back as the pane content (stdout empty), and it
  # must use a code distinct from plain's documented 13.
  printf '#!/usr/bin/env bash\nif [ "$1" = pane ] && [ "$2" = read ]; then echo '\''{"error":{"code":"pane_not_found","message":"gone"}}'\''; exit 13; fi\nexit 0\n' > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
  local out rc=0
  out="$(terminal_peek 'wC:p99' 2>/dev/null)" || rc=$?
  [ "$rc" -eq 12 ]                       # pane-gone: distinct from plain's 13
  [ -z "$out" ]                          # the error JSON did NOT reach the content channel
  # (2) herdr is UNREACHABLE (not on PATH): a third, distinct code — not 12, not 13.
  rm -f "$FAKEBIN/herdr"
  rc=0
  out="$(PATH=/usr/bin:/bin terminal_peek 'wC:p1' 2>/dev/null)" || rc=$?
  [ "$rc" -eq 10 ]
}

# Pull the internal key (4th bracket of the `agent rename` line) from the argv log.
_last_agent_rename_key() {
  sed -n 's/.*\[agent\] \[rename\] \[[^]]*\] \[\([^]]*\)\].*/\1/p' "$ARGV_LOG" | tail -1
}

@test "herdr naming: the internal key avoids the known fold/join collisions ('-' and ':')" {
  # 2026-09-01: the old fold (':' and non-regex chars -> '-') and ANY
  # literal separator have a STRUCTURAL (deterministic, reachable) collision, because
  # the separator is legal inside a name. Example:
  #     ("a-b","c") and ("a","b-c")   both fold to  a-b-c
  # and the same holds for the ':' the spec proposed as the join char:
  #     ("a:b","c") and ("a","b:c")   both join to  a:b:c
  # The newline-joined SHA-256 derivation (newline is a forbidden control char in
  # both names) removes that STRUCTURAL ambiguity, so each of these four members
  # gets a distinct key. This is NOT a proof of injectivity — a 96-bit hash of
  # arbitrary input has collisions by pigeonhole; the key is collision-RESISTANT,
  # and uniqueness is only needed among the dozens of live agents. This control
  # pins that the known fold/join collisions specifically do not recur (a test that
  # only checks "a key is produced" passes even if the fold returns).
  _install_fake_herdr "sess-77"
  agmsg_terminal_load herdr
  : > "$ARGV_LOG"; terminal_name 'p1' 'a-b' 'c'  >/dev/null; local k1; k1="$(_last_agent_rename_key)"
  : > "$ARGV_LOG"; terminal_name 'p2' 'a'   'b-c' >/dev/null; local k2; k2="$(_last_agent_rename_key)"
  : > "$ARGV_LOG"; terminal_name 'p3' 'a:b' 'c'  >/dev/null; local k3; k3="$(_last_agent_rename_key)"
  : > "$ARGV_LOG"; terminal_name 'p4' 'a'   'b:c' >/dev/null; local k4; k4="$(_last_agent_rename_key)"
  # every key is well-formed against herdr's regex ('a' + 24 hex)
  for k in "$k1" "$k2" "$k3" "$k4"; do [[ "$k" =~ ^a[0-9a-f]{24}$ ]]; done
  # the two '-' collisions are distinct, and the two ':' collisions are distinct
  [ "$k1" != "$k2" ]
  [ "$k3" != "$k4" ]
}

# --- ABI completeness + structural clobber-proofing (#1014 review) -------

@test "abi: every driver defines every required terminal_* function" {
  # The declaration/implementation match flagged in review: an ops.sh missing a verb
  # would, after a prior load, silently run the previous driver's same-named
  # function. agmsg_terminal_load verifies the full set; loading each driver must
  # therefore succeed (a missing verb fails the load loudly).
  agmsg_terminal_load plain
  agmsg_terminal_load tmux
  agmsg_terminal_load herdr
}

@test "abi: capabilities= verbs are actually implemented by each driver" {
  local d cap fn
  for d in plain tmux herdr; do
    ( agmsg_terminal_load "$d"
      for cap in $(agmsg_terminal_get "$d" capabilities); do
        fn="terminal_$cap"
        declare -F "$fn" >/dev/null 2>&1 || { echo "$d advertises $cap but lacks $fn" >&2; exit 1; }
      done )
  done
}

@test "load: switching drivers does not inherit the previous driver's ops (clobber)" {
  _install_fake_tmux
  # Load tmux, then plain. plain has NO addressable pane, so its PEEK is
  # unsupported. If plain load left tmux's terminal_peek behind, peek on a pane id
  # would call tmux; instead it must be plain's unsupported.
  agmsg_terminal_load tmux
  agmsg_terminal_load plain
  run terminal_peek '%9'
  [ "$status" -eq 13 ]
  grep -q 'unsupported' <<<"$output"
  # And the tmux binary was never invoked by plain's peek.
  refute grep -q '^tmux ' "$ARGV_LOG"
}

@test "load: a driver missing an ABI function fails the load, leaving nothing behind" {
  # Register a broken external driver (missing terminal_poke) as a trusted plugin.
  local pdir="$TEST_SKILL_DIR/plugins/terminals/broken"
  mkdir -p "$pdir"
  printf 'name=broken\ncapabilities=\n' > "$pdir/terminal.conf"
  cat > "$pdir/ops.sh" <<'OPS'
terminal_check(){ echo ok; }
terminal_describe(){ printf 'name=broken\n'; }
terminal_detect(){ printf -- '-\n'; }
terminal_spawn(){ printf -- '-\n'; }
terminal_despawn(){ echo ok; }
terminal_peek(){ echo ok; }
terminal_name(){ echo ok; }
OPS
  mkdir -p "$TEST_SKILL_DIR/db"
  printf 'terminals/broken\t%s\n' "$pdir" > "$TEST_SKILL_DIR/db/trusted-plugins"
  # First load a good driver so a leftover COULD be borrowed. Call load DIRECTLY
  # with stderr to a FILE (NOT `run` or $(...), both subshells) so its unset
  # affects THIS shell, which is where "nothing left behind" must hold.
  agmsg_terminal_load plain
  local err="$TEST_SKILL_DIR/load.err" rc=0
  agmsg_terminal_load broken 2>"$err" || rc=$?
  [ "$rc" -ne 0 ]
  grep -q 'missing ABI functions' "$err"
  grep -q 'terminal_poke' "$err"
  # Nothing partial left behind: terminal_poke must be undefined now.
  refute declare -F terminal_poke
}

# --- fail-closed resolution (#1014 review) ------------------------------

@test "detect: tmux with an empty \$TMUX_PANE still PLACES in tmux (presence)" {
  # For placement, being in tmux is enough — spawn records the pane it CREATES,
  # not the caller's own. An empty $TMUX_PANE does not fall through to plain.
  export TMUX="/tmp/sock,1,0"
  unset TMUX_PANE
  run agmsg_terminal_resolve_placement "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "tmux" ]
}

@test "detect: tmux with an empty \$TMUX_PANE is FATAL for naming, with a reason" {
  # For naming, we must identify the pane. Present-but-no-id is fatal: say why,
  # non-zero — better than naming nothing (the fail-closed rule lives on this side).
  export TMUX="/tmp/sock,1,0"
  unset TMUX_PANE
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "cannot identify this pane" <<<"$output"
  grep -q "TMUX_PANE" <<<"$output"
}

@test "resolve: an override that names no real driver fails loudly, not '<typo>\t'" {
  export AGMSG_TERMINAL_DRIVER=tnux
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "unknown terminal driver 'tnux'" <<<"$output"
}

# --- plain: OS-terminal spawn/despawn; peek/poke/name unsupported ------------

@test "plain: peek/poke/name are unsupported (no addressable pane)" {
  agmsg_terminal_load plain
  local v
  for v in peek poke name; do
    run "terminal_$v" "-" x y
    [ "$status" -eq 13 ]
    grep -q 'unsupported' <<<"$output"
  done
}

@test "plain: spawn runs the boot THROUGH the {cmd} template, and returns '-'; despawn is a no-op ok" {
  agmsg_terminal_load plain
  # The fake BOOT records that IT ran — so the test proves the template actually
  # launched the boot, not merely that the template's own side effect fired. A
  # dropped/garbled {cmd} would leave $ran absent (red), which a "touch marker;
  # ignore {cmd}" template would hide.
  local ran="$TEST_SKILL_DIR/boot-ran"
  local boot="$TEST_SKILL_DIR/boot"
  printf '#!/usr/bin/env bash\ntouch %q\n' "$ran" > "$boot"
  chmod +x "$boot"
  # The template invokes {cmd} directly (a runnable path), like a real terminal
  # would run the boot script.
  export AGMSG_TERMINAL="{cmd}"
  run terminal_spawn alice /proj window "$boot"
  [ "$status" -eq 0 ]
  [ "$output" = "-" ]
  [ -f "$ran" ]     # the boot itself ran, reached via the template
  run terminal_despawn "-"
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "plain: spawn ISOLATES backend stdout — the record-op result is exactly '-'" {
  # spawn is a record op: its stdout must be the id ('-') and nothing else. A backend
  # (here a {cmd} template) that writes to stdout must not pollute the captured result
  # — otherwise the caller reads '<noise>\n-' as the placement id. Capture stdout
  # ALONE (stderr, where the noise now goes as a diagnostic, is separated).
  agmsg_terminal_load plain
  local noisy="$TEST_SKILL_DIR/noisy-boot"
  printf '#!/usr/bin/env bash\necho "BACKEND STDOUT NOISE"\nprintf "and more\\n"\n' > "$noisy"
  chmod +x "$noisy"
  export AGMSG_TERMINAL="{cmd}"
  local out rc=0
  out="$(terminal_spawn alice /proj window "$noisy" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ]
  [ "$out" = "-" ]                       # exactly '-', the backend noise did not leak
}

# --- load failure cleanup: source failure, like missing-function, leaves nothing (review round 2) ---

@test "load: a driver whose ops.sh fails to source leaves no partial functions behind" {
  local pdir="$TEST_SKILL_DIR/plugins/terminals/halfsource"
  mkdir -p "$pdir"
  printf 'name=halfsource\ncapabilities=\n' > "$pdir/terminal.conf"
  # Defines some terminal_* (these parse and DO get defined), then the source
  # returns non-zero at runtime — so `. ops.sh` fails WITH partial functions live,
  # which is exactly what the source-failure cleanup must wipe. (A parse error
  # instead would define nothing, and the pre-source unset alone would pass the
  # test — this fixture makes the source-failure arm actually load-bearing.)
  cat > "$pdir/ops.sh" <<'OPS'
terminal_check(){ echo ok; }
terminal_despawn(){ echo ok; }
false
OPS
  mkdir -p "$TEST_SKILL_DIR/db"
  printf 'terminals/halfsource\t%s\n' "$pdir" > "$TEST_SKILL_DIR/db/trusted-plugins"
  agmsg_terminal_load plain
  local err="$TEST_SKILL_DIR/src.err" rc=0
  agmsg_terminal_load halfsource 2>"$err" || rc=$?
  [ "$rc" -ne 0 ]
  # Whatever the source defined before aborting must be gone, and no prior
  # driver's ops remain either.
  refute declare -F terminal_check
  refute declare -F terminal_despawn
  [ -z "$_AGMSG_TERMINAL_LOADED" ]
}

# --- herdr spawn target validation (review round 2) --------------------------------

@test "herdr: spawn rejects an unknown target instead of defaulting" {
  _install_fake_herdr "s"
  agmsg_terminal_load herdr
  export HERDR_PANE_ID='wC:p1'
  run terminal_spawn alice /proj paen-v bash -lc boot
  [ "$status" -eq 13 ]
  grep -q 'unknown target' <<<"$output"
  # It must NOT have split anything.
  refute grep -q '\[pane\] \[split\]' "$ARGV_LOG"
}

@test "herdr: spawn window without HERDR_WORKSPACE_ID fails explicitly, not a silent split" {
  _install_fake_herdr "s"
  agmsg_terminal_load herdr
  unset HERDR_WORKSPACE_ID
  export HERDR_PANE_ID='wC:p1'
  run terminal_spawn alice /proj window bash -lc boot
  [ "$status" -eq 13 ]
  grep -q 'needs HERDR_WORKSPACE_ID' <<<"$output"
  refute grep -q '\[pane\] \[split\]' "$ARGV_LOG"
}

# --- Review round 5: presence vs binary availability; errexit-safe reason read ---

@test "herdr: HERDR_ENV=1 with NO herdr binary still PLACES in herdr (presence != binary)" {
  # Restrict PATH so `herdr` is genuinely absent (this machine has a real one),
  # keeping bash/coreutils. TMUX is also set. Presence is HERDR_ENV alone, so
  # placement must pick herdr — not fall through to tmux/plain.
  export PATH="/usr/bin:/bin"
  command -v herdr >/dev/null 2>&1 && skip "herdr on the minimal PATH; cannot test absence here"
  export HERDR_ENV=1 TMUX="/tmp/s,1,0" TMUX_PANE="%4"
  run agmsg_terminal_resolve_placement "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "herdr" ]
}

@test "herdr naming: 'agent list' cannot answer -> fatal, reason 'did not answer'" {
  # herdr present (HERDR_ENV=1) but its list errors: resolve-for-name is fatal and
  # The driver's reason reaches the error (the reason reaches A). A real herdr
  # is on PATH here, so shadow it with a failing fake.
  _fake_herdr_list_fails
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "herdr naming: answered but no match -> fatal, reason 'not among live agents'" {
  _fake_herdr_list_empty
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "not among the live agents" <<<"$output"
  refute grep -q "did not answer" <<<"$output"
}

@test "herdr naming: exit-0 INVALID json -> did-not-answer, NOT 'no match' (json_valid gate)" {
  # POSITIVE PROOF the json_valid gate discriminates: a herdr that exits 0 with
  # non-JSON bytes must be "could not answer" (return 2), not silently downgraded to
  # "answered, this session is not among the agents". The two reasons are the two
  # sides named in review: garbage -> did-not-answer; empty valid array -> not-among.
  _fake_herdr_list_garbage
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "resolve_name: no set -e leak; a BARE call still reaches and PRINTS the verdict line" {
  # Review round 6: the old control wrapped the call in `|| rc=$?`, which disables set -e
  # for the ENTIRE function body — so an internal errexit leak could not be observed.
  # This is a BARE call under `set -e`: two leak-prone sites run before the verdict —
  #   (1) the loop's `id="$(_detect_one herdr ...)"` returns non-zero (HERDR_ENV unset)
  #   (2) the reason read when errf=/dev/null (mktemp forced to fail)
  # Under bash 3.2 an unguarded either would ABORT before the verdict prints, so the
  # discriminator is the LINE, not the status (a clean return 1 and a mid-body abort
  # share status). Run under /bin/bash (3.2 on macOS) where the leak actually fires.
  cat > "$FAKEBIN/mktemp" <<'M'
#!/usr/bin/env bash
exit 1
M
  chmod +x "$FAKEBIN/mktemp"; export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/s,1,0"; unset TMUX_PANE   # tmux present, no pane -> name is fatal
  unset HERDR_ENV                             # herdr tried first, detect returns non-zero
  run /bin/bash -c 'set -euo pipefail; source "'"$SKILL_DIR"'/scripts/lib/terminal-registry.sh"; agmsg_terminal_resolve_name sess-x'
  [ "$status" -eq 1 ]
  grep -q "cannot identify this pane to name it" <<<"$output"
}

@test "herdr naming: valid JSON, UNKNOWN schema ({}) -> did-not-answer, NOT 'no match'" {
  # 2026-09-01: a SUCCESSFUL json_each is not proof of a recognized list.
  # json_each on {} returns 0 rows and succeeds, which without the json_type gate
  # would misclassify an unknown schema as "answered, session not present". Only a
  # real ARRAY at a candidate path counts as answered. This is the OTHER side of the
  # empty-valid-array control; invalid-JSON alone does not cover this hole.
  _fake_herdr_list_unknown_schema           # payload {}
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "herdr naming: valid JSON, UNKNOWN wrapper ({\"unknown\":[]}) -> did-not-answer" {
  # An object whose only array lives at an UNRECOGNIZED key must not be read as an
  # agent list. None of the candidate paths ($.result.agents, $, $.agents, $.result)
  # is an array here, so no path is queried -> could not answer.
  _fake_herdr_list_unknown_schema wrap      # payload {"unknown":[]}
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "herdr naming: entry-shape drift (SCALAR agent_session) is did-not-answer, NOT not-among" {
  # 2026-09-01 (3rd instance of the shape): the answer depends on the session
  # id being COMPARED against a real entry, so schema drift is NOT a positive proof
  # of absence. A non-empty array whose entries are the OLD scalar-agent_session
  # shape has 0 expected-shape entries -> did-not-answer (return 2), not "answered,
  # not among". (The earlier version of this test asserted the misclassification.)
  _fake_herdr_list_scalar_session "sess-77"
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-77"
  [ "$status" -ne 0 ]
  refute grep -q 'wC:p4' <<<"$output"
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "herdr naming: real shape, a DIFFERENT live session -> not-among (the other side)" {
  # The both-sides control: real entry shape (well-formed agents), but this session
  # id is not among them. THIS is the only 'answered, not among' case. Paired with
  # the drift test above, it pins that only a real-shape entry set answers, and a
  # scalar/ill-formed one does not.
  _install_fake_herdr "sess-OTHER"           # a well-formed list whose only agent is someone else
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -ne 0 ]
  grep -q "not among the live agents" <<<"$output"
  refute grep -q "did not answer" <<<"$output"
}

@test "herdr naming: a BARE PANE (no agent_session) is decidable — absent target is not-among" {
  # Live-measured: the real machine has a session-less pane among the agents.
  # A bare pane definitely is not the target, so it does NOT block a not-among answer
  # (the earlier well==alen rule treated it as unreadable, making not-among
  # unreachable — every absent session wrongly returned did-not-answer).
  _fake_herdr_list_bare_pane "sess-OTHER"
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -ne 0 ]
  grep -q "not among the live agents" <<<"$output"
  refute grep -q "did not answer" <<<"$output"
}

@test "herdr naming: a BARE PANE does not block resolving a present target" {
  _fake_herdr_list_bare_pane "sess-mine"     # the agent entry IS this session; a bare pane also present
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\tw1:p4')" ]
}

@test "herdr naming: the bare-pane arm is POSITIVE by STRUCTURE — an unresolvable entry is did-not-answer" {
  # B recognizes a session-less pane by structure (2026-09-04), not by a value
  # or a key-name set — both drift while a pane lives. An entry is did-not-answer, never
  # a silent not-among, unless it is provably a bare pane: agent_session key absent, a
  # valid pane_id, the fixed identity anchor present, and NO field object/array-valued.
  # The crux is (d‴): a session hidden under a RENAMED key must not pass, in ANY shape —
  # an object OR an array. Each future_* / session_ids control hides sess-mine ITSELF,
  # so a too-broad B would return not-among for a session that is actually present.
  export HERDR_ENV=1
  local raw
  for raw in '{}' \
             '{"agent":"claude","agent_status":"running","future_session":{"value":"sess-mine"},"pane_id":"w1:p4","terminal_id":"tm1","tab_id":"t1","workspace_id":"w1"}' \
             '{"agent":"claude","agent_status":"idle","future_session":{"id":"sess-mine"},"pane_id":"w1:p4","terminal_id":"tm1","tab_id":"t1","workspace_id":"w1"}' \
             '{"agent":"claude","agent_status":"running","future_sessions":[{"id":"sess-mine"}],"pane_id":"w1:p4","terminal_id":"tm1","tab_id":"t1","workspace_id":"w1"}' \
             '{"agent":"claude","agent_status":"running","session_ids":["sess-mine"],"pane_id":"w1:p4","terminal_id":"tm1","tab_id":"t1","workspace_id":"w1"}' \
             '{"agent":"grok","agent_status":"running","pane_id":"w2:p2"}' \
             '{"agent":"grok","pane_id":"w2:p2","terminal_id":"tm1","tab_id":"t1"}' \
             '{"pane_id":"w2:p2"}' \
             '{"agent":"","pane_id":"BADFORM"}' \
             '{"agent":"grok","agent_status":"done","pane_id":"BADFORM","terminal_id":"tm1","tab_id":"t1","workspace_id":"w1"}' \
             '{"agent":"grok","agent_session":null,"pane_id":"BADFORM"}' \
             '{"agent":"claude","agent_session":"scalar","pane_id":"w2:p2"}'; do
    _fake_herdr_list_plus "$raw"
    run agmsg_terminal_resolve_name "sess-mine"
    [ "$status" -ne 0 ]              || { echo "FAIL resolved: $raw"; return 1; }
    grep -q "did not answer" <<<"$output" || { echo "FAIL not did-not-answer: $raw"; return 1; }
    refute grep -q "not among the live agents" <<<"$output" || { echo "FAIL claimed not-among: $raw"; return 1; }
  done
}

@test "herdr naming: a STRUCTURE-complete bare pane reaches not-among in every agent_status, named or with an unknown scalar" {
  # The other side of the arm: a pane that IS provably session-less (anchor present, all
  # scalar, agent_session absent) must be decidable REGARDLESS of agent_status's value,
  # so an absent target is not-among. This is what the value-pinned 'done' broke — the
  # real bare pane was 'working' and fell out (round-8 twice). Each raw below hides no
  # session; the target sess-mine is genuinely absent, so the answer is not-among.
  #   - working / idle / done: the live-changing value must NOT gate the answer.
  #   - an unknown SCALAR extension key: herdr adding a scalar field must not break it.
  #   - name + display_agent (a NAMED bare pane): DEFENSIVE — this state (name present,
  #     agent_session absent) was NOT observed as of 2026-09-04 (live measurement); display_agent
  #     was a string in one 2026-09-04 agent list. Kept so naming (this driver's own job)
  #     cannot silently make a member unresolvable.
  export HERDR_ENV=1
  local anchor='"terminal_id":"tm1","tab_id":"t1","workspace_id":"w1"'
  local raw
  for raw in '{"agent":"codex","agent_status":"working","pane_id":"w5:p3",'"$anchor"'}' \
             '{"agent":"codex","agent_status":"idle","pane_id":"w5:p3",'"$anchor"'}' \
             '{"agent":"codex","agent_status":"done","pane_id":"w5:p3",'"$anchor"'}' \
             '{"agent":"codex","agent_status":"working","new_scalar_field":"whatever","pane_id":"w5:p3",'"$anchor"'}' \
             '{"agent":"codex","agent_status":"done","name":"team__codex","display_agent":"team:codex","pane_id":"w5:p3",'"$anchor"'}'; do
    _fake_herdr_list_plus "$raw"
    run agmsg_terminal_resolve_name "sess-mine"
    [ "$status" -ne 0 ]                                     || { echo "FAIL resolved: $raw"; return 1; }
    grep -q "not among the live agents" <<<"$output"       || { echo "FAIL not not-among: $raw"; return 1; }
    refute grep -q "did not answer" <<<"$output"           || { echo "FAIL claimed did-not-answer: $raw"; return 1; }
  done
}

@test "herdr naming: target session with a MISSING/null pane_id -> did-not-answer (unaddressable)" {
  # Review round 10: pane_ok must be a definite 0/1, not a boolean that goes NULL when
  # pane_id is absent — else a target session with no pane_id falls into neither hit
  # (AND pane_ok) nor badhit (AND NOT pane_ok) and, if it is the only decidable
  # entry, reads as not-among though the target is present-but-unaddressable. Both a
  # MISSING pane_id and an explicit null must land in badhit -> did-not-answer.
  export HERDR_ENV=1
  local raw
  for raw in '{"agent":"claude","agent_session":{"value":"sess-mine"}}' \
             '{"agent":"claude","agent_session":{"value":"sess-mine"},"pane_id":null}'; do
    _fake_herdr_list_plus "$raw"
    run agmsg_terminal_resolve_name "sess-mine"
    [ "$status" -ne 0 ]                    || { echo "FAIL resolved: $raw"; return 1; }
    grep -q "did not answer" <<<"$output"  || { echo "FAIL not did-not-answer: $raw"; return 1; }
    refute grep -q "not among the live agents" <<<"$output" || { echo "FAIL claimed not-among: $raw"; return 1; }
  done
}

@test "herdr naming: MIXED array, target ABSENT -> did-not-answer (cannot rule out the malformed entry)" {
  # One layer further: >=1 well-formed entry proves some entries are readable,
  # NOT that the target is not hiding in a malformed sibling. Here alen=2 (a
  # well-formed other-session entry + a malformed one) and well=1; the searched
  # session is in neither well-formed slot. Absence is NOT provable — the target
  # could be the unread malformed entry — so this is did-not-answer, not not-among.
  _fake_herdr_list_mixed "sess-OTHER"
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "herdr naming: MIXED array, target IS the well-formed entry -> RESOLVES (find is decisive)" {
  # A positive find is decisive regardless of malformed siblings — we located the
  # pane. The malformed entry only blocks an ABSENCE claim, not a present one.
  _fake_herdr_list_mixed "sess-mine"         # the well-formed entry IS this session
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\twA:p1')" ]
}

@test "herdr naming: a pane_id containing '|' is NOT well-formed -> did-not-answer (framing-safe)" {
  # JSON text can contain the '|' this function frames on. 'w1:p|4' passes
  # the skeleton but the '|' is caught by the safety class, so it exercises that
  # guard (not just the skeleton). Its entry is not well-formed -> the sole entry is
  # ill-formed -> did-not-answer, and no truncated/garbled pane is resolved.
  _fake_herdr_list_one_pane "sess-mine" 'w1:p|4'
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "herdr naming: a pane_id containing a newline is NOT well-formed -> did-not-answer" {
  # 'w1:p\n4' passes the skeleton (w…:p…) but the newline is caught by the safety
  # class, so this exercises the '*[^…]*' guard specifically, not just the skeleton.
  _fake_herdr_list_one_pane "sess-mine" 'w1:p\n4'    # \n is a JSON string escape -> a real newline
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
}

@test "herdr naming: the MEASURED real pane-id form (w1:p4) still RESOLVES (not over-narrowed)" {
  # Assert with the measured value that narrowing did not reject the real form.
  # Real herdr 0.8.0 on this machine emits w<n>:p<x> (w1:p4, w1:pB, w5:p3).
  _fake_herdr_list_one_pane "sess-mine" 'w1:p4'
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\tw1:p4')" ]
}

@test "herdr naming: the SEARCH predicate == the well-formed predicate (no numeric pane_id find)" {
  # The search must not be weaker than the count. A malformed entry that carries
  # the target agent_session.value but a NUMERIC pane_id is NOT well-formed; the
  # search must skip it (not return pane 123), and with a well-formed sibling present
  # the set is not fully comparable -> did-not-answer. A search predicate of only
  # (agent_session object + value match) would resolve '123' here.
  _fake_herdr_list_numeric_pane "sess-mine"
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -ne 0 ]
  refute grep -q '123' <<<"$output"
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "resolve order: NESTED herdr-in-tmux — tmux (produces %0) wins over herdr (present, no id)" {
  # 2026-09-01: a nested herdr-in-tmux inherits HERDR_* into a tmux server it
  # spawned. herdr says 'present' but resolves no pane; tmux CAN produce %0. The
  # id-producer must win (record tmux:%0 — the pane really is a tmux pane), not the
  # first-present. herdr is tried first in declaration order, so this proves the
  # preference is by id-produced, not by order.
  _fake_herdr_list_empty                       # herdr present, resolves nothing
  export HERDR_ENV=1
  export TMUX="/tmp/s,1,0" TMUX_PANE="%0"      # tmux present, has a pane
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tmux\t/tmp/s:%%0')" ]
}

@test "resolve order: herdr broken AND no tmux pane -> FATAL with BOTH reasons, not silent plain" {
  # The load-bearing case: real herdr with the lookup broken, and $TMUX_PANE empty.
  # No candidate produces a nameable id. This must fail LOUDLY with EVERY present
  # candidate's reason (not one), rather than fall through to plain's '-' and succeed
  # silently. 'noisy wrong' beats 'silent wrong'.
  _fake_herdr_list_fails                        # herdr present, 'did not answer'
  export HERDR_ENV=1
  export TMUX="/tmp/s,1,0"; unset TMUX_PANE     # tmux present, no pane
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  refute grep -q $'^plain\t-' <<<"$output"      # did NOT silently resolve to plain
  grep -q "herdr:" <<<"$output"                 # BOTH reasons present, not one
  grep -q "tmux:" <<<"$output"
}

@test "resolve order: BOTH produce an id -> declaration order wins (herdr over tmux)" {
  # When more than one candidate produces a nameable id, the declaration order
  # (herdr > tmux > plain) is the tiebreak. herdr resolves its pane AND tmux has a
  # pane; herdr must win.
  _install_fake_herdr "sess-77"                 # herdr resolves wC:p4 for sess-77
  export HERDR_ENV=1
  export TMUX="/tmp/s,1,0" TMUX_PANE="%0"       # tmux also has a pane
  run agmsg_terminal_resolve_name "sess-77"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\twC:p4')" ]
}

# --- naming vs placement: join must not take a seat's record ------------------
#
# The record is what peek/poke/despawn resolve a member's pane through, so the
# pane it names has to be the one HOLDING the seat. `join` proves nothing about
# that: the same identity can be joined from a second session while a first one
# holds it through actas. The assertion is deliberately on the OLD value's
# survival, not on "nothing broke" — a version that wiped the record to empty
# would pass the weaker form.
@test "terminal_name_self: without 'record' the seat's existing placement is untouched" {
  _install_fake_tmux
  export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%1"
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"

  local rec; rec="$(agmsg_spawn_path seatteam alice)"
  mkdir -p "$(dirname "$rec")"
  printf 'tmux:%%HELD\t/proj/A\tclaude-code\n' > "$rec"
  local snapshot="$BATS_TEST_TMPDIR/placement.snapshot"
  cp "$rec" "$snapshot"

  # The second session names its own pane for the same identity, without claiming
  # the seat: the 6th argument is omitted, which is the default.
  run agmsg_terminal_name_self "" seatteam alice /proj/B claude-code
  [ "$status" -eq 0 ]

  # Positive control first: the pane WAS named, so a green result below cannot be
  # "the call did nothing".
  grep -q '\[select-pane\]' "$ARGV_LOG" || grep -q '\[set-option\]' "$ARGV_LOG"

  # `cmp`, not a captured string: command substitution strips trailing newlines,
  # so the string form cannot see a rewrite that changes only that. The sibling
  # test below had the same blind spot and was narrowed with it.
  cmp -s "$rec" "$snapshot"
  grep -q '%HELD' "$rec"
}

@test "terminal_name_self: with 'record' the placement is written" {
  _install_fake_tmux
  export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%1"
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"

  local rec; rec="$(agmsg_spawn_path seatteam bob)"
  run agmsg_terminal_name_self "" seatteam bob /proj/B claude-code record
  [ "$status" -eq 0 ]
  [ -f "$rec" ]
  grep -q 'tmux:/tmp/fake:%1' "$rec"
}

@test "terminal_name_self: a failed record re-write leaves the EXISTING correct record intact (atomic)" {
  # SessionStart / actas re-name a pane that ALREADY has a correct record. A raw
  # `>` truncates it at open, so a write that then fails (ENOSPC / permission) has
  # destroyed the authority peek/poke/despawn depend on BEFORE it can report the
  # failure. agmsg_write_atomic writes a temp beside the record and renames, so a
  # failed write leaves the old record whole — the point of routing both writers
  # through it. Here the run dir is made read-only so the temp cannot be created.
  _install_fake_tmux
  export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%1"
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"

  local rec; rec="$(agmsg_spawn_path seatteam carol)"
  mkdir -p "$(dirname "$rec")"
  printf 'tmux:%%OLD\t/proj/OLD\tclaude-code\n' > "$rec"    # a correct existing record
  chmod 500 "$(dirname "$rec")"                             # the re-write will fail

  run agmsg_terminal_name_self "" seatteam carol /proj/NEW claude-code record
  chmod 700 "$(dirname "$rec")"                             # restore for teardown
  [ "$status" -ne 0 ]                                       # the write failed and said so
  # the OLD record survives byte-for-byte — never truncated to empty or partial
  grep -q 'tmux:%OLD' "$rec"
  grep -q '/proj/OLD' "$rec"
}

# --- actas hands the terminal the identifier the TERMINAL knows ---------------
#
# The lock token and the terminal's identifier are different things. actas
# normalizes its argument into the composite "<sid>.<pid>" — a token that exists
# only inside agmsg — and that is right for the lock; herdr's agent_session.value
# is the BARE sid the CLI published. Passing the composite asks herdr a question
# it cannot answer, the answer is "cannot identify this pane", and the `|| true`
# on the naming call means the CLAIM still reports success. So a hand-started
# herdr seat claims its role and is silently unreachable to peek/poke.
#
# Driven through actas-claim.sh rather than the helper, because the defect is in
# what the caller passes. The sid goes in already composite so the normalizer's
# pid discovery cannot change what is under test.
@test "actas-claim: names the pane when the sid arrives COMPOSITE and herdr knows the bare one" {
  _install_fake_herdr "sess-bare"
  export HERDR_ENV=1
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db/messages.db"
  bash "$SKILL_DIR/scripts/join.sh" seatteam alice claude-code /proj/A >/dev/null

  run bash "$SKILL_DIR/scripts/actas-claim.sh" /proj/A claude-code alice "sess-bare.4242"
  [ "$status" -eq 0 ]
  # Positive controls, both before the claim under test can be read as a pass:
  # the claim really happened, and the fake herdr really was reached (otherwise
  # "no rename" would only mean the resolver never ran).
  printf '%s' "$output" | grep -Fq 'status=ok'
  grep -Fq 'herdr [agent] [list]' "$ARGV_LOG"

  # The pane was named for this role.
  grep -Fq 'herdr [pane] [rename] [wC:p4] [seatteam:alice]' "$ARGV_LOG"

  # ...and the placement record points peek/poke at that pane.
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"
  local rec; rec="$(agmsg_spawn_path seatteam alice)"
  [ -f "$rec" ]
  grep -Fq 'herdr:wC:p4' "$rec"
}

# --- join names a pane; it does not take the seat -----------------------------
#
# The 6th argument's default is "do not write the record", and join is the caller
# that relies on it: the same identity can be joined from a second session while a
# first one holds it through actas, and the record is what peek/poke resolve a
# member's pane through. A second pane joining an already-held identity must not
# take that placement over.
#
# Driven through join.sh, because the property is the CALLER's choice. The
# helper's default is covered above — and that test stays green when join passes
# `record`, which is measured: adding it to join.sh:260 leaves every test in this
# file and in test_actas_integration green. A safe default proves nothing about
# who takes it.
@test "join: names the pane but does NOT take the seat's placement" {
  _install_fake_tmux
  export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%1"
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db/messages.db"
  source "$SKILL_DIR/scripts/lib/actas-lock.sh"

  # A placement already held for this identity by whoever actually claimed it,
  # and a byte-for-byte snapshot of it to compare against afterwards.
  local rec; rec="$(agmsg_spawn_path seatteam alice)"
  mkdir -p "$(dirname "$rec")"
  printf 'tmux:%%HELD\t/proj/OLD\tclaude-code\n' > "$rec"
  local snapshot="$BATS_TEST_TMPDIR/placement.snapshot"
  cp "$rec" "$snapshot"

  run bash "$SKILL_DIR/scripts/join.sh" seatteam alice claude-code /proj/A
  [ "$status" -eq 0 ]

  # Positive control FIRST: join reached the naming step and the pane really was
  # named. Without it a join that skipped naming altogether also leaves the record
  # alone, and this test would read that as the property holding.
  grep -q '\[select-pane\]' "$ARGV_LOG" || grep -q '\[set-option\]' "$ARGV_LOG"

  # The seat's placement is not join's to take. `cmp`, not `[ "$(cat …)" = … ]`:
  # command substitution strips every trailing newline, so the string form is
  # blind to a rewrite that changes only that — measured, both ways, before this
  # line was written. Compared against the whole file, not against "a record
  # exists": a version that emptied it would pass the weaker form.
  cmp -s "$rec" "$snapshot"
  # What that file still says, spelled out for the next reader.
  grep -q '%HELD' "$rec"
  grep -q '/proj/OLD' "$rec"
}

# --- AGMSG_TERMINAL_NAMING=off drops the label and keeps the key (#1044) ------
#
# Two names, and only one of them is optional. The key is the name the TERMINAL
# addresses the agent by in its own namespace; the label is what a person reads.
# (peek/poke/despawn in this repo resolve through the placement record's pane id
# — an earlier version of this comment said the key, and that is false here.) A
# caller that wants no terminal writes at all is describing `plain`.
#
# Both drivers are exercised because the split is not the same shape in each:
# herdr has two commands (`pane rename` / `agent rename`), tmux has a pane option
# and a title. "Same idea, so same result" is not a measurement.
@test "naming off (tmux): the pane option is set and the title is not (#1044)" {
  _install_fake_tmux
  export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%1"
  export AGMSG_TERMINAL_NAMING=off

  run agmsg_terminal_name_self "" offteam alice /proj/A claude-code
  [ "$status" -eq 0 ]

  # The key: still set, because it is addressing.
  # The op and its arguments. The line now leads with `[-S] [<socket>]` — every
  # call is aimed at the server that owns the pane (#1051) — so anchoring on
  # `tmux [set-option]` would be asserting the absence of that fix.
  grep -Fq '[set-option] [-p] [-t] [%1] [@agmsg_agent] [offteam:alice]' "$ARGV_LOG"
  # And the aim itself, which is the new behaviour worth pinning.
  grep -Fq '[-S] [/tmp/fake]' "$ARGV_LOG"
  # The decoration: not set.
  refute grep -Fq 'select-pane' "$ARGV_LOG"
  refute grep -Fq 'rename-window' "$ARGV_LOG"
}

@test "naming ON by default (tmux): both the option and the title (#1044)" {
  _install_fake_tmux
  export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/fake,1,0" TMUX_PANE="%1"
  unset AGMSG_TERMINAL_NAMING

  run agmsg_terminal_name_self "" onteam alice /proj/A claude-code
  [ "$status" -eq 0 ]
  grep -Fq '[@agmsg_agent] [onteam:alice]' "$ARGV_LOG"
  grep -Fq 'select-pane' "$ARGV_LOG"
}

@test "naming off (herdr): agent rename happens, pane rename does not (#1044)" {
  _install_fake_herdr "sess-off"
  export HERDR_ENV=1
  export AGMSG_TERMINAL_NAMING=off

  run agmsg_terminal_name_self "sess-off" offteam alice /proj/A claude-code
  [ "$status" -eq 0 ]

  # The key: still set.
  grep -Fq 'herdr [agent] [rename]' "$ARGV_LOG"
  # The visible label: not set.
  refute grep -Fq 'herdr [pane] [rename]' "$ARGV_LOG"
}

@test "naming ON by default (herdr): both renames (#1044)" {
  _install_fake_herdr "sess-on"
  export HERDR_ENV=1
  unset AGMSG_TERMINAL_NAMING

  run agmsg_terminal_name_self "sess-on" onteam alice /proj/A claude-code
  [ "$status" -eq 0 ]
  grep -Fq 'herdr [pane] [rename] [wC:p4] [onteam:alice]' "$ARGV_LOG"
  grep -Fq 'herdr [agent] [rename]' "$ARGV_LOG"
}

# --- a failed KEY is a failure, in the mode everybody uses (#1044) ------------
#
# The severities were backwards: the label's failure was fatal and the key's was
# swallowed with `|| true`, so "a member's name is never absent" held strictly in
# the reduced mode and not in the default one. Measured by a reviewer, not
# reasoned about: with the key rename failing, default mode returned rc=0 and
# printed `ok`.
#
# Both modes are asserted, because "it goes red under `off`" is not evidence
# about the default — that split is exactly what hid this.
@test "a failed key rename fails the naming, in DEFAULT mode (#1044)" {
  _install_fake_herdr "sess-k"
  export HERDR_ENV=1
  export HERDR_AGENT_RENAME_RC=1
  unset AGMSG_TERMINAL_NAMING

  run agmsg_terminal_name_self "sess-k" keyteam alice /proj/A claude-code
  [ "$status" -ne 0 ]

  # It really did get as far as trying, rather than failing earlier for some
  # other reason. The evidence used to be "the label was set first" — that was an
  # artefact of the old order, and the key now goes first precisely so a failed
  # label cannot take addressing down with it.
  grep -Fq 'herdr [agent] [rename]' "$ARGV_LOG"
}

@test "a failed key rename fails the naming, in KEY-ONLY mode too (#1044)" {
  _install_fake_herdr "sess-k"
  export HERDR_ENV=1
  export HERDR_AGENT_RENAME_RC=1
  export AGMSG_TERMINAL_NAMING=off

  run agmsg_terminal_name_self "sess-k" keyteam alice /proj/A claude-code
  [ "$status" -ne 0 ]
  grep -Fq 'herdr [agent] [rename]' "$ARGV_LOG"
}

# And the paired positive: the same setup with the rename succeeding must pass,
# or the two tests above are satisfied by naming being broken outright.
@test "the same setup with the key rename succeeding is green (#1044)" {
  _install_fake_herdr "sess-k"
  export HERDR_ENV=1
  export HERDR_AGENT_RENAME_RC=0
  unset AGMSG_TERMINAL_NAMING

  run agmsg_terminal_name_self "sess-k" keyteam alice /proj/A claude-code
  [ "$status" -eq 0 ]
}

# --- the label is decoration: its failure must not cost the addressing (#1044) -
#
# Reported by a reviewer against the previous revision: with the label renamed
# first and its failure fatal, a failed decoration returned 13 before the key was
# ever attempted. The requirement — a member's pane is never without a name —
# broke through a second door, and the fix for the first door (the key's failure
# no longer swallowed) did not touch it.
@test "a failed LABEL rename still leaves the member addressable (#1044)" {
  _install_fake_herdr "sess-l"
  export HERDR_ENV=1
  export HERDR_PANE_RENAME_RC=1     # the decoration fails
  export HERDR_AGENT_RENAME_RC=0    # the key would succeed, if it is reached
  unset AGMSG_TERMINAL_NAMING

  run agmsg_terminal_name_self "sess-l" labelteam alice /proj/A claude-code
  # Not fatal: the caller writes the placement record only on 0, and that record
  # is the other half of addressing — so failing here would throw away exactly
  # what this test is about.
  [ "$status" -eq 0 ]

  # The key was set. This is the assertion the previous revision could not pass.
  grep -Fq 'herdr [agent] [rename]' "$ARGV_LOG"
  # ...and the label really was attempted and really did fail, or the line above
  # proves nothing about this scenario.
  grep -Fq 'herdr [pane] [rename]' "$ARGV_LOG"
}

# --- a key that cannot be DERIVED is a failure, not an ok (#1044) -------------
#
# The commit that made the key fatal claimed this branch in a comment and left it
# unguarded: a reviewer's mutation that returned ok for an underivable key failed
# no test. A comment is not a check.
#
# `_herdr_internal_key` can fail three ways — the lib directory not resolving,
# `hash.sh` missing, and the hash itself failing. This drives the third: a
# `agmsg_sha256` that is present and returns non-zero. The other two are the same
# `return 1` one line apart and are not separately exercised.
@test "a key that cannot be derived fails the naming (#1044)" {
  _install_fake_herdr "sess-h"
  export HERDR_ENV=1
  unset AGMSG_TERMINAL_NAMING

  # Present, so the `command -v` guard passes, and failing, so the hash does not.
  agmsg_sha256() { return 1; }
  export -f agmsg_sha256 2>/dev/null || true

  run agmsg_terminal_name_self "sess-h" hashteam alice /proj/A claude-code
  [ "$status" -ne 0 ]

  # Nothing was renamed: no key could be built, so the member is not addressable
  # and saying `ok` would have claimed that it was.
  refute grep -Fq 'herdr [agent] [rename]' "$ARGV_LOG"
}

# --- a driver that is missing a required op does not load (#1051) -------------
#
# The registry has always refused a driver missing an ABI function; what it did
# not have is anything that NOTICES when the required set grows. #1051 adds
# `terminal_pane_state`, and the failure mode named when it was approved is
# "someone adds an op and forgets to add it to `_AGMSG_TERMINAL_REQUIRED`" — a
# hole that leaves the op optional in practice while the contract says otherwise.
#
# So this asserts the coupling in both directions:
#   a driver missing the NEW op is refused  — the required set really includes it
#   the refusal names the missing function  — an operator can act on it
#   the shipped drivers all satisfy it      — the requirement is not vacuous
@test "a driver missing terminal_pane_state is refused, by name (#1051)" {
  local d="$TEST_SKILL_DIR/scripts/drivers/terminals/stubby"
  mkdir -p "$d"
  printf 'name=stubby\ncapabilities=\n' > "$d/terminal.conf"
  # DERIVE the set from the registry, minus the one op under test. An enumerated
  # list here silently falls behind the moment another op joins the required set:
  # the stub is then missing two ops, the loader names whichever it finds first,
  # and the positive control below cannot load at all. (Measured — terminal_where
  # and terminal_arrange landed on the base and did exactly that.)
  local fn
  : > "$d/ops.sh"
  for fn in $_AGMSG_TERMINAL_REQUIRED; do
    [ "$fn" = terminal_pane_state ] && continue
    printf '%s() { return 0; }\n' "$fn" >> "$d/ops.sh"
  done
  # The derivation is only meaningful if it actually left the op out, and only
  # honest if it wrote the others.
  refute grep -q 'terminal_pane_state' "$d/ops.sh"
  [ "$(grep -c '() { return 0; }' "$d/ops.sh")" -ge 8 ]

  run agmsg_terminal_load stubby
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -Fq 'terminal_pane_state'

  # Positive control: the same driver WITH the op loads. Without it, this test
  # also passes when `agmsg_terminal_load` is broken for every input.
  printf 'terminal_pane_state() { echo unknown; return 13; }\n' >> "$d/ops.sh"
  run agmsg_terminal_load stubby
  [ "$status" -eq 0 ]
}

@test "every shipped driver implements the required set (#1051)" {
  local drv
  for drv in tmux herdr plain; do
    run agmsg_terminal_load "$drv"
    [ "$status" -eq 0 ] || { echo "driver $drv failed to load: $output"; return 1; }
  done
}

# --- terminal_pane_state: the three answers, and what earns each one (#1051) --
#
# `terminal_despawn` cannot answer "is that pane still there?": measured on a
# throwaway server, `kill-pane` returns non-zero both for a pane already gone and
# for one it could not close, and the driver maps both to 13. So a graceful
# teardown that WORKED would have had to report needs-force.
#
# The answers are not symmetric in cost. `present` and `unknown` keep the
# placement record; `gone` DELETES it, and that is the only irreversible one — so
# `gone` has to be earned, and every uncertainty resolves to `unknown`.
_fake_tmux_server() {   # <mode: alive|empty|noserver|broken>
  local mode="$1"
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
# Skip the server selector the driver puts first, the way real tmux does.
if [ "\$1" = -S ]; then shift 2; fi
case "$mode" in
  alive)    [ "\$1" = list-panes ] && echo '%1'; exit 0 ;;
  empty)    [ "\$1" = list-panes ] && exit 0; exit 0 ;;
  noserver) echo "no server running on /tmp/fake-sock" >&2; exit 1 ;;
  broken)   echo "some other tmux failure" >&2; exit 1 ;;
esac
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

@test "pane_state: the pane is in its server's list -> present (#1051)" {
  _fake_tmux_server alive
  agmsg_terminal_load tmux
  run terminal_pane_state "/tmp/fake-sock:%1"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
  # Asked the server the ref names, not whichever one was reachable.
  grep -Fq '[-S] [/tmp/fake-sock]' "$ARGV_LOG"
}

@test "pane_state: the server answers and the pane is not in it -> gone (#1051)" {
  _fake_tmux_server empty
  agmsg_terminal_load tmux
  run terminal_pane_state "/tmp/fake-sock:%1"
  [ "$status" -eq 0 ]
  [ "$output" = gone ]
}

@test "pane_state: the server is no longer running -> gone (#1051)" {
  # The ordinary case for a member that had its own window: closing the last pane
  # ends the server. Measured — without this the answer was `unknown` exactly
  # when the teardown had worked. The discriminator is tmux SAYING so; the socket
  # file survives the server's exit and proves nothing.
  _fake_tmux_server noserver
  agmsg_terminal_load tmux
  run terminal_pane_state "/tmp/fake-sock:%1"
  [ "$status" -eq 0 ]
  [ "$output" = gone ]
}

@test "pane_state: any OTHER failure is unknown, not gone (#1051)" {
  _fake_tmux_server broken
  agmsg_terminal_load tmux
  run terminal_pane_state "/tmp/fake-sock:%1"
  [ "$status" -eq 10 ]
  [ "$output" = unknown ]
}

@test "pane_state: an id with no socket cannot name an authority -> unknown (#1051)" {
  # A record written before refs carried the server. Two servers can both hold
  # `%1`, so there is no one to ask — and answering `gone` here is what deletes a
  # live member's record.
  _fake_tmux_server alive
  agmsg_terminal_load tmux
  run terminal_pane_state "%1"
  [ "$status" -eq 10 ]
  [ "$output" = unknown ]
}

@test "pane_state: plain says it cannot be asked, and that is not 'gone' (#1051)" {
  agmsg_terminal_load plain
  run terminal_pane_state "-"
  [ "$status" -eq 13 ]
  [ "$output" = unknown ]
}

# --- herdr pane_state: `gone` is a claim about the WHOLE list (#1051) ---------
#
# The first version asked only "is the container an array?" and then read "no
# entry matched" as absence. An array whose entries were never inspected proves
# nothing: a target sitting in an entry this driver cannot read came back as
# `gone`, and `gone` is the answer that deletes the record. Aligned with
# `_herdr_pane_for_session`, which only says not-among when EVERY entry is
# decidable.
#
# A herdr `agent list` carrying the two MEASURED decidable entries plus one raw
# caller-supplied entry, so a test can add exactly one undecidable entry and
# nothing else. The two fixed entries both carry a grammatical pane_id and the
# identity anchor (agent/terminal_id/tab_id/workspace_id), so on their own the
# list is fully decidable.
_fake_herdr_list_anchored_plus() {
  local raw="$1"
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '"'"'{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"sess-OTHER"},"pane_id":"w1:p4","terminal_id":"tm0","tab_id":"t0","workspace_id":"w0"},{"agent":"codex","agent_status":"working","tab_id":"t1","terminal_id":"tm1","workspace_id":"w1","pane_id":"w5:p3"}%s]}}'"'"'; exit 0; }\nexit 0\n' "$raw" > "$FAKEBIN/herdr"
  chmod +x "$FAKEBIN/herdr"; export PATH="$FAKEBIN:$PATH"
}

# --- every id-taking tmux op honours BOTH ref forms (#1051, co2/tl) ----------
#
# Putting the socket in the ref made the WRITERS emit `<socket>:%N`; the READERS
# were not counted at the same time, and four of them pattern-matched a bare
# `%`/`@` and called an ambient `tmux`. Those are TWO defects per site, not one:
# a ref stripped but not routed reaches whatever server is ambient, where the
# same pane id is a DIFFERENT pane — which is where #1051 started.
#
# The op list is DERIVED, not typed: the ABI minus the ops that take no pane id.
# A new id-taking op therefore fails this test until it is covered, instead of
# quietly inheriting the old assumption (the fixture-enumeration mistake, again).
_TMUX_NO_ID_OPS="terminal_check terminal_describe terminal_detect terminal_spawn"

# op -> the argument list to call it with, using SOCKID/BAREID as the id slot.
_tmux_op_args() {
  case "$1" in
    terminal_arrange) printf '%s place_below %s' "$2" "$2" ;;
    terminal_poke)    printf '%s hello' "$2" ;;
    terminal_name)    printf '%s k label' "$2" ;;
    terminal_team_input_ready) printf '%s claude' "$2" ;;
    *)                printf '%s' "$2" ;;
  esac
}

@test "every id-taking tmux op derives from the ABI and is covered here (#1051)" {
  # The guard for the table above: if the ABI grows an id-taking op, this fails
  # until _tmux_op_args and the two tests below have seen it. Without this the
  # coverage claim is only as current as the day it was typed.
  local op uncovered=""
  for op in $_AGMSG_TERMINAL_REQUIRED $_AGMSG_TERMINAL_OPTIONAL; do
    case " $_TMUX_NO_ID_OPS " in *" $op "*) continue ;; esac
    grep -q "^${op}() {" scripts/drivers/terminals/tmux/ops.sh || uncovered="$uncovered $op(missing)"
  done
  [ -z "$uncovered" ] || { echo "not implemented by the tmux driver:$uncovered"; return 1; }
  # And the exclusion list is not a place to hide an op: every name in it must be
  # a real ABI op, or a typo silently drops a reader from the sweep.
  for op in $_TMUX_NO_ID_OPS; do
    case " $_AGMSG_TERMINAL_REQUIRED $_AGMSG_TERMINAL_OPTIONAL " in
      *" $op "*) : ;;
      *) echo "exclusion names a non-op: $op"; return 1 ;;
    esac
  done
}

@test "a socket-qualified ref reaches the OWNING server, with a bare -t (#1051)" {
  _fake_tmux_server alive
  agmsg_terminal_load tmux
  local op args n=0 want=0
  for op in $_AGMSG_TERMINAL_REQUIRED $_AGMSG_TERMINAL_OPTIONAL; do
    case " $_TMUX_NO_ID_OPS " in *" $op "*) continue ;; esac
    want=$((want + 1))
    : > "$ARGV_LOG"
    # shellcheck disable=SC2046
    run $op $(_tmux_op_args "$op" '/tmp/fake-sock:%1')
    # Not asserting success: some ops legitimately answer unsupported/unknown
    # against a stub. What must hold is HOW they asked.
    if [ -s "$ARGV_LOG" ]; then
      n=$((n + 1))
      grep -Fq '[-S] [/tmp/fake-sock]' "$ARGV_LOG" \
        || { echo "$op: did not select the owning server"; cat "$ARGV_LOG"; return 1; }
      refute grep -Fq '[/tmp/fake-sock:%1]' "$ARGV_LOG" \
        || { echo "$op: passed the socket-qualified id through as a target"; cat "$ARGV_LOG"; return 1; }
    fi
  done
  # Positive control. Every assertion above is inside `if [ -s ... ]`, so an op
  # that stops invoking tmux is checked by nothing and the sweep shrinks in
  # silence — "0 findings" and "never ran" would look identical. Measured: all
  # of them invoke tmux today, so anything less is a real change to explain.
  [ "$n" -eq "$want" ] || { echo "only $n of $want id-taking ops reached tmux"; return 1; }
}

@test "a LEGACY bare ref still works and selects no server (#1051)" {
  # Without this half, making every op REQUIRE a socket would pass the test
  # above. Legacy bare refs are real input: agmsg_terminal_ref_terminal accepts
  # a schemeless bare tmux id on purpose, and records written before the socket
  # axis carry exactly that.
  _fake_tmux_server alive
  agmsg_terminal_load tmux
  local op silent=""
  for op in $_AGMSG_TERMINAL_REQUIRED $_AGMSG_TERMINAL_OPTIONAL; do
    case " $_TMUX_NO_ID_OPS " in *" $op "*) continue ;; esac
    : > "$ARGV_LOG"
    # shellcheck disable=SC2046
    run $op $(_tmux_op_args "$op" '%1')
    if [ -s "$ARGV_LOG" ]; then
      refute grep -Fq '[-S]' "$ARGV_LOG" \
        || { echo "$op: selected a server for a ref that names none"; cat "$ARGV_LOG"; return 1; }
      continue
    fi
    silent="$silent $op"
    # An op that invoked nothing asserted nothing, so name why it is allowed to.
    # `pane_state` is the ONE deliberate abstainer: a bare id names no server, so
    # there is nobody to ask, and `gone` here would delete a live member's
    # record. It must say so — unknown/10 — rather than merely doing nothing.
    [ "$op" = terminal_pane_state ] \
      || { echo "$op invoked no tmux for a legacy bare ref (silently refused?)"; return 1; }
    [ "$status" -eq 10 ] && [ "$output" = unknown ] \
      || { echo "pane_state abstained without saying unknown/10: status=$status out=$output"; return 1; }
  done
  # The abstainer list is pinned, not counted: a second op going quiet would keep
  # any >=N count green while its half of the sweep asserted nothing, and
  # "everything now requires a socket" would read as a pass.
  [ "$silent" = " terminal_pane_state" ] \
    || { echo "unexpected set of ops invoking nothing:$silent"; return 1; }
}

@test "pane_state (herdr): the pane is in the list -> present (#1051)" {
  _fake_herdr_list_anchored_plus ""
  agmsg_terminal_load herdr
  run terminal_pane_state "w5:p3"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
}

@test "pane_state (herdr): every entry decidable and no match -> gone (#1051)" {
  # The positive control for the one below: with the SAME two entries and nothing
  # added, an absent pane is honestly gone. Without this, the `unknown` test
  # cannot tell "the extra entry made it undecidable" from "this driver can never
  # say gone".
  _fake_herdr_list_anchored_plus ""
  agmsg_terminal_load herdr
  run terminal_pane_state "w9:p9"
  [ "$status" -eq 0 ]
  [ "$output" = gone ]
}

@test "pane_state (herdr): ONE undecidable entry and no match -> unknown, not gone (#1051)" {
  # Differs from the control above by exactly one array element: an object with a
  # grammatical pane_id but no identity anchor, so this driver cannot say it is a
  # herdr pane at all. The target could be that entry under a shape we do not
  # read, so absence is not established — and `gone` here would delete a live
  # member's record.
  _fake_herdr_list_anchored_plus ',{"pane_id":"w2:p2"}'
  agmsg_terminal_load herdr
  run terminal_pane_state "w9:p9"
  [ "$status" -eq 10 ]
  [ "$output" = unknown ]
}

@test "pane_state (herdr): an undecidable entry does not hide a MATCH (#1051)" {
  # `hit` is deliberately looser than the decidability test: an exact pane_id
  # match is evidence the pane exists whatever else the list looks like, and
  # `present` keeps the record. Being permissive toward the cheap answer is not
  # the same mistake as being permissive toward the destructive one.
  _fake_herdr_list_anchored_plus ',{"pane_id":"w2:p2"}'
  agmsg_terminal_load herdr
  run terminal_pane_state "w2:p2"
  [ "$status" -eq 0 ]
  [ "$output" = present ]
}

# --- a socket path may contain a space (#1051) --------------------------------
#
# The record is one TAB-separated line, so what breaks it is a TAB or a newline.
# An ordinary space does not, and a socket under a home directory with a space in
# it is perfectly normal — refusing 0x20 would reject a legitimate ref.
@test "ref grammar: a tmux socket path containing a SPACE is accepted (#1051)" {
  [ "$(agmsg_terminal_ref_terminal 'tmux:/Users/A B/tmp/s:%3')" = 'tmux' ]
  [ "$(agmsg_terminal_ref_id 'tmux:/Users/A B/tmp/s:%3')" = '/Users/A B/tmp/s:%3' ]
}

@test "ref grammar: a tmux socket path containing a TAB or newline is refused (#1051)" {
  # These are the bytes that actually corrupt the record's framing — it is one
  # TAB-separated line — and they are the only ones that need refusing.
  local bad
  for bad in "$(printf 'tmux:/tmp/a\tb:%%3')" "$(printf 'tmux:/tmp/a\nb:%%3')"; do
    run agmsg_terminal_ref_terminal "$bad"
    [ "$status" -ne 0 ] || { echo "FAIL: control byte accepted in '$bad'"; return 1; }
    [ -z "$output" ]    || { echo "FAIL: printed '$output'"; return 1; }
  done
}
