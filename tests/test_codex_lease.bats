#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export RUN_DIR="$TEST_SKILL_DIR/run"
  mkdir -p "$RUN_DIR"
  source "$SCRIPTS/lib/codex-lease.sh"
}

teardown() {
  teardown_test_env
}

@test "codex lease: TUI generations have distinct paths" {
  local a b
  a="$(codex_tui_lease_path team alice thread-1 generation-a)"
  b="$(codex_tui_lease_path team alice thread-1 generation-b)"
  [ "$a" != "$b" ]
  [[ "$a" == *"codex-tui-lease.team.alice."*".generation-a" ]]
}

@test "codex lease: write uses format handshake and compare-delete" {
  local path
  path="$(codex_write_tui_lease team alice thread-1 generation-a "$TEST_SKILL_DIR/project" ws://127.0.0.1:1 $$)"
  [ -f "$path" ]
  [ "$(codex_lease_field "$path" format_version)" = "1" ]
  [ "$(codex_lease_field "$path" generation)" = "generation-a" ]

  codex_lease_compare_delete "$path" generation-b
  [ -f "$path" ]
  codex_lease_compare_delete "$path" generation-a
  [ ! -e "$path" ]
}

@test "codex lease: lifecycle lock serializes owners" {
  codex_lifecycle_lock_acquire project-hash
  [ -d "$(codex_appserver_lock_dir project-hash)" ]
  codex_lifecycle_lock_release project-hash
  [ ! -e "$(codex_appserver_lock_dir project-hash)" ]
}

@test "codex lease: app-server cleanup waits for the last immutable ref" {
  local record ref1 ref2
  record="$(codex_appserver_record_path project-hash)"
  codex_record_write_ready project-hash generation-a version msys 999999 1234
  ref1="$(codex_appserver_ref_add project-hash tui-one generation-a)"
  ref2="$(codex_appserver_ref_add project-hash tui-two generation-a)"

  codex_appserver_ref_remove_and_cleanup project-hash "$ref1" generation-a
  [ -f "$record" ]
  [ -f "$ref2" ]

  codex_appserver_ref_remove_and_cleanup project-hash "$ref2" generation-a
  [ ! -e "$record" ]
}

@test "codex lease: ref replacement publishes new before removing old" {
  local old new
  codex_record_write_ready project-hash generation-a version msys 999999 1234
  old="$(codex_appserver_ref_add project-hash old-ref generation-a)"
  new="$(codex_appserver_ref_replace project-hash "$old" new-ref generation-a)"
  [ ! -e "$old" ]
  [ -f "$new" ]
  [ "$(codex_lease_field "$new" generation)" = generation-a ]
}

@test "codex lease: ref replacement rejects a generation changed before lock acquisition" {
  local old
  codex_record_write_ready project-hash generation-b version msys 999999 1234
  old="$(codex_appserver_ref_add project-hash old-ref generation-a)"

  run codex_appserver_ref_replace project-hash "$old" new-ref generation-a
  [ "$status" -ne 0 ]
  [ -f "$old" ]
  [ ! -e "$(codex_appserver_refs_dir project-hash)/new-ref" ]
}
