# Shared setup/teardown for agmsg BATS tests.
# Each test gets an isolated skill directory with its own DB and teams.

setup_test_env() {
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

teardown_test_env() {
  rm -rf "$TEST_SKILL_DIR"
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
