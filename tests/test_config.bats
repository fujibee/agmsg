#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
}

teardown() {
  teardown_test_env
}

@test "config show: creates default config if none exists" {
  run bash "$SCRIPTS/config.sh" show
  [ "$status" -eq 0 ]
  [[ "$output" =~ "check_interval" ]]
  [ -f "$TEST_SKILL_DIR/db/config.yaml" ]
}

@test "config get: returns default value when no config" {
  run bash "$SCRIPTS/config.sh" get hook.check_interval 60
  [ "$status" -eq 0 ]
  [ "$output" = "60" ]
}

@test "config set: sets a value" {
  bash "$SCRIPTS/config.sh" set hook.check_interval 30
  run bash "$SCRIPTS/config.sh" get hook.check_interval
  [ "$status" -eq 0 ]
  [ "$output" = "30" ]
}

@test "config set: updates existing value" {
  bash "$SCRIPTS/config.sh" set hook.check_interval 30
  bash "$SCRIPTS/config.sh" set hook.check_interval 120
  run bash "$SCRIPTS/config.sh" get hook.check_interval
  [ "$output" = "120" ]
}

@test "config set: adds new section and key" {
  bash "$SCRIPTS/config.sh" show >/dev/null
  bash "$SCRIPTS/config.sh" set display.timestamp_format relative
  run bash "$SCRIPTS/config.sh" get display.timestamp_format
  [ "$output" = "relative" ]
}

@test "config get: returns default for missing key" {
  run bash "$SCRIPTS/config.sh" get nonexistent.key fallback
  [ "$output" = "fallback" ]
}
