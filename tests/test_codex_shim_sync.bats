#!/usr/bin/env bats
# The Codex PATH shim (~/.agents/bin/codex) is not needed while agmsgd delivers
# Codex notices: `codex-shim-install.sh sync` removes an agmsg shim owned by this
# install then, and puts it back when the monitor needs it again. The fixture
# sandboxes HOME, so the shim lives under the test's own directory.

load test_helper

setup() {
  setup_test_env
  SHIM="$HOME/.agents/bin/codex"
  INSTALLER="$TYPES/codex/codex-shim-install.sh"
  REAL_BIN="$TEST_SKILL_DIR/realbin"
  mkdir -p "$REAL_BIN" "$TEST_SKILL_DIR/run"
  printf '#!/bin/sh\necho real\n' > "$REAL_BIN/codex"
  chmod +x "$REAL_BIN/codex"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  export SHIM INSTALLER REAL_BIN
}

teardown() { teardown_test_env; }

# `sync` keeps the shim on Windows (it adds --no-daemon on an elevated shell), so
# the cases that watch it being removed or restored only make sense elsewhere.
_posix_only() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) skip "sync keeps the Codex shim on Windows; this case is POSIX-only" ;;
  esac
}

_agmsgd() {   # on|off
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='$1';"
}

_choose() {   # <value>
  printf 'codex\t/some/project\t%s\n' "$1" > "$TEST_SKILL_DIR/run/delivery-choice"
}

@test "sync: agmsgd off leaves the shim alone" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  _agmsgd off
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "unchanged:" <<<"$output"
  [ -x "$SHIM" ]
}

@test "sync: agmsgd on removes this install's shim, and codex then resolves to the real binary" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  _agmsgd on
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "removed: $SHIM" <<<"$output"
  [ ! -e "$SHIM" ]
  [ -f "$TEST_SKILL_DIR/run/codex-shim-retired" ]
  [ "$(PATH="$HOME/.agents/bin:$REAL_BIN:/usr/bin:/bin" command -v codex)" = "$REAL_BIN/codex" ]
}

@test "sync: turning agmsgd off puts the removed shim back, and only once" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  _agmsgd on
  bash "$INSTALLER" sync >/dev/null
  _agmsgd off
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "installed: $SHIM" <<<"$output"
  [ -x "$SHIM" ]
  grep -Fq "agmsg-shim-owner" "$SHIM"
  [ ! -e "$TEST_SKILL_DIR/run/codex-shim-retired" ]
  run bash "$INSTALLER" sync
  grep -Fq "unchanged:" <<<"$output"
}

@test "sync: a shim that was never removed here is not created when agmsgd is off" {
  _agmsgd off
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  [ ! -e "$SHIM" ]
}

@test "sync: a project that chose the monitor keeps the shim, and choosing agmsgd again lets it go" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  _agmsgd on
  _choose monitor
  run bash "$INSTALLER" sync
  grep -Fq "unchanged:" <<<"$output"
  [ -x "$SHIM" ]
  _choose agmsgd
  run bash "$INSTALLER" sync
  grep -Fq "removed: $SHIM" <<<"$output"
  [ ! -e "$SHIM" ]
  _choose monitor
  run bash "$INSTALLER" sync
  grep -Fq "installed: $SHIM" <<<"$output"
  [ -x "$SHIM" ]
}

@test "sync: a codex that is not an agmsg shim is never removed" {
  _posix_only
  mkdir -p "$HOME/.agents/bin"
  printf '#!/bin/sh\necho mine\n' > "$SHIM"
  chmod +x "$SHIM"
  _agmsgd on
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "kept: $SHIM (not an agmsg shim)" <<<"$output"
  grep -Fq "echo mine" "$SHIM"
  [ ! -e "$TEST_SKILL_DIR/run/codex-shim-retired" ]
}

@test "sync: a shim owned by a different install is not removed" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  sed -i.bak 's#^\# agmsg-shim-owner: .*#\# agmsg-shim-owner: /somewhere/else/scripts/drivers/types/codex#' "$SHIM"
  rm -f "$SHIM.bak"
  _agmsgd on
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "kept: $SHIM (owned by a different install)" <<<"$output"
  [ -x "$SHIM" ]
}

@test "sync: Windows keeps the shim (it adds --no-daemon on an elevated shell)" {
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  mkdir -p "$TEST_SKILL_DIR/fakebin"
  printf '#!/bin/sh\necho MINGW64_NT-10.0\n' > "$TEST_SKILL_DIR/fakebin/uname"
  chmod +x "$TEST_SKILL_DIR/fakebin/uname"
  _agmsgd on
  run env PATH="$TEST_SKILL_DIR/fakebin:$PATH" bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "Windows keeps the Codex shim" <<<"$output"
  [ -x "$SHIM" ]
}

@test "sync: a place that was filled meanwhile is not overwritten when restoring" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  _agmsgd on
  bash "$INSTALLER" sync >/dev/null
  printf '#!/bin/sh\necho theirs\n' > "$SHIM"
  chmod +x "$SHIM"
  _agmsgd off
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "echo theirs" "$SHIM"
  [ ! -e "$TEST_SKILL_DIR/run/codex-shim-retired" ]
}

@test "delivery: choosing the monitor for Codex brings the shim back, choosing agmsgd removes it" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  _agmsgd on
  bash "$INSTALLER" sync >/dev/null
  [ ! -e "$SHIM" ]
  mkdir -p "$TEST_SKILL_DIR/project"
  run bash "$SCRIPTS/delivery-cli.sh" monitor --type codex --project "$TEST_SKILL_DIR/project"
  grep -Fq "installed: $SHIM" <<<"$output"
  [ -x "$SHIM" ]
}

@test "sync: a dangling symlink in the shim's place is not written through when restoring" {
  _posix_only
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  _agmsgd on
  bash "$INSTALLER" sync >/dev/null
  ln -s "$TEST_SKILL_DIR/nowhere" "$SHIM"
  _agmsgd off
  run bash "$INSTALLER" sync
  [ "$status" -eq 0 ]
  grep -Fq "kept: $SHIM (already present)" <<<"$output"
  [ -L "$SHIM" ]
  [ "$(readlink "$SHIM")" = "$TEST_SKILL_DIR/nowhere" ]
  [ ! -e "$TEST_SKILL_DIR/nowhere" ]
  [ ! -e "$TEST_SKILL_DIR/run/codex-shim-retired" ]
}

@test "AGMSG_AGENTS_BIN moves the shim's place, and sync works there" {
  _posix_only
  export AGMSG_AGENTS_BIN="$TEST_SKILL_DIR/side-bin"
  AGMSG_CODEX_SHIM_INSTALL_QUIET=1 bash "$INSTALLER" install
  [ -x "$AGMSG_AGENTS_BIN/codex" ]
  [ ! -e "$SHIM" ]
  _agmsgd on
  run bash "$INSTALLER" sync
  grep -Fq "removed: $AGMSG_AGENTS_BIN/codex" <<<"$output"
  [ ! -e "$AGMSG_AGENTS_BIN/codex" ]
}

