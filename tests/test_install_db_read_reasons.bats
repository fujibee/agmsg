#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# A read of agmsgd's setting from install.db that FAILS (after the wait for a
# writer) used to end in `|| true` and look the same as an unset value: the update
# skipped the restart without a word, the post-update hint pointed at turning agmsgd
# on, and the self-heal skipped its restart without a word. Each case here makes the
# read fail with sqlite3's status 5 (database is locked) and checks that the reason
# is given, and that nothing new stops: the same return status as before.

load test_helper

setup() {
  export FAKE_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKE_HOME"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SHIMS="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$SHIMS"
  FAKE="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$FAKE/run" "$FAKE/scripts"
  sqlite3 "$FAKE/run/install.db" "CREATE TABLE daemon_intent(desired TEXT, op_gen INT); INSERT INTO daemon_intent VALUES('on',7); CREATE TABLE daemon_owner(state TEXT); INSERT INTO daemon_owner VALUES('none');"
  # sqlite3 that fails with status 5 when the SQL mentions <word>, and is the real
  # one otherwise.
  fail_sqlite_on() {
    local real
    real="$(command -v sqlite3)"
    printf '%s\n' '#!/usr/bin/env bash' \
      'for a in "$@"; do' \
      "  case \"\$a\" in *$1*) echo 'Error: database is locked' >&2; exit 5 ;; esac" \
      'done' \
      "exec $real \"\$@\"" > "$SHIMS/sqlite3"
    chmod +x "$SHIMS/sqlite3"
  }
  fns="$BATS_TEST_TMPDIR/install-fns.sh"
  awk '/^# --- Defaults ---/ {exit} {print}' "$REPO_ROOT/install.sh" > "$fns"
  export fns
}

has() { printf '%s\n' "$output" | grep -qF -- "$1"; }

@test "restart_daemon: an unreadable intent says the restart was not attempted, and still returns 0" {
  fail_sqlite_on 'daemon_intent'
  PATH="$SHIMS:$PATH" run bash -c 'set -u; source "$1"; agmsg_install_restart_daemon "$2"' _ "$fns" "$FAKE"
  [ "$status" -eq 0 ]
  has "could not read its setting in $FAKE/run/install.db (sqlite3 exit status 5)"
  has "was not restarted after the update"
  refute has "starting the updated version"
}

@test "restart_daemon: an unreadable state while waiting says so, and the start still goes on" {
  printf '%s\n' '#!/usr/bin/env bash' 'echo "agmsg daemon start: running"' > "$FAKE/scripts/daemon.sh"
  chmod +x "$FAKE/scripts/daemon.sh"
  fail_sqlite_on 'daemon_owner'
  PATH="$SHIMS:$PATH" run bash -c 'set -u; source "$1"; agmsg_install_restart_daemon "$2"' _ "$fns" "$FAKE"
  [ "$status" -eq 0 ]
  has "could not read its state in $FAKE/run/install.db (sqlite3 exit status 5)"
  has "starting the updated version"
}

@test "restart_daemon: a readable, unset intent stays silent about reads" {
  sqlite3 "$FAKE/run/install.db" "UPDATE daemon_intent SET desired = 'off';"
  PATH="$SHIMS:$PATH" run bash -c 'set -u; source "$1"; agmsg_install_restart_daemon "$2"' _ "$fns" "$FAKE"
  [ "$status" -eq 0 ]
  refute has "could not read"
  [ -z "$output" ]
}

@test "daemon hint: an unreadable setting does not suggest turning agmsgd on" {
  fail_sqlite_on 'daemon_intent'
  PATH="$SHIMS:$PATH" run bash -c 'set -u; source "$1"; agmsg_install_daemon_hint "$2"' _ "$fns" "$FAKE"
  [ "$status" -eq 0 ]
  has "its setting in $FAKE/run/install.db could not be read (sqlite3 exit status 5)"
  refute has "Turn it on with"
}

@test "daemon hint: a readable off setting still suggests turning it on" {
  sqlite3 "$FAKE/run/install.db" "UPDATE daemon_intent SET desired = 'off';"
  PATH="$SHIMS:$PATH" run bash -c 'set -u; source "$1"; agmsg_install_daemon_hint "$2"' _ "$fns" "$FAKE"
  [ "$status" -eq 0 ]
  has "Turn it on with"
}

@test "self-heal: an unreadable intent says the automatic restart was skipped, and returns 0" {
  : > "$FAKE/scripts/daemon.sh"
  fail_sqlite_on 'daemon_intent'
  mkdir -p "$FAKE/scripts/lib"
  # The whole lib directory: daemon-state.sh sources instance-id.sh, which sources
  # compat.sh, and a missing one prints an error that would hide behind a green test.
  cp -R "$REPO_ROOT"/scripts/lib/. "$FAKE/scripts/lib/"
  PATH="$SHIMS:$PATH" run bash -c 'set -u; source "$1/scripts/lib/daemon-state.sh"; _agmsg_daemon_self_heal' _ "$FAKE"
  [ "$status" -eq 0 ]
  refute has "No such file"
  has "could not read agmsgd's setting in"
  has "(sqlite3 exit status 5)"
  has "the automatic restart was skipped this time"
}

# The diagnostics are best effort: with stderr closed (a failed write) every case ends
# with the status and the progress it had without them.

@test "restart_daemon with stderr closed: an unreadable intent still returns 0 and does not start" {
  printf '%s\n' '#!/usr/bin/env bash' 'echo started > "$(dirname "$0")/started"' > "$FAKE/scripts/daemon.sh"
  chmod +x "$FAKE/scripts/daemon.sh"
  fail_sqlite_on 'daemon_intent'
  PATH="$SHIMS:$PATH" run bash -c 'set -euo pipefail; source "$1"; exec 2>&-; agmsg_install_restart_daemon "$2"' _ "$fns" "$FAKE"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE/scripts/started" ]
}

@test "restart_daemon with stderr closed: an unreadable state still goes on to start" {
  printf '%s\n' '#!/usr/bin/env bash' 'echo started > "$(dirname "$0")/started"; echo "agmsg daemon start: running"' > "$FAKE/scripts/daemon.sh"
  chmod +x "$FAKE/scripts/daemon.sh"
  fail_sqlite_on 'daemon_owner'
  PATH="$SHIMS:$PATH" run bash -c 'set -euo pipefail; source "$1"; exec 2>&-; agmsg_install_restart_daemon "$2"' _ "$fns" "$FAKE"
  [ "$status" -eq 0 ]
  [ -e "$FAKE/scripts/started" ]
}

@test "self-heal with stderr closed: an unreadable intent still returns 0" {
  : > "$FAKE/scripts/daemon.sh"
  fail_sqlite_on 'daemon_intent'
  mkdir -p "$FAKE/scripts/lib"
  cp -R "$REPO_ROOT"/scripts/lib/. "$FAKE/scripts/lib/"
  PATH="$SHIMS:$PATH" run bash -c 'set -euo pipefail; source "$1/scripts/lib/daemon-state.sh"; exec 2>&-; _agmsg_daemon_self_heal' _ "$FAKE"
  [ "$status" -eq 0 ]
}
