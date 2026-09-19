# Shared setup/teardown for agmsg BATS tests.
# Each test gets an isolated skill directory with its own DB and teams.

# #1095: a test that exercises join.sh/actas-claim.sh/spawn.sh/watch.sh/
# session-start.sh/check-inbox.sh (or the two libraries under them) is, as far
# as the self-naming primitive can tell, a seat acting -- so it names the pane
# it is running in, with its own fixture team/agent. On a real machine that is
# the developer's own terminal, inherited because bats runs inside it. This is
# TOP-LEVEL, not inside setup_test_env(): `load test_helper` runs it before
# ANY test's own setup(), so it reaches every file that loads this one,
# including one (test_install.bats) whose own setup() never calls
# setup_test_env. A file that deliberately exercises the switch itself
# (test_self_name.bats, test_self_rename.bats) unsets this right after
# loading -- that is a local, visible override, not a gap in this default.
# Hard safety boundary: a test that opts back into self-naming must first install
# a fake terminal. Clear every ambient terminal marker while this helper loads,
# before any suite-level setup or test body can unset AGMSG_SELF_NAME. Tests that
# deliberately model a real terminal restore these variables explicitly, using
# a fake driver or a documented fixture socket.
unset TMUX TMUX_PANE TMUX_TMPDIR
unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SESSION HERDR_BIN_PATH HERDR_STARTUP_CWD
# #1229: the claude-code transcript-path resolver (agmsg_transcript_path)
# prefers CLAUDE_CONFIG_DIR over $HOME/.claude when set -- a developer or
# agent running under a multi-account profile carries this in their real
# shell, and every fixture in this suite that creates a transcript under the
# sandboxed HOME assumes that IS the resolved root. Left ambient, those tests
# would silently resolve against the real profile dir instead of the fixture.
unset CLAUDE_CONFIG_DIR
# #1229: poke.sh's plain-no-pane fallback resolves ITS OWN caller identity
# from AGMSG_SESSION_ID/CLAUDE_CODE_SESSION_ID/CODEX_THREAD_ID (the same
# chain fix.sh uses). Left ambient, a suite run from inside a real
# claude-code session (this repo's own dev loop very much included) would
# make that resolution succeed using the DEVELOPER's real session id instead
# of whatever the fixture set up, silently changing which branch a test
# exercises. Tests that deliberately model a caller set these explicitly.
unset AGMSG_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
export AGMSG_SELF_NAME=off

setup_test_env() {
  # A test never inherits the developer's terminal. The terminal drivers
  # identify "this pane" from the environment (tmux: $TMUX/$TMUX_PANE; herdr:
  # HERDR_PANE_ID, measured 2026-09-08), and join/send/inbox/history name the
  # caller's pane through it -- so a suite run from inside a real tmux or herdr
  # pane would otherwise write the fixture's team:agent onto the developer's
  # own pane. Tests that want a terminal set these AFTER this call, against a
  # fake on PATH. CI runners carry none of these, so nothing changes there.
  unset TMUX TMUX_PANE TMUX_TMPDIR
  unset HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SESSION HERDR_BIN_PATH HERDR_STARTUP_CWD
  unset CLAUDE_CONFIG_DIR
  unset AGMSG_SESSION_ID CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
  export TEST_SKILL_DIR="$(mktemp -d)"
  mkdir -p "$TEST_SKILL_DIR"/{scripts,db,teams}

  # Copy all scripts to isolated skill dir. Recursive so nested helper dirs
  # (scripts/lib/) come along without enumerating files.
  cp -R "$BATS_TEST_DIRNAME"/../scripts/. "$TEST_SKILL_DIR/scripts/"
  chmod +x "$TEST_SKILL_DIR/scripts/"*.sh
  chmod +x "$TEST_SKILL_DIR/scripts/"*.js 2>/dev/null || true

  # Agent-type manifests + per-type runtimes now live under scripts/drivers/types/
  # (the type registry reads <skill-root>/scripts/drivers/types/<name>/type.conf),
  # so the recursive scripts/ copy above already brings them along — no separate
  # copy is needed. Just ensure codex's folded runtime scripts stay executable.
  chmod +x "$TEST_SKILL_DIR/scripts/drivers/types/codex/"*.sh 2>/dev/null || true

  # Initialize DB
  bash "$TEST_SKILL_DIR/scripts/internal/init-db.sh"

  # Convenience vars
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  export TYPES="$TEST_SKILL_DIR/scripts/drivers/types"

  # Sandbox HOME so NO test can touch the developer's real home. Several paths
  # write under $HOME — e.g. codex-shim-install.sh creates $HOME/.agents/bin/codex
  # and install.sh's configure_codex_sandbox edits $HOME/.codex/config.toml — and
  # a leaked write would clobber the real install / shim (and dangle once this
  # temp dir is torn down). bats runs each test in its own subshell, so the
  # export is scoped to the test and needs no restore. See #41.
  export HOME="$TEST_SKILL_DIR/home"
  mkdir -p "$HOME"
}

# PIDs (one per line, this shell excluded) whose command line references <dir>.
# The detached codex children — codex-bridge-launcher.sh and the codex-bridge.js it
# starts (codex-monitor.sh spawns the launcher with `… &`, "outlives this script") —
# resolve their SKILL_DIR from their own script path, so their argv carries
# TEST_SKILL_DIR. The launcher records no pidfile of its own, so a pidfile sweep cannot
# reach it; the command line is what names it. Unix uses ps; on Git Bash ps enumerates
# MSYS processes, which the launcher/bridge are, so it reaches them there too.
#
# LIMIT (named deliberately, not a defect): this matches only processes that carry
# $dir IN THEIR ARGV. A process whose CWD is inside $dir but whose argv does not name
# it would NOT be found. The two known holders are argv-visible today — the launcher
# resolves SKILL_DIR from its own script path (argv[0]), and the bridge receives
# --workspace-root <dir> — so they are caught; but that is a property of THOSE two, not
# a guarantee about any future holder. A cwd/open-fd sweep (lsof) would close the gap;
# it is deliberately NOT used because lsof is slow and this runs in EVERY test's
# teardown — too heavy for the ~all tests that hold nothing. If a future detached child
# holds $dir without naming it in argv, revisit (add an lsof pass gated on the rm
# actually failing, so the cost is paid only when it is needed).
_pids_referencing_dir() {   # <dir>
  ps -eo pid=,args= 2>/dev/null |
    AGMSG_REAP_DIR="$1" awk -v me="$$" 'index($0, ENVIRON["AGMSG_REAP_DIR"]) { if ($1+0 != me+0) print $1 }'
}

# Reap any process still holding $TEST_SKILL_DIR, then let handles release, BEFORE the
# rm. Those detached children keep writing $TEST_SKILL_DIR/run after the test body
# returns and are in no pidset the tests kill, so the bare rm below races them and fails
# `rm: Directory not empty` (or, on Windows, `Device or resource busy` on the bridge's
# open messages.db). #662 == #1036 == #1049.
#
# Scope is $TEST_SKILL_DIR ITSELF — a unique mktemp path — so matching it in process
# args cannot reach a developer's live bridge or another test's processes; this is never
# a blanket `pkill codex-bridge.js`. Guarded to a temp path so a mis-set variable can
# never turn the scan loose on a short/rooty prefix. A single `ps` for the ~all tests
# that spawn nothing.
#
# The SIGTERM→wait→SIGKILL sequence is EXERCISED by tests/test_teardown_reap.bats (kill,
# scope-safety, no-op, guard); whether the wait budget is long enough on a load-3-digit
# host, and whether killing a holder RELEASES the Windows file handle before the rm, are
# both timing/OS facts this repo cannot measure on the author's loaded machine — CI
# (dedicated runners, Windows leg) measures them. Written as designed-and-static-checked,
# NOT as "measured", per the day's rule that a claim states how it was verified (#1036).
_reap_test_skill_dir_procs() {
  local dir="${TEST_SKILL_DIR:-}"
  case "$dir" in
    ""|/|/tmp|/var|/private|/usr|"$HOME") return 0 ;;
  esac
  case "$dir" in
    /tmp/*|/private/*|/var/folders/*|/private/var/folders/*) : ;;
    *)
      # Outside the well-known temp roots, allow ONLY under a TMPDIR that is set AND a
      # real path — never unset, "", or "/". Resolve and VALIDATE the prefix before using
      # it as a pattern: a pattern assembled from an empty prefix ("${TMPDIR:+…}" with
      # TMPDIR unset, or "${TMPDIR%/}" with TMPDIR="/") degenerates to match ANY non-empty
      # dir. This guards a KILL, so the loose failure kills EXTRA processes, not nothing
      # (co2 BLOCKING). Strip the trailing slash first, then require the result non-empty,
      # so unset / "" / "/" all fail closed. Only then is "$_tmp" safe as a pattern prefix.
      local _tmp="${TMPDIR:-}"; _tmp="${_tmp%/}"
      [ -n "$_tmp" ] || return 0
      case "$dir" in "$_tmp"/?*) : ;; *) return 0 ;; esac
      ;;
  esac
  local pids tries=0 sig p
  while :; do
    pids="$(_pids_referencing_dir "$dir")"
    [ -n "$pids" ] || return 0
    # Escalate to SIGKILL quickly (after ~0.3s of SIGTERM): a detached launcher may not
    # act on SIGTERM, and this is a teardown, not a graceful shutdown. SIGKILL is
    # uncatchable, so once sent the process WILL die — the only remaining wait is for ps
    # to stop listing it, which a heavily loaded host can slow. So keep re-checking up
    # to ~6s (a bound only ever reached when something is genuinely stuck; the ~all tests
    # that hold nothing return on the first check above), then return and let the rm
    # surface anything still there. The 6s headroom is what covers a load-3-digit host.
    sig=TERM; [ "$tries" -ge 3 ] && sig=KILL
    for p in $pids; do kill "-$sig" "$p" 2>/dev/null || true; done
    [ "$tries" -ge 60 ] && return 1
    sleep 0.1 2>/dev/null || true
    tries=$((tries + 1))
  done
}

# Derive the run-file path a real caller would use for (team, agent), instead
# of a test hardcoding the pre-#1023 legacy literal "<team>__<agent>". join.sh
# mints team_id unconditionally when it creates a brand-new team config, and
# mints the member's member_id in the same call once team_id exists -- so a
# freshly join.sh'd team/agent pair (the normal case in this suite) resolves
# to the NEW id-keyed path, not the legacy one. A literal string baked into a
# test fixture silently stops matching the path production code actually
# reads or writes the moment #1023 lands, with no error at the mismatch site.
_ready_path() {   # <team> <agent>
  ( SKILL_DIR="$TEST_SKILL_DIR"; source "$TEST_SKILL_DIR/scripts/lib/actas-lock.sh"; agmsg_ready_path "$1" "$2" )
}
_spawn_record_path() {   # <team> <agent>
  ( SKILL_DIR="$TEST_SKILL_DIR"; source "$TEST_SKILL_DIR/scripts/lib/actas-lock.sh"; agmsg_spawn_path "$1" "$2" )
}
_actas_session_path() {   # <team> <agent>
  ( SKILL_DIR="$TEST_SKILL_DIR"; source "$TEST_SKILL_DIR/scripts/lib/actas-lock.sh"; actas_lock_path "$1" "$2" )
}

teardown_test_env() {
  # Try the plain rm FIRST, and only reap when it actually fails. The reaper's scan is a
  # full `ps -eo pid=,args=`; running it in EVERY teardown would add that cost to all of
  # the (vast majority of) tests that hold nothing — across the suite's hundreds of tests
  # that dominates the runtime and pushes CI shards over their timeout. The race it fixes
  # is rare (only the codex tests spawn the detached launcher), and it announces itself
  # as a non-zero rm ("Directory not empty" / "Device or resource busy"), so pay the cost
  # exactly there: on failure, reap the TEST_SKILL_DIR-scoped holders and retry.
  rm -rf "$TEST_SKILL_DIR" 2>/dev/null && return 0
  local reap_status=0 rm_status=0
  _reap_test_skill_dir_procs || reap_status=$?
  rm -rf "$TEST_SKILL_DIR" || rm_status=$?
  [ "$reap_status" -eq 0 ] && [ "$rm_status" -eq 0 ]
}

# Print the renderable type set from the registry rather than duplicating the
# list in each composition assertion. The optional root is useful for tests
# that copy scripts into an isolated skill directory.
agmsg_renderable_types() {
  local root="${1:-$BATS_TEST_DIRNAME/..}"
  (
    # shellcheck disable=SC1091
    source "$root/scripts/lib/type-registry.sh"
    printf '%s\n' $AGMSG_RENDERABLE_SKILL_TYPES
  )
}

# A fake `tmux` that logs its argv and produces the ids/text real tmux would.
#
# Shared because three suites drive the terminal layer now — the registry's own
# tests, the watcher, and per-turn delivery (#1044 gave the last two a naming
# call). Callers set FAKEBIN and ARGV_LOG first; nothing here reads them at
# source time, so a suite that does not want a fake terminal is unaffected.
agmsg_install_fake_tmux() {
  # The label this fake REMEMBERS. A pane option that is set and then never
  # readable is not a model of tmux: `terminal_label_of` asks a pane which agmsg
  # label it carries, and code that acts on the answer (the self-naming fast
  # half, #1130) cannot be tested against a fake that always answers nothing.
  # So `set-option ... @agmsg_agent <label>` is stored per pane and
  # `display-message` replays it. Only the one format that asks for the label is
  # answered; every other format falls through to silence exactly as before, so
  # suites that depend on this fake's other behaviour are untouched.
  export FAKE_TMUX_STATE="${FAKE_TMUX_STATE:-$FAKEBIN/tmux.labels}"
  : > "$FAKE_TMUX_STATE"
  cat > "$FAKEBIN/tmux" <<EOF
#!/usr/bin/env bash
{ printf 'tmux'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$ARGV_LOG"
state='$FAKE_TMUX_STATE'
args=("\$@")
if [ "\${args[0]}" = -S ]; then args=("\${args[@]:2}"); fi
case "\${args[0]}" in
  new-window)   echo '@7' ;;
  split-window) echo '%9' ;;
  capture-pane) printf 'line one\nline two\n' ;;
  set-option)
    # set-option -p -t <id> @agmsg_agent <label>
    if [ "\${args[4]}" = '@agmsg_agent' ]; then
      pane="\${args[3]}"; label="\${args[5]}"
      [ -f "\$state" ] && grep -v "^\$pane	" "\$state" > "\$state.new" 2>/dev/null || : > "\$state.new"
      printf '%s\t%s\n' "\$pane" "\$label" >> "\$state.new"
      mv "\$state.new" "\$state"
    fi ;;
  display-message)
    # display-message -p -t <id> <format>
    if [ "\${args[4]}" = '#{pane_id}|#{@agmsg_agent}' ]; then
      pane="\${args[3]}"
      label="\$(awk -F'\t' -v p="\$pane" '\$1 == p { print \$2 }' "\$state" 2>/dev/null)"
      printf '%s|%s\n' "\$pane" "\$label"
    fi ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/tmux"
  export PATH="$FAKEBIN:$PATH"
}

# Clear the agmsg label the fake tmux remembers for <pane>, without touching the
# pane or the server -- the state "someone renamed the pane by hand" leaves.
agmsg_fake_tmux_clear_label() {   # <pane>
  [ -f "${FAKE_TMUX_STATE:-}" ] || return 0
  grep -v "^$1	" "$FAKE_TMUX_STATE" > "$FAKE_TMUX_STATE.new" 2>/dev/null || : > "$FAKE_TMUX_STATE.new"
  mv "$FAKE_TMUX_STATE.new" "$FAKE_TMUX_STATE"
}

# Skip a test on native Windows / Git Bash (MSYS/MINGW/Cygwin). Use ONLY for
# behaviour that depends on POSIX process semantics agmsg does not yet support
# there — watcher discovery/kill via ps/pgrep, and session liveness via kill -0
# (#134 Bug 2, #181). These are the residual windows-latest failures left after
# the Git Bash compat (#179) and sqlite CRLF (#180) fixes; quarantining them
# lets the experimental leg report green instead of perpetually red. Each call
# site names the tracking issue so the skip is removed when the bug is fixed.
skip_on_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "${1:-not yet supported on native Windows}" ;;
  esac
}

# The inverse, for the handful of tests whose whole point is native Windows: the
# real tasklist, the real MSYS pid space, no stub in between. Everywhere else
# they would prove nothing, so they skip rather than pass vacuously.
skip_unless_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) skip "${1:-only meaningful under Git Bash}" ;;
  esac
}

# The Antigravity monitor is Linux-only: antigravity-tui-supervisor.py reads
# /proc/<pid>/stat for every liveness check, and the control actions all go
# through antigravity-mode.mjs, which does the same. Use for any test that
# actually invokes the installed agy-tui shim; tests that only check install.sh's
# own file handling (ownership, symlink replacement) do not need this.
skip_unless_linux() {
  [ "$(uname -s)" = Linux ] || skip "${1:-Antigravity TUI monitor is Linux-only}"
}

# In-memory sqlite for test ASSERTIONS, stripping CR. sqlite3.exe writes stdout
# in text mode on Windows (\n -> \r\n); $(...) keeps the trailing \r, so a probe
# like [ "$(sqlite3 :memory: 'SELECT json_valid(...)')" = "1" ] compares "1\r"
# against "1" and fails even when the script under test wrote a correct file.
# This is the test-side mirror of scripts/lib/storage.sh's agmsg_sqlite_mem.
sqlite_mem() { sqlite3 :memory: "$@" | tr -d '\r'; }

# Permission bits of <path> as octal, e.g. 700.
#
# NOT `stat -f "%Lp" "$p" 2>/dev/null || stat -c "%a" "$p"`. That idiom leans on
# the BSD form FAILING under GNU. It does fail — but only after writing
# filesystem information to STDOUT, because GNU reads `-f` as `--file-system`
# and the format string as a second file operand. `2>/dev/null` hides the error
# it then prints, not the output already written, so the capture becomes that
# block with the real mode appended and no comparison can match. Green on macOS,
# red on any GNU host, and the reason is invisible at the call site.
#
# Branch on the platform instead, the way scripts/lib/compat.sh already does for
# mtime. One implementation so a fourth call site cannot reintroduce it.
file_mode() {
  case "$(uname -s)" in
    Darwin*) stat -f "%Lp" "$1" ;;
    *)       stat -c "%a" "$1" ;;
  esac
}

# Resolve a file path for use inside a sqlite3 readfile('...') call in a test.
# On native Windows, sqlite3 only reads a Windows path (C:\Users\...), not a Git
# Bash POSIX path (/c/Users/... or /tmp/...): an unconverted path reads back as
# empty, so the surrounding json_extract / json_valid sees nothing and the check
# fails even though the script under test wrote a correct file. cygpath -w
# converts it; a no-op off Windows (cygpath absent). The result is then single-
# quote-escaped for the SQL string literal. Mirrors scripts/lib/storage.sh's
# agmsg_sql_readfile_path — the production helper these tests are validating.
rf() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    p="$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")"
  fi
  printf '%s' "$p" | sed "s/'/''/g"
}

# --- Bounded condition waits -------------------------------------------------
#
# Wait for a condition to become true, polling, instead of sleeping a fixed
# interval and hoping. A fixed `sleep 1` after launching a watcher is wrong in
# both directions at once: it costs a whole second when the watcher was ready in
# 40ms, and it still flakes on a loaded runner where the watcher needs 1.2s.
# Polling is both faster and steadier, which is why the pattern already existed
# ad hoc in test_watch.bats, test_install.bats and test_codex_bridge_launcher.bats
# before it was hoisted here.
#
# Each returns non-zero on timeout, so a caller can fail with its own message or
# clean up a background process first. The 10s ceiling is far above any real
# local transition and well under the per-job CI timeout.
#
# NOTE: these replace waits for a condition that will become TRUE. A test that
# asserts something does NOT happen cannot poll for it — see the comment at the
# remaining fixed sleeps in test_delivery.bats.

_WAIT_TICKS=100    # x 0.1s = 10s ceiling
_WAIT_INTERVAL=0.1

wait_for_file() {
  local file="$1" i
  for i in $(seq 1 $_WAIT_TICKS); do
    [ -f "$file" ] && return 0
    sleep $_WAIT_INTERVAL
  done
  return 1
}

wait_for_missing() {
  local path="$1" i
  for i in $(seq 1 $_WAIT_TICKS); do
    [ ! -e "$path" ] && return 0
    sleep $_WAIT_INTERVAL
  done
  return 1
}

wait_for_file_contains() {
  local file="$1" needle="$2" i
  for i in $(seq 1 $_WAIT_TICKS); do
    [ -f "$file" ] && grep -q "$needle" "$file" && return 0
    sleep $_WAIT_INTERVAL
  done
  return 1
}

# Waits for a mock HTTP fixture (mock_slack_server.py, mock_openrouter_server.py,
# ...) to actually be ready to accept connections, not just for it to have
# PRINTED its port -- a process can write that line before its own accept
# loop is scheduled, and a loaded CI runner is exactly where that gap widens
# (review finding, #1339: this is what made the slack/jev mock-server tests
# flake on a busy macos-latest runner while ubuntu/windows stayed green).
# Polls a real TCP connect via bash's own /dev/tcp. On timeout, prints
# exactly what it was waiting for (the port file's path and, if it got that
# far, the port itself) instead of leaving the caller's own assertion to
# report a bare failure with no context.
#
# Uses its OWN, longer ceiling (30s, not the shared 10s _WAIT_TICKS every
# other wait_for_* helper here uses): this waits on a fresh python3
# subprocess actually being scheduled and finishing its own startup/import
# work, not an in-process condition -- a real fork+exec, which a saturated
# CI runner can push past 10s on its own even when nothing is actually
# broken (review finding, #1339 round 2: this recurred on a LATER macos CI
# run, that time never even reaching the port-file-written stage within the
# old 10s bound).
_MOCK_SERVER_WAIT_TICKS=300   # x 0.1s = 30s ceiling
wait_for_mock_server_port() {   # <port_file> -> prints the port on stdout
  local port_file="$1" i port=""
  for i in $(seq 1 $_MOCK_SERVER_WAIT_TICKS); do
    if [ -z "$port" ] && [ -f "$port_file" ]; then
      port="$(cat "$port_file" 2>/dev/null)"
      case "$port" in ''|*[!0-9]*) port="" ;; esac
    fi
    if [ -n "$port" ]; then
      if { exec 3<>"/dev/tcp/127.0.0.1/$port"; } 2>/dev/null; then
        exec 3<&- 3>&-
        printf '%s' "$port"
        return 0
      fi
    fi
    sleep $_WAIT_INTERVAL
  done
  # Names what it was waiting for AND how long -- a bare "timed out" was
  # exactly what forced guessing at the cause the first two times this
  # flaked (review finding, #1341: the maintainer asked for this explicitly,
  # so a next occurrence does not start the same investigation from zero).
  # Each tick is 0.1s, so ticks/10 and ticks%10 give exact whole and tenths
  # digits without floating-point arithmetic (bash has none) -- accurate at
  # both the real 30s ceiling and a test's much shorter override, rather
  # than integer-dividing away the fraction and printing a misleading "0s".
  local waited_s="$((_MOCK_SERVER_WAIT_TICKS / 10)).$((_MOCK_SERVER_WAIT_TICKS % 10))"
  if [ -z "$port" ]; then
    echo "wait_for_mock_server_port: timed out after ${waited_s}s waiting for $port_file to name a port" >&2
  else
    echo "wait_for_mock_server_port: timed out after ${waited_s}s waiting for 127.0.0.1:$port (from $port_file) to accept a connection" >&2
  fi
  return 1
}

# Positive evidence that a pid is gone. NOT `kill -0 || gone`.
#
# A failed `kill -0` is ESRCH (dead) or EPERM (alive, but not signalable by us —
# sandboxes do exactly this, and a live instance of it was found in
# delivery.sh status the same day this was written). Treating every failure as
# "gone" is how a wait-for-exit helper reports success for a running process,
# which turns every test built on it into a green that proves nothing. That is
# the defect this file's own callers were just fixed for; the helper must not
# reintroduce it one level down.
#
# Mirrors _agmsg_pid_alive in scripts/lib/instance-id.sh, then cross-checks the
# process table, which does not depend on signalling permission at all. Saying
# "gone" now requires kill(2) and ps to agree.
_pid_gone() {
  local pid="$1" err stat
  # `export LC_ALL=C` rather than a bare prefix: a prefix misses the builtin on
  # bash 3.2, and the ESRCH match below is on English text.
  err="$(export LC_ALL=C; kill -0 "$pid" 2>&1)" && return 1
  case "$err" in
    *[Nn]'o such process'*) ;;
    *) return 1 ;;   # EPERM and anything unrecognised mean "assume alive"
  esac
  stat="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -z "$stat" ] && return 0
  case "$stat" in Z*) return 0 ;; esac   # terminated, just not reaped yet
  return 1
}

# Wait for a process to actually be gone. Writing a pidfile and dying are not
# atomic, so asserting `! kill -0 $pid` the instant a pidfile disappears races
# the TERM trap (#124).
wait_for_pid_exit() {
  local pid="$1" i
  for i in $(seq 1 $_WAIT_TICKS); do
    # Reap finished children first: an unreaped zombie still answers `kill -0`,
    # so without this a process that HAS exited can keep looking alive for the
    # whole timeout. `jobs` is what makes bash collect them.
    jobs >/dev/null 2>&1 || true
    _pid_gone "$pid" && return 0
    sleep $_WAIT_INTERVAL
  done
  return 1
}

# Wait for <file> to contain exactly <expected>, for pidfile handoffs where the
# file exists throughout but its contents flip to the successor.
wait_for_file_is() {
  local file="$1" expected="$2" i
  for i in $(seq 1 $_WAIT_TICKS); do
    if [ -f "$file" ] && [ "$(cat "$file" 2>/dev/null)" = "$expected" ]; then
      return 0
    fi
    sleep $_WAIT_INTERVAL
  done
  return 1
}

# Pin a fake-owned session_id under the given run/ directory so the lock
# liveness check (which runs `kill -0` on cc-instance.<pid>) considers
# <sid> alive for the duration of the bats process.
#
# Used to be inlined in every test that needed a live peer owner. Pulled
# up here per #65 review finding 7 — the fake cc-instance pattern is part
# of the lock contract; repeating it inline invites tests that flake the
# moment we tighten what "alive" means.
#
# Usage: setup_live_owner <run_dir> <session_id>
setup_live_owner() {
  local run_dir="$1" sid="$2"
  mkdir -p "$run_dir"
  echo "$sid" > "$run_dir/cc-instance.$$"
}

# A PATH containing only `bash` and `dirname` (real binaries, via symlink)
# -- enough to exec bash itself (so `env PATH=... bash script.sh` doesn't
# fail on "bash: command not found" before the script even starts) and for
# remote.sh/team-list.sh to resolve SCRIPT_DIR/SKILL_DIR and reach their
# agmsg_require_python3 preflight check, but with no `python3` findable via
# `command -v`. Used to test the preflight check itself fails fast with a
# clear message instead of ever invoking python3 (see
# lib/require-python3.sh) -- deliberately NOT built by filtering the real
# PATH's directories, so it can't accidentally still contain a python3
# from some other directory.
# A PATH holding what doctor needs and no age. Shadowing with a stub does not
# work: `command -v` skips a non-executable entry and finds the real binary
# further along, so the lookup only fails if the PATH is built from scratch --
# the same approach path_without_python3 takes.
path_without_age() {
  local dir tool
  dir="$(mktemp -d)"
  for tool in bash dirname basename readlink python3 node uname sed grep \
              awk cat tr mktemp; do
    if command -v "$tool" >/dev/null 2>&1; then
      ln -s "$(command -v "$tool")" "$dir/$tool" 2>/dev/null || true
    fi
  done
  printf '%s' "$dir"
}

path_without_python3() {
  local dir
  dir="$(mktemp -d)"
  ln -s "$(command -v bash)" "$dir/bash"
  ln -s "$(command -v dirname)" "$dir/dirname"
  printf '%s' "$dir"
}

# Fail the test when <cmd> SUCCEEDS.
#
# `! cmd` cannot do this. POSIX errexit exempts a negated command, on every
# bash, so `! grep -q needle file` is silent when the needle IS there -- the
# one outcome it was written to catch. Measured on 3.2.57 and 5.3.15: both
# report `ok` (#670).
#
# Deliberately not `run cmd` + `[ "$status" -ne 0 ]`, which also works: `run`
# overwrites `$output` and `$status`, so converting an absence check that way
# silently breaks any assertion after it that still reads `$output`. That is a
# real bug, not a hypothetical -- it happened twice in #697 -- and 48 sites is
# too many to hand that to.
#
# Says what failed, because a bare `false` leaves the reader to work out which
# of several absence checks was the one that fired.
refute() {
  if "$@"; then
    echo "refute: '$*' unexpectedly succeeded" >&2
    return 1
  fi
}

# A live process whose command line contains <path>, and nothing else.
#
# The kill paths in session-end.sh / session-start.sh only signal a pid whose
# cmdline still looks like this install's watch.sh -- a deliberate defence
# against pid recycling. Fixtures used a bare `sleep`, whose cmdline does not
# match, so the kill never fired and the assertion checking for it was `!
# kill -0 ...`, which is silent on every bash. The tests passed for years
# without once exercising the branch they are named after (#670).
#
# It runs a script that sleeps; it does NOT exec, which would drop the argument
# from the command line, and it does NOT start the real watcher -- a live
# watcher inside a test is how a suite grows processes that outlive it.
# Sets DECOY_PID rather than printing it: `pid="$(spawn_...)"` runs the `&` in
# a command substitution's subshell, and the child dies with that subshell. The
# first version did exactly that, and the tests using it went green because the
# decoy was already gone -- not because anything had killed it. Returning
# through a variable keeps the process a child of the test.
# The same reader the product uses to decide whether a pid is one of ours, so
# a fixture's precondition is checked the way session-end.sh checks it rather
# than by a lookalike.
_decoy_cmdline() {
  # shellcheck disable=SC1090
  . "$SCRIPTS/lib/compat.sh"
  compat_get_cmdline "$1"
}

spawn_decoy_with_cmdline() {
  local path="$1" decoy
  decoy="$(mktemp -d)/decoy.sh"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$decoy"
  chmod +x "$decoy"
  bash "$decoy" "$path" 3>&- &
  DECOY_PID=$!
}

# Sends <count> messages of ~<bodylen> bytes each from <from> to <to> on
# <team>, via storage_send directly rather than send.sh's own CLI (#777
# argv-length regressions in inbox.sh/check-inbox.sh/watch.sh/watch-once.sh).
#
# A plain bash FUNCTION CALL, not a subprocess: `storage_send "$team" ...
# "$body"` hands the body to sqlite3 through the same escaped-argv path
# production code uses for a single INSERT (which is not itself in scope --
# no test here builds a body anywhere near that ceiling), but building the
# backlog this way never has to exec anything with the WHOLE backlog as one
# argument, which is exactly the shape production code used to get wrong
# on read. Bodies are tagged "$label-$i-<pad>" so a caller can assert both
# ends of the run (index 0 and count-1) are actually present in what the
# script under test displayed, not just that its exit status was 0.
# 1.3.1 CI speedup: a 100-message backlog through the loop below used to
# spawn one sqlite3 process PER MESSAGE (storage_send's own -bail invocation),
# which is what made the two tests that build a real argv-ceiling-sized
# backlog the two slowest in this file. Verified before switching: a 3-message
# batch built the old way (storage_send in a loop, one sqlite3 call each) and
# the new way (one sqlite3 call for all 3) were compared row-for-row across
# both `messages` and `events` -- same team/from/to/body fields, same rowid
# sequencing, same events.legacy_id -> messages.rowid linkage. Only
# created_at differs, because the batched form finishes fast enough that
# _sqlite_now's second-granularity clock barely advances between messages --
# expected, not a correctness difference (each message's timestamp is still
# a real, distinct call to the same clock function). Only takes this path
# when the driver is sqlite (the only one an argv-ceiling concern applies to,
# and the one whose private functions this depends on); any other driver
# keeps the one-call-per-message loop unchanged.
bulk_send_direct() {
  local team="$1" from="$2" to="$3" count="$4" bodylen="$5" label="$6" \
    i=0 pad
  pad="$(head -c "$bodylen" /dev/zero | tr '\0' 'x')"
  (
    # shellcheck disable=SC1090
    source "$SCRIPTS/lib/storage.sh"
    agmsg_storage_load
    if declare -F _sqlite_message_sent_sql >/dev/null 2>&1 \
      && declare -F _sqlite_db >/dev/null 2>&1 \
      && declare -F _sqlite_now >/dev/null 2>&1; then
      storage_init "$team" >/dev/null 2>&1 || true
      local db batch id at
      db="$(_sqlite_db "$team")"
      batch=""
      while [ "$i" -lt "$count" ]; do
        id="$(compat_uuid7)"
        at="$(_sqlite_now)"
        batch="${batch}
$(_sqlite_message_sent_sql "$team" "$from" "$to" "${label}-${i}-${pad}" "$id" "$at")"
        i=$((i + 1))
      done
      agmsg_sqlite_warm
      printf '%s\n' "$batch" | agmsg_sqlite -bail "$db" >/dev/null
    else
      while [ "$i" -lt "$count" ]; do
        storage_send "$team" "$from" "$to" "${label}-${i}-${pad}" >/dev/null
        i=$((i + 1))
      done
    fi
  )
}
