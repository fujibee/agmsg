#!/usr/bin/env bats

load test_helper

SERVER_ID="018f0000-0000-7000-8000-000000000001"
TEAM_ID="018f0000-0000-7000-8000-000000000002"

setup() {
  setup_test_env
  bash "$SCRIPTS/join.sh" testteam alice claude-code /tmp/project-a

  local cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  updated="$(sqlite_mem "
    SELECT json_set('$escaped',
      '\$.drivers.partition', 'per-team',
      '\$.remote_binding', json_object(
        'endpoint', 'https://remote.example',
        'server_instance_id', '$SERVER_ID',
        'remote_team_id', '$TEAM_ID',
        'remote_team_name', 'testteam',
        'protocol_version', 1,
        'capabilities', json_object('write_allowed_ciphers', json_array('none')),
        'connected_at', '2026-07-30T00:00:00Z',
        'disconnected_at', '2026-07-30T00:01:00Z',
        'binding_revision', 1
      ));")"
  printf '%s\n' "$updated" > "$cfg"

  mkdir -p "$TEST_SKILL_DIR/db/teams/testteam"
  sqlite3 "$TEST_SKILL_DIR/db/teams/testteam/messages.db" <<'SQL'
CREATE TABLE events (
  seq INTEGER PRIMARY KEY,
  type TEXT NOT NULL,
  team TEXT NOT NULL
);
INSERT INTO events(seq,type,team) VALUES
  (1,'message_sent','testteam'),
  (2,'member_joined','testteam');
CREATE TABLE messages (id INTEGER PRIMARY KEY);
INSERT INTO messages(id) VALUES (1);
SQL
}

teardown() {
  teardown_test_env
}

set_disconnected_at() {
  local value="$1" cfg="$TEST_SKILL_DIR/teams/testteam/config.json" escaped updated
  escaped="$(sed "s/'/''/g" "$cfg")"
  if [ "$value" = null ]; then
    updated="$(sqlite_mem "SELECT json_set('$escaped', '\$.remote_binding.disconnected_at', null);")"
  else
    updated="$(sqlite_mem "SELECT json_set('$escaped', '\$.remote_binding.disconnected_at', '$value');")"
  fi
  printf '%s\n' "$updated" > "$cfg"
}

@test "forget: refuses an active binding before deleting anything" {
  set_disconnected_at null
  local store="$TEST_SKILL_DIR/db/teams/testteam/messages.db"

  run bash "$SCRIPTS/remote.sh" forget --yes testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"still connected"* ]]
  [[ "$output" == *"remote.sh disconnect testteam"* ]]
  [ -f "$TEST_SKILL_DIR/teams/testteam/config.json" ]
  [ -f "$store" ]
}

@test "forget: shows its scope and rejects noninteractive deletion without --yes" {
  local store="$TEST_SKILL_DIR/db/teams/testteam/messages.db"

  run bash "$SCRIPTS/remote.sh" forget testteam
  [ "$status" -ne 0 ]
  [[ "$output" == *"Store: $store"* ]]
  [[ "$output" == *"Events: 3"* ]]
  [[ "$output" == *"The server copy remains."* ]]
  [[ "$output" == *"requires an interactive terminal or --yes"* ]]
  [ -f "$TEST_SKILL_DIR/teams/testteam/config.json" ]
  [ -f "$store" ]
}

@test "forget: rejects any binding ABA while confirmation is pending" {
  local out="$TEST_SKILL_DIR/forget.out" cfg="$TEST_SKILL_DIR/teams/testteam/config.json"
  run python3 - "$SCRIPTS/remote.sh" "$cfg" "$out" <<'PY'
import json, os, pty, subprocess, sys

remote, cfg, out = sys.argv[1:]
master, slave = pty.openpty()
proc = subprocess.Popen(
    ["bash", remote, "forget", "testteam"],
    stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
captured = b""
prompt = b"Type 'testteam' to confirm:"
while prompt not in captured:
    chunk = os.read(master, 4096)
    if not chunk:
        break
    captured += chunk
if prompt not in captured:
    proc.kill()
    proc.wait()
    sys.exit("forget confirmation prompt was not reached")

with open(cfg, encoding="utf-8") as handle:
    document = json.load(handle)
original = dict(document["remote_binding"])
document["remote_binding"]["endpoint"] = "https://changed.example"
document["remote_binding"]["binding_revision"] = 2
with open(cfg, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
    handle.write("\n")
document["remote_binding"] = original
document["remote_binding"]["binding_revision"] = 3
with open(cfg, "w", encoding="utf-8") as handle:
    json.dump(document, handle)
    handle.write("\n")

os.write(master, b"testteam\n")
while True:
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    captured += chunk
status = proc.wait()
with open(out, "wb") as handle:
    handle.write(captured)
sys.exit(0 if status != 0 else "forget accepted an ABA binding")
PY
  [ "$status" -eq 0 ]
  grep -q "changed while forget was waiting" "$out"
  [ -f "$cfg" ]
  [ -d "$TEST_SKILL_DIR/db/teams/testteam" ]
}

@test "forget: removes the complete local team without contacting the server" {
  local store_dir="$TEST_SKILL_DIR/db/teams/testteam"
  local trust_file="$TEST_SKILL_DIR/run/remote-trust/age-v1-$SERVER_ID-$TEAM_ID-v1.json"

  mkdir -p "$TEST_SKILL_DIR/db/remote-sync" \
    "$TEST_SKILL_DIR/run/remote-credentials/testteam" \
    "$TEST_SKILL_DIR/run/remote-trust"
  printf '%s\n' '{}' > "$TEST_SKILL_DIR/db/remote-sync/testteam.json"
  printf '%s\n' 'identity' > "$TEST_SKILL_DIR/run/remote-credentials/testteam/0.key"
  printf '%s\n' '{}' > "$trust_file"
  printf '%s\n' 'old engine output' > "$TEST_SKILL_DIR/run/remote-sync.testteam.log"

  run bash "$SCRIPTS/remote.sh" forget --yes testteam
  [ "$status" -eq 0 ]
  [[ "$output" == *"The server copy was not changed."* ]]
  [ ! -d "$TEST_SKILL_DIR/teams/testteam" ]
  [ ! -d "$store_dir" ]
  [ ! -e "$TEST_SKILL_DIR/db/remote-sync/testteam.json" ]
  [ ! -d "$TEST_SKILL_DIR/run/remote-credentials/testteam" ]
  [ ! -e "$trust_file" ]
  [ ! -e "$TEST_SKILL_DIR/run/remote-sync.testteam.log" ]
}

@test "forget: preserves trust referenced by another local team" {
  local trust_file="$TEST_SKILL_DIR/run/remote-trust/age-v1-$SERVER_ID-$TEAM_ID-v1.json"
  bash "$SCRIPTS/join.sh" alias alice claude-code /tmp/project-b
  cp "$TEST_SKILL_DIR/teams/testteam/config.json" "$TEST_SKILL_DIR/teams/alias/config.json"
  mkdir -p "$TEST_SKILL_DIR/run/remote-trust"
  printf '%s\n' '{}' > "$trust_file"

  run bash "$SCRIPTS/remote.sh" forget --yes testteam
  [ "$status" -eq 0 ]
  [ -f "$trust_file" ]
}
