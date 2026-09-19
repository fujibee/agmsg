#!/usr/bin/env bats

# External-plugin discovery + opt-in (trust) gating for the driver registry.
# External drivers run shell code with the user's privileges, so they are NEVER
# loaded unless explicitly trusted (`agmsg plugin trust`). These tests lock that
# contract for the "types" axis: ignored-until-trusted, later-wins override,
# path-pinned trust (no swap), the warning, and the plugin CLI.
#
# <root> for the registry is TEST_SKILL_DIR (driver-registry resolves up two from
# scripts/lib/), so the default external base is $TEST_SKILL_DIR/plugins and the
# trust allowlist is $TEST_SKILL_DIR/db/trusted-plugins.

load test_helper

setup() { setup_test_env; }
teardown() { teardown_test_env; }

# Make a minimal external 'types' driver at <base>/types/<name> with a distinctive
# hooks_file so overrides are observable.
mk_ext_type() {
  local base="$1" name="$2" hooks="${3:-.x/$2.json}"
  local d="$base/types/$name"
  mkdir -p "$d"
  printf 'name=%s\ntemplate=template.md\nhooks_file=%s\n' "$name" "$hooks" > "$d/type.conf"
  printf '# external template\n' > "$d/template.md"
}

known() {
  bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_known_types | sort -u" 2>/dev/null
}

@test "plugin: an external type under <root>/plugins is ignored until trusted" {
  mk_ext_type "$TEST_SKILL_DIR/plugins" foo
  run known
  refute grep -qx foo <<<"$output"
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_dir foo"
  [ "$status" -ne 0 ]
}

@test "plugin: an untrusted external type warns with the opt-in command" {
  mk_ext_type "$TEST_SKILL_DIR/plugins" bar
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_known_types >/dev/null"
  echo "$output" | grep -q "not trusted"
  echo "$output" | grep -q "agmsg plugin trust types/bar"
}

@test "plugin trust: makes an external type discoverable" {
  mk_ext_type "$TEST_SKILL_DIR/plugins" foo
  run bash "$SCRIPTS/plugin.sh" trust types/foo
  [ "$status" -eq 0 ]
  run known
  echo "$output" | grep -qx foo
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get foo hooks_file"
  [ "$output" = ".x/foo.json" ]
}

@test "plugin trust: a trusted external overrides a built-in (later-wins)" {
  # Built-in codex hooks_file is .codex/hooks.json; the trusted plugin shadows it.
  mk_ext_type "$TEST_SKILL_DIR/plugins" codex ".over/codex.json"
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex hooks_file"
  [ "$output" = ".codex/hooks.json" ]   # untrusted: built-in still wins
  bash "$SCRIPTS/plugin.sh" trust types/codex
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_get codex hooks_file"
  [ "$output" = ".over/codex.json" ]    # trusted: plugin overrides
}

@test "plugin: AGMSG_PLUGIN_DIRS supplies external types (when trusted)" {
  local ext="$TEST_SKILL_DIR/extra"
  mk_ext_type "$ext" baz
  run bash -c "export AGMSG_PLUGIN_DIRS='$ext'; source '$SCRIPTS/lib/type-registry.sh'; agmsg_known_types | sort -u"
  refute grep -qx baz <<<"$output"
  AGMSG_PLUGIN_DIRS="$ext" bash "$SCRIPTS/plugin.sh" trust types/baz
  run bash -c "export AGMSG_PLUGIN_DIRS='$ext'; source '$SCRIPTS/lib/type-registry.sh'; agmsg_known_types | sort -u"
  echo "$output" | grep -qx baz
}

@test "plugin: trust is path-pinned — a name trusted at a different path is not honored" {
  mk_ext_type "$TEST_SKILL_DIR/plugins" foo
  # Hand-write a trust entry pointing somewhere else; the real dir must stay ignored.
  mkdir -p "$TEST_SKILL_DIR/db"
  printf 'types/foo\t/some/other/path\n' > "$TEST_SKILL_DIR/db/trusted-plugins"
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_dir foo"
  [ "$status" -ne 0 ]
}

@test "plugin untrust: revokes a previously trusted external type" {
  mk_ext_type "$TEST_SKILL_DIR/plugins" foo
  bash "$SCRIPTS/plugin.sh" trust types/foo
  run known; echo "$output" | grep -qx foo
  bash "$SCRIPTS/plugin.sh" untrust types/foo
  run known; ! echo "$output" | grep -qx foo
}

@test "plugin trust: a bare ambiguous name errors and lists axis-qualified candidates" {
  mkdir -p "$TEST_SKILL_DIR/plugins/types/dup" "$TEST_SKILL_DIR/plugins/storage/dup"
  printf 'name=dup\n' > "$TEST_SKILL_DIR/plugins/types/dup/type.conf"
  printf 'name=dup\n' > "$TEST_SKILL_DIR/plugins/storage/dup/driver.conf"
  run bash "$SCRIPTS/plugin.sh" trust dup
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ambiguous"
  echo "$output" | grep -q "types/dup"
  echo "$output" | grep -q "storage/dup"
}

@test "plugin list: marks built-in, trusted, and UNTRUSTED states" {
  mk_ext_type "$TEST_SKILL_DIR/plugins" foo
  bash "$SCRIPTS/plugin.sh" trust types/foo
  mk_ext_type "$TEST_SKILL_DIR/plugins" qux
  run bash "$SCRIPTS/plugin.sh" list
  [ "$status" -eq 0 ]
  echo "$output" | grep -E "types/codex .*builtin"
  echo "$output" | grep -E "types/foo .*trusted"
  echo "$output" | grep -E "types/qux .*UNTRUSTED"
}
