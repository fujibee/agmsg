#!/usr/bin/env bats

# Where an install keeps its run/, db/, teams/, ext-tools/ and .trash/:
# outside the skills directory (which Codex watches), with a link back. These
# run the real install.sh / uninstall.sh against a throwaway HOME.

load test_helper  # for refute

setup() {
  export FAKE_HOME="$(mktemp -d)"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export SK="$FAKE_HOME/.agents/skills/agmsg"
  export ST="$FAKE_HOME/.agmsg/agmsg"
  unset CODEX_HOME AGMSG_HOME AGMSG_STORAGE_PATH AGMSG_CONFIG AGMSG_STORAGE_DRIVER AGMSG_APP_BASE AGMSG_SPAWN_OPTIONS_FILE
  export AGMSG_AGENT_PID=""
}

teardown() {
  [ -n "${FAKE_HOME:-}" ] && [ -d "$FAKE_HOME" ] && command rm -rf "$FAKE_HOME"
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
}

@test "uninstall removes the state root too, and its Codex entries" {
  mkdir -p "$FAKE_HOME/.codex"
  printf 'model = "m"\n' > "$FAKE_HOME/.codex/config.toml"
  inst
  echo d > "$SK/db/keep-me-not"
  run env HOME="$FAKE_HOME" bash "$SK/uninstall.sh" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$ST/db" ] && [ ! -e "$ST/teams" ]
  # the entries carry the resolved spelling (/private/var for /var on macOS)
  ! grep -q '/\.agmsg/agmsg' "$FAKE_HOME/.codex/config.toml"
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
  grep -qF -- "$ST belongs to $FAKE_HOME/.agents/skills/elsewhere" <<<"$output"
  [ "$(cat "$ST/.owner")" = "$FAKE_HOME/.agents/skills/elsewhere" ]
}

@test "--cmd config is a stated install error; nothing is created" {
  run inst_cmd config
  [ "$status" -eq 1 ]
  grep -qF -- "'config' cannot be an install name" <<<"$output"
  [ ! -e "$FAKE_HOME/.agents/skills/config" ]
  [ ! -e "$FAKE_HOME/.agmsg/config" ]
}
