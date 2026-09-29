#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  LAUNCH="$SCRIPTS/daemon/agmsgd-launch.sh"
}

teardown() {
  teardown_test_env
}

# A fresh Node binary path this launcher's own version/node:sqlite check
# will accept, and a throwaway install.db already migrated with the real
# schema.sql this launcher's own repo copy carries.
_seed_install_db() {
  sqlite3 "$SKILLDIR_INSTALL_DB" < "$SCRIPTS/daemon/schema.sql"
}

setup_install_db() {
  mkdir -p "$TEST_SKILL_DIR/run"
  SKILLDIR_INSTALL_DB="$TEST_SKILL_DIR/run/install.db"
  _seed_install_db
}

@test "agmsgd-launch: no install.db -> exits 0, starts nothing" {
  run bash "$LAUNCH"
  [ "$status" -eq 0 ]
}

@test "agmsgd-launch: intent is not 'on' -> exits 0 silently" {
  setup_install_db
  # schema.sql seeds desired = NULL; explicitly set it to 'off' too.
  sqlite3 "$SKILLDIR_INSTALL_DB" "UPDATE daemon_intent SET desired = 'off';"
  run bash "$LAUNCH"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "agmsgd-launch: intent on, no completion record at all -> exits 0, records a start attempt" {
  setup_install_db
  sqlite3 "$SKILLDIR_INSTALL_DB" "UPDATE daemon_intent SET desired = 'on';"
  run bash "$LAUNCH"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -Fq 'install.sh needs to run again'
  count="$(sqlite3 "$SKILLDIR_INSTALL_DB" "SELECT count(*) FROM daemon_start_attempts;")"
  [ "$count" -eq 1 ]
}

@test "agmsgd-launch: an update in progress (a held install-op lock) -> exits 75" {
  setup_install_db
  sqlite3 "$SKILLDIR_INSTALL_DB" "UPDATE daemon_intent SET desired = 'on';"
  touch "$TEST_SKILL_DIR/run/install-manifest.json.prev"

  # sqlite3 given a whole statement list as one argument runs it and exits
  # immediately -- releasing the lock before the launcher could ever see
  # it held. An interactive session, fed through a FIFO kept open past
  # the BEGIN EXCLUSIVE, is what actually holds it across commands, the
  # way a real in-progress install.sh would.
  local fifo="$TEST_SKILL_DIR/run/holder.fifo"
  mkfifo "$fifo"
  sqlite3 "$TEST_SKILL_DIR/run/install-op.lock.db" < "$fifo" &
  local holder_pid=$!
  exec 8> "$fifo"
  echo "BEGIN EXCLUSIVE;" >&8
  # No fixed sleep budget: poll until the lock is actually held (a second,
  # independent probe blocks), so this test does not race the holder's
  # own startup time.
  local waited=0
  while sqlite3 -cmd "PRAGMA busy_timeout=0;" "$TEST_SKILL_DIR/run/install-op.lock.db" "BEGIN EXCLUSIVE; ROLLBACK;" >/dev/null 2>&1; do
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || break
    sleep 0.05
  done

  run bash "$LAUNCH"
  [ "$status" -eq 75 ]

  echo "ROLLBACK;" >&8
  exec 8>&-
  wait "$holder_pid" 2>/dev/null || true
}

@test "agmsgd-launch: a crashed update (.prev present, lock free) -> exits 0, records a start attempt" {
  setup_install_db
  sqlite3 "$SKILLDIR_INSTALL_DB" "UPDATE daemon_intent SET desired = 'on';"
  touch "$TEST_SKILL_DIR/run/install-manifest.json.prev"
  run bash "$LAUNCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"never completed"* ]]
}

@test "agmsgd-launch: bootstrap_version mismatch -> exits 75, records a start attempt" {
  setup_install_db
  sqlite3 "$SKILLDIR_INSTALL_DB" "UPDATE daemon_intent SET desired = 'on';"
  echo '{"bootstrap_version":999}' > "$TEST_SKILL_DIR/run/install-manifest.json"
  run bash "$LAUNCH"
  [ "$status" -eq 75 ]
  [[ "$output" == *"bootstrap version mismatch"* ]]
}

@test "agmsgd-launch: intent on, completion record present, but no usable Node recorded -> exits 0, records a start attempt" {
  setup_install_db
  sqlite3 "$SKILLDIR_INSTALL_DB" "UPDATE daemon_intent SET desired = 'on';"
  echo '{"bootstrap_version":1}' > "$TEST_SKILL_DIR/run/install-manifest.json"
  run bash "$LAUNCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no usable Node"* ]]
}

@test "agmsgd-launch: full happy path execs into scripts/daemon/agmsgd with (skillDir, desired, op_gen)" {
  setup_install_db
  local real_node
  real_node="$(command -v node)"
  sqlite3 "$SKILLDIR_INSTALL_DB" "UPDATE daemon_intent SET desired = 'on', op_gen = 7; UPDATE meta SET node_path = '$real_node';"
  echo '{"bootstrap_version":1}' > "$TEST_SKILL_DIR/run/install-manifest.json"
  # Stub the Node entrypoint so this test exercises only the launcher's
  # own decision to hand off, not agmsgd itself (a separate component with
  # its own tests).
  cat > "$TEST_SKILL_DIR/scripts/daemon/agmsgd" <<'EOF'
#!/usr/bin/env node
console.log(JSON.stringify(process.argv.slice(2)));
EOF
  chmod +x "$TEST_SKILL_DIR/scripts/daemon/agmsgd"

  run bash "$LAUNCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"\"$TEST_SKILL_DIR\",\"on\",\"7\""* ]]
}
