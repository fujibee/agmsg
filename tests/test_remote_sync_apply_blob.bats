#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  SERVER_ID=018f3f7e-0000-7000-8000-000000000000
  TEAM_ID=018f3f7e-0000-7000-8000-000000000001
}

teardown() { teardown_test_env; }

blob_page() {
  jq -nc '
    range(1;4) as $seq |
    {type:"sync_pull_message",server_seq:($seq|tostring),
     id:("550e8400-e29b-41d4-a716-44665544000" + ($seq|tostring)),
     server_received_at:"2026-07-20T13:00:00.000000Z",
     envelope:{v:1,cipher:"age-v1",key_id:"epoch-1",
       blob:(["ciphertext-once-" + ("x" * 8192) + "\u0027\n\\$(false)日本語", "", "third-blob"][($seq-1)])},
     status:"importable",policy_revision:"0",local_security_revision:"0",
     projection:{body:("body-" + ($seq|tostring)),from_agent:"alice",to_agent:"bob",
       created_at:"2026-07-20T13:00:00.000000Z"}}'
  printf '%s\n' '{"type":"sync_pull_cursor","next_after":"3"}'
}

capture_apply_sql() {
  local probe="$TEST_SKILL_DIR/sql-probe" real
  real="$(command -v sqlite3)"
  mkdir -p "$probe"
  export APPLY_SQL_CAPTURE="$probe/apply.sql"
  printf '%s\n' '#!/usr/bin/env bash' \
    'for argument in "$@"; do' \
    '  if [ "$argument" = -bail ]; then' \
    '    cat > "$APPLY_SQL_CAPTURE"' \
    "    exec $(printf '%q' "$real") \"\$@\" < \"\$APPLY_SQL_CAPTURE\"" \
    '  fi' \
    'done' \
    "exec $(printf '%q' "$real") \"\$@\"" > "$probe/sqlite3"
  chmod +x "$probe/sqlite3"
  export PATH="$probe:$PATH"
}

@test "sync apply: each ciphertext appears once in SQL and remains byte-exact across replay (#957)" {
  local page db expected actual pass
  capture_apply_sql
  page=$(blob_page)
  expected=$(printf '%s\n' "$page" | jq -sc '[.[]|select(.type=="sync_pull_message")|.envelope.blob]')
  for pass in 1 2; do
    run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$page"
    [ "$status" -eq 0 ]
    [ "$(grep -o 'ciphertext-once-' "$APPLY_SQL_CAPTURE" | wc -l | tr -d ' ')" -eq 1 ]
    [ "$(printf '%s\n' "$output" | jq -s '[.[]|select(.status=="imported")]|length')" -eq 3 ]
    db=$(agmsg_db_path demo)
    actual=$(agmsg_sqlite "$db" "SELECT json_group_array(blob) FROM (SELECT blob FROM sync_messages ORDER BY server_seq);" | tr -d '\r')
    [ "$actual" = "$expected" ]
    actual=$(agmsg_sqlite "$db" "SELECT json_group_array(blob) FROM (SELECT blob FROM sync_quarantine ORDER BY server_seq);" | tr -d '\r')
    [ "$actual" = "$expected" ]
    [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM events e JOIN messages m ON m.id=e.legacy_id WHERE e.body=m.body AND e.body='body-'||e.seq;" | tr -d '\r')" -eq 3 ]
    [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM messages;" | tr -d '\r')" -eq 3 ]
    [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM sqlite_master WHERE name='sync_apply_envelope';" | tr -d '\r')" -eq 0 ]
  done
}

@test "sync apply: pending blobs survive reprocess with an interleaved roster record (#957)" {
  local page ready db
  page=$(blob_page | jq -c 'if .type=="sync_pull_message" then .status="pending_key" | del(.projection) else . end')
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$page"
  [ "$status" -eq 0 ]
  db=$(agmsg_db_path demo)
  [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM events;" | tr -d '\r')" -eq 0 ]
  ready=$(blob_page | jq -c 'if .server_seq=="2" then .projection={kind:"member_joined"} else . end')
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$ready"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | jq -s '[.[]|select(.status=="imported")]|length')" -eq 3 ]
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$ready"
  [ "$status" -eq 0 ]
  [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM events;" | tr -d '\r')" -eq 2 ]
  [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM messages;" | tr -d '\r')" -eq 2 ]
  [ "$(agmsg_sqlite "$db" "SELECT blob FROM sync_messages WHERE server_seq='3';" | tr -d '\r')" = third-blob ]
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<'{"type":"sync_pull_cursor","next_after":"3"}'
  [ "$status" -eq 0 ]
  [ "$(agmsg_sqlite "$db" "SELECT transport_cursor FROM sync_bindings;" | tr -d '\r')" = 3 ]
}

@test "sync apply: changed ciphertext is rejected against quarantine and mappings (#957)" {
  local page changed db pass
  page=$(blob_page)
  run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$page"
  [ "$status" -eq 0 ]
  db=$(agmsg_db_path demo)
  agmsg_sqlite "$db" "DELETE FROM sync_quarantine WHERE server_seq='2';"
  changed=$(printf '%s\n' "$page" | jq -c 'if .type=="sync_pull_message" then .envelope.blob="changed-"+.server_seq else . end')
  for pass in 1 2; do
    run storage_sync_apply_pull demo "$SERVER_ID" "$TEAM_ID" 1 <<<"$changed"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | jq -s '[.[]|select(.status=="corrupt_state")]|length')" -eq 3 ]
    [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM sync_conflicts WHERE blob='changed-'||server_seq;" | tr -d '\r')" -eq 3 ]
    [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM sync_messages WHERE blob LIKE 'changed-%';" | tr -d '\r')" -eq 0 ]
    [ "$(agmsg_sqlite "$db" "SELECT count(*) FROM messages;" | tr -d '\r')" -eq 3 ]
  done
}
