#!/usr/bin/env bats

# Install smoke tests. These run the real install.sh against a throwaway HOME so
# the packaged artifact (not a hand-built tree like test_helper builds) is what
# gets validated. Catches packaging drift — e.g. a new scripts/lib/ helper that
# the installer forgets to copy, which would make every command die at `source`.

setup() {
  export FAKE_HOME="$(mktemp -d)"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SK="$FAKE_HOME/.agents/skills/agmsg"
}

teardown() {
  rm -rf "$FAKE_HOME"
}

@test "install: fresh install ships scripts/lib and the commands actually run" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  [ -f "$SK/scripts/lib/storage.sh" ]

  # End-to-end through the installed scripts — a missing sourced helper would
  # surface here, not just as a stat on a file.
  bash "$SK/scripts/join.sh" demo alice claude-code /tmp/install-projA
  bash "$SK/scripts/join.sh" demo bob   claude-code /tmp/install-projB
  run bash "$SK/scripts/send.sh" demo alice bob "hello from install"
  [ "$status" -eq 0 ]
  run bash "$SK/scripts/inbox.sh" demo bob
  [ "$status" -eq 0 ]
  [[ "$output" =~ "hello from install" ]]
}

@test "install: --update restores scripts/lib even if it went missing" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  rm -rf "$SK/scripts/lib"
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update
  [ -f "$SK/scripts/lib/storage.sh" ]
  run bash "$SK/scripts/send.sh" demo alice bob "after update"
  [ "$status" -eq 0 ]
}

@test "install: AGMSG_STORAGE_PATH override works against the installed skill" {
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg
  local store="$FAKE_HOME/override-store"
  AGMSG_STORAGE_PATH="$store" bash "$SK/scripts/send.sh" demo alice bob "via override"
  [ -f "$store/messages.db" ]
  run bash -c "AGMSG_STORAGE_PATH='$store' bash '$SK/scripts/inbox.sh' demo bob"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "via override" ]]
}
