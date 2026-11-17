#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# An `install.sh --update` that ends between "Updating agmsg..." and the first
# progress line used to end with no word about why: several steps in that stretch
# return 1 and the caller exits 1. A CI run twice ended a test that way (the output
# stopped at "Updating agmsg...", status non-zero) with nothing to say which step it
# was. Each case here makes one of those steps fail and checks that the update
# names the step, the command and the path, and still ends with the same status.
#
# Every run uses a throwaway HOME, as test_install.bats does.

load test_helper

setup() {
  export FAKE_HOME="$(mktemp -d)"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SK="$FAKE_HOME/.agents/skills/agmsg"
  unset CODEX_HOME
  unset AGMSG_STORAGE_PATH AGMSG_CONFIG AGMSG_STORAGE_DRIVER AGMSG_APP_BASE AGMSG_SPAWN_OPTIONS_FILE
  export AGMSG_AGENT_PID=""
  SHIMS="$BATS_TEST_TMPDIR/shims"
  mkdir -p "$SHIMS"
  HOLDER_PID=""
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg >/dev/null 2>&1
}

teardown() {
  if [ -n "$HOLDER_PID" ]; then
    kill "$HOLDER_PID" 2>/dev/null || true
    wait "$HOLDER_PID" 2>/dev/null || true
  fi
  rm -rf "$FAKE_HOME"
}

# A command that fails when any argument matches <pattern>, and otherwise runs
# the real one found after the shim directory.
shim_fail_on() {   # <command> <glob pattern for an argument>
  local real
  real="$(command -v "$1")"
  printf '%s\n' '#!/usr/bin/env bash' \
    'for a in "$@"; do' \
    "  case \"\$a\" in $2) exit 1 ;; esac" \
    'done' \
    "exec $real \"\$@\"" > "$SHIMS/$1"
  chmod +x "$SHIMS/$1"
}

update() {
  HOME="$FAKE_HOME" PATH="$SHIMS:$PATH" run bash "$REPO_ROOT/install.sh" --update
}

has() { printf '%s\n' "$output" | grep -qF -- "$1"; }

@test "an update that goes through names no stopping step" {
  update
  [ "$status" -eq 0 ]
  refute has "update stopped at"
}

@test "install.db held by another writer: the update names the table, sqlite's rc and the file, and still exits 1" {
  ( printf 'BEGIN EXCLUSIVE;\n'; sleep 60 ) | sqlite3 "$SK/run/install.db" >/dev/null 2>&1 &
  HOLDER_PID=$!
  # Wait until the hold is real: a second writer must be refused.
  local i=0
  while sqlite3 "$SK/run/install.db" "CREATE TABLE IF NOT EXISTS probe_hold(x);" >/dev/null 2>&1; do
    sqlite3 "$SK/run/install.db" "DROP TABLE probe_hold;" >/dev/null 2>&1
    i=$((i + 1)); [ "$i" -lt 300 ] || break
    sleep 0.1
  done
  [ "$i" -lt 300 ]
  update
  [ "$status" -eq 1 ]
  has "install.db: creating the meta table failed (sqlite3 rc="
  has "$SK/run/install.db"
  has "could not read or create install.db's meta row"
  has "update stopped at: starting the install operation"
  has "(exit status 1)"
}

@test "the incomplete-operation record cannot be made: mktemp failure names the step and the directory" {
  shim_fail_on mktemp '*.install-op-incomplete*'
  update
  [ "$status" -eq 1 ]
  has "incomplete-operation record: mktemp failed in $SK/run"
  has "could not record the incomplete-operation marker: $SK/run/install-op-incomplete.json"
  has "update stopped at: starting the install operation"
}

@test "the recovery helper cannot be made: mktemp failure names the helper's directory" {
  shim_fail_on mktemp '*.install-op-recovery*'
  update
  [ "$status" -eq 1 ]
  has "recovery helper: mktemp failed in $SK/run"
  has "update stopped at: writing the recovery helper ($SK/run/install-op-recovery.sh)"
}

@test "the recovery helper cannot be made: chmod failure names the file" {
  shim_fail_on chmod '*.install-op-recovery*'
  update
  [ "$status" -eq 1 ]
  has "recovery helper: chmod 600 failed on"
  has "update stopped at: writing the recovery helper"
}

@test "the trash directory cannot be recreated: names the directory" {
  shim_fail_on mkdir '*/.trash'
  update
  [ "$status" -eq 1 ]
  has "could not recreate the trash directory"
  has "update stopped at: resetting $SK/.trash"
}

@test "CHANGELOG.md cannot be copied: names the target" {
  shim_fail_on cp '*/CHANGELOG.md'
  update
  [ "$status" -eq 1 ]
  has "update stopped at: copying CHANGELOG.md to $SK/CHANGELOG.md"
}
