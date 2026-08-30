#!/usr/bin/env bats

load test_helper
bats_require_minimum_version 1.5.0

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init agsuite >/dev/null
}

teardown() { teardown_test_env; }

contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
not_contains() { case "$1" in *"$2"*) return 1 ;; *) return 0 ;; esac; }

@test "lifecycle contract: sqlite advertises the complete public capability explicitly" {
  run storage_capabilities agsuite
  [ "$status" -eq 0 ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")','$.schema');")" = "agmsg-lifecycle-capabilities/v1" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")','$.driver');")" = "sqlite" ]
  for capability in operation_key delivery_receipt read_receipt application_ack work_registration outbox history_query; do
    [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$output" | sed "s/'/''/g")','$.capabilities.$capability');")" = "supported" ]
  done
}

@test "lifecycle contract: one operation key commits one message and delivery receipt" {
  local first second
  first="$(storage_operation_send agsuite alice bob action op-send-1 wake:bob "apply once")"
  second="$(storage_operation_send agsuite alice bob action op-send-1 wake:bob "apply once")"

  [ "$second" = "$first" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$first" | sed "s/'/''/g")','$.type');")" = "message_sent" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$first" | sed "s/'/''/g")','$.operation_key');")" = "op-send-1" ]
  [ -n "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$first" | sed "s/'/''/g")','$.delivery_receipt_id');")" ]

  run storage_lifecycle_history agsuite --operation-key op-send-1
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"type":"message_sent"')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '"type":"delivery_receipt"')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '"type":"outbox_pending"')" -eq 1 ]
}

@test "lifecycle contract: concurrent retries converge on one logical message" {
  local outputs="$BATS_TEST_TMPDIR/concurrent"
  mkdir -p "$outputs"
  local i pid status=0
  for i in 1 2 3 4 5 6 7 8; do
    bash -c 'source "$SKILL_DIR/scripts/lib/storage.sh"; agmsg_storage_load; storage_operation_send agsuite alice bob action op-concurrent wake:bob "apply once"' >"$outputs/$i" 2>"$outputs/$i.err" &
  done
  for pid in $(jobs -p); do wait "$pid" || status=1; done
  [ "$status" -eq 0 ]
  [ "$(sort -u "$outputs"/[1-8] | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_messages WHERE operation_key='op-concurrent';")" -eq 1 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE operation_key='op-concurrent' AND type='delivery_receipt';")" -eq 1 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='op-concurrent' AND kind='wake';")" -eq 1 ]
}

@test "lifecycle contract: reusing an operation key for different content fails visibly" {
  storage_operation_send agsuite alice bob action op-conflict wake:bob "first" >/dev/null
  run --separate-stderr storage_operation_send agsuite alice bob action op-conflict wake:bob "different"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  contains "$stderr" operation_key_conflict
}

@test "lifecycle contract: fetch records a read receipt and leases actionable delivery until ACK" {
  local sent message_id fetched
  sent="$(storage_operation_send agsuite alice bob terminal op-fetch-1 wake:bob "done")"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"

  fetched="$(storage_operation_fetch agsuite bob consumer-1 900)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$fetched" | sed "s/'/''/g")','$.id');")" = "$message_id" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$fetched" | sed "s/'/''/g")','$.operation_key');")" = "op-fetch-1" ]
  [ -n "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$fetched" | sed "s/'/''/g")','$.read_receipt_id');")" ]

  run storage_operation_fetch agsuite bob consumer-2 900
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run storage_lifecycle_active agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" "$message_id"
  contains "$output" '"state":"processing"'
}

@test "lifecycle contract: application ACK is idempotent and creates cleanup without recursive ACK" {
  local sent message_id first second
  sent="$(storage_operation_send agsuite alice bob action op-ack-1 wake:bob "apply")"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  storage_operation_fetch agsuite bob consumer-1 900 >/dev/null

  first="$(storage_operation_ack agsuite bob "$message_id" op-ack-1 consumer-1 applied cleanup:bob "done")"
  second="$(storage_operation_ack agsuite bob "$message_id" op-ack-1 consumer-1 applied cleanup:bob "done")"
  [ "$second" = "$first" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$first" | sed "s/'/''/g")','$.type');")" = "application_ack" ]

  run storage_lifecycle_history agsuite --operation-key op-ack-1
  [ "$(printf '%s\n' "$output" | grep -c '"type":"application_ack"')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c '"type":"outbox_pending"')" -eq 2 ]
  [ "$(printf '%s\n' "$output" | grep -c 'ack_required')" -eq 0 ]
}

@test "lifecycle contract: outbox lease expiry replays the same durable row" {
  storage_operation_send agsuite alice bob terminal op-outbox-1 wake:bob "done" >/dev/null
  local first outbox_id replayed
  first="$(storage_outbox_claim agsuite notifier-1 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$first" | sed "s/'/''/g")','$.id');")"
  [ -n "$outbox_id" ]

  run storage_outbox_claim agsuite notifier-2 1
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_outbox SET lease_expires_at=0 WHERE id='$outbox_id';"
  replayed="$(storage_outbox_claim agsuite notifier-2 30)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$replayed" | sed "s/'/''/g")','$.id');")" = "$outbox_id" ]
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$replayed" | sed "s/'/''/g")','$.attempt');")" = "2" ]
}

@test "lifecycle contract: successful wake stays durable until read receipt" {
  storage_operation_send agsuite alice bob terminal op-wake-read wake:bob "done" >/dev/null
  local claimed outbox_id replayed
  claimed="$(storage_outbox_claim agsuite notifier-1 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"

  run storage_outbox_complete agsuite "$outbox_id" notifier-1
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = "pending" ]

  run storage_outbox_claim agsuite notifier-2 30
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_outbox SET available_at=0 WHERE id='$outbox_id';"
  replayed="$(storage_outbox_claim agsuite notifier-2 30)"
  contains "$replayed" "\"id\":\"$outbox_id\""

  storage_operation_fetch agsuite bob consumer-1 900 >/dev/null
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = "done" ]
}

@test "lifecycle contract: expired processing lease requeues the same wake episode" {
  storage_operation_send agsuite alice bob terminal op-processing-expiry wake:bob "done" >/dev/null
  storage_operation_fetch agsuite bob consumer-1 30 >/dev/null
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_processing_leases SET expires_at=0;"

  run storage_outbox_claim agsuite notifier-2 30
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE operation_key='op-processing-expiry';")" = "pending" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT available_at > CAST(strftime('%s','now') AS INTEGER) FROM lifecycle_outbox WHERE operation_key='op-processing-expiry';")" -eq 1 ]

  local replayed
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_outbox SET available_at=0 WHERE operation_key='op-processing-expiry';"
  replayed="$(storage_outbox_claim agsuite notifier-2 30)"
  contains "$replayed" '"operation_key":"op-processing-expiry"'
  contains "$replayed" '"kind":"wake"'

  run storage_operation_fetch agsuite bob consumer-2 30
  [ "$status" -eq 0 ]
  contains "$output" '"operation_key":"op-processing-expiry"'
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE operation_key='op-processing-expiry' AND kind='wake';")" = "done" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE operation_key='op-processing-expiry' AND type='read_receipt';")" -eq 2 ]
}

@test "lifecycle contract: stale outbox owner and conflicting ACK fail visibly" {
  local sent message_id claimed outbox_id
  sent="$(storage_operation_send agsuite alice bob action op-owner-conflict wake:bob "apply")"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  claimed="$(storage_outbox_claim agsuite notifier-1 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"

  run storage_outbox_complete agsuite "$outbox_id" stale-owner
  [ "$status" -ne 0 ]
  contains "$output" runtime_error
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT lease_owner FROM lifecycle_outbox WHERE id='$outbox_id';")" = notifier-1 ]

  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_outbox SET status='done',lease_owner=NULL,lease_expires_at=NULL WHERE id='$outbox_id';"
  storage_operation_fetch agsuite bob consumer-1 900 >/dev/null
  storage_operation_ack agsuite bob "$message_id" op-owner-conflict consumer-1 applied cleanup:bob "done" >/dev/null
  run --separate-stderr storage_operation_ack agsuite bob "$message_id" op-owner-conflict consumer-1 applied cleanup:other "done"
  [ "$status" -ne 0 ]
  contains "$stderr" acknowledgement_conflict
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='op-owner-conflict' AND kind='cleanup';")" -eq 1 ]
}

@test "lifecycle contract: active projection follows read ACK and cleanup state" {
  local action action_id cleanup cleanup_id
  storage_operation_send agsuite alice bob info op-active-info wake:bob "notice" >/dev/null

  run storage_lifecycle_active agsuite bob
  contains "$output" op-active-info

  storage_operation_fetch agsuite bob info-reader 30 >/dev/null
  action="$(storage_operation_send agsuite alice bob action op-active-action wake:bob "apply")"
  action_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$action" | sed "s/'/''/g")','$.id');")"
  run storage_lifecycle_active agsuite bob
  not_contains "$output" op-active-info
  contains "$output" op-active-action

  storage_operation_fetch agsuite bob action-reader 30 >/dev/null
  storage_operation_ack agsuite bob "$action_id" op-active-action action-reader applied cleanup:bob "done" >/dev/null
  run storage_lifecycle_active agsuite bob
  contains "$output" op-active-action
  contains "$output" '"state":"cleanup_pending"'

  cleanup="$(storage_outbox_claim agsuite notifier-cleanup 30)"
  cleanup_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$cleanup" | sed "s/'/''/g")','$.id');")"
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$cleanup" | sed "s/'/''/g")','$.kind');")" = cleanup ]
  storage_outbox_complete agsuite "$cleanup_id" notifier-cleanup >/dev/null
  run storage_lifecycle_active agsuite bob
  not_contains "$output" op-active-action
}

@test "lifecycle contract: additive migration preserves legacy message and read behavior" {
  local db="$TEST_SKILL_DIR/db/messages.db"
  rm -f "$db" "$db-wal" "$db-shm"
  sqlite3 "$db" "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, team TEXT NOT NULL, from_agent TEXT NOT NULL, to_agent TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL, read_at TEXT); INSERT INTO messages(team,from_agent,to_agent,body,created_at) VALUES('agsuite','alice','bob','legacy-unread','2026-01-01T00:00:00Z');"

  storage_init agsuite >/dev/null
  run storage_history agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" legacy-unread
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE body='legacy-unread';")" -eq 1 ]
  storage_send agsuite alice bob "post-migration-unread" >/dev/null
  run storage_list_unread agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" post-migration-unread
  run storage_capabilities agsuite
  [ "$status" -eq 0 ]
  contains "$output" '"operation_key":"supported"'
}

@test "lifecycle contract: export and restore preserve receipts outbox and work history" {
  local sent message_id export_file="$BATS_TEST_TMPDIR/lifecycle.jsonl"
  sent="$(storage_operation_send agsuite alice bob terminal op-export wake:bob "done")"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  storage_operation_fetch agsuite bob exporter 900 >/dev/null
  storage_operation_ack agsuite bob "$message_id" op-export exporter applied cleanup:bob "recorded" >/dev/null
  storage_work_event agsuite issue-277 op-export-work origin running "" "restore me" >/dev/null
  storage_export agsuite "$export_file"

  rm -f "$TEST_SKILL_DIR/db/messages.db" "$TEST_SKILL_DIR/db/messages.db-wal" "$TEST_SKILL_DIR/db/messages.db-shm"
  storage_import agsuite "$export_file"

  run storage_lifecycle_history agsuite --operation-key op-export
  [ "$status" -eq 0 ]
  contains "$output" '"type":"delivery_receipt"'
  contains "$output" '"type":"read_receipt"'
  contains "$output" '"type":"application_ack"'
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='op-export';")" -eq 2 ]
  run storage_lifecycle_history agsuite --operation-key op-export-work
  contains "$output" '"type":"work_event"'
}

@test "lifecycle contract: unsupported driver reports unsupported and refuses lifecycle writes" {
  export AGMSG_STORAGE_DRIVER=jsonl
  _AGMSG_STORAGE_LOADED=""
  agmsg_storage_load
  storage_init agsuite >/dev/null

  run storage_capabilities agsuite
  [ "$status" -eq 0 ]
  contains "$output" '"driver":"jsonl"'
  contains "$output" '"operation_key":"unsupported"'

  run "$SCRIPTS/api.sh" get teams agsuite capabilities
  [ "$status" -eq 0 ]
  contains "$output" '"driver":"jsonl"'
  contains "$output" '"history_query":"unsupported"'

  run --separate-stderr storage_operation_send agsuite alice bob action op-jsonl wake:bob "must fail"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  contains "$stderr" unsupported_capability
}

@test "lifecycle API: typed send fetch ACK and history use the public facade" {
  run "$SCRIPTS/api.sh" get teams agsuite capabilities
  [ "$status" -eq 0 ]
  contains "$output" '"schema":"agmsg-lifecycle-capabilities/v1"'

  local sent message_id fetched acked
  sent="$(printf '%s\n' '{"from":"alice","to":"bob","kind":"terminal","operation_key":"api-op-1","wake_target":"wake:bob","body":"finished"}' | "$SCRIPTS/api.sh" post teams agsuite messages)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  [ -n "$message_id" ]

  fetched="$(printf '%s\n' '{"agent":"bob","consumer":"consumer-api","lease_seconds":900}' | "$SCRIPTS/api.sh" post teams agsuite fetch)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$fetched" | sed "s/'/''/g")','$.id');")" = "$message_id" ]

  acked="$(printf '%s\n' "{\"agent\":\"bob\",\"message_id\":\"$message_id\",\"operation_key\":\"api-op-1\",\"consumer\":\"consumer-api\",\"result\":\"applied\",\"cleanup_target\":\"cleanup:bob\",\"reason\":\"recorded\"}" | "$SCRIPTS/api.sh" post teams agsuite acknowledgements)"
  [ "$(sqlite_mem "SELECT json_extract('$(printf '%s' "$acked" | sed "s/'/''/g")','$.result');")" = "applied" ]

  run "$SCRIPTS/api.sh" get teams agsuite lifecycle --operation-key api-op-1
  [ "$status" -eq 0 ]
  contains "$output" '"type":"delivery_receipt"'
  contains "$output" '"type":"read_receipt"'
  contains "$output" '"type":"application_ack"'
}


@test "lifecycle API: work events are idempotent canonical history records" {
  local first second
  first="$(printf '%s\n' '{"work_key":"issue-277:m2","operation_key":"work:m2:registered","actor":"origin","state":"registered","result":"","reason":"launch committed"}' | "$SCRIPTS/api.sh" post teams agsuite work-events)"
  second="$(printf '%s\n' '{"work_key":"issue-277:m2","operation_key":"work:m2:registered","actor":"origin","state":"registered","result":"","reason":"launch committed"}' | "$SCRIPTS/api.sh" post teams agsuite work-events)"
  [ "$second" = "$first" ]
  contains "$first" '"type":"work_event"'

  run "$SCRIPTS/api.sh" get teams agsuite lifecycle --operation-key work:m2:registered
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"type":"work_event"')" -eq 1 ]

  run --separate-stderr bash -c 'printf "%s\n" '\''{"work_key":"issue-277:m2","operation_key":"work:m2:registered","actor":"origin","state":"terminal","result":"success","reason":"different"}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite work-events'
  [ "$status" -ne 0 ]
  contains "$stderr" operation_key_conflict

  run "$SCRIPTS/api.sh" get teams agsuite active
  [ "$status" -eq 0 ]
  contains "$output" '"work_key":"issue-277:m2"'
  contains "$output" '"state":"registered"'

  printf '%s\n' '{"work_key":"issue-277:m2","operation_key":"work:m2:closed","actor":"origin","state":"closed","result":"success","reason":"cleanup complete"}' | "$SCRIPTS/api.sh" post teams agsuite work-events >/dev/null
  run "$SCRIPTS/api.sh" get teams agsuite active
  [ "$status" -eq 0 ]
  not_contains "$output" '"work_key":"issue-277:m2"'
}

@test "lifecycle API: notifier leases retry and complete the canonical outbox" {
  printf '%s\n' '{"from":"alice","to":"bob","kind":"terminal","operation_key":"api-outbox","wake_target":"wake:bob","body":"finished"}' | "$SCRIPTS/api.sh" post teams agsuite messages >/dev/null
  local claimed outbox_id replayed
  claimed="$(printf '%s\n' '{"owner":"notifier-api","lease_seconds":30}' | "$SCRIPTS/api.sh" post teams agsuite outbox-claims)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"
  [ -n "$outbox_id" ]

  run bash -c 'printf "%s\n" "{\"outbox_id\":\"$1\",\"owner\":\"notifier-api\",\"delay_seconds\":10,\"error\":\"adapter_failed\"}" | "$SKILL_DIR/scripts/api.sh" post teams agsuite outbox-retries' _ "$outbox_id"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT last_error FROM lifecycle_outbox WHERE id='$outbox_id';")" = adapter_failed ]

  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_outbox SET available_at=0 WHERE id='$outbox_id';"
  replayed="$(printf '%s\n' '{"owner":"notifier-api","lease_seconds":30}' | "$SCRIPTS/api.sh" post teams agsuite outbox-claims)"
  contains "$replayed" "\"id\":\"$outbox_id\""
  contains "$replayed" '"attempt":2'

  run bash -c 'printf "%s\n" "{\"outbox_id\":\"$1\",\"owner\":\"notifier-api\"}" | "$SKILL_DIR/scripts/api.sh" post teams agsuite outbox-completions' _ "$outbox_id"
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = "pending" ]
}

@test "lifecycle contract: work registration and launch outbox commit atomically" {
  local registration replay api_registration
  registration="$(storage_work_register agsuite issue-277:m2 register:m2 origin 7 origin-seat launch:worker wake:origin 900)"
  replay="$(storage_work_register agsuite issue-277:m2 register:m2 origin 7 origin-seat launch:worker wake:origin 900)"

  [ "$registration" = "$replay" ]
  contains "$registration" '"type":"work_registration"'
  contains "$registration" '"generation":7'
  contains "$registration" '"origin":"origin-seat"'
  contains "$registration" '"wake_target":"wake:origin"'
  contains "$registration" '"stall_deadline":900'
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE type='work_event' AND operation_key='register:m2' AND state='registered';")" -eq 1 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='register:m2' AND kind='launch' AND target='launch:worker';")" -eq 1 ]

  run --separate-stderr storage_work_register agsuite issue-277:m2 register:m2 origin 8 origin-seat launch:worker wake:origin 900
  [ "$status" -ne 0 ]
  contains "$stderr" operation_key_conflict

  api_registration="$(printf '%s\n' '{"work_key":"issue-277:m2-api","operation_key":"register:m2-api","actor":"origin","generation":8,"origin":"origin-seat","launch_target":"launch:worker","wake_target":"wake:origin","stall_deadline":1200}' | "$SCRIPTS/api.sh" post teams agsuite registrations)"
  contains "$api_registration" '"type":"work_registration"'
  contains "$api_registration" '"operation_key":"register:m2-api"'
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='register:m2-api' AND kind='launch';")" -eq 1 ]
}

@test "lifecycle contract: a middle-statement fault rolls back the whole send" {
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "CREATE TRIGGER fail_delivery_receipt BEFORE INSERT ON lifecycle_events WHEN NEW.type='delivery_receipt' BEGIN SELECT RAISE(ABORT,'receipt_fault'); END;"

  run --separate-stderr storage_operation_send agsuite alice bob action op-rollback wake:bob "must roll back"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_messages WHERE operation_key='op-rollback';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='op-rollback';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM events WHERE type='message_sent' AND body='must roll back';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM messages WHERE body='must roll back';")" -eq 0 ]
}

@test "lifecycle contract: ACK and outbox control faults roll back their state changes" {
  local sent message_id claimed outbox_id
  sent="$(storage_operation_send agsuite alice bob action op-control-rollback wake:bob "apply")"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  storage_operation_fetch agsuite bob handler 900 >/dev/null
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "CREATE TRIGGER fail_cleanup BEFORE INSERT ON lifecycle_outbox WHEN NEW.kind='cleanup' BEGIN SELECT RAISE(ABORT,'cleanup_fault'); END;"

  run --separate-stderr storage_operation_ack agsuite bob "$message_id" op-control-rollback handler applied cleanup:bob done
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE type='application_ack' AND message_id='$message_id';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_processing_leases WHERE message_id='$message_id';")" -eq 1 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE kind='cleanup' AND message_id='$message_id';")" -eq 0 ]

  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "DROP TRIGGER fail_cleanup;"
  storage_operation_ack agsuite bob "$message_id" op-control-rollback handler applied cleanup:bob done >/dev/null
  claimed="$(storage_outbox_claim agsuite notifier 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "CREATE TRIGGER fail_outbox_sent BEFORE INSERT ON lifecycle_events WHEN NEW.type='outbox_sent' BEGIN SELECT RAISE(ABORT,'complete_fault'); END;"

  run storage_outbox_complete agsuite "$outbox_id" notifier
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = leased ]

  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "CREATE TRIGGER fail_outbox_error BEFORE INSERT ON lifecycle_events WHEN NEW.type='outbox_error' BEGIN SELECT RAISE(ABORT,'retry_fault'); END;"
  run storage_outbox_retry agsuite "$outbox_id" notifier 10 adapter_failed
  [ "$status" -ne 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = leased ]
  [ -z "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COALESCE(last_error,'') FROM lifecycle_outbox WHERE id='$outbox_id';")" ]
}

@test "lifecycle contract: fetch observes processing expiry before redelivery" {
  storage_operation_send agsuite alice bob action op-fetch-expiry wake:bob "retry" >/dev/null
  storage_operation_fetch agsuite bob first-consumer 900 >/dev/null
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_processing_leases SET expires_at=0;"

  run storage_operation_fetch agsuite bob second-consumer 900
  [ "$status" -eq 0 ]
  contains "$output" '"operation_key":"op-fetch-expiry"'
  contains "$output" '"attempt":2'

  run storage_lifecycle_history agsuite --operation-key op-fetch-expiry
  [ "$status" -eq 0 ]
  contains "$output" '"reason":"processing_lease_expired"'
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE operation_key='op-fetch-expiry' AND kind='wake';")" = done ]
}

@test "lifecycle contract: notifier failure is visible through public history and active queries" {
  storage_operation_send agsuite alice bob terminal op-visible-error wake:bob "done" >/dev/null
  local claimed outbox_id
  claimed="$(storage_outbox_claim agsuite notifier 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"
  storage_outbox_retry agsuite "$outbox_id" notifier 10 adapter_failed >/dev/null

  run storage_lifecycle_history agsuite --operation-key op-visible-error
  [ "$status" -eq 0 ]
  contains "$output" '"type":"outbox_error"'
  contains "$output" '"reason":"adapter_failed"'

  run storage_lifecycle_active agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" '"type":"delivery_error"'
  contains "$output" '"reason":"adapter_failed"'
}

@test "lifecycle contract: a trusted legacy external driver gets explicit unsupported defaults" {
  local plugin_root="$TEST_SKILL_DIR/plugins" driver="$TEST_SKILL_DIR/plugins/storage/legacy.sh"
  mkdir -p "$plugin_root/storage" "$TEST_SKILL_DIR/db"
  printf '%s\n' \
    'storage_check() { echo ok; }' \
    "storage_describe() { printf 'name=legacy\\n'; }" \
    >"$driver"
  printf 'storage/legacy\t%s\n' "$driver" >"$TEST_SKILL_DIR/db/trusted-plugins"

  run env AGMSG_STORAGE_DRIVER=legacy bash -c 'source "$SKILL_DIR/scripts/lib/storage.sh"; agmsg_storage_load; storage_capabilities agsuite'
  [ "$status" -eq 0 ]
  contains "$output" '"driver":"legacy"'
  contains "$output" '"operation_key":"unsupported"'
  contains "$output" '"work_registration":"unsupported"'

  run --separate-stderr env AGMSG_STORAGE_DRIVER=legacy bash -c 'source "$SKILL_DIR/scripts/lib/storage.sh"; agmsg_storage_load; storage_operation_send agsuite alice bob action op wake:bob body'
  [ "$status" -eq 13 ]
  contains "$stderr" 'unsupported_capability lifecycle-v1 for legacy'
}

@test "lifecycle API: typed fields reject wrong JSON types and preserve trailing newlines" {
  local sent message_id body_hex
  sent="$(printf '%s\n' '{"from":"alice","to":"bob","kind":"info","operation_key":"api-typed","wake_target":"wake:bob","body":"line one\n\n"}' | "$SCRIPTS/api.sh" post teams agsuite messages)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  body_hex="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT hex(body) FROM events WHERE type='message_sent' AND id='$message_id';")"
  [ "$body_hex" = 6C696E65206F6E650A0A ]

  run --separate-stderr bash -c 'printf "%s\n" '\''{"from":"alice","to":"bob","kind":"info","operation_key":"api-wrong-type","wake_target":"wake:bob","body":7}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite messages'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" "field 'body' must be text"
}
