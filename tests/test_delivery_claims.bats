#!/usr/bin/env bats
# Driver primitive gate: no consumer, facade, role reservation or live runtime.
load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init claims >/dev/null
  DB="$(agmsg_db_path claims)"
}
teardown() { teardown_test_env; }

_sql() { sqlite3 "$DB" "$1"; }
_token() { printf '%s\n' "$1" | jq -r '.claim_token' | head -1; }
_expire() { _sql "UPDATE delivery_claims SET expires_at=CAST(strftime('%s','now') AS INTEGER);"; }

_same_id_messages() {
  _sql "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at) VALUES
    (101,'claims','a','bob','one','2026-01-01'),
    (102,'other','a','bob','two','2026-01-01'),
    (103,'claims','a','carol','three','2026-01-01');
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id) VALUES
    ('message_sent','same','claims','a','carol','three','2026-01-01',103),
    ('message_sent','same','other','a','bob','two','2026-01-01',102),
    ('message_sent','same','claims','a','bob','one','2026-01-01',101);"
}

@test "claims: advertised reservation preserves unread and hides readiness" {
  local id rows token
  id=$(storage_send claims alice bob hello)
  rows=$(storage_claim_unread claims bob reader 60 10)
  token=$(_token "$rows")
  [ "${#token}" -eq 64 ]
  [ "$(printf '%s\n' "$rows" | jq -r .id)" = "$id" ]
  [ "$(_sql "SELECT COUNT(*) FROM delivery_claims WHERE expires_at>strftime('%s','now');")" = 1 ]
  run storage_list_unread claims bob
  [[ "$output" == *hello* ]] || return 1
  [ -z "$(storage_list_deliverable claims bob)" ]
  [ -z "$(storage_claim_unread claims bob reader 60 10)" ]
  run storage_describe claims
  [[ "$output" == *delivery-claims-v1,delivery-claims-bytes-v1* ]] || return 1
  storage_claim_release claims bob reader "$token" "$id" >/dev/null
  [[ "$(storage_list_deliverable claims bob)" == *hello* ]] || return 1
}

@test "claims: exact acquisition is all-or-none and validates bounds and addressed IDs" {
  local first second held token
  first=$(storage_send claims alice bob first)
  second=$(storage_send claims alice bob second)
  held=$(storage_claim_unread claims bob holder 60 1 "$first")
  token=$(_token "$held")
  run storage_claim_unread claims bob other 60 2 "$first" "$second"
  [ "$status" = 13 ]; [[ "$output" == *claim_unavailable* ]] || return 1
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
  run storage_claim_unread claims carol other 60 2 "$second"
  [ "$status" = 13 ]
  run storage_claim_unread claims bob other 0 2
  [ "$status" = 13 ]
  run storage_claim_unread claims bob other 3601 2
  [ "$status" = 13 ]
  run storage_claim_unread claims bob other 60 1001
  [ "$status" = 13 ]
  storage_claim_release claims bob holder "$token" "$first" >/dev/null
  # Exact recovery is not truncated to the normal batch limit.
  held=$(storage_claim_unread claims bob recovery 60 1 "$first" "$second")
  [ "$(printf '%s\n' "$held" | jq -s length)" = 2 ]
}

@test "claims: separate racing processes never share a message or a larger batch" {
  local i p1 p2 a b
  for i in $(seq 1 20); do storage_send claims alice bob "body-$i" >/dev/null; done
  (storage_claim_unread claims bob one 60 10 >"$TEST_SKILL_DIR/a") 3>&- & p1=$!
  (storage_claim_unread claims bob two 60 10 >"$TEST_SKILL_DIR/b") 3>&- & p2=$!
  wait "$p1"; wait "$p2"
  [ "$(jq -s length "$TEST_SKILL_DIR/a")" = 10 ]
  [ "$(jq -s length "$TEST_SKILL_DIR/b")" = 10 ]
  [ "$(cat "$TEST_SKILL_DIR/a" "$TEST_SKILL_DIR/b" | jq -s 'map(.id)|unique|length')" = 20 ]
  _sql 'DELETE FROM delivery_claims; DELETE FROM events; DELETE FROM messages;'
  storage_send claims alice bob only >/dev/null
  (storage_claim_unread claims bob one 60 1 >"$TEST_SKILL_DIR/a") 3>&- & p1=$!
  (storage_claim_unread claims bob two 60 1 >"$TEST_SKILL_DIR/b") 3>&- & p2=$!
  wait "$p1"; wait "$p2"
  [ "$(cat "$TEST_SKILL_DIR/a" "$TEST_SKILL_DIR/b" | jq -s length)" = 1 ]
}

@test "claims: expiry rotates the fence and stale owners cannot change successors" {
  local id old fresh token
  id=$(storage_send claims alice bob x)
  old=$(_token "$(storage_claim_unread claims bob owner 60 1)")
  _expire
  fresh=$(storage_claim_unread claims bob owner 60 1)
  token=$(_token "$fresh")
  [ "$token" != "$old" ]
  run storage_claim_renew claims bob owner "$old" 60 "$id"; [ "$status" = 13 ]
  run storage_claim_ack claims bob owner "$old" "$id"; [ "$status" = 13 ]
  run storage_claim_release claims bob owner "$old" "$id"; [ "$status" = 13 ]
  [ "$(_sql 'SELECT token FROM delivery_claims;')" = "$token" ]
  [[ "$(storage_list_unread claims bob)" == *'"body":"x"'* ]] || return 1
}

@test "claims: renew release and ACK validate the whole set before mutation" {
  local a b token before
  a=$(storage_send claims alice bob a); b=$(storage_send claims alice bob b)
  token=$(_token "$(storage_claim_unread claims bob owner 60 2)")
  before=$(_sql 'SELECT sum(expires_at) FROM delivery_claims;')
  run storage_claim_renew claims bob owner "$token" 3600 "$a" missing; [ "$status" = 13 ]
  [ "$(_sql 'SELECT sum(expires_at) FROM delivery_claims;')" = "$before" ]
  run storage_claim_release claims bob owner "$token" "$a" missing; [ "$status" = 13 ]
  run storage_claim_ack claims bob owner "$token" "$a" missing; [ "$status" = 13 ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 2 ]
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  run storage_claim_release claims bob wrong-owner "$token" "$a"; [ "$status" = 13 ]
  storage_claim_renew claims bob owner "$token" 3600 "$a" "$b" >/dev/null
  [ "$(_sql 'SELECT sum(expires_at) FROM delivery_claims;')" -gt "$before" ]
}

@test "claims: partial ACK uses exact reads and a gap-safe frontier with retained receipts" {
  local a b token tip before
  a=$(storage_send claims alice bob a); b=$(storage_send claims alice bob b)
  tip=$(storage_watch_tip claims:bob)
  token=$(_token "$(storage_claim_unread claims bob owner 60 2)")
  storage_claim_ack claims bob owner "$token" "$b" >/dev/null
  [ "$(storage_read_cursor_get claims bob)" = 0 ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
  [ "$(_sql 'SELECT retain_until-acked_at FROM delivery_ack_receipts;')" = 86400 ]
  [ "$(_sql 'SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;')" = 1 ]
  before=$(_sql 'SELECT retain_until FROM delivery_ack_receipts;')
  _expire
  storage_claim_ack claims bob owner "$token" "$b" >/dev/null
  [ "$(_sql 'SELECT retain_until FROM delivery_ack_receipts;')" = "$before" ]
  token=$(_token "$(storage_claim_unread claims bob successor 60 1 "$a")")
  storage_claim_ack claims bob successor "$token" "$a" >/dev/null
  [ "$(storage_read_cursor_get claims bob)" -ge "$tip" ]
  [ -z "$(storage_list_unread claims bob)" ]
}

@test "claims: lost ACK response retries by receipt only and expired receipt is unknown" {
  local id token
  id=$(storage_send claims alice bob x)
  token=$(_token "$(storage_claim_unread claims bob owner 60 1)")
  storage_claim_ack claims bob owner "$token" "$id" >/dev/null
  storage_claim_ack claims bob owner "$token" "$id" >/dev/null
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 1 ]
  _sql "UPDATE delivery_ack_receipts SET retain_until=CAST(strftime('%s','now') AS INTEGER);"
  run storage_claim_ack claims bob owner "$token" "$id"
  [ "$status" = 13 ]; [[ "$output" == *receipt_unknown* ]] || return 1
  [ -z "$(storage_claim_unread claims bob anyone 60 1)" ]
}

@test "claims: commit failure exposes no payload and rolls back the reservation" {
  storage_send claims alice bob secret-body >/dev/null
  _sql "CREATE TABLE missing_parent(id PRIMARY KEY);
    CREATE TABLE deferred_failure(id REFERENCES missing_parent(id) DEFERRABLE INITIALLY DEFERRED);
    CREATE TRIGGER fail_commit AFTER INSERT ON delivery_claims BEGIN
      INSERT INTO deferred_failure VALUES(1); END;"
  # Real SQLite deferred constraint fails at COMMIT, after the payload SELECT.
  # Keep the production wrapper: SQLite 3.53.4's SQL -cmd with -bail can
  # exit successfully without reading stdin. Enable FK checks in the SQL
  # stream instead, before BEGIN, and prove the intended failure fired.
  eval "$(declare -f _sqlite_exec_stdin | sed '1s/_sqlite_exec_stdin/_fixture_sqlite_exec_stdin/')"
  _sqlite_exec_stdin() {
    local rc=0
    _fixture_sqlite_exec_stdin "$1" "PRAGMA foreign_keys=ON; $2" || rc=$?
    printf '%s\n' "$rc" >"$TEST_SKILL_DIR/sqlite-rc"
    return "$rc"
  }
  local rc=0
  storage_claim_unread claims bob owner 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$(cat "$TEST_SKILL_DIR/sqlite-rc")" -ne 0 ]
  grep -q 'FOREIGN KEY constraint failed' "$TEST_SKILL_DIR/err"
  [ "$rc" = 13 ]
  [ ! -s "$TEST_SKILL_DIR/out" ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 0 ]
  [ "$(_sql 'SELECT COUNT(*) FROM deferred_failure;')" = 0 ]
}

@test "claims: failed ACK receipt write rolls back exact reads mirror frontier and claims" {
  local id token
  id=$(storage_send claims alice bob x)
  token=$(_token "$(storage_claim_unread claims bob owner 60 1)")
  _sql "CREATE TRIGGER fail_receipt BEFORE INSERT ON delivery_ack_receipts BEGIN SELECT RAISE(ABORT,'fixture receipt failure'); END;"
  run storage_claim_ack claims bob owner "$token" "$id"
  [ "$status" = 13 ]
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
  [ "$(_sql 'SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;')" = 0 ]
  [ "$(storage_read_cursor_get claims bob)" = 0 ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
  _sql 'DROP TRIGGER fail_receipt;'
  storage_claim_ack claims bob owner "$token" "$id" >/dev/null
  [ -z "$(storage_list_unread claims bob)" ]
}

@test "claims: killed claimant recovers only after expiry with a different fence" {
  local pid i old fresh
  storage_send claims alice bob recover >/dev/null
  bash -c 'source "$1/lib/storage.sh"; agmsg_storage_load; storage_claim_unread claims bob killed 60 1 > "$2"; exec sleep 30' \
    _ "$SCRIPTS" "$TEST_SKILL_DIR/claimed" 3>&- & pid=$!
  for i in $(seq 1 100); do [ -s "$TEST_SKILL_DIR/claimed" ] && break; sleep 0.02; done
  [ -s "$TEST_SKILL_DIR/claimed" ]
  old=$(_token "$(cat "$TEST_SKILL_DIR/claimed")")
  kill -KILL "$pid"; wait "$pid" || true
  [ -z "$(storage_claim_unread claims bob next 60 1)" ]
  _expire
  fresh=$(_token "$(storage_claim_unread claims bob next 60 1)")
  [ -n "$fresh" ]; [ "$old" != "$fresh" ]
}

@test "claims: imported reads dominate reservations and matching live ACK reconciles" {
  local a b token
  a=$(storage_send claims alice bob a); b=$(storage_send claims alice bob b)
  token=$(_token "$(storage_claim_unread claims bob owner 60 2)")
  printf '{"type":"message_read","id":"remote-read","team":"claims","agent":"bob","msg_id":"%s","at":"2026-01-01T00:00:00Z"}\n' "$a" >"$TEST_SKILL_DIR/import"
  storage_import claims "$TEST_SKILL_DIR/import"
  run storage_claim_renew claims bob owner "$token" 60 "$a" "$b"
  [ "$status" = 13 ]; [[ "$output" == *already_read* ]] || return 1
  storage_claim_ack claims bob owner "$token" "$a" >/dev/null
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read' AND msg_id='$a';")" = 1 ]
  _expire
  run storage_claim_unread claims bob next 60 2 "$a" "$b"; [ "$status" = 13 ]
  local rows; rows=$(storage_claim_unread claims bob next 60 2)
  [ "$(printf '%s\n' "$rows" | jq -r .id)" = "$b" ]
}

@test "claims: event legacy and negative projection identities reuse the unread projection" {
  local linked rows token id
  linked=$(storage_send claims alice bob linked)
  _sql "INSERT INTO events(type,id,team,from_agent,to_agent,body,at) VALUES('message_sent','opaque:event','claims','alice','bob','event-only','2026-01-01');
    INSERT INTO messages(id,team,from_agent,to_agent,body,created_at) VALUES(70,'claims','alice','bob','legacy-only','2026-01-01'),(71,'claims','alice','bob','projected','2026-01-01');
    INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at,legacy_id) VALUES(-71,'message_sent','projection','claims','alice','bob','projected','2026-01-01',71);"
  rows=$(storage_claim_unread claims bob owner 60 10)
  [ "$(printf '%s\n' "$rows" | jq -s length)" = 4 ]
  printf '%s\n' "$rows" | jq -e -s --arg linked "$linked" 'map(.id)|sort == (["70","71","opaque:event",$linked]|sort)'
  token=$(_token "$rows")
  storage_claim_ack claims bob owner "$token" "$linked" opaque:event 70 71 >/dev/null
  [ -z "$(storage_list_unread claims bob)" ]
  [ "$(_sql 'SELECT COUNT(*) FROM messages WHERE id IN (70,71) AND read_at IS NULL;')" = 2 ]
}

@test "claims: quote control and large bodies stay off external argv and preserve cleanup traps" {
  local body id rows token trap_before
  body=$(printf '%140000s' x); body="quote' $body"$'\n\r\t\001end'
  agmsg_sqlite() {
    local arg
    for arg in "$@"; do [ "${#arg}" -lt 10000 ] || return 99; done
    command sqlite3 -cmd '.timeout 5000' "$@"
  }
  id=$(storage_send claims "a'lice" bob "$body")
  trap_before=$(trap -p EXIT)
  rows=$(storage_claim_unread claims bob "owner'quoted" 60 1 "$id")
  [ "$(printf '%s\n' "$rows" | jq -r .body)" = "$body" ]
  token=$(_token "$rows")
  storage_claim_ack claims bob "owner'quoted" "$token" "$id" >/dev/null
  [ "$(trap -p EXIT)" = "$trap_before" ]
}

@test "claims: team and recipient keys are isolated even with identical opaque IDs" {
  _same_id_messages
  local token other
  token=$(_token "$(storage_claim_unread claims bob owner 60 1)")
  [ "$(storage_claim_unread other bob owner 60 1 | jq -r .body)" = two ]
  [ "$(storage_claim_unread claims carol owner 60 1 | jq -r .body)" = three ]
  storage_claim_ack claims bob owner "$token" same >/dev/null
  [ "$(_sql 'SELECT id FROM messages WHERE read_at IS NOT NULL;')" = 101 ]
  [[ "$(storage_list_unread other bob)" == *two* ]] || return 1
  [[ "$(storage_list_unread claims carol)" == *three* ]] || return 1
}

@test "claims: imported reads preserve another recipient's same-ID claim and legacy mirror" {
  _same_id_messages
  local bob carol
  bob=$(_token "$(storage_claim_unread claims bob owner 60 1)")
  carol=$(_token "$(storage_claim_unread claims carol owner 60 1)")
  printf '%s\n' '{"type":"message_read","id":"remote-read","team":"claims","agent":"bob","msg_id":"same","at":"2026-01-01T00:00:00Z"}' >"$TEST_SKILL_DIR/import"
  storage_import claims "$TEST_SKILL_DIR/import"
  [ "$(_sql 'SELECT id FROM messages WHERE read_at IS NOT NULL;')" = 101 ]
  [ -z "$(storage_list_unread claims bob)" ]
  [[ "$(storage_list_unread claims carol)" == *three* ]] || return 1
  [[ "$(storage_list_unread other bob)" == *two* ]] || return 1
  run storage_claim_renew claims bob owner "$bob" 60 same
  [ "$status" = 13 ]; [[ "$output" == *already_read* ]] || return 1
  storage_claim_renew claims carol owner "$carol" 60 same >/dev/null
  storage_claim_ack claims bob owner "$bob" same >/dev/null
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read' AND agent='bob' AND msg_id='same';")" = 1 ]
  [ "$(_sql 'SELECT id FROM messages WHERE read_at IS NOT NULL;')" = 101 ]
}

@test "claims: revision one upgrade does not repeat backlog adoption" {
  storage_send claims alice bob still-unread >/dev/null
  _sql 'DROP TABLE delivery_claims; DROP TABLE delivery_ack_receipts; DROP TABLE delivery_maintenance; PRAGMA user_version=1;'
  storage_init claims >/dev/null
  [ "$(_sql 'PRAGMA user_version;')" = 2 ]
  [[ "$(storage_claim_unread claims bob owner 60 1)" == *still-unread* ]] || return 1
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
}

@test "claims: per-team partition selection isolates reservations and read state" {
  mkdir -p "$SKILL_DIR/teams/isolated"
  printf '{"drivers":{"partition":"per-team"}}\n' >"$SKILL_DIR/teams/isolated/config.json"
  local a b token isolated_db
  a=$(storage_send claims alice bob shared)
  b=$(storage_send isolated alice bob partitioned)
  isolated_db=$(agmsg_db_path isolated)
  [ "$isolated_db" != "$DB" ]
  token=$(_token "$(storage_claim_unread isolated bob owner 60 1)")
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 0 ]
  storage_claim_ack isolated bob owner "$token" "$b" >/dev/null
  [ -z "$(storage_list_unread isolated bob)" ]
  [[ "$(storage_list_unread claims bob)" == *shared* ]] || return 1
}

# Hold the real transaction after BEGIN IMMEDIATE, using sqlite's own shell
# command only in this fixture. Competing calls use the unmodified driver.
_hold_delivery_transaction() {
  agmsg_sqlite() {
    if [ "${1-}" = -bail ] && [ "${2-}" = -batch ]; then
      {
        local first; IFS= read -r first
        printf '%s\n' "$first"
        if [ "$first" = 'BEGIN IMMEDIATE;' ]; then
          printf '.shell touch "%s/ready"\n' "$TEST_SKILL_DIR"
          printf '.shell while [ ! -e "%s/release" ]; do sleep 0.02; done\n' "$TEST_SKILL_DIR"
        fi
        cat
      } | command sqlite3 -cmd '.timeout 5000' "$@"
    else
      command sqlite3 -cmd '.timeout 5000' "$@"
    fi
  }
  "$@"
}

@test "maintenance: real concurrent transaction orders fence acquisition and renewal" {
  local mode id token first second i rc1 rc2
  id=$(storage_send claims alice bob x)
  for mode in claim-first barrier-first renew-first barrier-before-renew; do
    _sql 'DELETE FROM delivery_claims; DELETE FROM delivery_maintenance;'
    rm -f "$TEST_SKILL_DIR/ready" "$TEST_SKILL_DIR/release"
    token=""
    case "$mode" in
      renew-first|barrier-before-renew)
        token=$(_token "$(storage_claim_unread claims bob owner 60 1)") ;;
    esac
    [ "$mode" != barrier-before-renew ] || _expire
    case "$mode" in
      claim-first)
        (_hold_delivery_transaction storage_claim_unread claims bob owner 60 1 >"$TEST_SKILL_DIR/first" 2>&1) 3>&- & ;;
      renew-first)
        (_hold_delivery_transaction storage_claim_renew claims bob owner "$token" 60 "$id" >"$TEST_SKILL_DIR/first" 2>&1) 3>&- & ;;
      *)
        (_hold_delivery_transaction storage_delivery_maintenance_begin claims rename >"$TEST_SKILL_DIR/first" 2>&1) 3>&- & ;;
    esac
    first=$!
    for i in $(seq 1 500); do [ -e "$TEST_SKILL_DIR/ready" ] && break; sleep 0.02; done
    [ -e "$TEST_SKILL_DIR/ready" ]
    case "$mode" in
      claim-first|renew-first)
        (storage_delivery_maintenance_begin claims rename >"$TEST_SKILL_DIR/second" 2>&1) 3>&- & ;;
      barrier-first)
        (storage_claim_unread claims bob next 60 1 >"$TEST_SKILL_DIR/second" 2>&1) 3>&- & ;;
      barrier-before-renew)
        (storage_claim_renew claims bob owner "$token" 60 "$id" >"$TEST_SKILL_DIR/second" 2>&1) 3>&- & ;;
    esac
    second=$!
    touch "$TEST_SKILL_DIR/release"
    rc1=0; wait "$first" || rc1=$?
    rc2=0; wait "$second" || rc2=$?
    [ "$rc1" = 0 ]; [ "$rc2" = 13 ]
    [ "$(_sql "SELECT COUNT(*) FROM delivery_claims c JOIN delivery_maintenance m ON c.team=m.team WHERE c.expires_at>CAST(strftime('%s','now') AS INTEGER);")" = 0 ]
  done
}

@test "maintenance: claims first refuse begin, barrier first refuses acquire and renew" {
  local id token barrier fence
  id=$(storage_send claims alice bob x)
  token=$(_token "$(storage_claim_unread claims bob owner 60 1)")
  run storage_delivery_maintenance_begin claims rename
  [ "$status" = 13 ]; [[ "$output" == *claims_active* ]] || return 1
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_maintenance;')" = 0 ]
  _expire
  barrier=$(storage_delivery_maintenance_begin claims rename)
  fence=$(printf '%s\n' "$barrier" | jq -r .token)
  run storage_claim_unread claims bob next 60 1
  [ "$status" = 13 ]; [[ "$output" == *maintenance_active* ]] || return 1
  # A formerly live owner cannot renew through an admitted maintenance barrier.
  run storage_claim_renew claims bob owner "$token" 60 "$id"
  [ "$status" = 13 ]; [[ "$output" == *maintenance_active* ]] || return 1
  [ -z "$(storage_list_deliverable claims bob)" ]
  _sqlite_delivery_maintenance_finish_db "$DB" rename "$fence" claims >/dev/null
  [[ "$(storage_claim_unread claims bob next 60 1)" == *'"body":"x"'* ]] || return 1
}

@test "maintenance: barriers initialize absent explicit stores and persist until exact verified finish" {
  local path="$TEST_SKILL_DIR/new/place/destination.db" rows token fragment
  [ -z "$(_sqlite_delivery_maintenance_get_db "$path" alpha)" ]; [ ! -e "$path" ]
  rows=$(_sqlite_delivery_maintenance_begin_db "$path" "rename:alpha:beta" alpha beta)
  token=$(printf '%s\n' "$rows" | jq -r .token | head -1)
  [ "$(printf '%s\n' "$rows" | jq -s length)" = 2 ]
  [ "$(sqlite3 "$path" 'PRAGMA user_version;')" = 2 ]
  sqlite3 "$path" 'UPDATE delivery_maintenance SET created_at=0;'
  run bash -c 'source "$1/lib/storage.sh"; agmsg_storage_load; _sqlite_delivery_maintenance_get_db "$2" alpha' _ "$SCRIPTS" "$path"
  [ "$status" = 0 ]; [[ "$output" == *"$token"* ]] || return 1
  run _sqlite_delivery_maintenance_finish_db "$path" wrong "$token" alpha beta; [ "$status" = 13 ]
  run _sqlite_delivery_maintenance_finish_db "$path" rename:alpha:beta "$(printf '%064d' 0)" alpha beta; [ "$status" = 13 ]
  run _sqlite_delivery_maintenance_finish_db "$path" rename:alpha:beta "$token" alpha missing; [ "$status" = 13 ]
  run _sqlite_delivery_maintenance_finish_db "$path" rename:alpha:beta "$token" alpha; [ "$status" = 13 ]
  [ "$(sqlite3 "$path" 'SELECT COUNT(*) FROM delivery_maintenance;')" = 2 ]
  sqlite3 "$path" "INSERT INTO messages(team,from_agent,to_agent,body) VALUES('alpha','a','b','preserve-on-failure');"
  fragment=$(_sqlite_delivery_maintenance_finish_sql wrong "$token" alpha beta)
  run _sqlite_delivery_run_db "$path" "BEGIN IMMEDIATE; DELETE FROM messages; $fragment COMMIT;"
  [ "$status" = 13 ]
  [ "$(sqlite3 "$path" 'SELECT COUNT(*) FROM messages;')" = 1 ]
  fragment=$(_sqlite_delivery_maintenance_finish_sql rename:alpha:beta "$token" alpha beta)
  _sqlite_delivery_run_db "$path" "BEGIN IMMEDIATE; DELETE FROM messages; $fragment COMMIT;"
  [ -z "$(_sqlite_delivery_maintenance_get_db "$path" alpha)" ]
}

@test "maintenance: whole-team admission refuses another recipient but permits ACK receipts" {
  local id token rows
  id=$(storage_send claims alice carol x)
  token=$(_token "$(storage_claim_unread claims carol owner 60 1)")
  run _sqlite_delivery_maintenance_begin_db "$DB" rename:bob claims other
  [ "$status" = 13 ]; [ "$(_sql 'SELECT COUNT(*) FROM delivery_maintenance;')" = 0 ]
  storage_claim_ack claims carol owner "$token" "$id" >/dev/null
  rows=$(_sqlite_delivery_maintenance_begin_db "$DB" rename:bob claims other)
  [ "$(printf '%s\n' "$rows" | jq -s length)" = 2 ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 1 ]
  storage_claim_ack claims carol owner "$token" "$id" >/dev/null
}

@test "maintenance: read-only preflight accepts older schema and fails closed on missing current state" {
  _sql 'DROP TABLE delivery_maintenance; PRAGMA user_version=1;'
  run _sqlite_delivery_maintenance_get_db "$DB" claims
  [ "$status" = 0 ]; [ -z "$output" ]
  [ "$(_sql 'PRAGMA user_version;')" = 1 ]
  [ "$(_sql "SELECT COUNT(*) FROM sqlite_master WHERE name='delivery_maintenance';")" = 0 ]
  _sql 'PRAGMA user_version=2;'
  local rc=0
  _sqlite_delivery_maintenance_get_db "$DB" claims >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 12 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  [[ "$(cat "$TEST_SKILL_DIR/err")" == *corrupt_state* ]] || return 1
}

# Interpose only after the REAL committed claim, before its caller can publish
# buffered records. This makes selector/barrier races deterministic.
_intercept_claim_commit() {
  eval "$(declare -f _sqlite_delivery_run_db | sed '1s/_sqlite_delivery_run_db/_fixture_delivery_run_db/')"
  _sqlite_delivery_run_db() {
    local result
    result="$(_fixture_delivery_run_db "$@")" || return 13
    case "$2" in *'INSERT INTO delivery_claims('*) _fixture_after_commit "$1" || return 13 ;; esac
    [ -z "$result" ] || printf '%s\n' "$result"
  }
}

@test "claims: selector change after commit withholds payload despite a primed poll-cycle cache" {
  mkdir -p "$SKILL_DIR/teams/isolated"
  printf '{"drivers":{"partition":"per-team"}}\n' >"$SKILL_DIR/teams/isolated/config.json"
  storage_send isolated alice bob held >/dev/null
  local captured rc=0
  captured=$(agmsg_db_path isolated)
  _AGMSG_POLL_CYCLE_EPOCH=7
  _agmsg_partition_load isolated
  _fixture_after_commit() {
    printf '{"drivers":{"partition":"shared"}}\n' >"$SKILL_DIR/teams/isolated/config.json"
  }
  _intercept_claim_commit
  storage_claim_unread isolated bob owner 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  [[ "$(cat "$TEST_SKILL_DIR/err")" == *selector_changed* ]] || return 1
  [ "$(sqlite3 "$captured" 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 0 ]
}

@test "claims: shared fallback admission blocks per-team disclosure before and after commit" {
  mkdir -p "$SKILL_DIR/teams/isolated"
  printf '{"drivers":{"partition":"per-team"}}\n' >"$SKILL_DIR/teams/isolated/config.json"
  storage_send isolated alice bob held >/dev/null
  local captured barrier token rc=0
  captured=$(agmsg_db_path isolated)
  barrier=$(_sqlite_delivery_maintenance_begin_db "$DB" move isolated)
  token=$(printf '%s\n' "$barrier" | jq -r .token)
  storage_claim_unread isolated bob owner 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  [ "$(sqlite3 "$captured" 'SELECT COUNT(*) FROM delivery_claims;')" = 0 ]
  _sqlite_delivery_maintenance_finish_db "$DB" move "$token" isolated >/dev/null
  _fixture_after_commit() { _sqlite_delivery_maintenance_begin_db "$DB" move isolated >/dev/null; }
  _intercept_claim_commit
  rc=0
  storage_claim_unread isolated bob owner 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  [[ "$(cat "$TEST_SKILL_DIR/err")" == *maintenance_active* ]] || return 1
  [ "$(sqlite3 "$captured" 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
}

@test "claims: postcommit selector and shared-state read failures disclose no payload" {
  mkdir -p "$SKILL_DIR/teams/isolated"
  printf '{"drivers":{"partition":"per-team"}}\n' >"$SKILL_DIR/teams/isolated/config.json"
  storage_send isolated alice bob held >/dev/null
  local captured mode rc
  captured=$(agmsg_db_path isolated)
  _sqlite_db() {
    [ ! -e "$TEST_SKILL_DIR/resolver-failed" ] || return 1
    agmsg_db_path "$1"
  }
  _fixture_after_commit() {
    case "$mode" in
      selector) touch "$TEST_SKILL_DIR/resolver-failed" ;;
      shared) sqlite3 "$DB" 'DROP TABLE delivery_maintenance;' ;;
    esac
  }
  _intercept_claim_commit
  for mode in selector shared; do
    rm -f "$TEST_SKILL_DIR/resolver-failed"
    sqlite3 "$captured" 'DELETE FROM delivery_claims;'
    rc=0
    storage_claim_unread isolated bob owner 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
    [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
    [ "$(sqlite3 "$captured" 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
  done
}

@test "claims: acquisition pins init and transaction to one path when config changes after init" {
  mkdir -p "$SKILL_DIR/teams/isolated"
  printf '{"drivers":{"partition":"per-team"}}\n' >"$SKILL_DIR/teams/isolated/config.json"
  storage_send isolated alice bob held >/dev/null
  local captured rc=0
  captured=$(agmsg_db_path isolated)
  eval "$(declare -f _sqlite_init_db | sed '1s/_sqlite_init_db/_fixture_init_db/')"
  _sqlite_init_db() {
    _fixture_init_db "$1" || return 13
    printf '{"drivers":{"partition":"shared"}}\n' >"$SKILL_DIR/teams/isolated/config.json"
  }
  storage_claim_unread isolated bob owner 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  [ "$(sqlite3 "$captured" 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 0 ]
}

@test "claims: renew release and ACK resolve exactly one path for init and transaction" {
  local a b c token other="$TEST_SKILL_DIR/other.db" operation id
  a=$(storage_send claims alice bob a); b=$(storage_send claims alice bob b); c=$(storage_send claims alice bob c)
  token=$(_token "$(storage_claim_unread claims bob owner 60 3)")
  _sqlite_init_db "$other" >/dev/null
  _sqlite_db() {
    local count; count=$(cat "$TEST_SKILL_DIR/resolves")
    printf '%s\n' "$((count+1))" >"$TEST_SKILL_DIR/resolves"
    if [ "$count" = 0 ]; then printf '%s\n' "$DB"; else printf '%s\n' "$other"; fi
  }
  for operation in renew release ack; do
    printf '0\n' >"$TEST_SKILL_DIR/resolves"
    case "$operation" in
      renew) storage_claim_renew claims bob owner "$token" 60 "$a" >/dev/null ;;
      release) storage_claim_release claims bob owner "$token" "$b" >/dev/null ;;
      ack) storage_claim_ack claims bob owner "$token" "$c" >/dev/null ;;
    esac
    [ "$(cat "$TEST_SKILL_DIR/resolves")" = 1 ]
  done
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
  [ "$(sqlite3 "$other" "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
}

@test "claims: trailing LF in opaque ID and owner stays distinct through claim renew and ACK" {
  local id=$'trailing\n' owner=$'reader\n' rows token
  _sql "INSERT INTO events(type,id,team,from_agent,to_agent,body,at) VALUES
    ('message_sent','trailing'||char(10),'claims','alice','bob','LF','now'),
    ('message_sent','trailing','claims','alice','bob','plain','now');"
  rows=$(storage_claim_unread claims bob "$owner" 600 1 "$id")
  token=$(_token "$rows")
  [ "$(_sql "SELECT hex(msg_id)||':'||hex(owner) FROM delivery_claims;")" = '747261696C696E670A:7265616465720A' ]
  run storage_claim_renew claims bob reader "$token" 600 "$id"
  [ "$status" = 13 ]
  run storage_claim_ack claims bob "$owner" "$token" trailing
  [ "$status" = 13 ]
  storage_claim_renew claims bob "$owner" "$token" 600 "$id" >/dev/null
  storage_claim_ack claims bob "$owner" "$token" "$id" >/dev/null
  [ "$(_sql "SELECT hex(msg_id) FROM events WHERE type='message_read';")" = 747261696C696E670A ]
  [ "$(storage_list_unread claims bob | jq -r .body)" = plain ]
  storage_claim_ack claims bob "$owner" "$token" "$id" >/dev/null
}

@test "claims: failed ACK SQL generation preserves the lease and creates no receipt" {
  local id token generator original rc
  id=$(storage_send claims alice bob retained)
  token=$(_token "$(storage_claim_unread claims bob owner 60 1)")
  for generator in compat_uuid7 _sqlite_read_frontier_sql; do
    original=$(declare -f "$generator")
    eval "$generator() { return 1; }"
    # Conditional callers disable errexit throughout the function: refusal
    # must be explicit, not an accidental consequence of the caller's flags.
    if storage_claim_ack claims bob owner "$token" "$id" >"$TEST_SKILL_DIR/result"; then rc=0; else rc=$?; fi
    [ "$rc" = 13 ]
    grep -qx runtime_error "$TEST_SKILL_DIR/result"
    [ "$(_sql 'SELECT COUNT(*) FROM delivery_claims;')" = 1 ]
    [ "$(_sql 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 0 ]
    [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
    [ "$(_sql 'SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;')" = 0 ]
    [ "$(storage_read_cursor_get claims bob)" = 0 ]
    [ "$(storage_list_unread claims bob | jq -r .body)" = retained ]
    [ -z "$(storage_claim_unread claims bob competitor 60 1)" ]
    eval "$original"
  done
  storage_claim_ack claims bob owner "$token" "$id" >/dev/null
  [ -z "$(storage_list_unread claims bob)" ]
  [ "$(_sql 'SELECT COUNT(*) FROM delivery_ack_receipts;')" = 1 ]
}

@test "claims: legacy consume refuses SQL generation failure without advancing read state" {
  local id tip generator original rc
  id=$(storage_send claims alice bob retained)
  tip=$(storage_watch_tip claims:bob)
  for generator in compat_uuid7 _sqlite_read_frontier_sql; do
    original=$(declare -f "$generator")
    eval "$generator() { return 1; }"
    if storage_read_cursor_consume claims bob "$tip" "$id" >"$TEST_SKILL_DIR/result"; then rc=0; else rc=$?; fi
    [ "$rc" = 13 ]
    grep -qx runtime_error "$TEST_SKILL_DIR/result"
    [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 0 ]
    [ "$(_sql 'SELECT COUNT(*) FROM messages WHERE read_at IS NOT NULL;')" = 0 ]
    [ "$(storage_read_cursor_get claims bob)" = 0 ]
    [ "$(storage_list_unread claims bob | jq -r .body)" = retained ]
    eval "$original"
  done
  storage_read_cursor_consume claims bob "$tip" "$id" >/dev/null
  [ -z "$(storage_list_unread claims bob)" ]
}

@test "claims: a supported 1000-row exact batch reaches ACK within its 60-second lease" {
  _sql "WITH RECURSIVE n(v) AS (SELECT 1 UNION ALL SELECT v+1 FROM n WHERE v<1000)
    INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
    SELECT 'message_sent','bulk-'||v,'claims','alice','bob','body-'||v,'now' FROM n;"
  # Execute like a consumer: Bats' per-command DEBUG tracing otherwise adds
  # instrumentation time to every builtin in this thousand-member batch.
  run bash -c '
    set -euo pipefail
    source "$1/lib/storage.sh"; agmsg_storage_load
    ids=(); for ((id=1; id<=1000; id++)); do ids+=("bulk-$id"); done
    SECONDS=0
    rows=$(storage_claim_unread claims bob reader 60 1000 "${ids[@]}")
    token=$(printf "%s\n" "$rows" | jq -s -r ".[0].claim_token")
    [ "$(printf "%s\n" "$rows" | jq -s length)" = 1000 ]
    eval "$(declare -f compat_uuid7 | sed "1s/compat_uuid7/_uuid_original/")"
    calls_dir="$2"
    compat_uuid7() { printf "called\n" >> "$calls_dir/uuid-calls"; _uuid_original; }
    storage_claim_ack claims bob reader "$token" "${ids[@]}" >/dev/null
    printf "elapsed_seconds=%s\n" "$SECONDS"
    [ "$SECONDS" -lt 60 ]
  ' fixture "$SCRIPTS" "$TEST_SKILL_DIR"
  [ "$status" = 0 ]
  [ "$(wc -l < "$TEST_SKILL_DIR/uuid-calls" | tr -d ' ')" = 1 ]
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read';")" = 1000 ]
  [ "$(_sql "SELECT COUNT(DISTINCT id) FROM events WHERE type='message_read';")" = 1000 ]
  [ "$(_sql "SELECT COUNT(*) FROM events WHERE type='message_read' AND length(id)=36 AND substr(id,15,1)='7' AND substr(id,20,1) IN ('8','9','a','b');")" = 1000 ]
}
