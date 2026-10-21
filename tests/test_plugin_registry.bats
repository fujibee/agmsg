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

# --- db/plugin-sources bases + ext-tools through the registry (#1594) ---------

# A minimal ext-tool at <base>/ext-tools/<name> whose handle prints <tag>.
mk_ext_tool() {
  local base="$1" name="$2" tag="${3:-$2}"
  local d="$base/ext-tools/$name"
  mkdir -p "$d"
  printf 'timeout=5\n' > "$d/tool.conf"
  printf '#!/usr/bin/env bash\necho %s\n' "$tag" > "$d/handle"
  chmod +x "$d/handle"
}

# Register <dir> as an installed plugin source.
add_source() {
  printf 'github/o/%s\to/%s@x\tabc123\t%s\t2026-10-21T00:00:00Z\n' "$1" "$1" "$2" \
    >> "$TEST_SKILL_DIR/db/plugin-sources"
}

bases() {
  bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_driver_bases"
}

@test "plugin-sources: each abs-dir is an external base between plugins/ and AGMSG_PLUGIN_DIRS" {
  add_source r1 "$TEST_SKILL_DIR/plugins/sources/github/o/r1/abc123"
  add_source r2 "$TEST_SKILL_DIR/plugins/sources/github/o/r2/def456"
  export AGMSG_PLUGIN_DIRS="/extra/one"
  run bases
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = "external	$TEST_SKILL_DIR/plugins" ]
  [ "$(printf '%s\n' "$output" | sed -n 3p)" = "external	$TEST_SKILL_DIR/plugins/sources/github/o/r1/abc123" ]
  [ "$(printf '%s\n' "$output" | sed -n 4p)" = "external	$TEST_SKILL_DIR/plugins/sources/github/o/r2/def456" ]
  [ "$(printf '%s\n' "$output" | sed -n 5p)" = "external	/extra/one" ]
}

@test "plugin-sources: without the file the bases are exactly the old ones" {
  run bases
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 2 ]
}

@test "plugin-sources: a type from a source dir is ignored until trusted, then resolves" {
  local sd="$TEST_SKILL_DIR/plugins/sources/github/o/r1/abc123"
  mk_ext_type "$sd" srctype
  add_source r1 "$sd"
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_dir srctype"
  [ "$status" -ne 0 ]
  bash "$SCRIPTS/plugin.sh" trust types/srctype
  run bash -c "source '$SCRIPTS/lib/type-registry.sh'; agmsg_type_dir srctype"
  [ "$status" -eq 0 ]
  [ "$output" = "$sd/types/srctype" ]
}

@test "plugin list: plugins/sources is not listed as an axis" {
  mkdir -p "$TEST_SKILL_DIR/plugins/sources/github/o/r1/abc123"
  run bash "$SCRIPTS/plugin.sh" list
  [ "$status" -eq 0 ]
  refute grep -q "sources" <<<"$output"
  refute grep -q "github" <<<"$output"
}

@test "plugin list: a driver inside a source dir is listed and trustable" {
  local sd="$TEST_SKILL_DIR/plugins/sources/github/o/r1/abc123"
  mk_ext_tool "$sd" srctool
  add_source r1 "$sd"
  run bash "$SCRIPTS/plugin.sh" list
  grep -q "ext-tools/srctool *UNTRUSTED" <<<"$output"
  bash "$SCRIPTS/plugin.sh" trust ext-tools/srctool
  run bash "$SCRIPTS/plugin.sh" list
  grep -q "ext-tools/srctool *trusted" <<<"$output"
}

@test "resolve-project: the type probe sees a type in a source dir" {
  local sd="$TEST_SKILL_DIR/plugins/sources/github/o/r1/abc123"
  mk_ext_type "$sd" srctype
  add_source r1 "$sd"
  run bash -c "SKILL_DIR='$TEST_SKILL_DIR'; source '$SCRIPTS/lib/resolve-project.sh'; _agmsg_type_external_candidate srctype"
  [ "$status" -eq 0 ]
  run bash -c "SKILL_DIR='$TEST_SKILL_DIR'; source '$SCRIPTS/lib/resolve-project.sh'; _agmsg_type_external_candidate nope"
  [ "$status" -ne 0 ]
}

@test "ext-tool dir: a built-in is always resolved, no trust needed" {
  mkdir -p "$SCRIPTS/drivers/ext-tools/bt"
  printf 'timeout=5\n' > "$SCRIPTS/drivers/ext-tools/bt/tool.conf"
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir bt"
  [ "$status" -eq 0 ]
  [ "$output" = "$SCRIPTS/drivers/ext-tools/bt" ]
}

@test "ext-tool dir: an untrusted external is ignored with the usual warning" {
  mk_ext_tool "$TEST_SKILL_DIR/plugins" xt
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir xt"
  [ "$status" -ne 0 ]
  grep -q "external plugin 'ext-tools/xt' found at .* but not trusted (ignored)" <<<"$output"
  grep -q "agmsg plugin trust ext-tools/xt" <<<"$output"
}

@test "ext-tool dir: a trusted external resolves, and wins over a built-in of the same name" {
  mkdir -p "$SCRIPTS/drivers/ext-tools/dup"
  printf 'timeout=5\n' > "$SCRIPTS/drivers/ext-tools/dup/tool.conf"
  local sd="$TEST_SKILL_DIR/plugins/sources/github/o/r1/abc123"
  mk_ext_tool "$sd" dup
  add_source r1 "$sd"
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir dup 2>/dev/null"
  [ "$output" = "$SCRIPTS/drivers/ext-tools/dup" ]
  bash "$SCRIPTS/plugin.sh" trust ext-tools/dup
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir dup"
  [ "$status" -eq 0 ]
  [ "$output" = "$sd/ext-tools/dup" ]
}

@test "ext-tool dir: a name that is not a plain path segment never resolves" {
  mk_ext_tool "$TEST_SKILL_DIR/plugins" ok
  for bad in '../ok' 'a/b' '.' '' 'a b'; do
    run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_dir \"\$1\"" _ "$bad"
    [ "$status" -ne 0 ]
  done
}

@test "ext-tool available: lists built-ins and trusted externals only" {
  mkdir -p "$SCRIPTS/drivers/ext-tools/bt"
  printf 'timeout=5\n' > "$SCRIPTS/drivers/ext-tools/bt/tool.conf"
  mk_ext_tool "$TEST_SKILL_DIR/plugins" trusted1
  mk_ext_tool "$TEST_SKILL_DIR/plugins" untrusted1
  bash "$SCRIPTS/plugin.sh" trust ext-tools/trusted1
  run bash -c "source '$SCRIPTS/lib/driver-registry.sh'; agmsg_ext_tool_available"
  grep -q "trusted1" <<<"$output"
  grep -q "bt" <<<"$output"
  refute grep -q "untrusted1" <<<"$output"
}

@test "ext-tool.sh: usage finds a trusted external tool and refuses an untrusted one" {
  mk_ext_tool "$TEST_SKILL_DIR/plugins" xt
  printf 'usage text\n' > "$TEST_SKILL_DIR/plugins/ext-tools/xt/USAGE.md"
  run bash "$SCRIPTS/ext-tool.sh" usage xt
  [ "$status" -ne 0 ]
  grep -q "Unknown ext-tool: 'xt'" <<<"$output"
  bash "$SCRIPTS/plugin.sh" trust ext-tools/xt
  run bash "$SCRIPTS/ext-tool.sh" usage xt
  [ "$status" -eq 0 ]
}
