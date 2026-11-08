#!/usr/bin/env bats

# Where an install keeps its run/, db/, teams/, ext-tools/ and .trash/:
# outside the skills directory (which Codex watches), with a link back. These
# run the real install.sh / uninstall.sh against a throwaway HOME.

load test_helper  # for refute
load state_root_reap

setup() {
  export FAKE_HOME="$(mktemp -d)"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SK="$FAKE_HOME/.agents/skills/agmsg"
  export ST="$FAKE_HOME/.agmsg/agmsg"
  unset CODEX_HOME AGMSG_HOME AGMSG_STORAGE_PATH AGMSG_CONFIG AGMSG_STORAGE_DRIVER AGMSG_APP_BASE AGMSG_SPAWN_OPTIONS_FILE
  export AGMSG_AGENT_PID=""
  # No systemd unit for any team, on any machine the suite runs on: a real
  # systemctl may be missing, answer or fail (no user bus) depending on the host.
  printf '#!/bin/sh\necho LoadState=not-found\n' > "$FAKE_HOME/systemctl"
  chmod +x "$FAKE_HOME/systemctl"
  export AGMSG_SYSTEMCTL="$FAKE_HOME/systemctl"
}

teardown() {
  # A test that pauses an update at the writer pid-publish gate or holds a lock
  # must never leave either behind when an assertion fails first: release the
  # gate, then end the background jobs the test started (tests/state_root_reap.bash:
  # only jobs of this shell, never a process found by pid) before the fixture is
  # removed. A job that will not end fails the test.
  local reaped=0
  if [ -n "${LEGACY_GATE:-}" ]; then touch "$LEGACY_GATE.release" 2>/dev/null || true; fi
  bg_reap_all || reaped=1
  [ -n "${FAKE_HOME:-}" ] && [ -d "$FAKE_HOME" ] && command rm -rf "$FAKE_HOME"
  [ "$reaped" -eq 0 ]
}

inst() { HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg "$@"; }
inst_cmd() { HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd "$@"; }

# Puts a fresh install back in the layout older releases used: real directories
# in the skills directory, no state root.
demote() {
  local p
  for p in run db teams ext-tools .trash; do
    command rm "$SK/$p"
    command mv "$ST/$p" "$SK/$p"
  done
  command rm "$ST/.owner"
  command rmdir "$ST"
  command rm -f "$SK/.agmsg" && : > "$SK/.agmsg"
}

@test "a fresh install keeps run, db, teams, ext-tools and .trash in the state root, linked from the skills directory" {
  inst
  local p
  for p in run db teams ext-tools .trash; do
    [ -L "$SK/$p" ]
    [ "$(readlink "$SK/$p")" = "$ST/$p" ]
    [ -d "$ST/$p" ]
  done
  [ -f "$ST/run/install.db" ]
  [ ! -e "$SK/run.real" ]
}

@test "AGMSG_HOME moves the base of the state roots" {
  AGMSG_HOME="$FAKE_HOME/elsewhere" inst
  [ "$(readlink "$SK/db")" = "$FAKE_HOME/elsewhere/agmsg/db" ]
  [ ! -e "$ST" ]
}

@test "an install in the old layout is moved by --update: data kept, links left, writes land in the state root" {
  inst
  demote
  mkdir -p "$SK/teams/t1" "$SK/db/teams"
  echo cfg > "$SK/teams/t1/config.json"
  echo row > "$SK/db/marker"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qF -- "moving the state of 'agmsg'" <<<"$output"
  [ -L "$SK/teams" ] && [ "$(readlink "$SK/teams")" = "$ST/teams" ]
  [ "$(cat "$ST/teams/t1/config.json")" = cfg ]
  [ "$(cat "$SK/db/marker")" = row ]
  echo new > "$SK/run/probe"
  [ -f "$ST/run/probe" ]
  [ ! -e "$SK/run/install.db.real" ]
}

@test "--update twice moves nothing the second time" {
  inst
  demote
  run inst --update
  [ "$status" -eq 0 ]
  run inst --update
  [ "$status" -eq 0 ]
  refute grep -qF -- "moving the state" <<<"$output"
}

@test "an update interrupted after moving a directory (no link) finishes on the next run" {
  inst
  demote
  mkdir -p "$ST"
  command mv "$SK/teams" "$ST/teams"
  echo kept > "$ST/teams/marker"
  run inst --update
  [ "$status" -eq 0 ]
  [ "$(readlink "$SK/teams")" = "$ST/teams" ]
  [ "$(cat "$SK/teams/marker")" = kept ]
}

@test "when both copies hold data nothing is moved, the refusal names the install and the reason, and the update still succeeds" {
  inst
  demote
  mkdir -p "$ST/teams/other"
  echo x > "$ST/teams/other/f"
  echo y > "$SK/teams/f"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qF -- "state of 'agmsg' stays in $SK" <<<"$output"
  grep -qF -- "both $SK/teams and $ST/teams hold data" <<<"$output"
  [ ! -L "$SK/teams" ]
  [ -f "$SK/teams/f" ] && [ -f "$ST/teams/other/f" ]
}

@test "a state root that cannot be written refuses with the reason and nothing moves" {
  inst
  demote
  command rmdir "$FAKE_HOME/.agmsg"
  : > "$FAKE_HOME/.agmsg"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qF -- "state of 'agmsg' stays in $SK" <<<"$output"
  [ ! -L "$SK/run" ]
  [ -f "$SK/run/install.db" ]
}

@test "Codex writable_roots name the real state directories" {
  mkdir -p "$FAKE_HOME/.codex"
  printf 'model = "m"\n' > "$FAKE_HOME/.codex/config.toml"
  inst
  grep -qF "$ST/db" "$FAKE_HOME/.codex/config.toml"
  grep -qF "$ST/teams" "$FAKE_HOME/.codex/config.toml"
  grep -qF "$ST/run" "$FAKE_HOME/.codex/config.toml"
  grep -qF "$ST/ext-tools" "$FAKE_HOME/.codex/config.toml"
  # the install operation lock lives in a real directory at the install root
  [ -d "$SK/.install-op" ] && [ ! -L "$SK/.install-op" ]
  grep -qF "$SK/.install-op" "$FAKE_HOME/.codex/config.toml"
}

@test "--update on the old layout writes the real state directories into Codex writable_roots" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  printf '[sandbox_workspace_write]\nwritable_roots = ["%s/db"]\n' "$SK" > "$FAKE_HOME/.codex/config.toml"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qF "$ST/run" "$FAKE_HOME/.codex/config.toml"
  grep -qF "$ST/teams" "$FAKE_HOME/.codex/config.toml"
  grep -qF "$SK/.install-op" "$FAKE_HOME/.codex/config.toml"
}

@test "--update on the old layout replaces the entries it wrote for the now-linked directories, and leaves every other entry alone" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex" "$FAKE_HOME/mine"
  cat > "$FAKE_HOME/.codex/config.toml" <<EOF
model = "m"
[sandbox_workspace_write]
writable_roots = [
  "$FAKE_HOME/mine",
  "$SK/db",
  "$SK/teams", "$SK/run",
  "$SK/ext-tools",
  "$FAKE_HOME/.agents/skills/other/db"
]
EOF
  cp "$FAKE_HOME/.codex/config.toml" "$BATS_TEST_TMPDIR/original.toml"
  run inst --update
  [ "$status" -eq 0 ]
  local cfg="$FAKE_HOME/.codex/config.toml" p
  # the backup is the file as it was before the update touched it
  cmp "$cfg.bak" "$BATS_TEST_TMPDIR/original.toml"
  # no writable root is, or contains, a link
  for p in $(grep -o '"[^"]*"' "$cfg" | tr -d '"' | grep '^/'); do
    [ ! -L "$p" ]
  done
  # the new entries carry the resolved spelling (/private/var for /var on macOS)
  local real
  real="$(cd -P "$ST" && pwd -P)"
  for p in db teams run ext-tools; do
    refute grep -qF "\"$SK/$p\"" "$cfg"
    grep -qF "\"$real/$p\"" "$cfg"
  done
  grep -qF "\"$SK/.install-op\"" "$cfg"
  # entries that are not this install's own stay
  grep -qF "\"$FAKE_HOME/mine\"" "$cfg"
  grep -qF "\"$FAKE_HOME/.agents/skills/other/db\"" "$cfg"
  grep -qF 'model = "m"' "$cfg"
  # a second update has nothing left to replace and changes nothing
  cp "$cfg" "$BATS_TEST_TMPDIR/before.toml"
  run inst --update
  [ "$status" -eq 0 ]
  cmp "$cfg" "$BATS_TEST_TMPDIR/before.toml"
}

@test "--update only edits the writable_roots array: comments, other keys and text after the array keep a stale path" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  cat > "$FAKE_HOME/.codex/config.toml" <<EOF
model = "$SK/db"
[sandbox_workspace_write]
writable_roots = ["$FAKE_HOME/mine", "$SK/db"] # was "$SK/run"
note = "$SK/teams"
# writable_roots = [
#   "$SK/ext-tools",
# ]
EOF
  run inst --update
  [ "$status" -eq 0 ]
  local cfg="$FAKE_HOME/.codex/config.toml"
  grep -qxF "model = \"$SK/db\"" "$cfg"
  grep -qxF "#   \"$SK/ext-tools\"," "$cfg"
  grep -qxF "note = \"$SK/teams\"" "$cfg"
  grep -qF "# was \"$SK/run\"" "$cfg"
  grep -qF "\"$FAKE_HOME/mine\"" "$cfg"
  # inside the array the stale entry is gone
  refute grep -qE 'writable_roots = \[[^]]*"'"$SK"'/db"' "$cfg"
}

@test "--update removes a stale element in any string spelling, and only whole elements: an escaped-quote path stays" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  local esc="\\u002F${SK#/}"
  cat > "$FAKE_HOME/.codex/config.toml" <<EOF
[sandbox_workspace_write]
writable_roots = ["$FAKE_HOME/mine/\\"$SK/db", "$SK/db", '$SK/teams', "$esc/run", """$SK/ext-tools""", "$FAKE_HOME/mine"]
EOF
  run inst --update
  [ "$status" -eq 0 ]
  local cfg="$FAKE_HOME/.codex/config.toml"
  # the same path in a literal string, an escaped spelling or a one-line
  # multi-line string is the same root: gone too, and what is left is byte for byte
  grep -qF "\"$FAKE_HOME/mine/\\\"$SK/db\", \"$FAKE_HOME/mine\"]" "$cfg"
  refute grep -qF "$SK/teams" "$cfg"
  refute grep -qF "$SK/ext-tools" "$cfg"
  refute grep -qF "u002F" "$cfg"
}

@test "--update removes an obsolete root written only as a literal string" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  cat > "$FAKE_HOME/.codex/config.toml" <<EOF
[sandbox_workspace_write]
writable_roots = ['$SK/db', "$FAKE_HOME/mine"]
EOF
  run inst --update
  [ "$status" -eq 0 ]
  local cfg="$FAKE_HOME/.codex/config.toml"
  refute grep -qF "$SK/db" "$cfg"
  grep -qF "\"$FAKE_HOME/mine\"]" "$cfg"
}

@test "--update removes an obsolete root written only with an escape" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  local esc="\\u002F${SK#/}"
  cat > "$FAKE_HOME/.codex/config.toml" <<EOF
[sandbox_workspace_write]
writable_roots = ["$esc/teams", "$FAKE_HOME/mine"]
EOF
  run inst --update
  [ "$status" -eq 0 ]
  local cfg="$FAKE_HOME/.codex/config.toml"
  refute grep -qF "u002F" "$cfg"
  grep -qF "\"$FAKE_HOME/mine\"]" "$cfg"
}

@test "--update leaves a config with nothing obsolete in it untouched by the cleanup" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  printf '[sandbox_workspace_write]\nwritable_roots = ["%s/mine"]\n' "$FAKE_HOME" > "$FAKE_HOME/.codex/config.toml"
  printf 'sentinel\n' > "$FAKE_HOME/.codex/config.toml.bak"
  run inst --update
  [ "$status" -eq 0 ]
  # the addition still takes its own backup of the untouched file; the cleanup took none
  refute grep -qF "replaced Codex writable_roots entries" <<<"$output"
}

# The removal on its own, without the addition that follows it in an update
# (which reads the file by lines and is changed separately).
drop_stale_alone() {   # <config.toml> <stale path> [path to add]
  run env STALE_PATH="$2" bash -c '
    SKILL_DIR=/fixture/skill
    . "$1/scripts/lib/codex-config.sh"
    eval "$(sed -n "/^_sync_codex_roots()/,/^}/p" "$1/install.sh")"
    agmsg_install_op_require() { return 0; }
    move_into_place() { mv "$1" "$2"; }
    agmsg_codex_stale_writable_paths() { echo "$STALE_PATH"; }
    _sync_codex_roots "$2" ${3:+"$3"}
  ' _ "$REPO_ROOT" "$1" "${3:-}"
}

@test "--update on a config with a writable_roots example inside a multi-line string: the note stays byte for byte, the real array gets the real roots" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  local cfg="$FAKE_HOME/.codex/config.toml" real
  cat > "$cfg" <<EOF
developer_instructions = """
Keep this note exactly: writable_roots = ["$SK/db"] was configured by hand.
"""

[sandbox_workspace_write]
writable_roots = ["$SK/db", "$SK/teams", "$SK/run", "$SK/ext-tools", "/unrelated/keep-me", '$SK/db']
EOF
  run inst --update
  [ "$status" -eq 0 ]
  real="$(cd -P "$ST" && pwd -P)"
  grep -qxF "Keep this note exactly: writable_roots = [\"$SK/db\"] was configured by hand." "$cfg"
  grep -qxF 'developer_instructions = """' "$cfg"
  local line
  line="$(grep '^writable_roots = ' "$cfg")"
  [ "$(grep -c '^writable_roots = ' "$cfg")" -eq 1 ]
  refute grep -qE ',[[:space:]]*\]$' <<<"$line"
  grep -qF '"/unrelated/keep-me"' <<<"$line"
  local p
  for p in db teams run ext-tools; do
    grep -qF "\"$real/$p\"" <<<"$line"
    refute grep -qF "$SK/$p" <<<"$line"
  done
  grep -qF "\"$SK/.install-op\"" <<<"$line"
  # the second update has nothing to change
  cp "$cfg" "$BATS_TEST_TMPDIR/before.toml"
  run inst --update
  [ "$status" -eq 0 ]
  cmp "$cfg" "$BATS_TEST_TMPDIR/before.toml"
}

@test "--update adds the roots under [sandbox_workspace_write] when the table has no writable_roots, and creates the table when it is missing" {
  inst
  mkdir -p "$FAKE_HOME/.codex"
  local cfg="$FAKE_HOME/.codex/config.toml" real
  real="$(cd -P "$ST" && pwd -P)"
  printf 'note = """\nwritable_roots = ["x"]\n"""\n[sandbox_workspace_write] # kept\nnetwork_access = true\n' > "$cfg"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qxF 'writable_roots = ["x"]' "$cfg"
  grep -qxF '[sandbox_workspace_write] # kept' "$cfg"
  grep -qxF 'network_access = true' "$cfg"
  [ "$(grep -c '^writable_roots = .*install-op' "$cfg")" -eq 1 ]
  grep -qF "\"$real/run\"" "$cfg"
  printf 'model = "m"\n' > "$cfg"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qxF '[sandbox_workspace_write]' "$cfg"
  grep -qF "\"$real/db\"" "$cfg"
  grep -qxF 'model = "m"' "$cfg"
}

@test "roots are added to [sandbox_workspace_write] only: a profile table's array is left alone and the table is created when missing" {
  local cfg="$BATS_TEST_TMPDIR/c.toml"
  cat > "$cfg" <<'EOF'
[profiles.review.sandbox_workspace_write]
writable_roots = ["/keep"]
EOF
  drop_stale_alone "$cfg" /fixture/skill/db /fixture/state/db
  [ "$status" -eq 0 ]
  [ "$(cat "$cfg")" = "$(printf '%s\n' \
    '[profiles.review.sandbox_workspace_write]' \
    'writable_roots = ["/keep"]' \
    '' \
    '[sandbox_workspace_write]' \
    'writable_roots = ["/fixture/state/db"]')" ]
}

@test "roots are added under an existing [sandbox_workspace_write] that has no writable_roots, whatever a profile table holds" {
  local cfg="$BATS_TEST_TMPDIR/c.toml"
  cat > "$cfg" <<'EOF'
[profiles.review.sandbox_workspace_write]
writable_roots = ["/keep"]
[sandbox_workspace_write]
network_access = true
EOF
  drop_stale_alone "$cfg" /fixture/skill/db /fixture/state/db
  [ "$status" -eq 0 ]
  [ "$(cat "$cfg")" = "$(printf '%s\n' \
    '[profiles.review.sandbox_workspace_write]' \
    'writable_roots = ["/keep"]' \
    '[sandbox_workspace_write]' \
    'writable_roots = ["/fixture/state/db"]' \
    'network_access = true')" ]
}

@test "the removal reads only the real array: writable_roots text inside a multi-line string elsewhere is kept byte for byte" {
  local cfg="$BATS_TEST_TMPDIR/c.toml"
  cat > "$cfg" <<'EOF'
developer_instructions = """
Keep this example literally:
writable_roots = ["/fixture/skill/db"]
"""
other = '''
writable_roots = ["/fixture/skill/db"]
'''
[sandbox_workspace_write]
writable_roots = ["/fixture/skill/db", "/mine"]
EOF
  drop_stale_alone "$cfg" /fixture/skill/db
  [ "$status" -eq 0 ]
  [ "$(cat "$cfg")" = "$(printf '%s\n' \
    'developer_instructions = """' \
    'Keep this example literally:' \
    'writable_roots = ["/fixture/skill/db"]' \
    '"""' \
    "other = '''" \
    'writable_roots = ["/fixture/skill/db"]' \
    "'''" \
    '[sandbox_workspace_write]' \
    'writable_roots = ["/mine"]')" ]
}

@test "the removal changes nothing when only text outside the array mentions the path" {
  local cfg="$BATS_TEST_TMPDIR/c.toml"
  cat > "$cfg" <<'EOF'
developer_instructions = """
writable_roots = ["/fixture/skill/db"]
"""
[sandbox_workspace_write]
writable_roots = ["/mine"]
EOF
  cp "$cfg" "$BATS_TEST_TMPDIR/before.toml"
  drop_stale_alone "$cfg" /fixture/skill/db
  [ "$status" -eq 0 ]
  cmp "$cfg" "$BATS_TEST_TMPDIR/before.toml"
  [ ! -e "$cfg.bak" ] && [ ! -e "$cfg.tmp" ]
}

@test "--update follows the TOML string rules across lines: a multi-line string is one value, not array elements" {
  inst
  demote
  mkdir -p "$FAKE_HOME/.codex"
  cat > "$FAKE_HOME/.codex/config.toml" <<EOF
[sandbox_workspace_write]
writable_roots = [
  """$FAKE_HOME/mine/
"$SK/db"
end""", "$SK/db", "$FAKE_HOME/mine2" # "$SK/teams"
]
note = "$SK/db"
EOF
  run inst --update
  [ "$status" -eq 0 ]
  local cfg="$FAKE_HOME/.codex/config.toml"
  # the line inside the multi-line string is untouched; the real element after it went
  grep -qxF "\"$SK/db\"" "$cfg"
  grep -qxF "end\"\"\", \"$FAKE_HOME/mine2\" # \"$SK/teams\"" "$cfg"
  grep -qxF "note = \"$SK/db\"" "$cfg"
}

@test "uninstall removes the state root too, and its Codex entries" {
  mkdir -p "$FAKE_HOME/.codex"
  printf 'model = "m"\n' > "$FAKE_HOME/.codex/config.toml"
  inst
  echo d > "$SK/db/keep-me-not"
  run env HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$ST/db" ] && [ ! -e "$ST/teams" ]
  # nothing of this install is left but the lock database, whose removal could
  # give a waiter a different lock from the next installer's: no link
  # (dangling or not), no state root
  [ ! -L "$SK/run" ]
  [ "$(ls -A "$SK")" = .install-op ]
  [ -f "$SK/.install-op/lock.db" ]
  # the state root keeps only the old-layout lock file of the run/ it had
  [ ! -e "$ST/db" ] && [ ! -e "$ST/teams" ] && [ ! -e "$ST/.owner" ]
  [ "$(cd "$ST" && find . -mindepth 1 | sort | grep -vE 'install-op.lock.db|^\./run$' | wc -l | tr -d ' ')" -eq 0 ]
  # the entries carry the resolved spelling (/private/var for /var on macOS)
  ! grep -q '/\.agmsg/agmsg' "$FAKE_HOME/.codex/config.toml"
}

@test "uninstall reads the config by the same TOML rules: a writable_roots example in a multi-line string is kept, and an install then uninstall restores the file byte for byte" {
  mkdir -p "$FAKE_HOME/.codex"
  local cfg="$FAKE_HOME/.codex/config.toml"
  cat > "$cfg" <<EOF
developer_instructions = """
Keep this note exactly: writable_roots = ["$SK/db"] was configured by hand.
"""

[sandbox_workspace_write]
writable_roots = ["/unrelated/keep-me"]
EOF
  cp "$cfg" "$BATS_TEST_TMPDIR/original.toml"
  inst
  grep -qF "$ST" "$cfg" || grep -qF "install-op" "$cfg"
  run env HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  cmp "$cfg" "$BATS_TEST_TMPDIR/original.toml"
}

# The uninstall side of the scanner on its own: prints the result for a config.
scan_uninstall() {   # <config.toml> <directory of the install>
  run env AGMSG_STALE_PREFIXES="$2" bash -c '
    . "$1/scripts/lib/codex-config.sh"
    agmsg_codex_roots_scan "$2"
  ' _ "$REPO_ROOT" "$1"
}

@test "uninstall takes only its own elements out: the emptied array and the table around it stay, whatever follows them" {
  local cfg="$BATS_TEST_TMPDIR/c.toml"
  printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = ["/fixture/skill/db"]' '' 'network_access = true' > "$cfg"
  scan_uninstall "$cfg" /fixture/skill
  [ "$status" -eq 11 ]
  [ "$output" = "$(printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = []' '' 'network_access = true')" ]
  printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = ["/fixture/skill/db"]' '' '[other]' 'a = 1' > "$cfg"
  scan_uninstall "$cfg" /fixture/skill
  [ "$output" = "$(printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = []' '' '[other]' 'a = 1')" ]
}

@test "uninstall keeps a multi-line element and any other content of the array byte for byte" {
  local cfg="$BATS_TEST_TMPDIR/c.toml"
  printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = [' '"/fixture/skill/db",' "'''" "/unrelated'''" ']' > "$cfg"
  scan_uninstall "$cfg" /fixture/skill
  [ "$status" -eq 11 ]
  [ "$output" = "$(printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = [' "'''" "/unrelated'''" ']')" ]
  printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = ["/fixture/skill/db", 7]' > "$cfg"
  scan_uninstall "$cfg" /fixture/skill
  [ "$output" = "$(printf '%s\n' '[sandbox_workspace_write]' 'writable_roots = [7]')" ]
}

@test "uninstall of a config that held only this install's roots leaves an empty list and the table, and keeps a multi-line example" {
  mkdir -p "$FAKE_HOME/.codex"
  local cfg="$FAKE_HOME/.codex/config.toml"
  printf 'developer_instructions = """\nKeep: writable_roots = ["x"]\n"""\n' > "$cfg"
  inst
  grep -qxF '[sandbox_workspace_write]' "$cfg"
  run env HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  grep -qxF 'Keep: writable_roots = ["x"]' "$cfg"
  grep -qxF '[sandbox_workspace_write]' "$cfg"
  grep -qxF 'writable_roots = []' "$cfg"
}

@test "uninstall --keep-data keeps the state and drops the backup copies" {
  inst
  echo d > "$SK/db/data"
  echo b > "$SK/.trash/old"
  run env HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes --keep-data
  [ "$status" -eq 0 ]
  [ -f "$ST/db/data" ]
  [ ! -e "$ST/.trash" ]
}

@test "remote.sh sync stop: a team with no engine is already stopped" {
  inst
  mkdir -p "$SK/teams/t1"
  run env HOME="$FAKE_HOME" bash "$SK/scripts/remote.sh" sync stop t1
  [ "$status" -eq 0 ]
  grep -qF -- "stopped" <<<"$output"
  run env HOME="$FAKE_HOME" bash "$SK/scripts/remote.sh" sync stop "../x"
  [ "$status" -ne 0 ]
}

@test "the marker records where the state is; a copy of an install is flagged and not given the original's state silently" {
  inst
  [ "$(sed -n 's/^skill=//p' "$SK/.agmsg")" = "$SK" ]
  [ "$(sed -n 's/^state=//p' "$SK/.agmsg")" = "$ST" ]
  # cp -R keeps the links, so the copy points at the original's state
  command cp -R "$SK" "$FAKE_HOME/.agents/skills/agmsg-copy"
  [ "$(readlink "$FAKE_HOME/.agents/skills/agmsg-copy/db")" = "$ST/db" ]
  run env HOME="$FAKE_HOME" bash "$FAKE_HOME/.agents/skills/agmsg-copy/scripts/doctor.sh"
  grep -qF -- "looks like a copy of $SK and shares its state" <<<"$output"
}

@test "a state root made for another install is never shared: the refusal names the owner, nothing moves" {
  inst
  # a second install whose name maps to the same root
  mkdir -p "$FAKE_HOME/.agents/skills/other"
  : > "$FAKE_HOME/.agents/skills/other/.agmsg"
  mkdir -p "$FAKE_HOME/.agents/skills/other/teams"
  source "$REPO_ROOT/scripts/lib/state-root.sh"
  run env HOME="$FAKE_HOME" bash -c "source '$REPO_ROOT/scripts/lib/state-root.sh'; agmsg_state_preflight '$FAKE_HOME/.agents/skills/other' '$ST'"
  [ "$status" -eq 1 ]
  grep -qF -- "state of 'other' stays in $FAKE_HOME/.agents/skills/other: $ST belongs to $SK" <<<"$output"
  [ -d "$FAKE_HOME/.agents/skills/other/teams" ] && [ ! -L "$FAKE_HOME/.agents/skills/other/teams" ]
}

@test "an install outside ~/.agents/skills gets its own name: directory name plus a hash of its path" {
  source "$REPO_ROOT/scripts/lib/state-root.sh"
  local a b
  a="$(agmsg_state_key "$FAKE_HOME/kit/agmsg" "$FAKE_HOME/.agents")"
  b="$(agmsg_state_key "$FAKE_HOME/other-kit/agmsg" "$FAKE_HOME/.agents")"
  printf '%s\n' "$a" | grep -Eq '^agmsg-[0-9a-f]{8}$'
  printf '%s\n' "$b" | grep -Eq '^agmsg-[0-9a-f]{8}$'
  [ "$a" != "$b" ]
  [ "$(agmsg_state_key "$FAKE_HOME/.agents/skills/agmsg" "$FAKE_HOME/.agents")" = agmsg ]
  [ "$(agmsg_state_key "$FAKE_HOME/kit/agmsg" "$FAKE_HOME/.agents")" = "$a" ]
}

@test "a state that stays in place is recorded in the marker and shown by doctor every time" {
  inst
  demote
  command rmdir "$FAKE_HOME/.agmsg"
  : > "$FAKE_HOME/.agmsg"
  run inst --update
  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^state=//p' "$SK/.agmsg")" = in-place ]
  sed -n 's/^reason=//p' "$SK/.agmsg" | grep -qF -- "cannot create or write"
  run env HOME="$FAKE_HOME" bash "$SK/scripts/doctor.sh"
  grep -qF -- "state of 'agmsg' stays in $SK: " <<<"$output"
  grep -qF -- "cannot create or write" <<<"$output"
}

@test "updating or uninstalling one install leaves a second install's state, links and Codex entries alone" {
  mkdir -p "$FAKE_HOME/.codex"
  printf 'model = "m"\n' > "$FAKE_HOME/.codex/config.toml"
  inst
  HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg-second
  echo mine > "$ST/db/mine"
  echo theirs > "$FAKE_HOME/.agmsg/agmsg-second/db/theirs"
  run inst --update
  [ "$status" -eq 0 ]
  run env HOME="$FAKE_HOME" bash "$FAKE_HOME/.agents/skills/agmsg-second/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_HOME/.agmsg/agmsg-second/db" ]
  [ -f "$ST/db/mine" ]
  [ "$(readlink "$SK/db")" = "$ST/db" ]
  grep -q '/\.agmsg/agmsg/db' "$FAKE_HOME/.codex/config.toml"
  ! grep -q '/\.agmsg/agmsg-second' "$FAKE_HOME/.codex/config.toml"
}

@test "a hand-made layout (links to the right root, no .owner, bare marker) is adopted: .owner and marker written, nothing moved or stopped" {
  inst
  command rm "$ST/.owner"
  : > "$SK/.agmsg"
  echo keep > "$ST/db/keepme"
  local before after
  before="$(ls -i "$ST/db/keepme")"
  run inst --update
  [ "$status" -eq 0 ]
  refute grep -qF -- "moving the state" <<<"$output"
  [ "$(cat "$ST/.owner")" = "$SK" ]
  [ "$(sed -n 's/^skill=//p' "$SK/.agmsg")" = "$SK" ]
  [ "$(sed -n 's/^state=//p' "$SK/.agmsg")" = "$ST" ]
  [ "$(ls -i "$ST/db/keepme")" = "$before" ]
  [ "$(readlink "$SK/db")" = "$ST/db" ]
}

@test "a hand-made layout whose root belongs to another existing install is refused, not adopted" {
  inst
  mkdir -p "$FAKE_HOME/.agents/skills/elsewhere"
  printf '%s\n' "$FAKE_HOME/.agents/skills/elsewhere" > "$ST/.owner"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qF -- "belongs to $FAKE_HOME/.agents/skills/elsewhere" <<<"$output"
  [ "$(cat "$ST/.owner")" = "$FAKE_HOME/.agents/skills/elsewhere" ]
}

@test "--cmd config is a stated install error; nothing is created" {
  run inst_cmd config
  [ "$status" -eq 1 ]
  grep -qF -- "'config' cannot be an install name" <<<"$output"
  [ ! -e "$FAKE_HOME/.agents/skills/config" ]
  [ ! -e "$FAKE_HOME/.agmsg/config" ]
}

@test "uninstalling a copy (cp -R keeps the links) removes its links only and leaves the original's state and run alone" {
  inst
  mkdir -p "$ST/teams/t"
  printf 'keep\n' > "$ST/teams/t/owner-data"
  printf 'keep\n' > "$ST/run/original-run-file"
  command cp -R "$SK" "$FAKE_HOME/.agents/skills/agmsg-copy"
  run env HOME="$FAKE_HOME" bash "$FAKE_HOME/.agents/skills/agmsg-copy/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  grep -qF -- "was linked into the state of $SK; this install now has its own" <<<"$output"
  [ -f "$ST/teams/t/owner-data" ]
  [ -f "$ST/run/original-run-file" ]
  [ -d "$ST/db" ]
  [ -L "$SK/db" ]
}

@test "uninstalling a copy with --keep-data leaves the original's state alone too" {
  inst
  printf 'keep\n' > "$ST/.trash/backup"
  command cp -R "$SK" "$FAKE_HOME/.agents/skills/agmsg-copy"
  run env HOME="$FAKE_HOME" bash "$FAKE_HOME/.agents/skills/agmsg-copy/uninstall.sh" --yes --keep-data
  [ "$status" -eq 0 ]
  [ -f "$ST/.trash/backup" ]
}

@test "updating a copy gives it its own state and leaves the original's backups, marker, owner and links alone" {
  inst
  printf 'keep\n' > "$ST/.trash/original-backup"
  printf 'keep\n' > "$ST/run/original-run-file"
  command cp -R "$SK" "$FAKE_HOME/.agents/skills/agmsg-copy"
  local before_marker before_owner
  before_marker="$(<"$SK/.agmsg")"
  before_owner="$(<"$ST/.owner")"
  run env HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --update --cmd agmsg-copy
  [ "$status" -eq 0 ]
  grep -qF -- "was linked into the state of $SK; this install now has its own" <<<"$output"
  [ "$(<"$SK/.agmsg")" = "$before_marker" ]
  [ "$(<"$ST/.owner")" = "$before_owner" ]
  [ -f "$ST/.trash/original-backup" ]
  [ -f "$ST/run/original-run-file" ]
  [ "$(readlink "$SK/run")" = "$ST/run" ]
  [ "$(readlink "$FAKE_HOME/.agents/skills/agmsg-copy/run")" = "$FAKE_HOME/.agmsg/agmsg-copy/run" ]
  [ "$(<"$FAKE_HOME/.agmsg/agmsg-copy/.owner")" = "$FAKE_HOME/.agents/skills/agmsg-copy" ]
}

@test "agmsgd state: only one 'none' row is stopped; unreadable, no row, several rows and other values are unknown" {
  eval "$(sed -n '/^agmsg_install_daemon_active() {/,/^}/p' "$REPO_ROOT/install.sh")"
  local s="$BATS_TEST_TMPDIR/s" rc
  mkdir -p "$s/run"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 1 ]
  sqlite3 "$s/run/install.db" "CREATE TABLE other(x);"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 1 ]
  sqlite3 "$s/run/install.db" "CREATE TABLE daemon_owner(state TEXT);"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 2 ]
  sqlite3 "$s/run/install.db" "INSERT INTO daemon_owner VALUES('none');"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 1 ]
  sqlite3 "$s/run/install.db" "INSERT INTO daemon_owner VALUES('none');"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 2 ]
  sqlite3 "$s/run/install.db" "DELETE FROM daemon_owner; INSERT INTO daemon_owner VALUES('weird');"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 2 ]
  sqlite3 "$s/run/install.db" "DELETE FROM daemon_owner; INSERT INTO daemon_owner VALUES('ready');"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 0 ]
  printf 'this is not a database\n' > "$s/run/install.db"
  rc=0; agmsg_install_daemon_active "$s" || rc=$?; [ "$rc" -eq 2 ]
}

@test "an unfinished install operation on record: the update refuses and nothing was moved" {
  inst
  demote
  printf '{}\n' > "$SK/run/install-op-incomplete.json"
  run inst --update
  [ "$status" -ne 0 ]
  grep -qF -- "incomplete-operation record blocks this install" <<<"$output"
  [ -d "$SK/run" ] && [ ! -L "$SK/run" ]
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  [ -z "$(ls -A "$ST" 2>/dev/null)" ]
}

# A process whose command line is what the engine check looks for, a direct job
# of this shell (so teardown reaps it). <mode> says what it does on TERM: leave
# (default), ignore it, or point the pidfile at the process in FAKE_ENGINE_SUCCESSOR
# (a job the test started beforehand, another engine or a foreign process) and
# leave. Nothing is forked from inside the trap.
fake_engine() {   # <team> [mode] -> sets ENGINE_PID, writes the pidfile
  cat > "$BATS_TEST_TMPDIR/node" <<'EOS'
#!/bin/sh
case "$FAKE_ENGINE_MODE" in
  ignore) trap '' TERM ;;
  successor) trap 'echo "$FAKE_ENGINE_SUCCESSOR" > "$FAKE_ENGINE_PIDFILE"; exit 0' TERM ;;
esac
while :; do sleep 1; done
EOS
  chmod +x "$BATS_TEST_TMPDIR/node"
  FAKE_ENGINE_MODE="${2:-}" FAKE_ENGINE_PIDFILE="$SK/run/remote-sync.$1.pid" FAKE_ENGINE_SUCCESSOR="${FAKE_ENGINE_SUCCESSOR:-}" \
    "$BATS_TEST_TMPDIR/node" "$SK/scripts/internal/remote-sync.mjs" run --team "$1" &
  ENGINE_PID=$!
  track_bg "$ENGINE_PID"
  printf '%s\n' "$ENGINE_PID" > "$SK/run/remote-sync.$1.pid"
  sleep 0.3
}

# remote.sh as an old install has it: no `sync stop` at all (releases up to 1.7.1
# have none), and `status --json` answers like the real one. The first answer (the
# update's snapshot) says the engine runs; a later one (asked before the stop) says
# <state after>, with <pid> when it runs.
stub_remote() {   # <engine_state after the first answer> [pid]
  rm -f "$BATS_TEST_TMPDIR/status-asked"
  mkdir -p "$SK/teams/t1"
  cat > "$SK/scripts/remote.sh" <<EOS
#!/usr/bin/env bash
case "\$1 \$2" in
  "status --json")
    if [ -e "$BATS_TEST_TMPDIR/status-asked" ]; then s=$1; p=${2:-null}; else s=running; p=${2:-null}; : > "$BATS_TEST_TMPDIR/status-asked"; fi
    echo "{\"local_team\":\"t1\",\"engine_state\":\"\$s\",\"engine_pid\":\$p}" ;;
  "sync restart") echo "\$3" >> "\$(dirname "\$0")/../restarted.txt" ;;
  *) echo "Usage: remote.sh sync start|restart <team>" >&2; exit 1 ;;
esac
EOS
}

@test "the installer stops a live sync engine itself (an installed remote.sh may have no 'sync stop'), and the state moves" {
  inst
  demote
  fake_engine t1
  stub_remote running "$ENGINE_PID"
  run inst --update
  [ "$status" -eq 0 ]
  refute grep -qF "could not be stopped" <<<"$output"
  [ "$(readlink "$SK/db")" = "$ST/db" ]
  run kill -0 "$ENGINE_PID"
  [ "$status" -ne 0 ]
  [ ! -e "$SK/run/down/state.json" ]
}

@test "an engine a supervisor owns keeps the state where it is, visibly, and the next update tries the move again" {
  inst
  demote
  fake_engine t1
  stub_remote running "$ENGINE_PID"
  printf '#!/bin/sh\necho LoadState=loaded\n' > "$BATS_TEST_TMPDIR/systemctl"
  chmod +x "$BATS_TEST_TMPDIR/systemctl"
  AGMSG_SYSTEMCTL="$BATS_TEST_TMPDIR/systemctl" run inst --update
  grep -qF -- "the sync engine for 't1' could not be stopped" <<<"$output"
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  [ -z "$(ls -A "$ST" 2>/dev/null)" ]
  [ "$(sed -n 's/^state=//p' "$SK/.agmsg")" = in-place ]
  kill -0 "$ENGINE_PID"
  # shown where a person looks, with the command that moves it
  [ -f "$SK/run/down/state.json" ]
  grep -qF "is still in $SK" "$SK/run/down/state.json"
  grep -qF "the next update tries the move again" "$SK/run/down/state.json"
  grep -qF "npx agmsg@latest install --update" "$SK/run/down/state.json"
  run bash "$SK/scripts/doctor.sh"
  grep -qF "state is degraded since" <<<"$output"
  # no unit any more: the next update stops the engine, moves, and clears the record
  stub_remote running "$ENGINE_PID"
  run inst --update
  [ "$status" -eq 0 ]
  [ "$(readlink "$SK/db")" = "$ST/db" ]
  [ ! -e "$SK/run/down/state.json" ]
  [ ! -e "$ST/run/down/state.json" ]
}

@test "an update does not move the state when the systemd probe fails, or when the pidfile is there and cannot be read; it says so and records it" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  inst
  demote
  stub_remote running
  printf '#!/bin/sh\necho "Failed to connect to bus: Permission denied" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/sc"
  chmod +x "$BATS_TEST_TMPDIR/sc"
  AGMSG_SYSTEMCTL="$BATS_TEST_TMPDIR/sc" run inst --update
  grep -qF -- "the sync engine for 't1' could not be stopped" <<<"$output"
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  [ -f "$SK/run/down/state.json" ]
  # a pidfile that is there but cannot be read
  printf '%s\n' "$$" > "$SK/run/remote-sync.t1.pid"
  chmod 000 "$SK/run/remote-sync.t1.pid"
  stub_remote running
  run inst --update
  chmod 600 "$SK/run/remote-sync.t1.pid"
  grep -qF -- "the sync engine for 't1' could not be stopped" <<<"$output"
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  [ -f "$SK/run/down/state.json" ]
}

@test "an engine that ignores TERM is KILLed once it is still the same engine" {
  inst
  demote
  fake_engine t1 ignore
  stub_remote running "$ENGINE_PID"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qF "stopped the sync engine for 't1' (pid $ENGINE_PID)" <<<"$output"
  [ "$(readlink "$SK/db")" = "$ST/db" ]
  run kill -0 "$ENGINE_PID"
  [ "$status" -ne 0 ]
}

@test "an engine that takes the place of the stopped one is left alone and the state stays where it is" {
  inst
  demote
  # the successor is another engine, started by the test and tracked
  fake_engine t1
  local successor=$ENGINE_PID
  FAKE_ENGINE_SUCCESSOR=$successor fake_engine t1 successor
  local first=$ENGINE_PID
  printf '%s\n' "$first" > "$SK/run/remote-sync.t1.pid"
  stub_remote running "$first"
  run inst --update
  grep -qF -- "the sync engine for 't1' could not be stopped" <<<"$output"
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  run kill -0 "$first"
  [ "$status" -ne 0 ]
}

@test "a foreign process the pidfile names after the stop is never signalled" {
  inst
  demote
  sleep 300 &
  local foreign=$!
  track_bg "$foreign"
  FAKE_ENGINE_SUCCESSOR=$foreign fake_engine t1 successor
  stub_remote running "$ENGINE_PID"
  run inst --update
  [ "$status" -eq 0 ]
  [ "$(readlink "$SK/db")" = "$ST/db" ]
  # still running: nothing was sent to it
  kill -0 "$foreign"
}

# The locked stop, with the machine mocked out: signals, liveness and the
# ownership answer are replaced so a pid that is reused, a supervisor that appears
# or an unreadable command line can be staged exactly.
stop_locked_with() {   # <ownership answers, one per call, "rc[:pid]" separated by spaces> -> sets SIGNALS, STOP_RC
  eval "$(sed -n '/^_agmsg_install_engine_stop_locked() {/,/^}/p' "$REPO_ROOT/install.sh")"
  OWNED_FILE="$BATS_TEST_TMPDIR/owned-answers"
  printf '%s\n' $1 > "$OWNED_FILE"
  SIGNALS=""
  # one answer per call; the calls run in command substitutions, so the queue is a file
  agmsg_install_engine_owned_pid() {
    local answer rest
    answer="$(sed -n 1p "$OWNED_FILE")"
    rest="$(sed 1d "$OWNED_FILE")"
    printf '%s\n' "$rest" > "$OWNED_FILE"
    case "$answer" in *:*) printf '%s\n' "${answer#*:}" ;; esac
    return "${answer%%:*}"
  }
  agmsg_install_pid_gone() { [ "${PID_GONE:-no}" = yes ]; }
  kill() { SIGNALS="$SIGNALS $*"; }
  sleep() { :; }
  STOP_RC=0
  _agmsg_install_engine_stop_locked "$BATS_TEST_TMPDIR/sk" t1 >/dev/null || STOP_RC=$?
}

# agmsg_install_engine_owned_pid against the real helpers, with the host's
# observations staged: "positively none" (1) is for evidence of absence only.
owned_pid_with() {   # sets OWNED_RC
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/lib/compat.sh"
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/lib/instance-id.sh"
  eval "$(sed -n '/^agmsg_install_engine_owned_pid() {/,/^}/p' "$REPO_ROOT/install.sh")"
  OWNED_RC=0
  agmsg_install_engine_owned_pid "$BATS_TEST_TMPDIR/sk" t1 >/dev/null 2>&1 || OWNED_RC=$?
}

@test "owned pid: a systemd probe that is there and fails, or answers nothing readable, is unknown; no systemctl at all is no unit" {
  mkdir -p "$BATS_TEST_TMPDIR/sk/run"
  printf '#!/bin/sh\necho "Failed to connect to bus: Permission denied" >&2\nexit 1\n' > "$BATS_TEST_TMPDIR/sc"
  chmod +x "$BATS_TEST_TMPDIR/sc"
  AGMSG_SYSTEMCTL="$BATS_TEST_TMPDIR/sc" owned_pid_with
  [ "$OWNED_RC" -eq 3 ]
  printf '#!/bin/sh\nexit 0\n' > "$BATS_TEST_TMPDIR/sc"
  AGMSG_SYSTEMCTL="$BATS_TEST_TMPDIR/sc" owned_pid_with
  [ "$OWNED_RC" -eq 3 ]
  printf '#!/bin/sh\necho LoadState=loaded\n' > "$BATS_TEST_TMPDIR/sc"
  AGMSG_SYSTEMCTL="$BATS_TEST_TMPDIR/sc" owned_pid_with
  [ "$OWNED_RC" -eq 2 ]
  AGMSG_SYSTEMCTL="$BATS_TEST_TMPDIR/none-such" owned_pid_with
  [ "$OWNED_RC" -eq 1 ]
}

@test "owned pid: an absent pidfile is no engine; one that is there and cannot be read is unknown" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  mkdir -p "$BATS_TEST_TMPDIR/sk/run"
  owned_pid_with
  [ "$OWNED_RC" -eq 1 ]
  printf '%s\n' "$$" > "$BATS_TEST_TMPDIR/sk/run/remote-sync.t1.pid"
  chmod 000 "$BATS_TEST_TMPDIR/sk/run/remote-sync.t1.pid"
  owned_pid_with
  chmod 600 "$BATS_TEST_TMPDIR/sk/run/remote-sync.t1.pid"
  [ "$OWNED_RC" -eq 3 ]
  # readable, naming a live process that is not the engine: positively none
  owned_pid_with
  [ "$OWNED_RC" -eq 1 ]
}

@test "locked stop: a pid that stops being the engine after TERM (reused) is never KILLed" {
  mkdir -p "$BATS_TEST_TMPDIR/sk/run"
  PID_GONE=no stop_locked_with "0:4242 0:4242 1"
  [ "$STOP_RC" -eq 1 ]
  [ "$SIGNALS" = " -TERM 4242" ]
}

@test "locked stop: an engine that cannot be inspected is not a stopped engine" {
  mkdir -p "$BATS_TEST_TMPDIR/sk/run"
  PID_GONE=no stop_locked_with "3"
  [ "$STOP_RC" -eq 1 ]
  [ -z "$SIGNALS" ]
}

@test "locked stop: nothing positively found afterwards (a supervisor, unknown, a new owner) keeps the state and the newer pidfile" {
  mkdir -p "$BATS_TEST_TMPDIR/sk/run"
  local after
  for after in 2 3 "0:5555"; do
    printf '5555\n' > "$BATS_TEST_TMPDIR/sk/run/remote-sync.t1.pid"
    PID_GONE=yes stop_locked_with "0:4242 0:4242 $after"
    [ "$STOP_RC" -eq 1 ]
    [ "$(cat "$BATS_TEST_TMPDIR/sk/run/remote-sync.t1.pid")" = 5555 ]
  done
  # positively no engine: stopped, and the pidfile that still names the old pid goes
  printf '4242\n' > "$BATS_TEST_TMPDIR/sk/run/remote-sync.t1.pid"
  PID_GONE=yes stop_locked_with "0:4242 0:4242 1"
  [ "$STOP_RC" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/sk/run/remote-sync.t1.pid" ]
}

@test "an engine that already stood down on its own is a stopped engine: the state moves" {
  inst
  demote
  stub_remote stale
  run inst --update
  [ "$status" -eq 0 ]
  refute grep -qF "could not be stopped" <<<"$output"
  [ "$(readlink "$SK/db")" = "$ST/db" ]
}

# tests/fixtures/remote-1.7.1.sh is scripts/remote.sh of the v1.7.1 tag, byte for
# byte: the installed script an update from that release meets. It has no
# 'sync stop' (cmd_sync knows start and restart only).
@test "against the remote.sh of release 1.7.1 (no 'sync stop'), a running engine is stopped by the installer, said so, and the state moves" {
  inst
  demote
  cp "$REPO_ROOT/tests/fixtures/remote-1.7.1.sh" "$SK/scripts/remote.sh"
  run grep -q 'cmd_sync_stop' "$SK/scripts/remote.sh"
  [ "$status" -ne 0 ]
  HOME="$FAKE_HOME" bash "$SK/scripts/join.sh" t1 alice claude-code /tmp/project-a >/dev/null
  python3 -I - "$SK/teams/t1/config.json" <<'EOS'
import json, sys
p = sys.argv[1]
c = json.load(open(p))
c["remote_binding"] = {"connected_at": "2026-01-01T00:00:00Z", "endpoint": "http://127.0.0.1:9", "state": "active"}
json.dump(c, open(p, "w"))
EOS
  fake_engine t1
  run env HOME="$FAKE_HOME" bash "$SK/scripts/remote.sh" status --json
  grep -Eq '"engine_state": ?"running"' <<<"$output"
  run inst --update
  [ "$status" -eq 0 ]
  grep -qF "stopped the sync engine for 't1' (pid $ENGINE_PID)" <<<"$output"
  refute grep -qF "could not be stopped" <<<"$output"
  [ "$(readlink "$SK/db")" = "$ST/db" ]
  run kill -0 "$ENGINE_PID"
  [ "$status" -ne 0 ]
}

@test "an update that leaves the state in place does not start agmsgd or the engines early: they come back once, after the completion record is written" {
  inst
  demote
  sqlite3 "$SK/run/install.db" "UPDATE daemon_intent SET desired = 'on';"
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  tar -C "$REPO_ROOT" --exclude=.git --exclude=node_modules --exclude=worktrees -cf - . | tar -C "$src" -xf -
  # a supervisor owns the engine: the move is given up. The installed (old)
  # scripts must not start anything now, against a record that is aside.
  fake_engine t1
  stub_remote running "$ENGINE_PID"
  printf '#!/bin/sh\necho LoadState=loaded\n' > "$BATS_TEST_TMPDIR/systemctl"
  chmod +x "$BATS_TEST_TMPDIR/systemctl"
  printf '#!/usr/bin/env bash\necho "early daemon $*" >> "%s/starts.txt"\n' "$BATS_TEST_TMPDIR" > "$SK/scripts/daemon.sh"
  chmod +x "$SK/scripts/daemon.sh"
  # the updated scripts
  printf '#!/usr/bin/env bash\nm=no; [ -f "%s/run/install-manifest.json" ] && m=yes\necho "daemon $* manifest=$m" >> "%s/starts.txt"\n' "$SK" "$BATS_TEST_TMPDIR" > "$src/scripts/daemon.sh"
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "status --json") echo %s ;; "sync restart") echo "restart $3" >> "%s/starts.txt" ;; esac\n' "'{\"local_team\":\"t1\",\"engine_state\":\"running\"}'" "$BATS_TEST_TMPDIR" > "$src/scripts/remote.sh"
  run env HOME="$FAKE_HOME" AGMSG_SYSTEMCTL="$BATS_TEST_TMPDIR/systemctl" bash "$src/install.sh" --cmd agmsg --update
  grep -qF -- "the sync engine for 't1' could not be stopped" <<<"$output"
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  [ "$(wc -l < "$BATS_TEST_TMPDIR/starts.txt" | tr -d ' ')" -eq 2 ]
  [ "$(sed -n 1p "$BATS_TEST_TMPDIR/starts.txt")" = "restart t1" ]
  case "$(sed -n 2p "$BATS_TEST_TMPDIR/starts.txt")" in
    "daemon start --only-if-op-gen "*" manifest=yes") ;;
    *) cat "$BATS_TEST_TMPDIR/starts.txt" >&2; false ;;
  esac
}

@test "the sync engine is started after the completion record is written and the lock is let go, once per team" {
  inst
  demote
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src"
  tar -C "$REPO_ROOT" --exclude=.git --exclude=node_modules --exclude=worktrees -cf - . | tar -C "$src" -xf -
  cat > "$src/scripts/remote.sh" <<EOS
#!/usr/bin/env bash
case "\$1 \$2" in
  "status --json") echo '{"local_team":"t1","engine_state":"running"}' ;;
  "sync stop") exit 0 ;;
  "sync restart")
    m=no; [ -f "$SK/run/install-manifest.json" ] && m=yes
    l=held; sqlite3 -cmd '.timeout 200' "$SK/.install-op/lock.db" 'SELECT count(*) FROM sqlite_master;' >/dev/null 2>&1 && l=free
    echo "restart \$3 manifest=\$m lock=\$l" >> "$BATS_TEST_TMPDIR/restarts.txt"
    ;;
esac
EOS
  # the installed (old) remote.sh answers the first status question
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "status --json" ] && echo %s\nexit 0\n' "'{\"local_team\":\"t1\",\"engine_state\":\"running\"}'" > "$SK/scripts/remote.sh"
  run env HOME="$FAKE_HOME" bash "$src/install.sh" --cmd agmsg --update
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/restarts.txt")" = "restart t1 manifest=yes lock=free" ]
}

@test "agmsg daemon start during an update says the update is running; otherwise it names the update command for the install's own channel" {
  inst
  # the record does not match install.db
  printf '{"install_id":"other","gen":1}\n' > "$SK/run/install-manifest.json"
  printf '1.7.1\n' > "$SK/VERSION"
  run env HOME="$FAKE_HOME" bash "$SK/scripts/daemon.sh" start
  grep -qF "Repair it with: npx agmsg@latest install --update, then try again." <<<"$output"
  refute grep -qF "agmsg@next" <<<"$output"
  printf '1.8.0-rc.1\n' > "$SK/VERSION"
  run env HOME="$FAKE_HOME" bash "$SK/scripts/daemon.sh" start
  grep -qF "Repair it with: npx agmsg@next install --update, then try again." <<<"$output"
  # an operation that is alive: not a repair
  sleep 60 &
  local op=$!; track_bg "$op"
  printf '{"operation":"install","actor_pid":%s,"state":"in_progress"}\n' "$op" > "$SK/run/install-op-incomplete.json"
  run env HOME="$FAKE_HOME" bash "$SK/scripts/daemon.sh" start
  grep -qF "another agmsg install or update is running; agmsgd will start when it finishes." <<<"$output"
  refute grep -qF "Repair it with" <<<"$output"
  # a record left by an operation that is gone is not "running"
  kill "$op"; wait "$op" 2>/dev/null || true
  run env HOME="$FAKE_HOME" bash "$SK/scripts/daemon.sh" start
  grep -qF "Repair it with" <<<"$output"
}

@test "while another operation holds the install lock the update moves nothing; it moves once the lock is released" {
  inst
  demote
  hold_lock "$SK/.install-op/lock.db" 9
  local holder=$HOLD_PID
  sleep 1
  inst --update > "$BATS_TEST_TMPDIR/update.out" 2>&1 &
  local updater=$!; track_bg "$updater"
  sleep 4
  # still waiting for the lock: the state is where it was
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  [ -z "$(ls -A "$ST" 2>/dev/null)" ]
  wait "$holder" || true
  wait "$updater"
  [ -L "$SK/db" ]
  [ "$(readlink "$SK/db")" = "$ST/db" ]
}

@test "the install lock lives in the install directory, which a move does not touch: it is the same file before and after" {
  inst
  [ -f "$SK/.install-op/lock.db" ]
  [ ! -L "$SK/.install-op/lock.db" ]
  local before after
  before="$(python3 -I -c 'import os,sys;print(os.stat(sys.argv[1]).st_ino)' "$SK/.install-op/lock.db")"
  demote
  run inst --update
  [ "$status" -eq 0 ]
  after="$(python3 -I -c 'import os,sys;print(os.stat(sys.argv[1]).st_ino)' "$SK/.install-op/lock.db")"
  [ "$before" = "$after" ]
  [ -L "$SK/run" ]
}

@test "an installer from an earlier release that holds run/install-op.lock.db serializes the whole update: nothing is written until it lets go" {
  inst
  demote
  : > "$SK/run/install-op.lock.db"
  printf 'sentinel\n' > "$SK/scripts/agmsg"
  hold_lock "$SK/run/install-op.lock.db" 7
  local holder=$HOLD_PID
  sleep 1
  inst --update > "$BATS_TEST_TMPDIR/update.out" 2>&1 &
  local updater=$!; track_bg "$updater"
  sleep 3
  # still waiting: the installed script was not replaced, the state not moved
  [ "$(<"$SK/scripts/agmsg")" = sentinel ]
  [ -d "$SK/run" ] && [ ! -L "$SK/run" ]
  wait "$holder" || true
  wait "$updater"
  [ "$(<"$SK/scripts/agmsg")" != sentinel ]
  [ -L "$SK/run" ]
}

@test "an earlier-release installer that holds the old lock past the wait stops the update with the stated reason and changes nothing" {
  inst
  demote
  : > "$SK/run/install-op.lock.db"
  printf 'sentinel\n' > "$SK/scripts/agmsg"
  hold_lock "$SK/run/install-op.lock.db" 12
  local holder=$HOLD_PID
  sleep 1
  # the 30 s wait, shortened for the test
  run env AGMSG_TEST_INSTALL_OP_LEGACY_WAIT_MS=1500 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --update
  wait "$holder" || true
  [ "$status" -ne 0 ]
  grep -qF -- "another agmsg install or update is running (it holds the old-layout lock $SK/run/install-op.lock.db); nothing was changed. Run this again after it finishes." <<<"$output"
  [ "$(<"$SK/scripts/agmsg")" = sentinel ]
  [ -d "$SK/run" ] && [ ! -L "$SK/run" ]
  # nothing else moved either: no state root, no marker content, no Codex config
  [ ! -e "$ST" ]
  [ ! -s "$SK/.agmsg" ]
  [ ! -e "$FAKE_HOME/.codex" ]
  grep -qF -- "nothing was changed" <<<"$output"
}

@test "an earlier-release installer that holds the old lock past the wait stops the uninstall with the stated reason and removes nothing" {
  inst
  demote
  : > "$SK/run/install-op.lock.db"
  printf 'sentinel\n' > "$SK/scripts/agmsg"
  hold_lock "$SK/run/install-op.lock.db" 12
  local holder=$HOLD_PID
  sleep 1
  run env AGMSG_TEST_INSTALL_OP_LEGACY_WAIT_MS=1500 HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes
  wait "$holder" || true
  [ "$status" -ne 0 ]
  grep -qF -- "another agmsg install or update is running (it holds the old-layout lock $SK/run/install-op.lock.db); nothing was changed. Run this again after it finishes." <<<"$output"
  [ "$(<"$SK/scripts/agmsg")" = sentinel ]
  [ -d "$SK/run" ] && [ ! -L "$SK/run" ]
  [ -d "$SK/db" ] && [ -d "$SK/teams" ]
}

@test "state_link: run/ recreated by an ordinary writer in the gap is folded in, never linked into, and nothing is lost" {
  inst
  demote
  printf 'old\n' > "$SK/run/old-file"
  (
    . "$REPO_ROOT/scripts/lib/state-root.sh"
    fired=""
    ln() { if [ -z "$fired" ]; then fired=1; mkdir -p "$SK/run"; printf 'new\n' > "$SK/run/new-file"; fi; command ln "$@"; }
    agmsg_state_link "$SK" "$ST"
  )
  [ -L "$SK/run" ]
  [ "$(readlink "$SK/run")" = "$ST/run" ]
  [ ! -e "$ST/run/run" ]
  [ "$(<"$ST/run/old-file")" = old ]
  [ "$(<"$ST/run/new-file")" = new ]
}

@test "state_link: a recreated run/ that collides with a moved name is left in place and reported, and no file is lost" {
  inst
  demote
  printf 'old\n' > "$SK/run/same"
  run bash -c '
    . "$1/scripts/lib/state-root.sh"
    fired=""
    ln() { if [ -z "$fired" ]; then fired=1; mkdir -p "$SK/run"; printf "new\n" > "$SK/run/same"; fi; command ln "$@"; }
    agmsg_state_link "$SK" "$ST"' _ "$REPO_ROOT"
  [ "$status" -ne 0 ]
  grep -qF -- "could not link it back" <<<"$output"
  [ "$(<"$ST/run/same")" = old ]
  [ "$(<"$SK/run/same")" = new ]
  [ ! -e "$SK/run/run" ]
}

@test "an earlier-release installer that arrives while the update is running is held out until the update ends" {
  inst
  demote
  : > "$SK/run/install-op.lock.db"
  local gate="$BATS_TEST_TMPDIR/gate" i
  LEGACY_GATE="$gate"
  AGMSG_TEST_INSTALL_OP_WRITER_PID_PUBLISH_GATE="$gate" inst --update > "$BATS_TEST_TMPDIR/update.out" 2>&1 &
  local updater=$!; track_bg "$updater"
  for ((i = 0; i < 1500; i++)); do
    [ -e "$gate.pid" ] && break
    kill -0 "$updater" 2>/dev/null || break
    sleep 0.1
  done
  [ -e "$gate.pid" ]
  # the update is paused in the middle of its writes; a legacy entrant cannot start
  run sqlite3 -cmd '.timeout 500' "$SK/run/install-op.lock.db" "BEGIN EXCLUSIVE; COMMIT;"
  [ "$status" -ne 0 ]
  touch "$gate.release"
  wait "$updater"
  run sqlite3 -cmd '.timeout 5000' "$SK/run/install-op.lock.db" "BEGIN EXCLUSIVE; COMMIT;"
  [ "$status" -eq 0 ]
}

# The shell's job table, kill, sleep and wait are stubbed here, so no real
# process is signalled or waited for.
reap_stubs() {
  CALLS="$BATS_TEST_TMPDIR/calls"
  : > "$CALLS"
  sleep() { :; }
  kill() { printf 'kill %s\n' "$*" >> "$CALLS"; }
  wait() { printf 'wait %s\n' "$1" >> "$CALLS"; }
}

# The real teardown runs after the test: it must see no stubs and no tracked pid.
reap_unstub() {
  unset -f jobs kill sleep wait
  TEST_BG=()
}

@test "teardown: a pid the job table does not list as running is never signalled" {
  reap_stubs
  jobs() { :; }
  track_bg 4242
  bg_reap_all
  ! grep -q '^kill' "$CALLS" || return 1
  grep -qx 'wait 4242' "$CALLS"
  reap_unstub
}

@test "teardown: a job that will not end is signalled TERM then KILL, reported, failed, and never waited for" {
  reap_stubs
  jobs() { printf '4242\n'; }
  track_bg 4242
  bg_reap_all 2> "$BATS_TEST_TMPDIR/err" && return 1
  grep -qx 'kill 4242' "$CALLS"
  grep -qx 'kill -KILL 4242' "$CALLS"
  ! grep -q '^wait' "$CALLS" || return 1
  grep -qF "background job 4242 is still running" "$BATS_TEST_TMPDIR/err"
  reap_unstub
}

@test "teardown: a job of this shell that outlives its wait is ended, and one that has finished is left alone" {
  sleep 30 &
  local job=$!
  track_bg "$job"
  bg_is_running_job "$job"
  sleep 0.1 &
  local short=$!
  track_bg "$short"
  bg_reap_all
  refute bg_is_running_job "$job"
  refute bg_is_running_job "$short"
}
