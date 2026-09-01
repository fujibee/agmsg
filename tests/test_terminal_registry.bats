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
  printf '[{"agent_session":"%s","pane_id":"wC:p4"}]\n' "$sid"
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
# A herdr whose `agent list` answers with a valid EMPTY array (no live agents).
_fake_herdr_list_empty() {
  printf '#!/usr/bin/env bash\n[ "$1" = agent ] && [ "$2" = list ] && { echo "[]"; exit 0; }\nexit 0\n' > "$FAKEBIN/herdr"
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

@test "herdr: despawn closes the pane; peek reads visible; name encodes team__name" {
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
  grep -q '\[pane\] \[rename\] \[wC:p9\] \[teamx:alice\]' "$ARGV_LOG"
  grep -q '\[agent\] \[rename\] \[wC:p9\] \[teamx-alice\]' "$ARGV_LOG"
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

@test "resolve_name: an mktemp failure does not leak set -e; the caller still reaches the non-zero verdict" {
  # Force mktemp to fail by shadowing it with a stub that exits non-zero, and run
  # under `set -e`. The reason read must not exit the shell before the verdict.
  cat > "$FAKEBIN/mktemp" <<'M'
#!/usr/bin/env bash
exit 1
M
  chmod +x "$FAKEBIN/mktemp"; export PATH="$FAKEBIN:$PATH"
  export TMUX="/tmp/s,1,0"; unset TMUX_PANE   # tmux present, no pane -> name is fatal
  run bash -c 'set -euo pipefail; source "'"$SKILL_DIR"'/scripts/lib/terminal-registry.sh"; rc=0; agmsg_terminal_resolve_name sess-x >/dev/null 2>&1 || rc=$?; echo "verdict=$rc"'
  [ "$status" -eq 0 ]
  grep -q 'verdict=1' <<<"$output"
}
