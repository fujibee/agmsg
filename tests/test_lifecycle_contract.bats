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
  for capability in operation_key delivery_receipt read_receipt processing_lease_renewal application_ack work_registration work_event outbox history_query; do
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

@test "lifecycle contract: operation keys are sender-scoped through wake and cleanup outbox rows" {
  local first second first_id second_id fetched fetched_id
  first="$(storage_operation_send agsuite alice bob action op-shared-senders wake:bob "alice applies")"
  second="$(storage_operation_send agsuite carol bob action op-shared-senders wake:bob "carol applies")"
  first_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$first" | sed "s/'/''/g")','$.id');")"
  second_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$second" | sed "s/'/''/g")','$.id');")"

  [ "$first_id" != "$second_id" ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_messages WHERE operation_key='op-shared-senders';")" -eq 2 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='op-shared-senders' AND kind='wake';")" -eq 2 ]

  fetched="$(storage_operation_fetch agsuite bob consumer-one 900)"
  fetched_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$fetched" | sed "s/'/''/g")','$.id');")"
  storage_operation_ack agsuite bob "$fetched_id" op-shared-senders consumer-one applied cleanup:bob done >/dev/null
  fetched="$(storage_operation_fetch agsuite bob consumer-two 900)"
  fetched_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$fetched" | sed "s/'/''/g")','$.id');")"
  storage_operation_ack agsuite bob "$fetched_id" op-shared-senders consumer-two applied cleanup:bob done >/dev/null

  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE operation_key='op-shared-senders' AND type='application_ack';")" -eq 2 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='op-shared-senders' AND kind='cleanup';")" -eq 2 ]
}

@test "lifecycle contract: processing lease renewal fences foreign and expired consumers" {
  local sent message_id renewed first_expiry renewed_expiry
  sent="$(storage_operation_send agsuite alice bob action op-renew wake:bob work)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  storage_operation_fetch agsuite bob active-consumer 30 >/dev/null
  first_expiry="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT expires_at FROM lifecycle_processing_leases WHERE message_id='$message_id';")"

  renewed="$(storage_operation_renew agsuite bob "$message_id" op-renew active-consumer 900)"
  contains "$renewed" '"type":"processing_lease"'
  contains "$renewed" '"consumer":"active-consumer"'
  renewed_expiry="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT expires_at FROM lifecycle_processing_leases WHERE message_id='$message_id';")"
  [ "$renewed_expiry" -gt "$first_expiry" ]

  run --separate-stderr storage_operation_renew agsuite bob "$message_id" op-renew foreign-consumer 900
  [ "$status" -eq 13 ]
  contains "$stderr" processing_lease_conflict
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT expires_at FROM lifecycle_processing_leases WHERE message_id='$message_id';")" -eq "$renewed_expiry" ]

  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_processing_leases SET expires_at=0 WHERE message_id='$message_id';"
  run --separate-stderr storage_operation_renew agsuite bob "$message_id" op-renew active-consumer 900
  [ "$status" -eq 13 ]
  contains "$stderr" processing_lease_conflict
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT expires_at FROM lifecycle_processing_leases WHERE message_id='$message_id';")" -eq 0 ]
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

@test "lifecycle contract: expired processing and outbox leases reject stale owners" {
  local sent message_id claimed outbox_id
  sent="$(storage_operation_send agsuite alice bob action op-expired-fence wake:bob apply)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  storage_operation_fetch agsuite bob stale-consumer 30 >/dev/null
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_processing_leases SET expires_at=0 WHERE message_id='$message_id';"

  run --separate-stderr storage_operation_ack agsuite bob "$message_id" op-expired-fence stale-consumer applied cleanup:bob late
  [ "$status" -eq 13 ]
  contains "$stderr" acknowledgement_conflict
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE type='application_ack' AND message_id='$message_id';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE kind='cleanup' AND message_id='$message_id';")" -eq 0 ]

  storage_work_register agsuite issue-277:fence op-expired-outbox origin 1 origin-seat launch:worker wake:origin 60 >/dev/null
  claimed="$(storage_outbox_claim agsuite stale-notifier 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_outbox SET lease_expires_at=0 WHERE id='$outbox_id';"

  run storage_outbox_complete agsuite "$outbox_id" stale-notifier
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = leased ]
  run storage_outbox_retry agsuite "$outbox_id" stale-notifier 1 too_late
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = leased ]
  [ -z "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COALESCE(last_error,'') FROM lifecycle_outbox WHERE id='$outbox_id';")" ]
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
  sqlite3 "$db" < "$BATS_TEST_DIRNAME/fixtures/lifecycle-contract/issue-277-rev1.sql"
  [ "$(sqlite3 "$db" 'PRAGMA user_version;')" -eq 1 ]

  storage_init agsuite >/dev/null
  run storage_history agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" rev1-body
  [ "$(sqlite3 "$db" 'PRAGMA user_version;')" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE id=41 AND body='rev1-body' AND read_at='2026-01-01T00:01:00Z';")" -eq 1 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE id IN ('rev1-message','rev1-read');")" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT local_position FROM read_cursors WHERE team='agsuite' AND agent='bob';")" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT value FROM storage_metadata WHERE key='read_cursor_v1';")" = 1 ]
  storage_send agsuite alice bob "post-migration-unread" >/dev/null
  run storage_list_unread agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" post-migration-unread
  run storage_capabilities agsuite
  [ "$status" -eq 0 ]
  contains "$output" '"operation_key":"supported"'
}

@test "lifecycle contract: export and restore preserve receipts outbox and work history" {
  local sent message_id before_body_hex after_body_hex before_reason_hex after_reason_hex export_file="$BATS_TEST_TMPDIR/lifecycle.jsonl"
  sent="$(storage_operation_send agsuite alice bob terminal op-export wake:bob $'done\n\n')"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  before_body_hex="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT hex(body) FROM events WHERE type='message_sent' AND id='$message_id';")"
  [ "$before_body_hex" = 646F6E650A0A ]
  storage_operation_fetch agsuite bob exporter 900 >/dev/null
  storage_operation_ack agsuite bob "$message_id" op-export exporter applied cleanup:bob $'recorded\nexactly' >/dev/null
  before_reason_hex="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT hex(reason) FROM lifecycle_events WHERE type='application_ack' AND message_id='$message_id';")"
  storage_work_register agsuite issue-277 op-export-register origin 1 origin launch:worker wake:origin 2000000000 >/dev/null
  storage_work_event agsuite issue-277 op-export-work origin 1 running "" $'restore\nme' >/dev/null
  storage_export agsuite "$export_file"

  rm -f "$TEST_SKILL_DIR/db/messages.db" "$TEST_SKILL_DIR/db/messages.db-wal" "$TEST_SKILL_DIR/db/messages.db-shm"
  storage_import agsuite "$export_file"
  after_body_hex="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT hex(body) FROM events WHERE type='message_sent' AND id='$message_id';")"
  [ "$after_body_hex" = "$before_body_hex" ]
  after_reason_hex="$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT hex(reason) FROM lifecycle_events WHERE type='application_ack' AND message_id='$message_id';")"
  [ "$after_reason_hex" = "$before_reason_hex" ]

  run storage_lifecycle_history agsuite --operation-key op-export
  [ "$status" -eq 0 ]
  contains "$output" '"type":"delivery_receipt"'
  contains "$output" '"type":"read_receipt"'
  contains "$output" '"type":"application_ack"'
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='op-export';")" -eq 2 ]
  run storage_lifecycle_history agsuite --operation-key op-export-work
  contains "$output" '"type":"work_event"'
  storage_import agsuite "$export_file"
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE operation_key='op-export-work';")" -eq 1 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT hex(reason) FROM lifecycle_events WHERE operation_key='op-export-work';")" = 726573746F72650A6D65 ]
}

@test "lifecycle contract: shared-store export restores every team's lifecycle graph" {
  local export_file="$BATS_TEST_TMPDIR/shared-lifecycle.jsonl" db="$TEST_SKILL_DIR/db/messages.db"
  storage_operation_send agsuite alice bob action op-export-team-a wake:bob a >/dev/null
  storage_operation_send otherteam carol dave terminal op-export-team-b wake:dave b >/dev/null
  storage_operation_fetch otherteam dave export-consumer 900 >/dev/null
  storage_export agsuite "$export_file"

  rm -f "$db" "$db-wal" "$db-shm"
  storage_import agsuite "$export_file"

  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages WHERE team IN ('agsuite','otherteam');")" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_events WHERE type='delivery_receipt' AND team IN ('agsuite','otherteam');")" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE kind='wake' AND team IN ('agsuite','otherteam');")" -eq 2 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_processing_leases p JOIN lifecycle_messages m ON m.message_id=p.message_id WHERE m.team='otherteam';")" -eq 1 ]
  run storage_lifecycle_history otherteam --operation-key op-export-team-b
  [ "$status" -eq 0 ]
  contains "$output" '"type":"delivery_receipt"'
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
  contains "$output" '"processing_lease_renewal":"unsupported"'

  run "$SCRIPTS/api.sh" get teams agsuite capabilities
  [ "$status" -eq 0 ]
  contains "$output" '"driver":"jsonl"'
  contains "$output" '"history_query":"unsupported"'

  run --separate-stderr storage_operation_send agsuite alice bob action op-jsonl wake:bob "must fail"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  contains "$stderr" unsupported_capability

  run --separate-stderr storage_operation_renew agsuite bob message op-jsonl consumer 900
  [ "$status" -eq 13 ]
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
  storage_work_register agsuite issue-277:m2 work:m2:registration origin 2 origin launch:worker wake:origin 2000000000 >/dev/null
  first="$(printf '%s\n' '{"work_key":"issue-277:m2","operation_key":"work:m2:running","actor":"origin","generation":2,"state":"running","result":"","reason":"launch committed"}' | "$SCRIPTS/api.sh" post teams agsuite work-events)"
  second="$(printf '%s\n' '{"work_key":"issue-277:m2","operation_key":"work:m2:running","actor":"origin","generation":2,"state":"running","result":"","reason":"launch committed"}' | "$SCRIPTS/api.sh" post teams agsuite work-events)"
  [ "$second" = "$first" ]
  contains "$first" '"type":"work_event"'

  run "$SCRIPTS/api.sh" get teams agsuite lifecycle --operation-key work:m2:running
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"type":"work_event"')" -eq 1 ]

  run --separate-stderr bash -c 'printf "%s\n" '\''{"work_key":"issue-277:m2","operation_key":"work:m2:running","actor":"origin","generation":2,"state":"terminal","result":"success","reason":"different"}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite work-events'
  [ "$status" -ne 0 ]
  contains "$stderr" operation_key_conflict

  run "$SCRIPTS/api.sh" get teams agsuite active
  [ "$status" -eq 0 ]
  contains "$output" '"work_key":"issue-277:m2"'
  contains "$output" '"state":"running"'

  printf '%s\n' '{"work_key":"issue-277:m2","operation_key":"work:m2:closed","actor":"origin","generation":2,"state":"closed","result":"success","reason":"cleanup complete"}' | "$SCRIPTS/api.sh" post teams agsuite work-events >/dev/null
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

@test "lifecycle contract: import failure is visible and leaves no partial lifecycle graph" {
  local export_file="$BATS_TEST_TMPDIR/faulted-import.jsonl" db="$TEST_SKILL_DIR/db/messages.db"
  storage_operation_send agsuite alice bob terminal op-import-fault wake:bob restore >/dev/null
  storage_export agsuite "$export_file"
  rm -f "$db" "$db-wal" "$db-shm"
  storage_init agsuite >/dev/null
  sqlite3 "$db" "CREATE TRIGGER fail_import_message BEFORE INSERT ON events WHEN NEW.type='message_sent' BEGIN SELECT RAISE(ABORT,'import_fault'); END;"

  run --separate-stderr storage_import agsuite "$export_file"
  [ "$status" -eq 13 ]
  contains "$stderr" 'import failed'
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_sent';")" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages;")" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_events;")" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_outbox;")" -eq 0 ]
}

@test "lifecycle contract: malformed and incomplete JSONL imports fail before committing state" {
  local db="$TEST_SKILL_DIR/db/messages.db" malformed="$BATS_TEST_TMPDIR/malformed.jsonl"
  local nonobject="$BATS_TEST_TMPDIR/nonobject.jsonl" incomplete="$BATS_TEST_TMPDIR/incomplete.jsonl"
  printf '%s\n' '{malformed' >"$malformed"
  printf '%s\n' '[]' >"$nonobject"
  printf '%s\n' '{"type":"lifecycle_message","team":"agsuite","operation_key":"op-incomplete","message_id":"m-incomplete","recipient":"bob","kind":"action","wake_target":"wake:bob","created_at":"2026-01-01T00:00:00Z"}' >"$incomplete"

  local candidate
  for candidate in "$malformed" "$nonobject" "$incomplete"; do
    rm -f "$db" "$db-wal" "$db-shm"
    storage_init agsuite >/dev/null
    run --separate-stderr storage_import agsuite "$candidate"
    [ "$status" -eq 13 ]
    contains "$stderr" 'invalid JSON record'
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events;")" -eq 0 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages;")" -eq 0 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_events;")" -eq 0 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_outbox;")" -eq 0 ]
  done
}

@test "lifecycle contract: known lifecycle import rejects semantic and conflicting records atomically" {
  local db="$TEST_SKILL_DIR/db/messages.db" invalid="$BATS_TEST_TMPDIR/invalid-kind.jsonl"
  local conflict="$BATS_TEST_TMPDIR/conflict.jsonl" duplicate="$BATS_TEST_TMPDIR/duplicate.jsonl" record message_one message_two
  record='{"type":"lifecycle_message","team":"agsuite","sender":"alice","operation_key":"op-import-semantic","message_id":"m-one","recipient":"bob","kind":"action","wake_target":"wake:bob","created_at":"2026-01-01T00:00:00Z"}'
  message_one='{"type":"message_sent","id":"m-one","team":"agsuite","from":"alice","to":"bob","body":"one","at":"2026-01-01T00:00:00Z"}'
  message_two='{"type":"message_sent","id":"m-two","team":"agsuite","from":"alice","to":"bob","body":"two","at":"2026-01-01T00:00:00Z"}'
  printf '%s\n' "${record/\"kind\":\"action\"/\"kind\":\"not-a-kind\"}" >"$invalid"
  printf '%s\n%s\n%s\n%s\n' "$message_one" "$message_two" "$record" "${record/\"message_id\":\"m-one\"/\"message_id\":\"m-two\"}" >"$conflict"
  printf '%s\n%s\n%s\n' "$message_one" "$record" "$record" >"$duplicate"

  local candidate
  for candidate in "$invalid" "$conflict"; do
    rm -f "$db" "$db-wal" "$db-shm"
    storage_init agsuite >/dev/null
    run --separate-stderr storage_import agsuite "$candidate"
    [ "$status" -eq 13 ]
    contains "$stderr" 'import failed'
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages;")" -eq 0 ]
  done

  rm -f "$db" "$db-wal" "$db-shm"
  storage_import agsuite "$duplicate"
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages WHERE operation_key='op-import-semantic';")" -eq 1 ]
}

@test "lifecycle contract: import rejects invalid acknowledgement results atomically" {
  local db="$TEST_SKILL_DIR/db/messages.db" candidate="$BATS_TEST_TMPDIR/invalid-ack-result.jsonl"
  printf '%s\n' \
    '{"type":"message_sent","id":"m-invalid-ack","team":"agsuite","from":"alice","to":"bob","body":"body","at":"2026-01-01T00:00:00Z"}' \
    '{"type":"lifecycle_message","team":"agsuite","sender":"alice","operation_key":"op-import-invalid-ack","message_id":"m-invalid-ack","recipient":"bob","kind":"action","wake_target":"wake:bob","created_at":"2026-01-01T00:00:00Z"}' \
    '{"type":"lifecycle_event","id":"ack-invalid","event_type":"application_ack","team":"agsuite","operation_key":"op-import-invalid-ack","message_id":"m-invalid-ack","actor":"handler","result":"not-a-result","reason":"done","target":"cleanup:bob","work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:01:00Z"}' \
    >"$candidate"

  run --separate-stderr storage_import agsuite "$candidate"
  [ "$status" -eq 13 ]
  contains "$stderr" 'import failed'
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages;")" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_events;")" -eq 0 ]
}

@test "lifecycle contract: import rejects invalid known event shapes and references" {
  local db="$TEST_SKILL_DIR/db/messages.db" candidate="$BATS_TEST_TMPDIR/invalid-event.jsonl" record
  local records=(
    '{"type":"lifecycle_event","id":"event-unknown","event_type":"future_known_wrapper","team":"agsuite","operation_key":"op-invalid-event","message_id":null,"actor":"worker","result":null,"reason":null,"target":null,"work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:00:00Z"}'
    '{"type":"lifecycle_event","id":"delivery-orphan","event_type":"delivery_receipt","team":"agsuite","operation_key":"op-invalid-event","message_id":"m-missing","actor":"bob","result":null,"reason":null,"target":null,"work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:00:00Z"}'
    '{"type":"lifecycle_event","id":"work-incomplete","event_type":"work_event","team":"agsuite","operation_key":"op-invalid-event","message_id":null,"actor":"worker","result":null,"reason":null,"target":null,"work_key":null,"state":"running","generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:00:00Z"}'
  )

  for record in "${records[@]}"; do
    rm -f "$db" "$db-wal" "$db-shm"
    storage_init agsuite >/dev/null
    printf '%s\n' "$record" >"$candidate"
    run --separate-stderr storage_import agsuite "$candidate"
    [ "$status" -eq 13 ]
    contains "$stderr" 'import failed'
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_events;")" -eq 0 ]
  done
}

@test "lifecycle contract: import rejects orphan processing leases atomically" {
  local db="$TEST_SKILL_DIR/db/messages.db" candidate="$BATS_TEST_TMPDIR/orphan-processing-lease.jsonl"
  printf '%s\n' \
    '{"type":"message_sent","id":"m-control","team":"agsuite","from":"alice","to":"bob","body":"body","at":"2026-01-01T00:00:00Z"}' \
    '{"type":"lifecycle_message","team":"agsuite","sender":"alice","operation_key":"op-import-control","message_id":"m-control","recipient":"bob","kind":"action","wake_target":"wake:bob","created_at":"2026-01-01T00:00:00Z"}' \
    '{"type":"lifecycle_processing_lease","message_id":"m-missing","consumer":"handler","expires_at":2000000000,"attempt":1,"read_receipt_id":"read-missing","updated_at":"2026-01-01T00:01:00Z"}' \
    >"$candidate"

  run --separate-stderr storage_import agsuite "$candidate"
  [ "$status" -eq 13 ]
  contains "$stderr" 'import failed'
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages;")" -eq 0 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_processing_leases;")" -eq 0 ]
}

@test "lifecycle contract: import rejects orphan messages and mismatched processing receipt kinds" {
  local db="$TEST_SKILL_DIR/db/messages.db" orphan="$BATS_TEST_TMPDIR/orphan-message.jsonl"
  local mismatch="$BATS_TEST_TMPDIR/mismatched-processing-kind.jsonl"
  printf '%s\n' '{"type":"lifecycle_message","team":"agsuite","sender":"alice","operation_key":"op-orphan-message","message_id":"m-orphan","recipient":"bob","kind":"action","wake_target":"wake:bob","created_at":"2026-01-01T00:00:00Z"}' >"$orphan"
  printf '%s\n' \
    '{"type":"message_sent","id":"m-kind","team":"agsuite","from":"alice","to":"bob","body":"body","at":"2026-01-01T00:00:00Z"}' \
    '{"type":"lifecycle_message","team":"agsuite","sender":"alice","operation_key":"op-kind","message_id":"m-kind","recipient":"bob","kind":"action","wake_target":"wake:bob","created_at":"2026-01-01T00:00:00Z"}' \
    '{"type":"lifecycle_event","id":"read-kind","event_type":"read_receipt","team":"agsuite","operation_key":"op-kind","message_id":"m-kind","actor":"handler","result":"info","reason":null,"target":null,"work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:01:00Z"}' \
    '{"type":"lifecycle_processing_lease","message_id":"m-kind","consumer":"handler","expires_at":2000000000,"attempt":1,"read_receipt_id":"read-kind","updated_at":"2026-01-01T00:01:00Z"}' \
    >"$mismatch"

  local candidate
  for candidate in "$orphan" "$mismatch"; do
    rm -f "$db" "$db-wal" "$db-shm"
    storage_init agsuite >/dev/null
    run --separate-stderr storage_import agsuite "$candidate"
    [ "$status" -eq 13 ]
    contains "$stderr" 'import failed'
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_messages;")" -eq 0 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_processing_leases;")" -eq 0 ]
  done
}

@test "lifecycle contract: import rejects an ownerless leased outbox atomically" {
  local db="$TEST_SKILL_DIR/db/messages.db" candidate="$BATS_TEST_TMPDIR/ownerless-leased-outbox.jsonl"
  printf '%s\n' \
    '{"type":"lifecycle_outbox","id":"outbox-orphan","team":"agsuite","operation_key":"op-import-outbox","kind":"launch","target":"launch:worker","message_id":null,"status":"leased","available_at":0,"lease_owner":null,"lease_expires_at":null,"attempt":1,"last_error":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:01:00Z"}' \
    >"$candidate"

  run --separate-stderr storage_import agsuite "$candidate"
  [ "$status" -eq 13 ]
  contains "$stderr" 'import failed'
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_outbox;")" -eq 0 ]
}

@test "lifecycle contract: documented optional retry error may be omitted" {
  local claimed outbox_id
  storage_work_register agsuite work-retry-optional op-retry-optional worker 1 origin \
    launch:worker wake:origin 2000000000 >/dev/null
  claimed="$(storage_outbox_claim agsuite notifier 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"

  run storage_outbox_retry agsuite "$outbox_id" notifier 1
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = pending ]

  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_outbox SET available_at=0 WHERE id='$outbox_id';"
  storage_outbox_claim agsuite api-notifier 30 >/dev/null
  run --separate-stderr bash -c 'printf "%s\n" "{\"outbox_id\":\"'$outbox_id'\",\"owner\":\"api-notifier\",\"delay_seconds\":1}" | "$SKILL_DIR/scripts/api.sh" post teams agsuite outbox-retries'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
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

@test "lifecycle contract: active projection treats an expired processing lease as pending" {
  storage_operation_send agsuite alice bob action op-active-expired wake:bob retry >/dev/null
  storage_operation_fetch agsuite bob expired-consumer 900 >/dev/null
  sqlite3 "$TEST_SKILL_DIR/db/messages.db" "UPDATE lifecycle_processing_leases SET expires_at=0;"

  run storage_lifecycle_active agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" '"operation_key":"op-active-expired"'
  contains "$output" '"state":"pending"'
  not_contains "$output" '"state":"processing"'
}

@test "lifecycle contract: active work retains registration fencing and wake metadata" {
  storage_work_register agsuite issue-277:active-meta register:active-meta origin 7 origin-seat launch:worker wake:origin 900 >/dev/null
  storage_work_event agsuite issue-277:active-meta transition:active-meta worker 7 running "" started >/dev/null

  run storage_lifecycle_active agsuite
  [ "$status" -eq 0 ]
  contains "$output" '"work_key":"issue-277:active-meta"'
  contains "$output" '"state":"running"'
  contains "$output" '"generation":7'
  contains "$output" '"origin":"origin-seat"'
  contains "$output" '"wake_target":"wake:origin"'
  contains "$output" '"stall_deadline":900'
}

@test "lifecycle contract: work transitions require atomic registration and current generation" {
  run --separate-stderr storage_work_event agsuite issue-277:orphan transition:orphan worker 1 registered "" bypass
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE work_key='issue-277:orphan';")" -eq 0 ]

  storage_work_register agsuite issue-277:fenced register:fenced:1 origin 1 origin launch:worker wake:origin 2000000000 >/dev/null
  storage_work_event agsuite issue-277:fenced transition:fenced:old-running old-worker 1 running "" old >/dev/null
  storage_work_register agsuite issue-277:fenced register:fenced:2 origin 2 origin launch:worker wake:origin 2000000000 >/dev/null
  run --separate-stderr storage_work_register agsuite issue-277:fenced register:fenced:1 origin 1 origin launch:worker wake:origin 2000000000
  [ "$status" -eq 13 ]
  run --separate-stderr storage_work_event agsuite issue-277:fenced transition:fenced:old-running old-worker 1 running "" old
  [ "$status" -eq 13 ]
  run --separate-stderr storage_work_event agsuite issue-277:fenced transition:fenced:stale old-worker 1 terminal failed stale
  [ "$status" -eq 13 ]
  storage_work_event agsuite issue-277:fenced transition:fenced:current worker 2 running "" current >/dev/null
  run storage_lifecycle_active agsuite
  contains "$output" '"work_key":"issue-277:fenced"'
  contains "$output" '"actor":"worker"'
  contains "$output" '"generation":2'
  not_contains "$output" '"actor":"old-worker"'
}

@test "lifecycle contract: exact whole-store import replay is idempotent for legacy messages" {
  local exported="$BATS_TEST_TMPDIR/exact-replay.jsonl" db="$TEST_SKILL_DIR/db/messages.db" legacy_id
  storage_operation_send agsuite alice bob action op-exact-replay wake:bob body >/dev/null
  legacy_id="$(storage_send otherteam carol dave legacy-body)"
  storage_mark_read_batch otherteam dave "$legacy_id"
  storage_export agsuite "$exported"
  rm -f "$db" "$db-wal" "$db-shm"
  storage_import agsuite "$exported"
  storage_import agsuite "$exported"

  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_sent' AND id IN (SELECT message_id FROM lifecycle_messages WHERE operation_key='op-exact-replay');")" -eq 1 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE body='body';")" -eq 1 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_sent' AND id='$legacy_id';")" -eq 1 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM events WHERE type='message_read' AND team='otherteam' AND msg_id='$legacy_id';")" -eq 1 ]
  [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM messages WHERE body='legacy-body';")" -eq 1 ]
}

@test "lifecycle contract: import rejects events that contradict lifecycle message semantics" {
  local candidate="$BATS_TEST_TMPDIR/contradictory-events.jsonl" db="$TEST_SKILL_DIR/db/messages.db"
  local records=(
    '{"type":"lifecycle_event","id":"ack-info","event_type":"application_ack","team":"agsuite","operation_key":"op-semantic","message_id":"m-semantic","actor":"handler","result":"applied","reason":"impossible","target":"cleanup:bob","work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:01:00Z"}'
    '{"type":"lifecycle_event","id":"delivery-wrong","event_type":"delivery_receipt","team":"agsuite","operation_key":"op-semantic","message_id":"m-semantic","actor":"mallory","result":null,"reason":"writer-never-emits","target":null,"work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:01:00Z"}'
    '{"type":"lifecycle_event","id":"read-wrong","event_type":"read_receipt","team":"agsuite","operation_key":"op-semantic","message_id":"m-semantic","actor":"bob","result":"action","reason":null,"target":null,"work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:01:00Z"}'
  )
  local record kind
  for record in "${records[@]}"; do
    rm -f "$db" "$db-wal" "$db-shm"
    storage_init agsuite >/dev/null
    kind=info
    [[ "$record" == *'read-wrong'* ]] && kind=terminal
    printf '%s\n' \
      '{"type":"message_sent","id":"m-semantic","team":"agsuite","from":"alice","to":"bob","body":"body","at":"2026-01-01T00:00:00Z"}' \
      "{\"type\":\"lifecycle_message\",\"team\":\"agsuite\",\"sender\":\"alice\",\"operation_key\":\"op-semantic\",\"message_id\":\"m-semantic\",\"recipient\":\"bob\",\"kind\":\"$kind\",\"wake_target\":\"wake:bob\",\"created_at\":\"2026-01-01T00:00:00Z\"}" \
      "$record" >"$candidate"
    run --separate-stderr storage_import agsuite "$candidate"
    [ "$status" -eq 13 ]
    contains "$stderr" 'import failed'
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_events;")" -eq 0 ]
  done
}

@test "lifecycle contract: import rejects incomplete outbox graphs" {
  local db="$TEST_SKILL_DIR/db/messages.db" candidate="$BATS_TEST_TMPDIR/incomplete-outbox.jsonl"
  local records=(
    '{"type":"lifecycle_outbox","id":"cleanup-no-ack","team":"agsuite","operation_key":"op-outbox-graph","kind":"cleanup","target":"cleanup:bob","message_id":"m-outbox-graph","status":"pending","available_at":0,"lease_owner":null,"lease_expires_at":null,"attempt":0,"last_error":null,"created_at":"2026-01-01T00:01:00Z","updated_at":"2026-01-01T00:01:00Z"}'
    '{"type":"lifecycle_outbox","id":"wake-wrong","team":"agsuite","operation_key":"op-outbox-graph","kind":"wake","target":"wake:mallory","message_id":"m-outbox-graph","status":"pending","available_at":0,"lease_owner":null,"lease_expires_at":null,"attempt":0,"last_error":null,"created_at":"2026-01-01T00:01:00Z","updated_at":"2026-01-01T00:01:00Z"}'
    '{"type":"lifecycle_event","id":"missing-outbox","event_type":"outbox_pending","team":"agsuite","operation_key":"op-outbox-graph","message_id":"m-outbox-graph","actor":"wake:bob","result":"wake","reason":null,"target":null,"work_key":null,"state":null,"generation":null,"origin":null,"wake_target":null,"stall_deadline":null,"at":"2026-01-01T00:01:00Z"}'
  )
  local record
  for record in "${records[@]}"; do
    rm -f "$db" "$db-wal" "$db-shm"
    storage_init agsuite >/dev/null
    printf '%s\n' \
      '{"type":"message_sent","id":"m-outbox-graph","team":"agsuite","from":"alice","to":"bob","body":"body","at":"2026-01-01T00:00:00Z"}' \
      '{"type":"lifecycle_message","team":"agsuite","sender":"alice","operation_key":"op-outbox-graph","message_id":"m-outbox-graph","recipient":"bob","kind":"action","wake_target":"wake:bob","created_at":"2026-01-01T00:00:00Z"}' \
      "$record" >"$candidate"
    run --separate-stderr storage_import agsuite "$candidate"
    [ "$status" -eq 13 ]
    contains "$stderr" 'import failed'
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_outbox;")" -eq 0 ]
    [ "$(sqlite3 "$db" "SELECT COUNT(*) FROM lifecycle_events;")" -eq 0 ]
  done
}

@test "lifecycle contract: a terminal work state cannot reopen within its generation" {
  storage_work_register agsuite work-terminal reg-terminal origin 1 origin launch:worker wake:origin 2000000000 >/dev/null
  storage_work_event agsuite work-terminal close-terminal worker 1 closed success done >/dev/null

  run --separate-stderr storage_work_event agsuite work-terminal reopen-terminal worker 1 running "" late
  [ "$status" -eq 13 ]
  run storage_lifecycle_active agsuite
  not_contains "$output" '"work_key":"work-terminal"'
}

@test "lifecycle contract: active attention exposes acknowledgement result and reason" {
  local sent message_id cleanup cleanup_id
  sent="$(storage_operation_send agsuite alice bob action op-attention wake:bob body)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  storage_operation_fetch agsuite bob handler 900 >/dev/null
  storage_operation_ack agsuite bob "$message_id" op-attention handler failed cleanup:bob denied >/dev/null
  cleanup="$(storage_outbox_claim agsuite notifier 30)"
  cleanup_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$cleanup" | sed "s/'/''/g")','$.id');")"
  storage_outbox_complete agsuite "$cleanup_id" notifier >/dev/null

  run storage_lifecycle_active agsuite bob
  [ "$status" -eq 0 ]
  contains "$output" '"state":"attention"'
  contains "$output" '"ack_result":"failed"'
  contains "$output" '"reason":"denied"'
}

@test "lifecycle contract: public queries expose current processing and outbox leases" {
  local sent claimed
  sent="$(storage_operation_send agsuite alice bob action op-query-leases wake:bob body)"
  contains "$sent" '"wake_outbox_id":'
  claimed="$(storage_outbox_claim agsuite notifier 30)"
  contains "$claimed" '"lease_owner":"notifier"'

  run storage_lifecycle_history agsuite --operation-key op-query-leases
  contains "$output" '"type":"outbox"'
  contains "$output" '"lease_owner":"notifier"'
  contains "$output" '"lease_expires_at":'

  storage_operation_fetch agsuite bob handler 900 >/dev/null
  run storage_lifecycle_history agsuite --operation-key op-query-leases
  contains "$output" '"type":"processing_lease"'
  contains "$output" '"consumer":"handler"'
  contains "$output" '"read_receipt_id":'
  contains "$output" '"expires_at":'
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
  contains "$output" '"processing_lease_renewal":"unsupported"'
  contains "$output" '"work_registration":"unsupported"'

  run --separate-stderr env AGMSG_STORAGE_DRIVER=legacy bash -c 'source "$SKILL_DIR/scripts/lib/storage.sh"; agmsg_storage_load; storage_operation_send agsuite alice bob action op wake:bob body'
  [ "$status" -eq 13 ]
  contains "$stderr" 'unsupported_capability lifecycle-v1 for legacy'
}

@test "lifecycle contract: reloading a legacy driver cannot retain sqlite lifecycle functions" {
  local plugin_root="$TEST_SKILL_DIR/plugins" driver="$TEST_SKILL_DIR/plugins/storage/legacy.sh"
  mkdir -p "$plugin_root/storage"
  printf '%s\n' \
    'storage_check() { echo ok; }' \
    "storage_describe() { printf 'name=legacy\\n'; }" \
    >"$driver"
  printf 'storage/legacy\t%s\n' "$driver" >"$TEST_SKILL_DIR/db/trusted-plugins"

  export AGMSG_STORAGE_DRIVER=legacy
  _AGMSG_STORAGE_LOADED=""
  agmsg_storage_load

  run storage_capabilities agsuite
  [ "$status" -eq 0 ]
  contains "$output" '"driver":"legacy"'
  contains "$output" '"operation_key":"unsupported"'
  run --separate-stderr storage_operation_send agsuite alice bob action op-reload wake:bob body
  [ "$status" -eq 13 ]
  contains "$stderr" 'unsupported_capability lifecycle-v1 for legacy'
  run --separate-stderr storage_operation_renew agsuite bob message op-reload consumer 900
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

@test "lifecycle API: identity and outbox error fields reject empty text without mutation" {
  local sent message_id claimed outbox_id
  sent="$(storage_operation_send agsuite alice bob action op-empty-identity wake:bob body)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"

  run --separate-stderr bash -c 'printf "%s\n" '\''{"agent":"bob","consumer":"","lease_seconds":30}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite fetch'
  [ "$status" -eq 2 ]
  contains "$stderr" "field 'consumer' must not be empty"
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_processing_leases WHERE message_id='$message_id';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE message_id='$message_id' AND type='read_receipt';")" -eq 0 ]

  run --separate-stderr bash -c 'printf "%s\n" '\''{"owner":"","lease_seconds":30}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite outbox-claims'
  [ "$status" -eq 2 ]
  contains "$stderr" "field 'owner' must not be empty"
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE operation_key='op-empty-identity';")" = pending ]

  claimed="$(storage_outbox_claim agsuite notifier 30)"
  outbox_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$claimed" | sed "s/'/''/g")','$.id');")"
  run --separate-stderr bash -c 'printf "%s\n" "{\"outbox_id\":\"'$outbox_id'\",\"owner\":\"notifier\",\"delay_seconds\":1,\"error\":\"\"}" | "$SKILL_DIR/scripts/api.sh" post teams agsuite outbox-retries'
  [ "$status" -eq 2 ]
  contains "$stderr" "field 'error' must not be empty"
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE id='$outbox_id';")" = leased ]
}

@test "lifecycle API: U+0000 text is rejected before shell extraction and commits nothing" {
  run --separate-stderr bash -c 'printf "%s\n" '\''{"from":"alice","to":"bob","kind":"action","operation_key":"api-nul","wake_target":"wake:bob","body":"before\u0000after"}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite messages'
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  contains "$stderr" 'U+0000'
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_messages WHERE operation_key='api-nul';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE operation_key='api-nul';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_outbox WHERE operation_key='api-nul';")" -eq 0 ]
}

@test "lifecycle API and storage reject control-bearing lease tokens without canonicalizing them" {
  local sent message_id
  sent="$(storage_operation_send agsuite alice bob action op-control-token wake:bob body)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"

  run --separate-stderr bash -c 'printf "%s\n" '\''{"agent":"bob","consumer":"x\n","lease_seconds":30}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite fetch'
  [ "$status" -eq 2 ]
  contains "$stderr" 'control characters'
  run --separate-stderr storage_operation_fetch agsuite bob $'direct\nconsumer' 30
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_processing_leases WHERE message_id='$message_id';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE type='read_receipt' AND message_id='$message_id';")" -eq 0 ]

  run --separate-stderr storage_outbox_claim agsuite $'notifier\nname' 30
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT status FROM lifecycle_outbox WHERE operation_key='op-control-token';")" = pending ]
}

@test "lifecycle API and storage reject Unicode C1 control characters in tokens" {
  local sent message_id
  sent="$(storage_operation_send agsuite alice bob action op-c1-control wake:bob body)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"

  run --separate-stderr bash -c 'printf "%s\n" '\''{"agent":"bob","consumer":"api\u0085consumer","lease_seconds":30}'\'' | "$SKILL_DIR/scripts/api.sh" post teams agsuite fetch'
  [ "$status" -eq 2 ]
  contains "$stderr" 'control characters'

  run --separate-stderr storage_operation_fetch agsuite bob $'direct\u0085consumer' 30
  [ "$status" -eq 13 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_processing_leases WHERE message_id='$message_id';")" -eq 0 ]
  [ "$(sqlite3 "$TEST_SKILL_DIR/db/messages.db" "SELECT COUNT(*) FROM lifecycle_events WHERE type='read_receipt' AND message_id='$message_id';")" -eq 0 ]
}

@test "lifecycle API: processing lease renewal uses the public facade" {
  local sent message_id
  sent="$(storage_operation_send agsuite alice bob action api-renew wake:bob work)"
  message_id="$(sqlite_mem "SELECT json_extract('$(printf '%s' "$sent" | sed "s/'/''/g")','$.id');")"
  storage_operation_fetch agsuite bob api-renewer 30 >/dev/null

  run bash -c 'printf "%s\n" "{\"agent\":\"bob\",\"message_id\":\"'$message_id'\",\"operation_key\":\"api-renew\",\"consumer\":\"api-renewer\",\"lease_seconds\":900}" | "$SKILL_DIR/scripts/api.sh" post teams agsuite lease-renewals'
  [ "$status" -eq 0 ]
  contains "$output" '"type":"processing_lease"'
  contains "$output" '"consumer":"api-renewer"'
}
