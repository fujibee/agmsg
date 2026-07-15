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

@test "codex lease: failed replacement write preserves the previous ref" {
  local old
  codex_record_write_ready project-hash generation-a version msys 999999 1234
  old="$(codex_appserver_ref_add project-hash old-ref generation-a)"
  codex_lease_atomic_write() { cat >/dev/null; return 1; }

  run codex_appserver_ref_replace project-hash "$old" new-ref generation-a
  [ "$status" -ne 0 ]
  [ -f "$old" ]
  [ ! -e "$(codex_appserver_refs_dir project-hash)/new-ref" ]
}

@test "codex lease: provisional startup ref protects and then releases a pre-turn TUI" {
  local ref record
  record="$(codex_appserver_record_path project-hash)"
  codex_record_write_ready project-hash generation-a version msys 999999 1234

  ref="$(codex_appserver_ref_add_provisional \
    project-hash startup-generation-a generation-a tui-generation-a $$)"
  [ -f "$ref" ]
  [ "$(codex_lease_field "$ref" ref_kind)" = startup ]
  [ "$(codex_lease_field "$ref" lease_generation)" = tui-generation-a ]

  codex_appserver_ref_gc project-hash
  [ -f "$ref" ]
  codex_appserver_ref_remove_and_cleanup project-hash "$ref" generation-a
  [ ! -e "$record" ]
}

@test "codex lease: startup GC removes a provisional ref only after its owner is proven dead" {
  local ref
  codex_record_write_ready project-hash generation-a version msys 999999 1234
  ref="$(codex_appserver_ref_add_provisional \
    project-hash startup-dead generation-a tui-generation-dead 999999)"
  [ -f "$ref" ]

  codex_appserver_ref_gc project-hash
  [ ! -e "$ref" ]
}

@test "codex lease: startup ref GC removes only proved-dead new-format owners" {
  local refs dead live legacy
  refs="$(codex_appserver_refs_dir project-hash)"; mkdir -p "$refs"
  dead="$refs/dead"; live="$refs/live"; legacy="$refs/legacy"
  cat >"$dead" <<EOF
generation=server-generation
lease_name=codex-tui-lease.team.alice.thread.dead-generation
lease_generation=dead-generation
owner_msys_pid=999999
owner_winpid=
owner_creation=
updated_at=$(date +%s)
EOF
  cat >"$live" <<EOF
generation=server-generation
lease_name=codex-tui-lease.team.alice.thread.live-generation
lease_generation=live-generation
owner_msys_pid=$$
owner_winpid=
owner_creation=
updated_at=$(date +%s)
EOF
  printf 'generation=server-generation\nupdated_at=%s\n' "$(date +%s)" >"$legacy"

  codex_appserver_ref_gc project-hash

  [ ! -e "$dead" ]
  [ -f "$live" ]
  [ -f "$legacy" ]
}

@test "codex lease: startup ref GC retains a native owner when liveness is unknown" {
  local refs ref
  refs="$(codex_appserver_refs_dir project-hash)"; mkdir -p "$refs"
  ref="$refs/unknown"
  cat >"$ref" <<EOF
generation=server-generation
lease_name=codex-tui-lease.team.alice.thread.unknown-generation
lease_generation=unknown-generation
owner_msys_pid=
owner_winpid=424242
owner_creation=creation-token
updated_at=$(date +%s)
EOF
  compat_pid_state_native() { echo unknown; }

  codex_appserver_ref_gc project-hash

  [ -f "$ref" ]
}

@test "codex lease: last ref cleanup retains an app-server record with unknown PID domain" {
  local record ref
  record="$(codex_appserver_record_path project-hash)"
  codex_record_write_ready project-hash generation-a version unknown 424242 1234
  ref="$(codex_appserver_ref_add project-hash tui-one generation-a)"

  codex_appserver_ref_remove_and_cleanup project-hash "$ref" generation-a

  [ -f "$record" ]
}
