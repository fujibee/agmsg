#!/usr/bin/env bats

# The runtime `agmsg` command and the launcher install places for it. Nothing
# here swaps HOME or touches a real bin directory: the launcher goes to
# AGMSG_BIN_DIR under the test's own temp dir, and the install is a copy of
# scripts/ in TEST_SKILL_DIR.

load test_helper

setup() {
  setup_test_env
  AGMSG="$TEST_SKILL_DIR/scripts/agmsg"
  chmod +x "$AGMSG"
  LIB="$TEST_SKILL_DIR/scripts/lib/agmsg-launcher.sh"
  BIN_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BIN_DIR"
  export AGMSG_BIN_DIR="$BIN_DIR"
}

teardown() {
  rm -rf "$TEST_SKILL_DIR"
}

@test "agmsg: unknown verb exits 2 with the location, reserved verb says not yet, daemon reaches daemon.sh" {
  run bash "$AGMSG" storage list
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not an agmsg command"* ]]
  [[ "$output" == *"$TEST_SKILL_DIR/scripts"* ]]

  run bash "$AGMSG" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"reserved"* ]]

  # A published-elsewhere verb is not passed through to its script.
  run bash "$AGMSG" send x y z
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not an agmsg command"* ]]

  # daemon reaches daemon.sh with the arguments unchanged (its own usage text).
  run bash "$AGMSG" daemon bogus
  [[ "$output" == *"agmsg daemon start|stop|status|enable|disable"* ]]
}

@test "launcher: placed into the chosen dir, reaches the runtime, and uninstall removes only that" {
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"placed $BIN_DIR/agmsg"* ]]
  [[ "$output" == *"visible in this environment: no"* ]]
  [ -x "$BIN_DIR/agmsg" ]

  # The launcher, not a symlink, and it lands on the real scripts/agmsg.
  [ ! -L "$BIN_DIR/agmsg" ]
  run "$BIN_DIR/agmsg" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"reserved"* ]]

  # Second run is a no-op.
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"already in place"* ]]

  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"removed agmsg command"* ]]
  [ ! -e "$BIN_DIR/agmsg" ]
  [ -d "$BIN_DIR" ]
}

# The four kinds of thing already sitting at the target: nothing is broken,
# nothing is followed, and the message says why.
@test "launcher: a valid symlink, a broken symlink, a directory and a foreign file are all left alone" {
  local elsewhere="$BATS_TEST_TMPDIR/elsewhere"
  printf 'original\n' > "$elsewhere"

  ln -s "$elsewhere" "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"not placed"* && "$output" == *"symlink"* ]]
  [ -L "$BIN_DIR/agmsg" ]
  [ "$(cat "$elsewhere")" = "original" ]
  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ -L "$BIN_DIR/agmsg" ]

  rm -f "$BIN_DIR/agmsg"
  ln -s "$BATS_TEST_TMPDIR/does-not-exist" "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"symlink"* ]]
  [ -L "$BIN_DIR/agmsg" ]
  [ ! -e "$BATS_TEST_TMPDIR/does-not-exist" ]

  rm -f "$BIN_DIR/agmsg"
  mkdir "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"not an agmsg launcher"* ]]
  [ -d "$BIN_DIR/agmsg" ]

  rmdir "$BIN_DIR/agmsg"
  printf '#!/bin/sh\necho mine\n' > "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"not an agmsg launcher"* ]]
  [ "$(sed -n 2p "$BIN_DIR/agmsg")" = "echo mine" ]
}

@test "launcher: another install's launcher is not taken over, an edited one is not removed" {
  local other="$BATS_TEST_TMPDIR/other-install"
  mkdir -p "$other/scripts"
  bash -c 'source "$1"; agmsg_launcher_render "$2" > "$3"' _ "$LIB" "$other" "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"belongs to the install at $other"* ]]
  grep -q "$other" "$BIN_DIR/agmsg"
  # This install's uninstall must not remove the other install's launcher.
  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ -f "$BIN_DIR/agmsg" ]

  rm -f "$BIN_DIR/agmsg"
  bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR" >/dev/null
  printf '# edited\n' >> "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"edited"* ]]
  [ -f "$BIN_DIR/agmsg" ]
}

@test "launcher: a relative AGMSG_BIN_DIR is refused and nothing is written" {
  cd "$BATS_TEST_TMPDIR"
  run env AGMSG_BIN_DIR=relative/bin bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not an absolute path"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/relative" ]
}

@test "launcher: an older npm agmsg ahead on PATH is named and the update is offered" {
  local old="$BATS_TEST_TMPDIR/oldbin"
  mkdir -p "$old"
  printf '#!/usr/bin/env node\n// agmsg npm bootstrapper.\n' > "$old/agmsg"
  chmod +x "$old/agmsg"
  run env PATH="$old:$PATH" bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [[ "$output" == *"older npm agmsg"* ]]
  [[ "$output" == *"npm i -g agmsg@latest"* ]]
  # It is only reported; nothing of the old entry is touched.
  grep -q 'agmsg npm bootstrapper' "$old/agmsg"
}

@test "launcher: a failed removal keeps the record and reports failure" {
  bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR" >/dev/null
  [ -f "$TEST_SKILL_DIR/run/agmsg-launcher.path" ]
  run env AGMSG_LAUNCHER_RM=false bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ "$status" -ne 0 ]
  [ -f "$BIN_DIR/agmsg" ]
  [ -f "$TEST_SKILL_DIR/run/agmsg-launcher.path" ]
}
