#!/usr/bin/env bats

# scripts/lib/grok-config.sh -- [cli] use_leader editing for grok-build's
# agmsgd mode. Direct unit tests against the library, no delivery.sh
# involved. the review on #1979 (2026-11-15): TOML shapes this does not
# attempt to parse (quoted key/table, dotted key, inline table) must be
# detected and refused, never misread as "absent" and double-written; a
# write failure must never lose the ownership marker for a key that was,
# in fact, never actually removed, and vice versa.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  CFG="$TEST_SKILL_DIR/grokhome/config.toml"
  mkdir -p "$(dirname "$CFG")"
  source "$SKILL_DIR/scripts/lib/hash.sh"
  source "$SKILL_DIR/scripts/lib/grok-config.sh"
}
teardown() { teardown_test_env; }

@test "scan: a quoted table header is reported unsupported, not absent" {
  printf '["cli"]\nuse_leader = false\n' > "$CFG"
  run agmsg_grok_use_leader_scan "$CFG"
  [ "$output" = "unsupported	quoted_table_header" ]
}

@test "scan: a quoted key under a bare [cli] table is reported unsupported, not absent" {
  printf '[cli]\n"use_leader" = false\n' > "$CFG"
  run agmsg_grok_use_leader_scan "$CFG"
  [ "$output" = "unsupported	quoted_key" ]
}

@test "scan: a dotted key is reported unsupported, not absent" {
  printf 'cli.use_leader = false\n' > "$CFG"
  run agmsg_grok_use_leader_scan "$CFG"
  [ "$output" = "unsupported	dotted_key" ]
}

@test "scan: an inline table is reported unsupported, not absent" {
  printf 'cli = { use_leader = false, model = "grok-4" }\n' > "$CFG"
  run agmsg_grok_use_leader_scan "$CFG"
  [ "$output" = "unsupported	inline_table" ]
}

@test "enable: refuses on an unsupported shape, writes nothing, and reports why" {
  printf '["cli"]\nuse_leader = false\n' > "$CFG"
  local before; before="$(cat "$CFG")"
  run agmsg_grok_use_leader_enable "$SKILL_DIR" "$CFG"
  [ "$status" -ne 0 ]
  [ "$output" = "unsupported:quoted_table_header" ]
  [ "$(cat "$CFG")" = "$before" ]
  ! ls "$SKILL_DIR"/run/grok-config-owns-use-leader.* >/dev/null 2>&1
}

@test "disable: refuses on an unsupported shape, writes nothing, preserves the marker" {
  mkdir -p "$SKILL_DIR/run"
  printf 'table' > "$SKILL_DIR/run/grok-config-owns-use-leader.$(printf '%s' "$CFG" | agmsg_sha1)"
  printf 'cli.use_leader = true\n' > "$CFG"
  local before; before="$(cat "$CFG")"
  run agmsg_grok_use_leader_disable "$SKILL_DIR" "$CFG"
  [ "$status" -ne 0 ]
  [ "$output" = "unsupported:dotted_key" ]
  [ "$(cat "$CFG")" = "$before" ]
  [ -f "$SKILL_DIR/run/grok-config-owns-use-leader.$(printf '%s' "$CFG" | agmsg_sha1)" ]
}

@test "enable: a write failure (unwritable config directory) leaves no marker behind" {
  # Make the directory read-only so the final mv onto the real path fails,
  # after the marker has already been committed -- the marker must then be
  # rolled back, not left claiming ownership of a key that was never
  # actually written.
  mkdir -p "$(dirname "$CFG")"
  chmod 555 "$(dirname "$CFG")"
  _quiet_enable() { agmsg_grok_use_leader_enable "$@" 2>/dev/null; }
  run _quiet_enable "$SKILL_DIR" "$CFG"
  chmod 755 "$(dirname "$CFG")"
  [ "$status" -ne 0 ]
  [ "$output" = "write_failed" ]
  [ ! -f "$CFG" ]
  ! ls "$SKILL_DIR"/run/grok-config-owns-use-leader.* >/dev/null 2>&1
}

@test "disable: a write failure (unwritable config directory) preserves the marker for a retry" {
  agmsg_grok_use_leader_enable "$SKILL_DIR" "$CFG" >/dev/null
  local marker="$SKILL_DIR/run/grok-config-owns-use-leader.$(printf '%s' "$CFG" | agmsg_sha1)"
  [ -f "$marker" ]
  chmod 555 "$(dirname "$CFG")"
  _quiet_disable() { agmsg_grok_use_leader_disable "$@" 2>/dev/null; }
  run _quiet_disable "$SKILL_DIR" "$CFG"
  chmod 755 "$(dirname "$CFG")"
  [ "$status" -ne 0 ]
  [ "$output" = "write_failed" ]
  # The marker survives the failed attempt -- a later retry can still see
  # that this install owns the key, instead of losing that fact forever.
  [ -f "$marker" ]
  grep -qx "use_leader = true" "$CFG"
}

@test "disable: succeeds and removes the marker only after the config write actually lands" {
  agmsg_grok_use_leader_enable "$SKILL_DIR" "$CFG" >/dev/null
  local marker="$SKILL_DIR/run/grok-config-owns-use-leader.$(printf '%s' "$CFG" | agmsg_sha1)"
  [ -f "$marker" ]
  run agmsg_grok_use_leader_disable "$SKILL_DIR" "$CFG"
  [ "$status" -eq 0 ]
  [ "$output" = "removed" ]
  [ ! -f "$marker" ]
}

# review on #1979, finding (1): a failed scan (mktemp or awk, isolated so
# every OTHER mktemp/awk call in enable/disable's own config-writing path
# still works normally) must never read as "absent" or "not true" --
# the real bug was disable() reading a failed scan as "the user changed
# it", dropping the ownership marker and leaving use_leader = true
# orphaned in the config. Overriding mktemp/awk as shell functions scoped
# to one test only intercepts the SCAN's own call (matched by its
# mktemp template's distinct name), never enable/disable's own writes.

@test "enable: a scan whose own mktemp fails reports write_failed, writes nothing, creates no marker" {
  # The scan's own mktemp/awk only run when the config FILE exists (an
  # absent one short-circuits to "absent" before ever reaching them) --
  # an existing file is needed to exercise the failure path at all.
  printf '[other]\nfoo = 1\n' > "$CFG"
  local before; before="$(cat "$CFG")"
  mktemp() { case "$*" in *agmsg-grok-scan-awk*) return 1 ;; *) command mktemp "$@" ;; esac; }
  run agmsg_grok_use_leader_enable "$SKILL_DIR" "$CFG"
  [ "$status" -ne 0 ]
  [ "$output" = "write_failed" ]
  [ "$(cat "$CFG")" = "$before" ]
  ! ls "$SKILL_DIR"/run/grok-config-owns-use-leader.* >/dev/null 2>&1
}

@test "enable: a scan whose own awk invocation fails reports write_failed, writes nothing, creates no marker" {
  printf '[other]\nfoo = 1\n' > "$CFG"
  local before; before="$(cat "$CFG")"
  awk() { case "$*" in *agmsg-grok-scan-awk*) return 1 ;; *) command awk "$@" ;; esac; }
  run agmsg_grok_use_leader_enable "$SKILL_DIR" "$CFG"
  [ "$status" -ne 0 ]
  [ "$output" = "write_failed" ]
  [ "$(cat "$CFG")" = "$before" ]
  ! ls "$SKILL_DIR"/run/grok-config-owns-use-leader.* >/dev/null 2>&1
}

@test "disable: a scan whose own mktemp fails reports write_failed, config and marker both untouched (the real bug: this used to be left_user_owned + marker dropped)" {
  agmsg_grok_use_leader_enable "$SKILL_DIR" "$CFG" >/dev/null
  local marker="$SKILL_DIR/run/grok-config-owns-use-leader.$(printf '%s' "$CFG" | agmsg_sha1)"
  [ -f "$marker" ]
  mktemp() { case "$*" in *agmsg-grok-scan-awk*) return 1 ;; *) command mktemp "$@" ;; esac; }
  run agmsg_grok_use_leader_disable "$SKILL_DIR" "$CFG"
  [ "$status" -ne 0 ]
  [ "$output" = "write_failed" ]
  [ -f "$marker" ]
  grep -qx "use_leader = true" "$CFG"
}

@test "disable: a scan whose own awk invocation fails reports write_failed, config and marker both untouched" {
  agmsg_grok_use_leader_enable "$SKILL_DIR" "$CFG" >/dev/null
  local marker="$SKILL_DIR/run/grok-config-owns-use-leader.$(printf '%s' "$CFG" | agmsg_sha1)"
  [ -f "$marker" ]
  awk() { case "$*" in *agmsg-grok-scan-awk*) return 1 ;; *) command awk "$@" ;; esac; }
  run agmsg_grok_use_leader_disable "$SKILL_DIR" "$CFG"
  [ "$status" -ne 0 ]
  [ "$output" = "write_failed" ]
  [ -f "$marker" ]
  grep -qx "use_leader = true" "$CFG"
}
