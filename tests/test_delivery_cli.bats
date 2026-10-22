#!/usr/bin/env bats
# `agmsg delivery`: agmsgd (install-wide) and this project's delivery together.
# Isolated scripts and data; nothing is registered with a real service manager,
# and agmsgd is never enabled here.

setup() {
  export TEST_SKILL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/delivery-cli.XXXXXX")"
  TEST_SKILL_DIR="$(cd "$TEST_SKILL_DIR" && pwd -P)"
  cp -R "$BATS_TEST_DIRNAME/../scripts" "$TEST_SKILL_DIR/scripts"
  export SCRIPTS="$TEST_SKILL_DIR/scripts"
  mkdir -p "$TEST_SKILL_DIR/run" "$TEST_SKILL_DIR/db" "$TEST_SKILL_DIR/project"
  export AGMSG_CONFIG="$TEST_SKILL_DIR/config.json"
  export AGMSG_STORAGE_PATH="$TEST_SKILL_DIR/db"
  sqlite3 "$TEST_SKILL_DIR/run/install.db" < "$SCRIPTS/daemon/schema.sql"
  export PROJECT="$TEST_SKILL_DIR/project"
}

teardown() { rm -rf "$TEST_SKILL_DIR"; }

@test "delivery: the shell command is public and listed in help" {
  run bash "$SCRIPTS/agmsg" help
  grep -Fq "delivery" <<<"$output"
}

@test "delivery status: agmsgd on shows the install state and the project's fallback as monitor (legacy)" {
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on';"
  bash "$SCRIPTS/delivery.sh" set monitor claude-code "$PROJECT" >/dev/null
  run bash "$SCRIPTS/agmsg" delivery status --type claude-code --project "$PROJECT"
  [ "$status" -eq 0 ]
  grep -Fq "delivery: agmsgd (on) — notices are delivered directly" <<<"$output"
  grep -Fq "this project's fallback: monitor (legacy)" <<<"$output"
}

@test "delivery status: agmsgd off but available says how to turn it on; no arguments mean status" {
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$PROJECT" >/dev/null
  run bash "$SCRIPTS/agmsg" delivery --type claude-code --project "$PROJECT"
  grep -Fq "delivery: agmsgd (off) — available; turn it on with: agmsg delivery agmsgd" <<<"$output"
  grep -Fq "this project: turn" <<<"$output"
}

@test "delivery agmsgd: where daemon enable would refuse, it says why and changes nothing" {
  printf '{"storage":"jsonl"}\n' > "$AGMSG_CONFIG"
  bash "$SCRIPTS/delivery.sh" set turn claude-code "$PROJECT" >/dev/null
  run bash "$SCRIPTS/agmsg" delivery agmsgd --type claude-code --project "$PROJECT"
  [ "$status" -eq 1 ]
  grep -Fq "agmsgd is not available here" <<<"$output"
  [ "$(sqlite3 "$TEST_SKILL_DIR/run/install.db" 'SELECT desired FROM daemon_intent;')" != on ]
  run bash "$SCRIPTS/delivery.sh" status claude-code "$PROJECT"
  grep -Fq "mode: turn" <<<"$output"
}

@test "delivery agmsgd: with agmsgd already on it leaves the project on monitor and does not enable again" {
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on';"
  run bash "$SCRIPTS/agmsg" delivery agmsgd --type claude-code --project "$PROJECT"
  [ "$status" -eq 0 ]
  run bash "$SCRIPTS/delivery.sh" status claude-code "$PROJECT"
  grep -Fq "mode: monitor" <<<"$output"
}

@test "delivery <mode>: the other modes are exactly delivery.sh set, and an agmsgd that is on is noted" {
  sqlite3 "$TEST_SKILL_DIR/run/install.db" "UPDATE daemon_intent SET desired='on';"
  run bash "$SCRIPTS/agmsg" delivery turn --type claude-code --project "$PROJECT"
  [ "$status" -eq 0 ]
  grep -Fq "agmsgd is still on" <<<"$output"
  run bash "$SCRIPTS/delivery.sh" status claude-code "$PROJECT"
  grep -Fq "mode: turn" <<<"$output"
}

@test "delivery: an unknown value is refused" {
  run bash "$SCRIPTS/agmsg" delivery sometimes --type claude-code --project "$PROJECT"
  [ "$status" -eq 2 ]
}
