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

# Background processes this test started, recorded as "pid|start time". Teardown
# signals one only while its pid still has that start time, so a pid that was
# reaped and then reused by something else is never touched.
TEST_BG=()
track_bg() {   # <pid>
  TEST_BG+=("$1|$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null)")
}

# "pid|start time" of <pid> and of everything below it, found while <pid> is
# still the verified owner.
bg_family() {   # <pid>
  local c
  printf '%s|%s\n' "$1" "$(LC_ALL=C ps -p "$1" -o lstart= 2>/dev/null)"
  for c in $(pgrep -P "$1" 2>/dev/null); do bg_family "$c"; done
}

# Ends the process in <record> if (and only if) it is still the recorded one:
# a polite wait, TERM, then KILL, each bounded.
bg_reap() {   # <pid|start time>
  local pid="${1%%|*}" started="${1#*|}" now i
  [ -n "$started" ] || return 0
  now="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)"
  [ "$now" = "$started" ] || return 0
  for ((i = 0; i < 10; i++)); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  kill "$pid" 2>/dev/null || true
  for ((i = 0; i < 15; i++)); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  now="$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null)"
  if [ "$now" = "$started" ]; then kill -KILL "$pid" 2>/dev/null || true; fi
  return 0
}

teardown() {
  # A test that pauses an update at the writer pid-publish gate or holds a lock
  # must never leave either behind when an assertion fails first: release the
  # gate, then end each background process the test started and what it started
  # in turn (lock helpers), verified by pid AND start time, before the fixture
  # is removed.
  local rec fam sub
  if [ -n "${LEGACY_GATE:-}" ]; then touch "$LEGACY_GATE.release" 2>/dev/null || true; fi
  for rec in ${TEST_BG[@]+"${TEST_BG[@]}"}; do
    [ "${rec#*|}" != "" ] || continue
    fam="$(bg_family "${rec%%|*}")"
    bg_reap "$rec"
    while IFS= read -r sub; do
      [ -n "$sub" ] && bg_reap "$sub"
    done <<< "$fam"
    wait "${rec%%|*}" 2>/dev/null || true
  done
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

@test "a sync engine that cannot be stopped keeps the state where it is, visibly, and the engine is started again" {
  inst
  demote
  cat > "$SK/scripts/remote.sh" <<'EOS'
#!/usr/bin/env bash
case "$1 $2" in
  "status --json") echo '{"local_team":"t1","engine_state":"running"}' ;;
  "sync stop") exit 1 ;;
  "sync restart") echo "$3" >> "$(dirname "$0")/../restarted.txt" ;;
esac
EOS
  run inst --update
  grep -qF -- "the sync engine for 't1' could not be stopped" <<<"$output"
  [ -d "$SK/db" ] && [ ! -L "$SK/db" ]
  [ -z "$(ls -A "$ST" 2>/dev/null)" ]
  [ "$(sed -n 's/^state=//p' "$SK/.agmsg")" = in-place ]
}

@test "while another operation holds the install lock the update moves nothing; it moves once the lock is released" {
  inst
  demote
  ( printf 'BEGIN EXCLUSIVE;\nSELECT 1;\n'; sleep 9 ) | sqlite3 "$SK/.install-op/lock.db" >/dev/null 2>&1 &
  local holder=$!; track_bg "$holder"
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
  ( printf 'BEGIN EXCLUSIVE;\nSELECT 1;\n'; sleep 7 ) | sqlite3 "$SK/run/install-op.lock.db" >/dev/null 2>&1 &
  local holder=$!; track_bg "$holder"
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

@test "an earlier-release installer that holds the old lock past the wait stops the update with a stated reason and changes nothing" {
  inst
  demote
  : > "$SK/run/install-op.lock.db"
  printf 'sentinel\n' > "$SK/scripts/agmsg"
  ( printf 'BEGIN EXCLUSIVE;\nSELECT 1;\n'; sleep 12 ) | sqlite3 "$SK/run/install-op.lock.db" >/dev/null 2>&1 &
  local holder=$!; track_bg "$holder"
  sleep 1
  # the 30 s wait, shortened for the test
  run env AGMSG_TEST_INSTALL_OP_LEGACY_WAIT_MS=1500 HOME="$FAKE_HOME" bash "$REPO_ROOT/install.sh" --cmd agmsg --update
  wait "$holder" || true
  [ "$status" -ne 0 ]
  grep -qF -- "an installer from an earlier release holds" <<<"$output"
  [ "$(<"$SK/scripts/agmsg")" = sentinel ]
  [ -d "$SK/run" ] && [ ! -L "$SK/run" ]
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
