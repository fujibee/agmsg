#!/usr/bin/env bats
load test_helper

setup() {
  setup_test_env
  source "$SCRIPTS/lib/storage.sh"
  source "$SCRIPTS/lib/delivery-claims.sh"
}
teardown() { teardown_test_env; }

@test "claim request: defaults are explicit and peek needs no owner" {
  agmsg_delivery_parse_request claim '{"team":"alpha","agent":"bob","owner":"reader"}'
  [ "$AGMSG_CLAIM_TEAM" = alpha ]
  [ "$AGMSG_CLAIM_AGENT" = bob ]
  [ "$AGMSG_CLAIM_OWNER" = reader ]
  [ "$AGMSG_CLAIM_TTL" = 60 ]
  [ "$AGMSG_CLAIM_LIMIT" = 100 ]
  [ "${#AGMSG_CLAIM_IDS[@]}" = 0 ]
  agmsg_delivery_parse_request peek '{"team":"alpha","agent":"bob","limit":7}'
  [ "$AGMSG_CLAIM_LIMIT" = 7 ]
  [ -z "$AGMSG_CLAIM_OWNER" ]
}

@test "claim request: opaque strings round trip without shell interpretation" {
  local token request id
  printf -v token '%064d' 0
  id=$'-quote\\backslash\'\r\n\t日本語|$(not-a-command)'
  request="$(jq -cn --arg token "$token" --arg id "$id" \
    '{team:"alpha",agent:"bob",owner:"reader",token:$token,ids:[$id]}')"
  agmsg_delivery_parse_request ack "$request"
  [ "$AGMSG_CLAIM_TOKEN" = "$token" ]
  [ "${#AGMSG_CLAIM_IDS[@]}" = 1 ]
  [ "${AGMSG_CLAIM_IDS[0]}" = "$id" ]
}

@test "claim request: malformed multiple objects duplicate keys and unknown fields fail without stdout" {
  local request rc
  for request in \
    'not json' \
    '{"team":"alpha","agent":"bob","owner":"r"} {}' \
    '{"team":"alpha","team":"beta","agent":"bob","owner":"r"}' \
    '{"team":"alpha","agent":"bob","owner":"r","typo":1}' \
    '{"team":"alpha","agent":"bob"}'; do
    rc=0
    agmsg_delivery_parse_request claim "$request" >"$TEST_SKILL_DIR/out" \
      2>"$TEST_SKILL_DIR/err" || rc=$?
    [ "$rc" = 13 ]
    [ ! -s "$TEST_SKILL_DIR/out" ]
    grep -q invalid_request "$TEST_SKILL_DIR/err"
  done
}

@test "claim request: reject wrong numeric types range and decoded NUL" {
  local field request
  for field in '"ttl":"60"' '"ttl":1.5' '"ttl":true' '"ttl":0' \
    '"ttl":3601' '"limit":1001' '"owner":"x\u0000y"' \
    '"ids":["x\u0000y"]' '"ids":null' '"own\u0000er":"r"'; do
    if [[ "$field" == '"owner"'* ]]; then
      request="{\"team\":\"alpha\",\"agent\":\"bob\",$field}"
    else
      request="{\"team\":\"alpha\",\"agent\":\"bob\",\"owner\":\"r\",$field}"
    fi
    run agmsg_delivery_parse_request claim "$request"
    [ "$status" = 13 ]
  done
  agmsg_delivery_parse_request claim '{"team":"alpha","agent":"bob","owner":"literal\\u0000"}'
  [ "$AGMSG_CLAIM_OWNER" = 'literal\u0000' ]
  run agmsg_delivery_parse_request claim '{"team":"alpha","agent":"bob","owner":"literal\\\u0000"}'
  [ "$status" = 13 ]
}

@test "claim request: controls require a valid token and nonempty unique string IDs" {
  local token ids
  printf -v token '%064d' 0
  for ids in '[]' '[""]' '["same","same"]' '[null]' '[2]'; do
    run agmsg_delivery_parse_request ack \
      "{\"team\":\"alpha\",\"agent\":\"bob\",\"owner\":\"r\",\"token\":\"$token\",\"ids\":$ids}"
    [ "$status" = 13 ]
  done
  run agmsg_delivery_parse_request ack \
    '{"team":"alpha","agent":"bob","owner":"r","token":"bad","ids":["one"]}'
  [ "$status" = 13 ]
  run agmsg_delivery_parse_request peek '{"team":"alpha","agent":"bob","owner":"r"}'
  [ "$status" = 13 ]
}

@test "claim request: a large opaque ID stays off external argv" {
  local token id request
  printf -v token '%064d' 0
  printf -v id '%140000s' x
  request="{\"team\":\"alpha\",\"agent\":\"bob\",\"owner\":\"r\",\"token\":\"$token\",\"ids\":[\"$id\"]}"
  agmsg_sqlite() {
    local arg
    for arg in "$@"; do [ "${#arg}" -lt 10000 ] || return 99; done
    command sqlite3 "$@"
  }
  agmsg_delivery_parse_request ack "$request"
  [ "${AGMSG_CLAIM_IDS[0]}" = "$id" ]
}

@test "claim capability: private functions alone never enable the machine API" {
  storage_describe() { printf 'name=fixture\ncapabilities=stage1-sync\n'; }
  storage_claim_unread() { printf 'must not be called'; }
  run agmsg_delivery_claims_supported
  [ "$status" = 1 ]
  [ -z "$output" ]
  storage_describe() { printf 'name=fixture\ncapabilities=stage1-sync,delivery-claims-v1\n'; }
  run agmsg_delivery_claims_supported
  [ "$status" = 0 ]
  [ -z "$output" ]
}

_load_claim_fixture() {
  export SKILL_DIR="$TEST_SKILL_DIR"
  agmsg_storage_load
}

@test "claim facade: precheck denial never calls storage or discloses a body" {
  _load_claim_fixture
  agmsg_bridge_claim_guard_check() { return 13; }
  storage_claim_unread() { touch "$TEST_SKILL_DIR/called"; printf 'secret\n'; }
  run agmsg_delivery_claim_unread alpha bob reader 60 1
  [ "$status" = 13 ]; [ -z "$output" ]; [ ! -e "$TEST_SKILL_DIR/called" ]
}

@test "claim facade: reservation published after commit suppresses body and retains undisclosed lease" {
  _load_claim_fixture
  local id rc=0 checks=0
  id="$(storage_send alpha alice bob secret)"
  agmsg_bridge_claim_guard_check() { checks=$((checks+1)); [ "$checks" = 1 ]; }
  agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]; [ "$checks" = 2 ]
  [ "$(sqlite3 "$(agmsg_db_path alpha)" 'SELECT count(*) FROM delivery_claims;')" = 1 ]
  [[ "$(storage_list_unread alpha bob)" == *secret* ]] || return 1
}

@test "claim facade: storage failure cannot leak tentative records" {
  _load_claim_fixture
  agmsg_bridge_claim_guard_check() { return 0; }
  storage_claim_unread() { printf '{"body":"uncommitted"}\n'; return 13; }
  run agmsg_delivery_claim_unread alpha bob reader 60 1
  [ "$status" = 13 ]; [ -z "$output" ]
}

@test "claim facade: exact guard fields protect controls and permitted ACK records a receipt" {
  _load_claim_fixture
  local id token rows
  id="$(storage_send alpha alice bob secret)"
  rows="$(agmsg_delivery_claim_unread alpha bob reader 60 1)"
  token="$(printf '%s\n' "$rows" | jq -r .claim_token)"
  agmsg_bridge_claim_guard_check() {
    printf '%s\n' "$@" >"$TEST_SKILL_DIR/guard-args"
    [ "$1" = ack ]
  }
  run agmsg_delivery_claim_renew alpha bob reader "$token" 60 "$id"
  [ "$status" = 13 ]; [ "$output" = runtime_error ]
  [ "$(sed -n '6p' "$TEST_SKILL_DIR/guard-args")" = "$id" ]
  run agmsg_delivery_claim_ack alpha bob reader "$token" "$id"
  [ "$status" = 0 ]; [ "$output" = ok ]
  [ "$(sed -n '5p' "$TEST_SKILL_DIR/guard-args")" = "$token" ]
  [ "$(sed -n '6p' "$TEST_SKILL_DIR/guard-args")" = "$id" ]
  [ -z "$(storage_list_unread alpha bob)" ]
}

@test "claim facade: readiness suppresses late reservations and rejects ambiguous resolution" {
  _load_claim_fixture
  storage_list_deliverable() { touch "$TEST_SKILL_DIR/reserved"; printf '{"id":"one"}\n'; }
  agmsg_bridge_reservation_status() { [ -f "$TEST_SKILL_DIR/reserved" ]; }
  run agmsg_delivery_list_deliverable alpha bob --limit 1
  [ "$status" = 0 ]; [ -z "$output" ]
  agmsg_bridge_reservation_status() { return 13; }
  run agmsg_delivery_list_deliverable alpha bob --limit 1
  [ "$status" = 13 ]; [ -z "$output" ]
}

@test "claim CLI: raw NUL is rejected before storage and controls keep their status ABI" {
  printf '{"team":"alpha","agent":"bob","owner":"r"}\0' >"$TEST_SKILL_DIR/request"
  local rc=0
  bash "$SCRIPTS/delivery-claims.sh" claim <"$TEST_SKILL_DIR/request" \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q invalid_request "$TEST_SKILL_DIR/err"
  rc=0
  bash "$SCRIPTS/delivery-claims.sh" ack <"$TEST_SKILL_DIR/request" \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ "$(cat "$TEST_SKILL_DIR/out")" = runtime_error ]
}

@test "claim CLI: valid requests remain unavailable without an advertised driver capability" {
  printf '\nstorage_describe() { printf "name=fixture\\ncapabilities=stage1-sync\\n"; }\n' >> "$SCRIPTS/drivers/storage/sqlite.sh"
  printf '{"team":"alpha","agent":"bob","owner":"r"}' >"$TEST_SKILL_DIR/request"
  local rc=0
  bash "$SCRIPTS/delivery-claims.sh" claim <"$TEST_SKILL_DIR/request" \
    >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q delivery_claims_unavailable "$TEST_SKILL_DIR/err"
}

@test "claim readiness: a route change after reading never returns stale records" {
  _load_claim_fixture
  storage_send alpha alice bob secret >/dev/null
  local original calls="$TEST_SKILL_DIR/resolutions"
  original="$(agmsg_db_path alpha)"
  _sqlite_delivery_fresh_db() {
    if [ -e "$calls" ]; then printf '%s.new\n' "$original"
    else touch "$calls"; printf '%s\n' "$original"; fi
  }
  local rc=0
  storage_list_deliverable alpha bob >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q selector_changed "$TEST_SKILL_DIR/err"
}

@test "claim readiness: absent store stays absent and a shared fallback barrier refuses readiness" {
  _load_claim_fixture
  local db barrier rc=0
  db="$(agmsg_db_path alpha)"
  rm -f "$db" "$db-wal" "$db-shm"
  [ -z "$(storage_list_deliverable alpha bob)" ]; [ ! -e "$db" ]
  storage_send alpha alice bob secret >/dev/null
  barrier="$(_sqlite_delivery_maintenance_begin_db "$db" '{"operation":"fixture"}' alpha)"
  storage_list_deliverable alpha bob >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q maintenance_active "$TEST_SKILL_DIR/err"
}

_enable_claim_cli_fixture() {
  _load_claim_fixture
  # The base machine ABI must work for drivers without the byte extension too.
  printf '\nstorage_describe() { printf "name=sqlite\\ncapabilities=delivery-claims-v1\\n"; }\n' \
    >>"$SCRIPTS/drivers/storage/sqlite.sh"
}
_claim_cli() { bash "$SCRIPTS/delivery-claims.sh" "$1" <"$TEST_SKILL_DIR/request"; }

@test "claim CLI: claim renew ACK and retained-receipt retry preserve machine framing" {
  _enable_claim_cli_fixture
  local id token rows
  id="$(storage_send alpha alice bob secret)"
  printf '{"team":"alpha","agent":"bob","owner":"r"}\n' >"$TEST_SKILL_DIR/request"
  rows="$(_claim_cli claim)"
  [ "$(printf '%s\n' "$rows" | jq -r .body)" = secret ]
  token="$(printf '%s\n' "$rows" | jq -r .claim_token)"
  jq -cn --arg id "$id" --arg token "$token" \
    '{team:"alpha",agent:"bob",owner:"r",token:$token,ttl:60,ids:[$id]}' >"$TEST_SKILL_DIR/request"
  run _claim_cli renew
  [ "$status" = 0 ]; [ "$output" = ok ]
  jq -cn --arg id "$id" --arg token "$token" \
    '{team:"alpha",agent:"bob",owner:"r",token:$token,ids:[$id]}' >"$TEST_SKILL_DIR/request"
  run _claim_cli ack
  [ "$status" = 0 ]; [ "$output" = ok ]
  run _claim_cli ack
  [ "$status" = 0 ]; [ "$output" = ok ]
  [ -z "$(storage_list_unread alpha bob)" ]
}

@test "claim CLI: failed stdout retains an undisclosed claim and never records read" {
  [ -c /dev/full ] || skip "requires a deterministic failing output device"
  _enable_claim_cli_fixture
  storage_send alpha alice bob secret >/dev/null
  printf '{"team":"alpha","agent":"bob","owner":"r"}\n' >"$TEST_SKILL_DIR/request"
  local rc=0
  _claim_cli claim >/dev/full 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" != 0 ]
  [ "$(sqlite3 "$(agmsg_db_path alpha)" 'SELECT count(*) FROM delivery_claims;')" = 1 ]
  [[ "$(storage_list_unread alpha bob)" == *secret* ]] || return 1
}

@test "claim facade: capability failure is not reported as an unsupported driver" {
  storage_describe() { return 13; }
  run agmsg_delivery_claim_unread alpha bob reader 60 1
  [ "$status" = 13 ]
  [[ "$output" == *capability_check_failed* ]] || return 1
  [[ "$output" != *delivery_claims_unavailable* ]] || return 1
}

@test "claim role dispatch: a prior driver hook cannot authorize a different unsupported type" {
  _load_claim_fixture
  local reservation type
  mkdir -p "$TEST_SKILL_DIR/run" "$TYPES/claim-fixture" "$TYPES/old-fixture"
  reservation="$(_agmsg_bridge_guard_path alpha bob)"
  printf '%s\n' 'agmsg_type_bridge_claim_guard_check() { return 0; }' \
    >"$TYPES/claim-fixture/bridge-read-guard.sh"
  printf '%s\n' 'agmsg_type_bridge_guard_check() { return 0; }' \
    >"$TYPES/old-fixture/bridge-read-guard.sh"
  printf '{"type":"claim-fixture"}\n' >"$reservation"
  agmsg_bridge_claim_guard_check claim alpha bob reader ""
  printf '{"type":"old-fixture"}\n' >"$reservation"
  run agmsg_bridge_claim_guard_check claim alpha bob reader ""
  [ "$status" = 13 ]
  [[ "$output" == *unsupported_role_guard* ]] || return 1
}

@test "claim readiness: one malformed durable reservation is a visible failure" {
  _load_claim_fixture
  mkdir -p "$TEST_SKILL_DIR/run"
  printf '{malformed\n' >"$(_agmsg_bridge_guard_path alpha bob)"
  local rc=0
  agmsg_delivery_list_deliverable alpha bob >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]
  [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q invalid_role_reservation "$TEST_SKILL_DIR/err"
}

@test "claim reservation status: missing invalid and unknown types fail instead of hiding work" {
  _load_claim_fixture
  mkdir -p "$TEST_SKILL_DIR/run"
  local request reservation
  reservation="$(_agmsg_bridge_guard_path alpha bob)"
  for request in '{}' '{"type":7}' '{"type":"../outside"}' '{"type":"unknown-fixture"}'; do
    printf '%s\n' "$request" >"$reservation"
    run agmsg_bridge_reservation_status alpha bob
    [ "$status" = 13 ]
  done
}

@test "claim reservation status: valid type-owned durable state suppresses readiness without read" {
  _load_claim_fixture
  mkdir -p "$TEST_SKILL_DIR/run" "$TYPES/status-fixture"
  local reservation
  reservation="$(_agmsg_bridge_guard_path alpha bob)"
  printf '%s\n' 'agmsg_type_bridge_reservation_check() { [ "$2" = alpha ] && [ "$3" = bob ]; }' \
    >"$TYPES/status-fixture/bridge-read-guard.sh"
  printf '{"type":"status-fixture"}\n' >"$reservation"
  storage_list_deliverable() { touch "$TEST_SKILL_DIR/unexpected-read"; return 13; }
  run agmsg_delivery_list_deliverable alpha bob
  [ "$status" = 0 ]; [ -z "$output" ]
  [ ! -e "$TEST_SKILL_DIR/unexpected-read" ]
}

@test "claim facade: malformed driver raw NUL cannot be stripped into a usable claimed record" {
  _load_claim_fixture
  mkdir -p "$TEST_SKILL_DIR/capture"
  export TMPDIR="$TEST_SKILL_DIR/capture"
  storage_claim_unread() { printf '{"body":"before\0after"}\n'; }
  local rc=0
  agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q invalid_record_nul "$TEST_SKILL_DIR/err"
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}

@test "claim facade: readiness capture rejects raw NUL and preserves producer failure" {
  _load_claim_fixture
  mkdir -p "$TEST_SKILL_DIR/capture"
  export TMPDIR="$TEST_SKILL_DIR/capture"
  storage_list_deliverable() { printf '{"body":"before\0after"}\n'; }
  local rc=0
  agmsg_delivery_list_deliverable alpha bob >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q invalid_record_nul "$TEST_SKILL_DIR/err"
  storage_list_deliverable() { printf '{"body":"tentative"}\n'; return 13; }
  rc=0
  agmsg_delivery_list_deliverable alpha bob >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}

@test "claim facade: normalize missing final LF but reject extra blank or malformed records" {
  _load_claim_fixture
  storage_claim_unread() { printf '{"id":"one"}'; }
  agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out"
  [ "$(wc -l <"$TEST_SKILL_DIR/out" | tr -d ' ')" = 1 ]
  [ "$(cat "$TEST_SKILL_DIR/out")" = '{"id":"one"}' ]
  local bad rc
  for bad in $'{"id":"one"}\n\n' $'{"id":"one"}\n \n' 'not-json' '[]'; do
    storage_claim_unread() { printf '%s' "$bad"; }
    rc=0
    agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
    [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
    grep -q invalid_record_framing "$TEST_SKILL_DIR/err"
  done
}

@test "claim request: malformed UTF-8 and lone surrogate IDs cannot change during decoding" {
  local bad document
  for bad in $'\377' $'\300\200' $'\340\200\200' $'\355\240\200' $'\364\220\200\200' $'\302' $'\200'; do
    document='{"team":"alpha","agent":"bob","owner":"'"$bad"'"}'
    run agmsg_delivery_parse_request claim "$document"
    [ "$status" = 13 ]
  done
  for bad in '\ud800' '\udfff'; do
    document='{"team":"alpha","agent":"bob","owner":"reader","ids":["'"$bad"'"]}'
    run agmsg_delivery_parse_request claim "$document"
    [ "$status" = 13 ]
  done
}

@test "claim request: valid Unicode scalar boundaries and paired escapes retain exact IDs" {
  local boundary=$'\177\302\200\337\277\340\240\200\355\237\277\356\200\200\357\277\277\360\220\200\200\364\217\277\277'
  local document='{"team":"alpha","agent":"bob","owner":"reader","ids":["'"$boundary"'","\ud83d\udce8","line\r\n\t"]}'
  agmsg_delivery_parse_request claim "$document"
  [ "${AGMSG_CLAIM_IDS[0]}" = "$boundary" ]
  [ "${AGMSG_CLAIM_IDS[1]}" = '📨' ]
  [ "${AGMSG_CLAIM_IDS[2]}" = $'line\r\n\t' ]
}

@test "claim facade: reject malformed Unicode decoded NUL and duplicate keys before any output" {
  _load_claim_fixture
  local bad rc
  for bad in $'{"body":"\377"}' $'{"\377":"value"}' \
    '{"body":"\ud800"}' '{"\udfff":"value"}' '{"body":"before\u0000after"}' \
    '{"id":"first","id":"second"}' '{"id":"first","\u0069d":"second"}' \
    '{"extra":{"body":"first","body":"second"}}'; do
    storage_claim_unread() { printf '%s' "$bad"; }
    rc=0
    agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
    [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
    grep -q invalid_record_framing "$TEST_SKILL_DIR/err"
  done
}

@test "claim facade: Unicode pairs and separate nested object keys remain lossless" {
  _load_claim_fixture
  local record='{"id":"📨","body":"\ud83d\udce8\r\n\t","extra":[{"key":"first"},{"key":"second"}],"literal":"\\u0000"}'
  storage_claim_unread() { printf '%s' "$record"; }
  agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out"
  [ "$(cat "$TEST_SKILL_DIR/out")" = "$record" ]
}

@test "claim facade: NUL escape parity is exact in keys values and mixed candidates" {
  _load_claim_fixture
  local slashes='' count field record rc
  for count in 0 1 2 3 4 5 6 7 8; do
    for field in key value; do
      if [ "$field" = key ]; then
        printf -v record '{"before":"\\\\u0000","%su0000":"ok","after":"\\\\u0000"}' "$slashes"
      else
        printf -v record '{"before":"\\\\u0000","body":"%su0000","after":"\\\\u0000"}' "$slashes"
      fi
      storage_claim_unread() { printf '%s\n' "$record"; }
      rc=0
      agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
      if [ $((count % 2)) -eq 0 ]; then
        [ "$rc" = 0 ]
        printf '%s\n' "$record" >"$TEST_SKILL_DIR/expected"
        cmp "$TEST_SKILL_DIR/expected" "$TEST_SKILL_DIR/out"
      else
        [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
        grep -q invalid_record_framing "$TEST_SKILL_DIR/err"
      fi
    done
    slashes="$slashes\\"
  done
}

@test "claim facade: large sparse and dense escaped records retain every byte" {
  _load_claim_fixture
  local shape
  for shape in sparse dense; do
    if [ "$shape" = sparse ]; then
      {
        printf 'wire payload\n\t\047\\'
        awk 'BEGIN { for (i=0; i<150000; i++) printf "x" }'
      } >"$TEST_SKILL_DIR/body"
    else
      awk 'BEGIN { for (i=0; i<15000; i++) printf "\047\\\n\t界" }' >"$TEST_SKILL_DIR/body"
    fi
    jq -Rsc '{id:"one",body:.,literal:"\\u0000",extra:[{key:"first"},{key:"second"}]}' \
      <"$TEST_SKILL_DIR/body" >"$TEST_SKILL_DIR/records"
    [ "$(wc -c <"$TEST_SKILL_DIR/records")" -gt 150000 ]
    storage_claim_unread() { cat "$TEST_SKILL_DIR/records"; }
    agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out"
    cmp "$TEST_SKILL_DIR/records" "$TEST_SKILL_DIR/out"
  done
}

@test "claim facade: invalid later record cannot disclose a valid prefix" {
  _load_claim_fixture
  mkdir -p "$TEST_SKILL_DIR/capture"
  export TMPDIR="$TEST_SKILL_DIR/capture"
  local bad rc
  for bad in '[]' 'not-json' ' ' '{"body":"before\u0000after"}' \
    '{"extra":{"same":1,"same":2}}' '{"body":"\ud800"}' $'{"body":"\377"}'; do
    storage_claim_unread() { printf '%s\n' '{"body":"valid prefix"}' "$bad"; }
    rc=0
    agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
    [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
    grep -q invalid_record_framing "$TEST_SKILL_DIR/err"
    [ -z "$(find "$TMPDIR" -type f -print)" ]
  done
}

@test "claim facade: SQL encoder failure cannot be masked by the validation footer" {
  _load_claim_fixture
  mkdir -p "$TEST_SKILL_DIR/capture"
  export TMPDIR="$TEST_SKILL_DIR/capture"
  storage_claim_unread() { printf '%s\n' '{"body":"private payload"}'; }
  awk() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = "quote='" ]; then
      command awk "$@" || return $?
      return 13
    fi
    command awk "$@"
  }
  local rc=0
  agmsg_delivery_claim_unread alpha bob reader 60 1 >"$TEST_SKILL_DIR/out" 2>"$TEST_SKILL_DIR/err" || rc=$?
  [ "$rc" = 13 ]; [ ! -s "$TEST_SKILL_DIR/out" ]
  grep -q invalid_record_framing "$TEST_SKILL_DIR/err"
  [ -z "$(find "$TMPDIR" -type f -print)" ]
}
