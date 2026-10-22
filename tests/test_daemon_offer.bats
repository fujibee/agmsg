#!/usr/bin/env bats
# `agmsg daemon offer <type>`: the read-only answer the delivery choice screen
# uses to decide whether to offer agmsgd. Isolated scripts and data; no real
# service is touched and nothing is enabled.

setup() {
  export TEST_SKILL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/daemon-offer.XXXXXX")"
  TEST_SKILL_DIR="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$TEST_SKILL_DIR/scripts"
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/db" "$TEST_SKILL_DIR/bin"
  export AGMSG_CONFIG="$TEST_SKILL_DIR/config.json"
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
}

teardown() { rm -rf "$TEST_SKILL_DIR"; }

@test "offer: a fresh install can enable agmsgd" {
  run bash "$SCRIPTS/daemon.sh" offer claude-code
  [ "$status" -eq 0 ]
  [ "$output" = "agmsgd=available" ]
  run bash "$SCRIPTS/daemon.sh" offer codex
  [ "$output" = "agmsgd=available" ]
}

@test "offer: it only reads; the intent stays off" {
  bash "$SCRIPTS/daemon.sh" offer claude-code >/dev/null
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" 'SELECT desired FROM daemon_intent;')" != on ]
}

@test "offer: agmsgd that is already on is reported as on, not offered again" {
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on';"
  run bash "$SCRIPTS/daemon.sh" offer claude-code
  [ "$output" = "agmsgd=on" ]
}

@test "offer: a non-sqlite storage is unavailable, with the reason" {
  printf '{"storage":"jsonl"}\n' > "$AGMSG_CONFIG"
  run bash "$SCRIPTS/daemon.sh" offer claude-code
  [ "$status" -eq 0 ]
  [[ "$output" == "agmsgd=unavailable reason="*sqlite* ]]
}

@test "offer: no usable Node is unavailable, with the reason" {
  printf '#!/bin/sh\nexit 1\n' > "$TEST_SKILL_DIR/bin/node"
  chmod +x "$TEST_SKILL_DIR/bin/node"
  run env PATH="$TEST_SKILL_DIR/bin:/usr/bin:/bin" bash "$SCRIPTS/daemon.sh" offer claude-code
  [[ "$output" == "agmsgd=unavailable reason="*Node* ]]
}

@test "offer: Linux without systemd user services is unavailable, with the reason" {
  printf '#!/bin/sh\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\necho Linux\n' > "$TEST_SKILL_DIR/bin/uname"
  printf '#!/bin/sh\nexit 1\n' > "$TEST_SKILL_DIR/bin/systemctl"
  chmod +x "$TEST_SKILL_DIR/bin/uname" "$TEST_SKILL_DIR/bin/systemctl"
  run env PATH="$TEST_SKILL_DIR/bin:$PATH" AGMSGD_SYSTEMCTL="$TEST_SKILL_DIR/bin/systemctl" bash "$SCRIPTS/daemon.sh" offer claude-code
  [[ "$output" == "agmsgd=unavailable reason="*systemd* ]]
}

@test "offer: a type agmsgd does not deliver to is not offered" {
  run bash "$SCRIPTS/daemon.sh" offer gemini
  [[ "$output" == "agmsgd=unavailable reason="* ]]
}
