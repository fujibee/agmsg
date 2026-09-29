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
  grep -Fq -- "is not an agmsg command" <<<"$output"
  grep -Fq -- "$TEST_SKILL_DIR/scripts" <<<"$output"

  run bash "$AGMSG" doctor
  [ "$status" -eq 2 ]
  grep -Fq -- "reserved" <<<"$output"

  # A published-elsewhere verb is not passed through to its script.
  run bash "$AGMSG" send x y z
  [ "$status" -eq 2 ]
  grep -Fq -- "is not an agmsg command" <<<"$output"

  # daemon reaches daemon.sh with the arguments unchanged (its own usage text).
  run bash "$AGMSG" daemon bogus
  grep -Fq -- "agmsg daemon start|stop|status|enable|disable" <<<"$output"
}

@test "launcher: placed into the chosen dir, reaches the runtime, and uninstall removes only that" {
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  grep -Fq -- "placed $BIN_DIR/agmsg" <<<"$output"
  grep -Fq -- "visible in this environment: no" <<<"$output"
  [ -x "$BIN_DIR/agmsg" ]

  # The launcher, not a symlink, and it lands on the real scripts/agmsg.
  [ ! -L "$BIN_DIR/agmsg" ]
  run "$BIN_DIR/agmsg" doctor
  [ "$status" -eq 2 ]
  grep -Fq -- "reserved" <<<"$output"

  # Second run is a no-op.
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "already in place" <<<"$output"

  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "removed agmsg command" <<<"$output"
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
  grep -Fq -- "not placed" <<<"$output"
  grep -Fq -- "symlink" <<<"$output"
  [ -L "$BIN_DIR/agmsg" ]
  [ "$(cat "$elsewhere")" = "original" ]
  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ -L "$BIN_DIR/agmsg" ]

  rm -f "$BIN_DIR/agmsg"
  ln -s "$BATS_TEST_TMPDIR/does-not-exist" "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "symlink" <<<"$output"
  [ -L "$BIN_DIR/agmsg" ]
  [ ! -e "$BATS_TEST_TMPDIR/does-not-exist" ]

  rm -f "$BIN_DIR/agmsg"
  mkdir "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "not an agmsg launcher" <<<"$output"
  [ -d "$BIN_DIR/agmsg" ]

  rmdir "$BIN_DIR/agmsg"
  printf '#!/bin/sh\necho mine\n' > "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "not an agmsg launcher" <<<"$output"
  [ "$(sed -n 2p "$BIN_DIR/agmsg")" = "echo mine" ]
}

@test "launcher: another install's launcher is not taken over, an edited one is not removed" {
  local other="$BATS_TEST_TMPDIR/other-install"
  mkdir -p "$other/scripts"
  bash -c 'source "$1"; agmsg_launcher_render "$2" > "$3"' _ "$LIB" "$other" "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "belongs to the install at $other" <<<"$output"
  grep -q "$other" "$BIN_DIR/agmsg"
  # This install's uninstall must not remove the other install's launcher.
  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ -f "$BIN_DIR/agmsg" ]

  rm -f "$BIN_DIR/agmsg"
  bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR" >/dev/null
  printf '# edited\n' >> "$BIN_DIR/agmsg"
  run bash -c 'source "$1"; agmsg_launcher_uninstall "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "edited" <<<"$output"
  [ -f "$BIN_DIR/agmsg" ]
}

@test "launcher: a relative AGMSG_BIN_DIR is refused and nothing is written" {
  cd "$BATS_TEST_TMPDIR"
  run env AGMSG_BIN_DIR=relative/bin bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  [ "$status" -eq 0 ]
  grep -Fq -- "not an absolute path" <<<"$output"
  [ ! -e "$BATS_TEST_TMPDIR/relative" ]
}

@test "launcher: an older npm agmsg ahead on PATH is named and the update is offered" {
  local old="$BATS_TEST_TMPDIR/oldbin"
  mkdir -p "$old"
  printf '#!/usr/bin/env node\n// agmsg npm bootstrapper.\n' > "$old/agmsg"
  chmod +x "$old/agmsg"
  # A newer entry sits first on PATH (as during an npx install); the older
  # global one behind it must still be found.
  local newer="$BATS_TEST_TMPDIR/newerbin"
  mkdir -p "$newer"
  printf '#!/usr/bin/env node\n// agmsg npm entry.\n' > "$newer/agmsg"
  chmod +x "$newer/agmsg"
  run env PATH="$newer:$old:$BIN_DIR:$PATH" bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "older npm agmsg" <<<"$output"
  grep -Fq -- "npm i -g agmsg@latest" <<<"$output"
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

@test "launcher: an older npm agmsg behind a Windows-style wrapper is recognised through the JS it names" {
  local wrap="$BATS_TEST_TMPDIR/npmwrap"
  mkdir -p "$wrap/node_modules/agmsg/bin"
  printf '// agmsg npm bootstrapper.\n' > "$wrap/node_modules/agmsg/bin/agmsg.js"
  printf '#!/bin/sh\nexec node "$basedir/node_modules/agmsg/bin/agmsg.js" "$@"\n' > "$wrap/agmsg"
  chmod +x "$wrap/agmsg"
  run env PATH="$wrap:$BIN_DIR:$PATH" bash -c 'source "$1"; agmsg_launcher_install "$2"' _ "$LIB" "$TEST_SKILL_DIR"
  grep -Fq -- "older npm agmsg" <<<"$output"
}
