#!/usr/bin/env bats

# Tests for scripts/lib/spawn-options.sh (#273): per-agent-type extra CLI
# args spawn.sh injects, configured via a YAML file (AGMSG_SPAWN_OPTIONS_FILE
# or the default ~/.agmsg/config/spawn_options.yaml).

load test_helper

setup() {
  setup_test_env
  # shellcheck disable=SC1090
  source "$TEST_SKILL_DIR/scripts/lib/spawn-options.sh"
}

teardown() { teardown_test_env; }

# --- agmsg_spawn_options_file ---

@test "spawn_options_file: defaults to ~/.agmsg/config/spawn_options.yaml under HOME" {
  unset AGMSG_SPAWN_OPTIONS_FILE
  [ "$(agmsg_spawn_options_file)" = "$HOME/.agmsg/config/spawn_options.yaml" ]
}

@test "spawn_options_file: AGMSG_SPAWN_OPTIONS_FILE overrides the default" {
  export AGMSG_SPAWN_OPTIONS_FILE="/tmp/custom-spawn-options.yaml"
  [ "$(agmsg_spawn_options_file)" = "/tmp/custom-spawn-options.yaml" ]
}

# --- agmsg_spawn_options_tokens ---

@test "spawn_options_tokens: missing file yields no tokens" {
  export AGMSG_SPAWN_OPTIONS_FILE="$TEST_SKILL_DIR/does-not-exist.yaml"
  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn_options_tokens: missing type section yields no tokens" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$file" <<'YAML'
codex:
  --sandbox: workspace-write
YAML
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "spawn_options_tokens: a string value expands to a two-token flag+value" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$file" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
YAML
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--permission-mode" ]
  [ "${lines[1]}" = "acceptEdits" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "spawn_options_tokens: a true value expands to a single flag-only token" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$file" <<'YAML'
claude-code:
  --dangerously-skip-permissions: true
YAML
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--dangerously-skip-permissions" ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "spawn_options_tokens: a false value is suppressed entirely" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$file" <<'YAML'
claude-code:
  --dangerously-skip-permissions: false
  --permission-mode: acceptEdits
YAML
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [[ "$output" != *"--dangerously-skip-permissions"* ]]
  [[ "$output" == *"--permission-mode"* ]]
}

@test "spawn_options_tokens: multiple keys under a section all emit, in order" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$file" <<'YAML'
codex:
  --sandbox: workspace-write
  --ask-for-approval: never
YAML
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens codex
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--sandbox" ]
  [ "${lines[1]}" = "workspace-write" ]
  [ "${lines[2]}" = "--ask-for-approval" ]
  [ "${lines[3]}" = "never" ]
}

@test "spawn_options_tokens: only the requested type's section is read" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$file" <<'YAML'
claude-code:
  --permission-mode: acceptEdits
codex:
  --sandbox: workspace-write
YAML
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens codex
  [ "$status" -eq 0 ]
  [[ "$output" != *"permission-mode"* ]]
  [[ "$output" == *"--sandbox"* ]]
  [[ "$output" == *"workspace-write"* ]]
}

@test "spawn_options_tokens: a value containing spaces stays a single token" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  cat > "$file" <<'YAML'
claude-code:
  --append-system-prompt: be extra careful with destructive commands
YAML
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--append-system-prompt" ]
  [ "${lines[1]}" = "be extra careful with destructive commands" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "spawn_options_tokens: empty file yields no tokens" {
  local file="$TEST_SKILL_DIR/spawn_options.yaml"
  : > "$file"
  export AGMSG_SPAWN_OPTIONS_FILE="$file"
  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- agmsg_spawn_options_sample_file / agmsg_ensure_spawn_options_sample ---

@test "spawn_options_sample_file: defaults to ~/.agmsg/config/spawn_options.yaml.sample under HOME" {
  unset AGMSG_SPAWN_OPTIONS_FILE
  [ "$(agmsg_spawn_options_sample_file)" = "$HOME/.agmsg/config/spawn_options.yaml.sample" ]
}

@test "spawn_options_sample_file: resolves beside AGMSG_SPAWN_OPTIONS_FILE when set" {
  export AGMSG_SPAWN_OPTIONS_FILE="/tmp/custom-dir/my_spawn_options.yaml"
  [ "$(agmsg_spawn_options_sample_file)" = "/tmp/custom-dir/spawn_options.yaml.sample" ]
}

@test "ensure_spawn_options_sample: creates sample under ~/.agmsg/config/ when AGMSG_SPAWN_OPTIONS_FILE is unset" {
  unset AGMSG_SPAWN_OPTIONS_FILE
  local src="$TEST_SKILL_DIR/scripts/spawn_options.yaml.sample"
  local dest="$HOME/.agmsg/config/spawn_options.yaml.sample"

  [ -f "$src" ]
  run agmsg_ensure_spawn_options_sample "$src"
  [ "$status" -eq 0 ]
  [ "$output" = "$dest" ]
  [ -f "$dest" ]
  [ ! -e "$HOME/.agmsg/config/spawn_options.yaml" ]
  # Must be LF-only (no CR bytes) so awk in spawn-options.sh parses tokens cleanly.
  run grep -n $'\r' "$dest"
  [ "$status" -eq 1 ]
}

@test "ensure_spawn_options_sample: creates sample beside AGMSG_SPAWN_OPTIONS_FILE and creates missing parent dirs" {
  local custom_dir="$BATS_TEST_TMPDIR/nested/custom-cfg"
  export AGMSG_SPAWN_OPTIONS_FILE="$custom_dir/spawn_options.yaml"
  local src="$TEST_SKILL_DIR/scripts/spawn_options.yaml.sample"
  local dest="$custom_dir/spawn_options.yaml.sample"

  run agmsg_ensure_spawn_options_sample "$src"
  [ "$status" -eq 0 ]
  [ "$output" = "$dest" ]
  [ -f "$dest" ]
  [ ! -e "$AGMSG_SPAWN_OPTIONS_FILE" ]
}

@test "ensure_spawn_options_sample: does not overwrite an existing sample file" {
  local custom_dir="$BATS_TEST_TMPDIR/keep-existing"
  mkdir -p "$custom_dir"
  export AGMSG_SPAWN_OPTIONS_FILE="$custom_dir/spawn_options.yaml"
  local dest="$custom_dir/spawn_options.yaml.sample"
  printf '# user kept sample\n' > "$dest"

  run agmsg_ensure_spawn_options_sample "$TEST_SKILL_DIR/scripts/spawn_options.yaml.sample"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$dest")" = "# user kept sample" ]
}

@test "shipped spawn_options.yaml.sample parses cleanly with expected balanced tokens" {
  export AGMSG_SPAWN_OPTIONS_FILE="$TEST_SKILL_DIR/scripts/spawn_options.yaml.sample"

  run agmsg_spawn_options_tokens codex
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--sandbox" ]
  [ "${lines[1]}" = "workspace-write" ]
  [ "${lines[2]}" = "--ask-for-approval" ]
  [ "${lines[3]}" = "on-request" ]
  [ "${lines[4]}" = "-c" ]
  [ "${lines[5]}" = "tui.disable_paste_burst=true" ]
  [ "${#lines[@]}" -eq 6 ]

  run agmsg_spawn_options_tokens claude-code
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--permission-mode" ]
  [ "${lines[1]}" = "acceptEdits" ]
  [ "${#lines[@]}" -eq 2 ]

  run agmsg_spawn_options_tokens antigravity
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "--mode" ]
  [ "${lines[1]}" = "accept-edits" ]
  [ "${#lines[@]}" -eq 2 ]

  run agmsg_spawn_options_tokens opencode
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
