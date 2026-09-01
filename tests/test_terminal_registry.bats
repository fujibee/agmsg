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

# A fake `tmux` that logs argv and produces the ids/text real tmux would.
_install_fake_tmux() {
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
case "\$1" in
  new-window)   echo '@7' ;;
  split-window) echo '%9' ;;
  capture-pane) printf 'line one\nline two\n' ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

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
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo '\''{"id":"1","result":{"type":"list","agents":[{"agent":"claude","agent_session":{"agent":"claude","kind":"id","source":"herdr:claude","value":"%s"},"pane_id":"w1:p4"},{"agent":"","pane_id":"w5:p3"}]}}'\''; exit 0; }\nexit 0\n' "$sid" > "$FAKEBIN/herdr"
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

@test "resolve: picks tmux from \$TMUX and returns \$TMUX_PANE as the self id" {
  _install_fake_tmux
  export TMUX="/tmp/sock,1,0" TMUX_PANE="%4"
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tmux\t%%4')" ]
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

# --- conf reader ------------------------------------------------------------

@test "conf: get reads a key, has tests membership, absent key returns default" {
  [ "$(agmsg_terminal_get tmux capabilities)" = "spawn despawn peek poke name" ]
  agmsg_terminal_has tmux capabilities peek
  refute agmsg_terminal_has tmux capabilities nonesuch
  [ "$(agmsg_terminal_get plain capabilities)" = "spawn despawn" ]
  [ "$(agmsg_terminal_get plain nonesuch DEFLT)" = "DEFLT" ]
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
  run terminal_spawn alice /proj pane-v bash -lc boot
  [ "$status" -eq 0 ]
  [ "$output" = "%9" ]
  grep -q 'split-window' "$ARGV_LOG"
  grep -q '\[-v\]' "$ARGV_LOG"
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

# Pull the internal key (4th bracket of the `agent rename` line) from the argv log.
_last_agent_rename_key() {
  sed -n 's/.*\[agent\] \[rename\] \[[^]]*\] \[\([^]]*\)\].*/\1/p' "$ARGV_LOG" | tail -1
}

@test "herdr naming: the internal key avoids the known fold/join collisions ('-' and ':')" {
  # tl/cc1/co1 2026-09-01: the old fold (':' and non-regex chars -> '-') and ANY
  # literal separator have a STRUCTURAL (deterministic, reachable) collision, because
  # the separator is legal inside a name. cc1's example:
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

# --- ABI completeness + structural clobber-proofing (co1 #1014 review) -------

@test "abi: every driver defines every required terminal_* function" {
  # The declaration/implementation match co1 flagged: an ops.sh missing a verb
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

# --- fail-closed resolution (co1 #1014 review) ------------------------------

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
  # non-zero — better than naming nothing (co1's fail-closed lives on this side).
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

# --- load failure cleanup: source failure, like missing-function, leaves nothing (co1 rd2) ---

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

# --- herdr spawn target validation (co1 rd2) --------------------------------

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

# --- co1 round-5: presence vs binary availability; errexit-safe reason read ---

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
  # the driver's reason reaches the error (co1: the reason reaches A). A real herdr
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
  # sides co1 named: garbage -> did-not-answer; empty valid array -> not-among.
  _fake_herdr_list_garbage
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -ne 0 ]
  grep -q "did not answer" <<<"$output"
  refute grep -q "not among the live agents" <<<"$output"
}

@test "resolve_name: no set -e leak; a BARE call still reaches and PRINTS the verdict line" {
  # co1 round-6: the old control wrapped the call in `|| rc=$?`, which disables set -e
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
  # co1/tl 2026-09-01: a SUCCESSFUL json_each is not proof of a recognized list.
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
  # co1/tl 2026-09-01 (3rd instance of the shape): the answer depends on the session
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
  # utildev live-measured: the real machine has a session-less pane among the agents.
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

@test "herdr naming: MIXED array, target ABSENT -> did-not-answer (cannot rule out the malformed entry)" {
  # co1/tl one layer further: >=1 well-formed entry proves some entries are readable,
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
  # co1/tl: json text can contain the '|' this function frames on. 'w1:p|4' passes
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
  # tl: assert with the measured value that narrowing did not reject the real form.
  # Real herdr 0.8.0 on this machine emits w<n>:p<x> (w1:p4, w1:pB, w5:p3).
  _fake_herdr_list_one_pane "sess-mine" 'w1:p4'
  export HERDR_ENV=1
  run agmsg_terminal_resolve_name "sess-mine"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'herdr\tw1:p4')" ]
}

@test "herdr naming: the SEARCH predicate == the well-formed predicate (no numeric pane_id find)" {
  # co1: the search must not be weaker than the count. A malformed entry that carries
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
  # tl 2026-09-01: a nested herdr-in-tmux inherits HERDR_* into a tmux server it
  # spawned. herdr says 'present' but resolves no pane; tmux CAN produce %0. The
  # id-producer must win (record tmux:%0 — the pane really is a tmux pane), not the
  # first-present. herdr is tried first in declaration order, so this proves the
  # preference is by id-produced, not by order.
  _fake_herdr_list_empty                       # herdr present, resolves nothing
  export HERDR_ENV=1
  export TMUX="/tmp/s,1,0" TMUX_PANE="%0"      # tmux present, has a pane
  run agmsg_terminal_resolve_name "sess-x"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'tmux\t%%0')" ]
}

@test "resolve order: herdr broken AND no tmux pane -> FATAL with BOTH reasons, not silent plain" {
  # tl's load-bearing case: real herdr with the lookup broken, and $TMUX_PANE empty.
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
  local before; before="$(cat "$rec")"

  # The second session names its own pane for the same identity, without claiming
  # the seat: the 6th argument is omitted, which is the default.
  run agmsg_terminal_name_self "" seatteam alice /proj/B claude-code
  [ "$status" -eq 0 ]

  # Positive control first: the pane WAS named, so a green result below cannot be
  # "the call did nothing".
  grep -q 'tmux \[select-pane\]' "$ARGV_LOG" || grep -q 'tmux \[set-option\]' "$ARGV_LOG"

  local after; after="$(cat "$rec")"
  [ "$after" = "$before" ]
  printf '%s' "$after" | grep -q '%HELD'
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
  grep -q 'tmux:%1' "$rec"
}
