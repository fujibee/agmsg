#!/usr/bin/env bats
load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR" AGMSG_STORAGE_DRIVER=sqlite
  bash "$SCRIPTS/join.sh" alpha ann claude-code /tmp/alpha-ann >/dev/null
  bash "$SCRIPTS/join.sh" alpha bob claude-code /tmp/alpha-bob >/dev/null
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  DB=$(agmsg_db_path alpha)
  CONFIG="$TEST_SKILL_DIR/teams/alpha/config.json"
  JOURNAL="$TEST_SKILL_DIR/teams/alpha/roster.jsonl"
}
teardown() {
  # Failed assertions must not leave the disposable gated child waiting.
  if [ -n "${DM_GATE:-}" ] && [ -f "$DM_GATE/pid" ]; then
    finish_gated_team_rename_child "$(cat "$DM_GATE/pid")" || true
    wait "${DM_RENAME_PID:-0}" 2>/dev/null || true
  fi
  teardown_test_env
}

claim_message() {
  storage_send alpha ann bob hello >/dev/null
  CLAIM=$(storage_claim_unread alpha bob test-owner 60 100)
  [ -n "$CLAIM" ]
}

fault_config_publication() {
  mkdir "$TEST_SKILL_DIR/fake-bin"
  export DM_REAL_MV DM_FAULT_TARGET DM_FAULT_MARKER
  DM_REAL_MV=$(command -v mv)
  DM_FAULT_TARGET="$CONFIG"
  DM_FAULT_MARKER="$TEST_SKILL_DIR/faulted"
  cat > "$TEST_SKILL_DIR/fake-bin/mv" <<'SH'
#!/usr/bin/env bash
last="${!#}"
last="$(cd "$(dirname "$last")" && pwd)/$(basename "$last")"
if { [ "$last" = "$DM_FAULT_TARGET" ] || { [ -n "${DM_FAULT_STAGE_PREFIX:-}" ] && [[ "$last" == *"/$DM_FAULT_STAGE_PREFIX"* ]]; }; } && [ ! -f "$DM_FAULT_MARKER" ]; then
  : > "$DM_FAULT_MARKER"
  exit 42
fi
exec "$DM_REAL_MV" "$@"
SH
  chmod +x "$TEST_SKILL_DIR/fake-bin/mv"
  export PATH="$TEST_SKILL_DIR/fake-bin:$PATH"
}

fault_sql_once() {
  export DM_REAL_SQLITE DM_SQL_MATCH DM_FAULT_MARKER DM_SQL_DB DM_SQL_REQUIRE_COMMIT
  DM_SQL_DB="${2:-}"
  DM_SQL_REQUIRE_COMMIT="${3:-true}"
  DM_REAL_SQLITE=$(command -v sqlite3)
  DM_SQL_MATCH="$1"
  DM_FAULT_MARKER="$TEST_SKILL_DIR/sql-faulted"
  mkdir -p "$TEST_SKILL_DIR/sql-bin"
  cat > "$TEST_SKILL_DIR/sql-bin/sqlite3" <<'SH'
#!/usr/bin/env bash
input=$(cat)
args="$*"
all="$args $input"
if [[ "$all" == *"$DM_SQL_MATCH"* && "$args" == *"$DM_SQL_DB"* && "$all" != *ROLLBACK* ]] &&
   { [ "$DM_SQL_REQUIRE_COMMIT" = false ] || [[ "$all" == *COMMIT* ]]; } && [ ! -f "$DM_FAULT_MARKER" ]; then
  printf '%s\n' "$args" > "$DM_FAULT_MARKER"
  exit 42
fi
printf '%s\n' "$input" | "$DM_REAL_SQLITE" "$@"
SH
  chmod +x "$TEST_SKILL_DIR/sql-bin/sqlite3"
  export PATH="$TEST_SKILL_DIR/sql-bin:$PATH"
}

# Fault only the disposable installation, at a unique production command
# boundary. No environment-controlled interruption hooks ship in the product.
inject_after() {
  local relative="$1" needle="$2"
  cp "$BATS_TEST_DIRNAME/../$relative" "$TEST_SKILL_DIR/$relative"
  node - "$TEST_SKILL_DIR/$relative" "$needle" <<'JS'
const fs = require('fs');
const [file, needle] = process.argv.slice(2);
const source = fs.readFileSync(file, 'utf8');
const boundary = `\n${needle}\n`;
if (source.split(boundary).length !== 2) throw new Error(`fault boundary is not one exact line: ${JSON.stringify(needle)}`);
fs.writeFileSync(file, source.replace(boundary, `${boundary}exit 42 # disposable fixture fault\n`));
JS
}

restore_script() { cp "$BATS_TEST_DIRNAME/../$1" "$TEST_SKILL_DIR/$1"; }

# These ordinary fault fixtures return synchronously after all foreground
# children have completed. Model the explicit operator step before retrying;
# the surviving-child fixtures below instead prove recovery stays blocked.
recover_fixture_locks() {
  local holder lock pid
  source "$SCRIPTS/lib/instance-id.sh"
  for holder in "$TEST_SKILL_DIR"/teams/*/.config.lock.holder; do
    [ -f "$holder" ] || continue
    grep -qx 'recovery manual' "$holder" || continue
    pid=$(sed -n 's/^pid //p' "$holder")
    [ -n "$pid" ] && ! _agmsg_pid_alive_local "$pid" || return 1
    lock="${holder%.holder}"
    [ ! -d "$lock" ] || rmdir "$lock" || return 1
    rm "$holder" || return 1
  done
}

@test "windows-native: maintenance fingerprints preserve exact bytes without external SHA tools" {
  local dir="$TEST_SKILL_DIR/no-digests" tool file expected actual
  mkdir "$dir"
  for tool in shasum sha256sum openssl; do
    printf '#!/bin/sh\nexit 1\n' > "$dir/$tool"
    chmod +x "$dir/$tool"
  done
  export PATH="$dir:$PATH"
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  agmsg_dm_load || return 1
  : > "$TEST_SKILL_DIR/empty"
  printf '雪 é 🐝\r\n\000end\n\n' > "$TEST_SKILL_DIR/bytes"
  printf 'line' > "$TEST_SKILL_DIR/no-lf"
  printf 'line\n' > "$TEST_SKILL_DIR/lf"
  for file in empty bytes no-lf lf; do
    expected=$(node -e 'const fs=require("fs"),c=require("crypto");console.log("sha3-256:"+c.createHash("sha3-256").update(fs.readFileSync(process.argv[1])).digest("hex"))' "$TEST_SKILL_DIR/$file") || return 1
    actual=$(agmsg_dm_hash "$TEST_SKILL_DIR/$file") || return 1
    [ "$actual" = "$expected" ] || return 1
  done
  [ "$(agmsg_dm_hash "$TEST_SKILL_DIR/no-lf")" != "$(agmsg_dm_hash "$TEST_SKILL_DIR/lf")" ] || return 1
  [ "$(agmsg_dm_hash "$TEST_SKILL_DIR/missing")" = absent ] || return 1
  local planned=$'{"note":"雪\'s"}\r\n'
  printf '%s\n' "$planned" > "$TEST_SKILL_DIR/planned"
  [ "$(agmsg_dm_hash_planned_line "$planned")" = "$(agmsg_dm_hash "$TEST_SKILL_DIR/planned")" ]
}

@test "delivery maintenance: SHA3 probe refuses wrong output and nonzero status without pipefail" {
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  agmsg_sqlite_mem() { printf '%s\n' "$DM_PROBE_OUTPUT"; return "$DM_PROBE_STATUS"; }
  local mode
  for mode in wrong empty extra failed; do
    DM_PROBE_OUTPUT=62ee883ee174594990f5551d569e9e8a51995ea49287b3f81a030089c5ff3f4e
    DM_PROBE_STATUS=0
    case "$mode" in
      wrong) DM_PROBE_OUTPUT=0000000000000000000000000000000000000000000000000000000000000000 ;;
      empty) DM_PROBE_OUTPUT='' ;;
      extra) DM_PROBE_OUTPUT+=$'\nextra' ;;
      failed) DM_PROBE_STATUS=42 ;;
    esac
    run bash_probe_without_pipefail
    [ "$status" -ne 0 ] || return 1
  done
}

bash_probe_without_pipefail() { set +o pipefail; agmsg_dm_hash_probe; }

@test "delivery maintenance: unreadable file or failed digest cannot emit a fingerprint" {
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  agmsg_sqlite_mem() {
    case "$*" in
      *X\'70726f6265\'*) printf '%s\n' 62ee883ee174594990f5551d569e9e8a51995ea49287b3f81a030089c5ff3f4e ;;
      *) printf '%s' "$DM_HASH_OUTPUT"; return "$DM_HASH_STATUS" ;;
    esac
  }
  local kind
  for kind in null malformed failed; do
    DM_HASH_STATUS=0
    DM_HASH_OUTPUT=''
    case "$kind" in
      malformed) DM_HASH_OUTPUT=broken ;;
      failed) DM_HASH_OUTPUT=62ee883ee174594990f5551d569e9e8a51995ea49287b3f81a030089c5ff3f4e; DM_HASH_STATUS=42 ;;
    esac
    run agmsg_dm_hash "$CONFIG"
    [ "$status" -ne 0 ] || return 1
    [[ "$output" != *sha3-256:* ]] || return 1
    run agmsg_dm_hash_planned_line '{"planned":true}'
    [ "$status" -ne 0 ] || return 1
    [[ "$output" != *sha3-256:* ]] || return 1
  done
}

@test "delivery maintenance: planned hash rejects failed byte encoders after complete output" {
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  # The real SQLite probe must pass before reaching the fixture's encoder.
  agmsg_dm_hash_probe || return 1
  od() { command od "$@"; return 42; }
  run agmsg_dm_hash_planned_line '{"planned":true}'
  [ "$status" -ne 0 ] || return 1
  [ -z "$output" ] || return 1
  unset -f od
  tr() {
    command tr "$@" || return 1
    # Leave the SQLite helper's CR normalization intact; fail only the encoder.
    [ "$*" != '-d [:space:]' ]
  }
  run agmsg_dm_hash_planned_line '{"planned":true}'
  [ "$status" -ne 0 ] || return 1
  [ -z "$output" ]
}

@test "delivery maintenance: symlink and nonregular state cannot match a file fingerprint" {
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  local expected
  expected=$(agmsg_dm_hash "$CONFIG") || return 1
  ln -s "$CONFIG" "$TEST_SKILL_DIR/config-link"
  run agmsg_dm_expect "$TEST_SKILL_DIR/config-link" "$expected"
  [ "$status" -ne 0 ] || return 1
  run agmsg_dm_hash "$TEST_SKILL_DIR/teams"
  [ "$status" -ne 0 ]
}

@test "delivery maintenance: unsupported SHA3 refuses rename and migration before recovery locks" {
  fault_sql_once 'sha3(' '' false
  local command
  for command in rename migrate; do
    rm -f "$DM_FAULT_MARKER"
    if [ "$command" = rename ]; then
      run bash "$SCRIPTS/rename.sh" alpha ann renamed
    else
      run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
    fi
    [ "$status" -ne 0 ] || return 1
    [ -f "$DM_FAULT_MARKER" ] || return 1
    [ ! -e "$TEST_SKILL_DIR/teams/alpha/.config.lock" ] || return 1
    [ ! -e "$TEST_SKILL_DIR/teams/alpha/.config.lock.holder" ] || return 1
    [ "$(jq -r '.agents.ann.member_id' "$CONFIG")" != null ] || return 1
    [ ! -f "$TEST_SKILL_DIR/db/teams/alpha/messages.db" ] || return 1
  done
}

@test "delivery maintenance: foreign or absent config fingerprints cannot resume an operation" {
  fault_config_publication
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ] || return 1
  local original candidate
  original=$(sqlite3 "$DB" 'SELECT descriptor FROM delivery_maintenance LIMIT 1;')
  [ -n "$original" ] || return 1
  cp "$CONFIG" "$TEST_SKILL_DIR/config.before-retry"
  cp "$JOURNAL" "$TEST_SKILL_DIR/journal.before-retry"
  for candidate in absent 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef; do
    sqlite3 "$DB" "UPDATE delivery_maintenance SET descriptor=json_set('$(agmsg_sqlesc "$original")','\$.config_after','$candidate');"
    recover_fixture_locks || return 1
    run bash "$SCRIPTS/rename.sh" alpha ann renamed
    [ "$status" -ne 0 ] || return 1
    cmp "$CONFIG" "$TEST_SKILL_DIR/config.before-retry" || return 1
    cmp "$JOURNAL" "$TEST_SKILL_DIR/journal.before-retry" || return 1
    [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ] || return 1
  done
  sqlite3 "$DB" "UPDATE delivery_maintenance SET descriptor='$(agmsg_sqlesc "$original")';"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
}

@test "delivery maintenance: agent rename refuses a live claim before registry writes" {
  claim_message
  cp "$CONFIG" "$TEST_SKILL_DIR/config.before"
  cp "$JOURNAL" "$TEST_SKILL_DIR/journal.before"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  cmp "$CONFIG" "$TEST_SKILL_DIR/config.before"
  cmp "$JOURNAL" "$TEST_SKILL_DIR/journal.before"
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(storage_history alpha | jq -r 'select(.type == "message_sent" or .body != null) | .from' | head -1)" = ann ]
}

@test "delivery maintenance: agent rename disposes expired claims and receipts" {
  claim_message
  sqlite3 "$DB" "UPDATE delivery_claims SET expires_at=0;
    INSERT INTO delivery_ack_receipts(team,agent,msg_id,owner,token,acked_at,retain_until) VALUES('alpha','bob','old','owner','token',1,9999999999);"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(jq -r '.agents.renamed.member_id' "$CONFIG")" != null ]
}

@test "delivery maintenance: durable neutral or legacy reservation refuses rename" {
  mkdir -p "$TEST_SKILL_DIR/run"
  for prefix in read-reservation antigravity-reservation; do
    printf '{broken' > "$TEST_SKILL_DIR/run/$prefix.alpha__retired.json"
    recover_fixture_locks
    run bash "$SCRIPTS/rename.sh" alpha ann renamed
    [ "$status" -ne 0 ]
    printf '%s\n' "$output" | grep -Fq 'durable read reservation exists'
    [ "$(jq -r '.agents.ann.member_id' "$CONFIG")" != null ]
    rm "$TEST_SKILL_DIR/run/$prefix.alpha__retired.json"
  done
}

@test "delivery maintenance: exact rename resumes journal-published config failure once" {
  storage_send alpha ann bob hello >/dev/null
  fault_config_publication
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  run storage_claim_unread alpha bob other 60 10
  [ "$status" -ne 0 ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.type == "member_renamed")] | length' "$JOURNAL")" = 1 ]
  [ "$(jq '[.renamed[] | select(.from == "ann" and .to == "renamed")] | length' "$CONFIG")" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: another rename cannot adopt a failed operation" {
  fault_config_publication
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann different
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'another or malformed operation'
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
}

@test "delivery maintenance: legacy no-journal rename keeps recovery exact" {
  rm "$JOURNAL"
  jq 'del(.team_id,.agents.ann.member_id,.agents.bob.member_id)' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  fault_config_publication
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ ! -e "$JOURNAL" ]
  [ "$(jq '.agents | has("renamed")' "$CONFIG")" = true ]
}

@test "delivery maintenance: initialization of a missing roster preserves its generated records on retry" {
  rm "$JOURNAL"
  fault_config_publication
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  cp "$JOURNAL" "$TEST_SKILL_DIR/journal.published"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  cmp "$JOURNAL" "$TEST_SKILL_DIR/journal.published"
  [ "$(jq -s '[.[] | select(.type == "member_renamed")] | length' "$JOURNAL")" = 1 ]
}

@test "delivery maintenance: rename resolves its store after waiting for registry lock" {
  storage_send alpha ann bob hello >/dev/null
  local lock="$TEST_SKILL_DIR/teams/alpha/.config.lock" child tries=0
  mkdir "$lock" "$TEST_SKILL_DIR/wait-bin"
  export DM_REAL_MKDIR DM_WAIT_MARKER
  DM_REAL_MKDIR=$(command -v mkdir)
  DM_WAIT_MARKER="$TEST_SKILL_DIR/waiting"
  cat > "$TEST_SKILL_DIR/wait-bin/mkdir" <<'SH'
#!/usr/bin/env bash
case "$*" in */.config.lock) : > "$DM_WAIT_MARKER" ;; esac
exec "$DM_REAL_MKDIR" "$@"
SH
  chmod +x "$TEST_SKILL_DIR/wait-bin/mkdir"
  PATH="$TEST_SKILL_DIR/wait-bin:$PATH" bash "$SCRIPTS/rename.sh" alpha ann renamed > "$TEST_SKILL_DIR/rename.log" 2>&1 & child=$!
  until [ -e "$DM_WAIT_MARKER" ]; do
    tries=$((tries+1)); [ "$tries" -lt 300 ]; sleep 0.01
  done
  mkdir -p "$TEST_SKILL_DIR/db/teams/alpha"
  sqlite3 "$DB" ".backup '$TEST_SKILL_DIR/db/teams/alpha/messages.db'"
  jq '.drivers.partition="per-team"' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  rmdir "$lock"
  wait "$child"
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/teams/alpha/messages.db" "SELECT from_agent FROM messages WHERE team='alpha';")" = renamed ]
  [ "$(sqlite3 "$DB" "SELECT from_agent FROM messages WHERE team='alpha';")" = ann ]
}

@test "delivery maintenance: post-config pre-SQL failure resumes data rewrite" {
  storage_send alpha ann bob hello >/dev/null
  fault_sql_once "UPDATE messages SET from_agent='renamed'"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  [ "$(jq '.agents | has("renamed")' "$CONFIG")" = true ]
  [ "$(sqlite3 "$DB" "SELECT from_agent FROM messages WHERE team='alpha';")" = ann ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" "SELECT from_agent FROM messages WHERE team='alpha';")" = renamed ]
  [ "$(jq -s '[.[] | select(.type == "member_renamed")] | length' "$JOURNAL")" = 1 ]
}

@test "delivery maintenance: corrupt retained final plan refuses before SQL mutation" {
  storage_send alpha ann bob hello >/dev/null
  fault_sql_once "UPDATE messages SET from_agent='renamed'"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  local token stage
  token=$(sqlite3 "$DB" "SELECT token FROM delivery_maintenance WHERE team='alpha';")
  stage="$(dirname "$DB")/.delivery-rename-$token"
  : > "$stage/unexpected"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$DB" "SELECT from_agent FROM messages WHERE team='alpha';")" = ann ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
}

@test "delivery maintenance: post-SQL pre-finish failure resumes without a stage" {
  storage_send alpha ann bob hello >/dev/null
  fault_sql_once 'DELETE FROM delivery_maintenance'
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$DB" "SELECT from_agent FROM messages WHERE team='alpha';")" = renamed ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(jq -s '[.[] | select(.type == "member_renamed")] | length' "$JOURNAL")" = 1 ]
}

@test "delivery maintenance: team rename refuses live shared claims before moving config" {
  claim_message
  recover_fixture_locks
  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -ne 0 ]
  [ -f "$CONFIG" ]
  [ ! -f "$TEST_SKILL_DIR/teams/gamma/config.json" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: per-team rename refuses a retained target-name shared claim" {
  bash "$SCRIPTS/internal/migrate-team-store.sh" alpha >/dev/null
  storage_send gamma ann bob retained >/dev/null
  local claimed
  claimed=$(storage_claim_unread gamma bob target-reader 60 10)
  [ -n "$claimed" ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -ne 0 ]
  [ -f "$CONFIG" ]
  [ ! -e "$TEST_SKILL_DIR/db/teams/gamma" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: failed second rename admission releases shared fallback barriers" {
  bash "$SCRIPTS/internal/migrate-team-store.sh" alpha >/dev/null
  claim_message
  recover_fixture_locks
  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -ne 0 ]
  [ -f "$CONFIG" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/teams/alpha/messages.db" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: per-team rename resumes after config moved before store" {
  storage_send alpha ann bob hello >/dev/null
  bash "$SCRIPTS/internal/migrate-team-store.sh" alpha >/dev/null
  local new_config="$TEST_SKILL_DIR/teams/gamma/config.json"
  fault_config_publication
  export DM_FAULT_TARGET="$TEST_SKILL_DIR/db/teams/gamma"
  recover_fixture_locks
  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -ne 0 ]
  [ ! -f "$CONFIG" ]
  [ -f "$new_config" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 2 ]
  run storage_claim_unread alpha bob stale 60 10
  [ "$status" -ne 0 ]
  run storage_claim_unread gamma bob premature 60 10
  [ "$status" -ne 0 ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -eq 0 ]
  [ "$(jq -r .name "$new_config")" = gamma ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/teams/gamma/messages.db" 'SELECT team FROM messages;')" = gamma ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: deletion refuses durable reservation even with force and yes" {
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '{broken' > "$TEST_SKILL_DIR/run/read-reservation.alpha__bob.json"
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --yes
  [ "$status" -ne 0 ]
  [ -f "$CONFIG" ]
  [ -f "$TEST_SKILL_DIR/run/read-reservation.alpha__bob.json" ]
}

@test "delivery maintenance: purge refuses live claims without changing messages" {
  claim_message
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --purge-messages --yes
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha';")" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: combined delete resumes after config removal before finish" {
  storage_send alpha ann bob hello >/dev/null
  fault_sql_once 'DELETE FROM delivery_maintenance'
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --purge-messages --yes
  [ "$status" -ne 0 ]
  [ ! -e "$CONFIG" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --purge-messages --yes
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha';")" = 0 ]
}

@test "delivery maintenance: config-only deletion discards expired claims and receipts" {
  claim_message
  sqlite3 "$DB" "UPDATE delivery_claims SET expires_at=0;
    INSERT INTO delivery_ack_receipts(team,agent,msg_id,owner,token,acked_at,retain_until) VALUES('alpha','bob','old','owner','token',1,9999999999);"
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --yes
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_claims;')" = 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_ack_receipts;')" = 0 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha';")" = 1 ]
}

@test "delivery maintenance: per-team config deletion keeps fallback admission until finish" {
  storage_send alpha ann bob hello >/dev/null
  bash "$SCRIPTS/internal/migrate-team-store.sh" alpha >/dev/null
  fault_sql_once 'DELETE FROM delivery_maintenance' "$DB"
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --yes
  [ "$status" -ne 0 ]
  [ ! -e "$CONFIG" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  run storage_claim_unread alpha bob fallback 60 10
  [ "$status" -ne 0 ]
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --yes
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/teams/alpha/messages.db" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: migration refuses live source claims before creating destination" {
  claim_message
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -ne 0 ]
  [ ! -e "$TEST_SKILL_DIR/db/teams/alpha" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(jq -r '.drivers.partition // "shared"' "$CONFIG")" = shared ]
}

@test "delivery maintenance: migration resumes an empty operation-token staging directory" {
  storage_send alpha ann bob hello >/dev/null
  fault_sql_once 'CREATE TABLE' '.delivery-migrate-'
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -ne 0 ]
  [ -f "$DM_FAULT_MARKER" ] || {
    printf 'migration failed before the staged-copy fault fired: status=%s\n' "$status"
    return 1
  }
  [ ! -e "$TEST_SKILL_DIR/db/teams/alpha" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -eq 0 ] || {
    # Keep evidence for a non-reproducing full-suite failure without exposing
    # paths, tokens, descriptors, config contents, or raw command output.
    printf 'empty-stage resume failed: status=%s\n' "$status"
    local stage entry stages=0 files=0 published=0 lock=0 holder=0 reason
    for stage in "$TEST_SKILL_DIR/db/teams"/.delivery-migrate-*; do
      [ -d "$stage" ] || continue
      stages=$((stages + 1))
      for entry in "$stage"/* "$stage"/.[!.]* "$stage"/..?*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then files=$((files + 1)); fi
      done
    done
    if [ -f "$TEST_SKILL_DIR/db/teams/alpha/messages.db" ]; then published=1; fi
    if [ -d "$TEST_SKILL_DIR/teams/alpha/.config.lock" ]; then lock=1; fi
    if [ -f "$TEST_SKILL_DIR/teams/alpha/.config.lock.holder" ]; then holder=1; fi
    printf 'stages=%s files=%s published=%s lock=%s holder=%s\n' "$stages" "$files" "$published" "$lock" "$holder"
    sqlite3 "$DB" "SELECT 'source_barriers='||COUNT(*) FROM delivery_maintenance;" 2>/dev/null || true
    for reason in 'database is locked' 'database is full' 'out of memory' 'unsupported state fingerprint' \
      'team identity/configuration differs' 'unbound partial staged schema' 'containment query failed'; do
      if [[ "$output" == *"$reason"* ]]; then printf 'stderr category: %s\n' "$reason"; fi
    done
    return 1
  }
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/teams/alpha/messages.db" 'PRAGMA journal_mode;')" = wal ]
}

@test "delivery maintenance: published migration retains barriers until WAL restoration succeeds" {
  storage_send alpha ann bob hello >/dev/null
  local dest="$TEST_SKILL_DIR/db/teams/alpha/messages.db"
  fault_sql_once 'PRAGMA journal_mode=WAL' "$dest" false
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -ne 0 ]
  [ -f "$dest" ]
  [ "$(jq -r '.drivers.partition // "shared"' "$CONFIG")" = shared ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  [ "$(sqlite3 "$dest" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  [ "$(sqlite3 "$dest" 'PRAGMA journal_mode;')" = delete ]
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$dest" 'PRAGMA journal_mode;')" = wal ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(sqlite3 "$dest" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: migration clears source first and resumes destination finalization" {
  storage_send alpha ann bob hello >/dev/null
  local dest="$TEST_SKILL_DIR/db/teams/alpha/messages.db"
  fault_sql_once 'DELETE FROM delivery_maintenance' "$dest"
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -ne 0 ]
  [ "$(jq -r '.drivers.partition' "$CONFIG")" = per-team ]
  grep -Fq "$dest" "$DM_FAULT_MARKER"
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(sqlite3 "$dest" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha';")" = 0 ]
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$dest" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: rename replans after admission before stage publication" {
  storage_send alpha ann bob hello >/dev/null
  fault_config_publication
  export DM_FAULT_TARGET='' DM_FAULT_STAGE_PREFIX='.delivery-rename-'
  cp "$CONFIG" "$TEST_SKILL_DIR/config.before"
  cp "$JOURNAL" "$TEST_SKILL_DIR/journal.before"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  cmp "$CONFIG" "$TEST_SKILL_DIR/config.before"
  cmp "$JOURNAL" "$TEST_SKILL_DIR/journal.before"
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
  [ "$(jq -s '[.[] | select(.type == "member_renamed")] | length' "$JOURNAL")" = 1 ]
}

@test "delivery maintenance: rename resumes after stage before journal publication" {
  fault_config_publication
  export DM_FAULT_TARGET="$JOURNAL"
  cp "$JOURNAL" "$TEST_SKILL_DIR/journal.before"
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -ne 0 ]
  cmp "$JOURNAL" "$TEST_SKILL_DIR/journal.before"
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 1 ]
  recover_fixture_locks
  run bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ "$(jq -s '[.[] | select(.type == "member_renamed")] | length' "$JOURNAL")" = 1 ]
}

@test "delivery maintenance: migration never adopts unexpected token-stage contents" {
  storage_send alpha ann bob hello >/dev/null
  fault_sql_once 'CREATE TABLE' '.delivery-migrate-'
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -ne 0 ]
  local token
  token=$(sqlite3 "$DB" "SELECT token FROM delivery_maintenance WHERE team='alpha';")
  : > "$TEST_SKILL_DIR/db/teams/.delivery-migrate-$token/unrelated"
  recover_fixture_locks
  run bash "$SCRIPTS/internal/migrate-team-store.sh" alpha
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'unexpected staging content'
  [ -f "$TEST_SKILL_DIR/db/teams/.delivery-migrate-$token/unrelated" ]
  [ ! -e "$TEST_SKILL_DIR/db/teams/alpha" ]
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha';")" = 1 ]
}

@test "delivery maintenance: remote sync resume requires exact planned contents" {
  local root="$TEST_SKILL_DIR/db" plan before after
  mkdir -p "$root/remote-sync"
  printf '{"local_team":"alpha","endpoint":"https://fixture.invalid"}\n' > "$root/remote-sync/alpha.json"
  chmod 600 "$root/remote-sync/alpha.json"
  plan=$(node "$SCRIPTS/internal/rename-sync-config.mjs" "$root" alpha gamma --plan)
  before=$(printf '%s' "$plan" | jq -r .source)
  after=$(printf '%s' "$plan" | jq -r .target)
  # Model the atomic target publication / source-unlink crash boundary.
  node -e 'const fs=require("fs"),p=process.argv[1],c=JSON.parse(fs.readFileSync(p+"/alpha.json"));c.local_team="gamma";fs.writeFileSync(p+"/gamma.json",JSON.stringify(c,null,2)+"\n",{mode:0o600})' "$root/remote-sync"
  run node "$SCRIPTS/internal/rename-sync-config.mjs" "$root" alpha gamma --resume "$before" "$after"
  [ "$status" -eq 0 ]
  [ ! -e "$root/remote-sync/alpha.json" ]
  run node "$SCRIPTS/internal/rename-sync-config.mjs" "$root" alpha gamma --resume "$before" "$after"
  [ "$status" -eq 0 ]
  printf '{"local_team":"gamma","different":true}\n' > "$root/remote-sync/gamma.json"
  run node "$SCRIPTS/internal/rename-sync-config.mjs" "$root" alpha gamma --resume "$before" "$after"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -Fq 'target remote sync config differs'
}

@test "delivery maintenance: rename publishes its private plan within one filesystem" {
  local real_mv
  real_mv=$(command -v mv)
  mkdir "$TEST_SKILL_DIR/other-temp" "$TEST_SKILL_DIR/cross-bin"
  export TMPDIR="$TEST_SKILL_DIR/other-temp" DM_REAL_MV="$real_mv" DM_CROSS_MARKER="$TEST_SKILL_DIR/crossed"
  cat > "$TEST_SKILL_DIR/cross-bin/mv" <<'SH'
#!/usr/bin/env bash
source="$1"; target="${!#}"
if [ -d "$source" ] && [[ "$target" == */.delivery-rename-* ]] &&
   [ "$(cd "$(dirname "$source")" && pwd)" != "$(cd "$(dirname "$target")" && pwd)" ]; then
  # Model a killed cross-filesystem copy: an authoritative but partial stage.
  : > "$DM_CROSS_MARKER"
  mkdir "$target"
  cp "$source/config.json" "$target/config.json"
  exit 42
fi
exec "$DM_REAL_MV" "$@"
SH
  chmod +x "$TEST_SKILL_DIR/cross-bin/mv"
  run env PATH="$TEST_SKILL_DIR/cross-bin:$PATH" bash "$SCRIPTS/rename.sh" alpha ann renamed
  [ "$status" -eq 0 ]
  [ ! -e "$DM_CROSS_MARKER" ]
  [ "$(jq '.agents | has("renamed")' "$CONFIG")" = true ]
}

@test "delivery maintenance: per-team rename resumes every external publication boundary" {
  storage_send alpha ann bob hello >/dev/null
  bash "$SCRIPTS/internal/migrate-team-store.sh" alpha >/dev/null
  mkdir -p "$TEST_SKILL_DIR/db/remote-sync"
  printf '{"local_team":"alpha"}\n' > "$TEST_SKILL_DIR/db/remote-sync/alpha.json"
  chmod 600 "$TEST_SKILL_DIR/db/remote-sync/alpha.json"
  local current=alpha next point n=0 dest
  local points=(
    '    shared_token="${AGMSG_DM_TOKEN:?maintenance result missing}"'
    '    if [ -f "$OLD_DIR/$file" ]; then mv "$OLD_DIR/$file" "$NEW_DIR/$file"; fi'
    '    mv "${source_db%/*}" "${target_db%/*}"'
    '    agmsg_write_atomic "$NEW_DIR/config.json" "$updated"'
    '  _sqlite_exec_stdin "$selected" "BEGIN IMMEDIATE; $guard $sql $(agmsg_dm_discard_claims_sql "$OLD_TEAM" "$NEW_TEAM") COMMIT;"'
    '    "$NODE_BIN" "$SCRIPT_DIR/internal/rename-sync-config.mjs" "$(agmsg_storage_dir)" "$OLD_TEAM" "$NEW_TEAM" --resume "$sync_before" "$sync_after"'
    '      $(_sqlite_delivery_maintenance_finish_sql "$descriptor" "$shared_token" "$OLD_TEAM" "$NEW_TEAM") COMMIT;"'
  )
  for point in "${points[@]}"; do
    n=$((n+1)); next="renamed$n"
    inject_after scripts/rename-team.sh "$point"
    recover_fixture_locks
    run bash "$SCRIPTS/rename-team.sh" "$current" "$next"
    [ "$status" -eq 42 ] || { printf 'fault %s: %s\n' "$n" "$output"; false; }
    restore_script scripts/rename-team.sh
    recover_fixture_locks
    run bash "$SCRIPTS/rename-team.sh" "$current" "$next"
    [ "$status" -eq 0 ] || { printf 'resume %s: %s\n' "$n" "$output"; false; }
    dest="$TEST_SKILL_DIR/db/teams/$next/messages.db"
    [ "$(jq -r .name "$TEST_SKILL_DIR/teams/$next/config.json")" = "$next" ]
    [ "$(jq -r .local_team "$TEST_SKILL_DIR/db/remote-sync/$next.json")" = "$next" ]
    [ "$(sqlite3 "$dest" 'SELECT team FROM messages;')" = "$next" ]
    [ "$(sqlite3 "$dest" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
    [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
    current="$next"
  done
}

@test "delivery maintenance: migration resumes staged commit through source finalization" {
  local point team dest config n=0
  local points=(
    '    ( umask 077; _sqlite_exec_stdin "$DEST" "ATTACH DATABASE '\''$src_lit'\'' AS src; $copy" ) >/dev/null'
    '  [ "$(agmsg_sqlite "$DEST" '\''PRAGMA journal_mode=DELETE;'\'')" = delete ] || exit 1'
    '  mv "$STAGE" "${CANONICAL_DEST%/*}"'
    '  agmsg_write_atomic "$CONFIG" "$UPDATED"'
    '  _drop_from_shared'
    '  _sqlite_delivery_maintenance_finish_db "$SHARED" "$DESCRIPTOR" "$SOURCE_TOKEN" "$TEAM" >/dev/null'
  )
  for point in "${points[@]}"; do
    n=$((n+1)); team="moving$n"
    bash "$SCRIPTS/join.sh" "$team" bob claude-code /tmp/bob >/dev/null
    storage_send "$team" ann bob hello >/dev/null
    config="$TEST_SKILL_DIR/teams/$team/config.json"
    dest="$TEST_SKILL_DIR/db/teams/$team/messages.db"
    inject_after scripts/internal/migrate-team-store.sh "$point"
    recover_fixture_locks
    run bash "$SCRIPTS/internal/migrate-team-store.sh" "$team"
    [ "$status" -eq 42 ] || { printf 'fault %s: %s\n' "$n" "$output"; false; }
    restore_script scripts/internal/migrate-team-store.sh
    recover_fixture_locks
    run bash "$SCRIPTS/internal/migrate-team-store.sh" "$team"
    [ "$status" -eq 0 ] || { printf 'resume %s: %s\n' "$n" "$output"; false; }
    [ "$(jq -r '.drivers.partition' "$config")" = per-team ]
    [ "$(sqlite3 "$dest" 'PRAGMA journal_mode;')" = wal ]
    [ "$(sqlite3 "$dest" 'SELECT body FROM messages;')" = hello ]
    [ "$(sqlite3 "$dest" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
    [ "$(sqlite3 "$DB" "SELECT count(*) FROM delivery_maintenance WHERE team='$team';")" = 0 ]
    [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='$team';")" = 0 ]
  done
}

@test "delivery maintenance: per-team deletion resumes paired admission and external cleanup boundaries" {
  local point relative team dest n=0
  local points=(
    'scripts/lib/team-delete.sh|      AGMSG_DM_DELETE_SHARED_TOKEN="${AGMSG_DM_TOKEN:?maintenance result missing}"'
    'scripts/team.sh|    agmsg_team_purge_messages "$TEAM"'
    'scripts/team.sh|    agmsg_team_delete_run_records "$TEAM" "$TEAM_DIR" "$CONFIG"'
    'scripts/team.sh|    rm -f "$TEAM_DIR/roster.jsonl" "$TEAM_DIR/roster-sync.json" "$TEAM_DIR/config.json"'
    'scripts/lib/team-delete.sh|      $(_sqlite_delivery_maintenance_finish_sql "$descriptor" "$AGMSG_DM_DELETE_SHARED_TOKEN" "$team") COMMIT;" || return 1'
  )
  for point in "${points[@]}"; do
    n=$((n+1)); team="deleting$n"
    bash "$SCRIPTS/join.sh" "$team" bob claude-code /tmp/bob >/dev/null
    storage_send "$team" ann bob hello >/dev/null
    bash "$SCRIPTS/internal/migrate-team-store.sh" "$team" >/dev/null
    dest="$TEST_SKILL_DIR/db/teams/$team/messages.db"
    relative="${point%%|*}"; point="${point#*|}"
    inject_after "$relative" "$point"
    recover_fixture_locks
    run bash "$SCRIPTS/team.sh" "$team" --delete --force --purge-messages --yes
    [ "$status" -eq 42 ] || { printf 'fault %s: %s\n' "$n" "$output"; false; }
    restore_script "$relative"
    recover_fixture_locks
    run bash "$SCRIPTS/team.sh" "$team" --delete --force --purge-messages --yes
    [ "$status" -eq 0 ] || { printf 'resume %s: %s\n' "$n" "$output"; false; }
    [ ! -e "$TEST_SKILL_DIR/teams/$team/config.json" ]
    [ "$(sqlite3 "$dest" 'SELECT count(*) FROM messages;')" = 0 ]
    [ "$(sqlite3 "$dest" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
    [ "$(sqlite3 "$DB" "SELECT count(*) FROM delivery_maintenance WHERE team='$team';")" = 0 ]
  done
}

@test "delivery maintenance: deletion resumes a partial registry unlink" {
  node - "$SCRIPTS/team.sh" <<'JS'
const fs=require('fs'), file=process.argv[2], source=fs.readFileSync(file,'utf8');
const needle='    rm -f "$TEAM_DIR/roster.jsonl" "$TEAM_DIR/roster-sync.json" "$TEAM_DIR/config.json"';
if(source.split(needle).length!==2) throw new Error('unlink boundary is not unique');
fs.writeFileSync(file,source.replace(needle,'    rm -f "$TEAM_DIR/roster.jsonl"\nexit 42'));
JS
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --yes
  [ "$status" -eq 42 ]
  [ ! -e "$JOURNAL" ]
  [ -f "$CONFIG" ]
  restore_script scripts/team.sh
  recover_fixture_locks
  run bash "$SCRIPTS/team.sh" alpha --delete --force --yes
  [ "$status" -eq 0 ]
  [ ! -e "$CONFIG" ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

# Gate the actual rename COMMIT, not schema initialization or read queries.
# Preserve SQLite's exit status so feature probes keep their real outcome.
start_gated_team_rename() {
  storage_send alpha ann bob original >/dev/null
  export DM_REAL_SQLITE DM_GATE DM_RELEASE
  DM_REAL_SQLITE=$(command -v sqlite3)
  DM_GATE="$TEST_SKILL_DIR/orphan-gate"
  DM_RELEASE="$TEST_SKILL_DIR/orphan-release"
  mkdir "$TEST_SKILL_DIR/gate-bin"
  cat > "$TEST_SKILL_DIR/gate-bin/sqlite3" <<'SH'
#!/usr/bin/env bash
input=$(cat)
gated=false
if [[ "$input" == *"UPDATE messages SET team='gamma' WHERE team='alpha';"* && "$input" == *COMMIT* ]] && mkdir "$DM_GATE" 2>/dev/null; then
  gated=true
  printf '%s\n' "$input" > "$DM_GATE/transaction.sql"
  printf '%s\n' "$PPID" > "$DM_GATE/subshell"
  printf '%s\n' "$$" > "$DM_GATE/pid"
  while [ ! -f "$DM_RELEASE" ]; do sleep 0.01; done
fi
rc=0
printf '%s\n' "$input" | "$DM_REAL_SQLITE" "$@" || rc=$?
if [ "$gated" = true ]; then printf '%s\n' "$rc" > "$DM_GATE/finished"; fi
exit "$rc"
SH
  chmod +x "$TEST_SKILL_DIR/gate-bin/sqlite3"
  export PATH="$TEST_SKILL_DIR/gate-bin:$PATH"
  bash "$SCRIPTS/rename-team.sh" alpha gamma >"$TEST_SKILL_DIR/first.log" 2>&1 &
  DM_RENAME_PID=$!
  local tries=0
  while [ ! -f "$DM_GATE/pid" ] && [ "$tries" -lt 2000 ]; do sleep 0.01; tries=$((tries+1)); done
  [ -f "$DM_GATE/pid" ] || { cat "$TEST_SKILL_DIR/first.log" >&3; return 1; }
}

finish_gated_team_rename_child() {
  local orphan="$1" tries=0
  : > "$DM_RELEASE"
  source "$SCRIPTS/lib/instance-id.sh"
  while _agmsg_pid_alive_local "$orphan" && [ "$tries" -lt 1000 ]; do sleep 0.01; tries=$((tries+1)); done
  if _agmsg_pid_alive_local "$orphan"; then return 1; fi
  [ -f "$DM_GATE/finished" ]
}

@test "delivery maintenance: killed rename requires descendant verification before exact recovery" {
 start_gated_team_rename
 local parent="$DM_RENAME_PID" orphan
 orphan=$(cat "$DM_GATE/pid")
 kill -KILL "$parent"
 wait "$parent" || true
 kill -0 "$orphan"
 export AGMSG_LOCK_TRIES=2
 run bash "$SCRIPTS/rename-team.sh" alpha gamma
 [ "$status" -ne 0 ]
 printf '%s\n' "$output" | grep -Fq 'requires manual recovery'
 [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 2 ]
 # A normal registry writer must also honor the maintenance lock policy.
 run bash "$SCRIPTS/join.sh" gamma new claude-code /tmp/new-registration
 [ "$status" -ne 0 ]
 kill -0 "$orphan"
 finish_gated_team_rename_child "$orphan"
 # Simulated operator recovery: only these disposable, exact locks, after
 # both the recorded shell and the gated mutating child have stopped.
 local team
 for team in alpha gamma; do
   rmdir "$TEST_SKILL_DIR/teams/$team/.config.lock"
   rm "$TEST_SKILL_DIR/teams/$team/.config.lock.holder"
 done
 run bash "$SCRIPTS/rename-team.sh" alpha gamma
 [ "$status" -eq 0 ]
 [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
 storage_send alpha ann bob replacement >/dev/null
 [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha' AND body='replacement';")" = 1 ]
}

@test "delivery maintenance: failed SQL wrapper retains locks until surviving child is verified stopped" {
  start_gated_team_rename
  local parent="$DM_RENAME_PID" orphan subshell result=0
  orphan=$(cat "$DM_GATE/pid")
  subshell=$(cat "$DM_GATE/subshell")
  kill -KILL "$subshell"
  wait "$parent" || result=$?
  [ "$result" -ne 0 ]
  kill -0 "$orphan"
  [ -d "$TEST_SKILL_DIR/teams/alpha/.config.lock" ]
  [ -d "$TEST_SKILL_DIR/teams/gamma/.config.lock" ]
  export AGMSG_LOCK_TRIES=2
  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires manual recovery"* ]] || return 1
  finish_gated_team_rename_child "$orphan"
  recover_fixture_locks
  run bash "$SCRIPTS/rename-team.sh" alpha gamma
  [ "$status" -eq 0 ]
  storage_send alpha ann bob replacement >/dev/null
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha' AND body='replacement';")" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: retired transaction cannot rewrite a replacement team's data" {
  start_gated_team_rename
  local orphan
  orphan=$(cat "$DM_GATE/pid")
  finish_gated_team_rename_child "$orphan"
  wait "$DM_RENAME_PID"
  storage_send alpha ann bob replacement >/dev/null
  run bash -c '"$DM_REAL_SQLITE" -bail "$1" < "$DM_GATE/transaction.sql"' _ "$DB"
  [ "$status" -ne 0 ]
  [[ "$output" == *maintenance_fence* ]] || return 1
  [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha' AND body='replacement';")" = 1 ]
  [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 0 ]
}

@test "delivery maintenance: transaction fence validates exact descriptor token and membership" {
  storage_init alpha >/dev/null
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  local descriptor='fixture operation' token other guard mutation
  token=$(printf '%064d' 1); other=$(printf '%064d' 2)
  sqlite3 "$DB" 'CREATE TABLE fence_sentinel(value INTEGER); INSERT INTO fence_sentinel VALUES(0);'
  for mutation in valid missing wrong_token wrong_descriptor extra_descriptor extra_token duplicate; do
    sqlite3 "$DB" "DELETE FROM delivery_maintenance; UPDATE fence_sentinel SET value=0;
      INSERT INTO delivery_maintenance VALUES('alpha','$descriptor','$token',1);"
    case "$mutation" in
      missing) sqlite3 "$DB" "DELETE FROM delivery_maintenance;" ;;
      wrong_token) sqlite3 "$DB" "UPDATE delivery_maintenance SET token='$other';" ;;
      wrong_descriptor) sqlite3 "$DB" "UPDATE delivery_maintenance SET descriptor='other';" ;;
      extra_descriptor) sqlite3 "$DB" "INSERT INTO delivery_maintenance VALUES('extra','$descriptor','$other',1);" ;;
      extra_token) sqlite3 "$DB" "INSERT INTO delivery_maintenance VALUES('extra','other','$token',1);" ;;
    esac
    if [ "$mutation" = duplicate ]; then
      guard=$(agmsg_dm_guard_sql "$descriptor" "$token" main alpha alpha)
    else
      guard=$(agmsg_dm_guard_sql "$descriptor" "$token" main alpha)
    fi
    run _sqlite_exec_stdin "$DB" "BEGIN IMMEDIATE; $guard UPDATE fence_sentinel SET value=1; COMMIT;"
    if [ "$mutation" = valid ]; then
      [ "$status" -eq 0 ]
      [ "$(sqlite3 "$DB" 'SELECT value FROM fence_sentinel;')" = 1 ]
    else
      [ "$status" -ne 0 ]
      [ "$(sqlite3 "$DB" 'SELECT value FROM fence_sentinel;')" = 0 ]
      if [ "$mutation" != duplicate ]; then [[ "$output" == *maintenance_fence* ]]; fi
    fi
  done
  run agmsg_dm_guard_sql "$descriptor" "$token" invalid_alias alpha
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "delivery maintenance: attached source fence precedes destination writes" {
  storage_init alpha >/dev/null
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  local descriptor='fixture source' token other guard dest
  token=$(printf '%064d' 1); other=$(printf '%064d' 2)
  dest="$TEST_SKILL_DIR/fence-destination.db"
  sqlite3 "$DB" "INSERT INTO delivery_maintenance VALUES('alpha','$descriptor','$token',1);"
  guard=$(agmsg_dm_guard_sql "$descriptor" "$token" src alpha)
  run _sqlite_exec_stdin "$dest" "ATTACH DATABASE '$DB' AS src; BEGIN IMMEDIATE; $guard CREATE TABLE fence_sentinel(value); INSERT INTO fence_sentinel VALUES(1); COMMIT;"
  [ "$status" -eq 0 ]
  sqlite3 "$DB" "UPDATE delivery_maintenance SET token='$other';"
  run _sqlite_exec_stdin "$dest" "ATTACH DATABASE '$DB' AS src; BEGIN IMMEDIATE; $guard CREATE TABLE forbidden(value); UPDATE fence_sentinel SET value=2; COMMIT;"
  [ "$status" -ne 0 ]
  [[ "$output" == *maintenance_fence* ]] || return 1
  [ "$(sqlite3 "$dest" 'SELECT value FROM fence_sentinel;')" = 1 ]
  [ "$(sqlite3 "$dest" "SELECT count(*) FROM sqlite_master WHERE name='forbidden';")" = 0 ]
}

@test "delivery maintenance: actual source deletion refuses a retired fence without losing rows" {
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  # Exercise the production builder, including its inline DELETE/COMMIT
  # appends after command substitution, without running migration setup.
  sed -n '/^_drop_from_shared()/,/^}/p' "$SCRIPTS/internal/migrate-team-store.sh" > "$TEST_SKILL_DIR/drop-from-shared.sh"
  source "$TEST_SKILL_DIR/drop-from-shared.sh"
  local TEAM=alpha SHARED="$DB" DESCRIPTOR='fixture source deletion'
  local SOURCE_TOKEN other src_tables mode
  SOURCE_TOKEN=$(printf '%064d' 1); other=$(printf '%064d' 2)
  for mode in valid retired; do
    storage_send alpha ann bob "source-delete-$mode" >/dev/null
    src_tables=$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table';")
    sqlite3 "$DB" "DELETE FROM delivery_maintenance;
      INSERT INTO delivery_maintenance VALUES('alpha','$DESCRIPTOR','$SOURCE_TOKEN',1);"
    if [ "$mode" = retired ]; then
      sqlite3 "$DB" "UPDATE delivery_maintenance SET token='$other';"
    fi
    run _drop_from_shared
    if [ "$mode" = valid ]; then
      [ "$status" = 0 ]; [ -z "$output" ]
      [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE team='alpha';")" = 0 ]
      [ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE team='alpha';")" = 0 ]
    else
      [ "$status" -ne 0 ]; [[ "$output" == *maintenance_fence* ]] || return 1
      [ "$(sqlite3 "$DB" "SELECT count(*) FROM messages WHERE body='source-delete-retired';")" = 1 ]
      [ "$(sqlite3 "$DB" "SELECT count(*) FROM events WHERE type='message_sent' AND body='source-delete-retired';")" = 1 ]
    fi
  done
}

@test "windows-native: maintenance fence blocks inline stale writes and preserves guard failures" {
  storage_init alpha >/dev/null
  source "$SCRIPTS/lib/delivery-maintenance.sh"
  local token guard rc=0
  token=$(printf '%064d' 1)
  sqlite3 "$DB" "CREATE TABLE fence_sentinel(value INTEGER); INSERT INTO fence_sentinel VALUES(0);
    INSERT INTO delivery_maintenance VALUES('alpha','fixture','$token',1);"
  guard=$(agmsg_dm_guard_sql fixture "$token" main alpha)
  run _sqlite_exec_stdin "$DB" "BEGIN IMMEDIATE; $guard UPDATE fence_sentinel SET value=1; COMMIT;"
  [ "$status" = 0 ]; [ -z "$output" ]
  [ "$(agmsg_sqlite "$DB" 'SELECT value FROM fence_sentinel;')" = 1 ]
  sqlite3 "$DB" "UPDATE delivery_maintenance SET token='$(printf '%064d' 2)';"
  _sqlite_exec_stdin "$DB" "BEGIN IMMEDIATE; $guard UPDATE fence_sentinel SET value=2; COMMIT;" \
    >"$TEST_SKILL_DIR/fence.out" 2>"$TEST_SKILL_DIR/fence.err" || rc=$?
  [ "$rc" -ne 0 ]; [ ! -s "$TEST_SKILL_DIR/fence.out" ]
  grep -q maintenance_fence "$TEST_SKILL_DIR/fence.err"
  [ "$(agmsg_sqlite "$DB" 'SELECT value FROM fence_sentinel;')" = 1 ]
  _sqlite_delivery_assert_sql() { return 42; }
  run agmsg_dm_guard_sql fixture "$token" main alpha
  [ "$status" = 42 ]
  refute grep -q 'SELECT 1 WHERE 0;' <<< "$output"
}

@test "delivery maintenance: finalization refuses extra descriptor or token membership" {
  storage_init alpha >/dev/null
  local descriptor='fixture finish' token other mutation
  token=$(printf '%064d' 1); other=$(printf '%064d' 2)
  for mutation in descriptor token; do
    sqlite3 "$DB" "DELETE FROM delivery_maintenance;
      INSERT INTO delivery_maintenance VALUES('alpha','$descriptor','$token',1);"
    if [ "$mutation" = descriptor ]; then
      sqlite3 "$DB" "INSERT INTO delivery_maintenance VALUES('extra','$descriptor','$other',1);"
    else
      sqlite3 "$DB" "INSERT INTO delivery_maintenance VALUES('extra','other','$token',1);"
    fi
    run _sqlite_delivery_maintenance_finish_db "$DB" "$descriptor" "$token" alpha
    [ "$status" -ne 0 ]
    [[ "$output" == *maintenance_mismatch* ]] || return 1
    [ "$(sqlite3 "$DB" 'SELECT count(*) FROM delivery_maintenance;')" = 2 ]
  done
}
