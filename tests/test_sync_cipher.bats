#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
}

teardown() { teardown_test_env; }

require_age() {
  if [ -n "${AGMSG_AGE_BIN:-}" ]; then
    [ -x "$AGMSG_AGE_BIN" ] || skip "AGMSG_AGE_BIN is not executable"
  elif ! command -v age >/dev/null 2>&1; then
    skip "standard age CLI is not installed"
  fi
}

@test "age-v1 shared contract vectors" {
  require_age
  run node --test "$BATS_TEST_DIRNAME/sync_cipher.test.mjs"
  [ "$status" -eq 0 ]
}

@test "bulk seal fan-out, worker failure, and per-request errors" {
  run node --test "$BATS_TEST_DIRNAME/seal_batch.test.mjs"
  [ "$status" -eq 0 ]
}

# Shared setup for the bulk-path tests: a store holding <count> sent messages
# and the sync_prepare record that seals them under age-v1. Leaves $prepare,
# $remote_team and $server_instance set for the caller.
bulk_store() {
  local count="$1" i=0 recipient
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_SYNC_NODE_BIN=node
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  while [ "$i" -lt "$count" ]; do
    storage_send demo alice bob "backfill message $i" >/dev/null
    i=$((i + 1))
  done
  server_instance=018f3f7e-0000-7000-8000-000000000000
  remote_team=018f3f7e-0000-7000-8000-000000000001
  recipient=$(jq -r '.recipient_sets.team_a.recipient' \
    "$BATS_TEST_DIRNAME/../docs/spec/vectors/age-v1-vectors.json")
  prepare=$(jq -nc --arg recipient "$recipient" '
    {type:"sync_prepare",envelope_v:1,cipher:"age-v1",key_id:"epoch-1",
     recipients:[$recipient],max_blob_bytes:1048576,allow_new:true}')
}

@test "a bulk page is sealed by one batched helper call" {
  require_age
  local prepare server_instance remote_team
  bulk_store 60
  export AGMSG_SYNC_TEST_INVOCATION_LOG="$BATS_TEST_TMPDIR/invocations.log"
  export AGMSG_SYNC_REAL_CIPHER_HELPER="$SCRIPTS/internal/sync-cipher.mjs"
  export AGMSG_SYNC_CIPHER_HELPER="$BATS_TEST_DIRNAME/fixtures/sync-cipher-invocation-probe.mjs"
  local published
  published=$(printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    "$server_instance" "$remote_team" 1 100 2>"$BATS_TEST_TMPDIR/prepare.err")
  [ "$(printf '%s\n' "$published" | grep -c sync_push_candidate)" -eq 60 ]
  # Progress goes to stderr, where it cannot corrupt the JSONL on stdout.
  grep -qF 'agmsg: sealing 60/60 (100%)' "$BATS_TEST_TMPDIR/prepare.err"
  # One process for the whole page, not one per message. Sealing 60 messages
  # used to cost 60 Node startups on top of 60 age forks.
  [ "$(wc -l < "$AGMSG_SYNC_TEST_INVOCATION_LOG" | tr -d ' ')" -eq 1 ]
  [ "$(cat "$AGMSG_SYNC_TEST_INVOCATION_LOG")" = "seal-batch 60" ]
}

@test "a batched page carries awkward and large bodies through byte for byte" {
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_SYNC_NODE_BIN=node
  export AGMSG_SYNC_CIPHER_HELPER="$SCRIPTS/internal/sync-cipher.mjs"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  # The page is streamed through paste and two jq passes on its way to the
  # helper, so a body has to survive a tab-delimited join, a JSON round trip and
  # a shell here-document unchanged. Every character below has broken one of
  # those at some point.
  local -a bodies
  bodies[0]='he said "hi" and left'
  bodies[1]='a backslash \ and a \"quoted\" escape'
  bodies[2]=$'tab\tseparated\tlooks like a delimiter'
  bodies[3]=$'first line\nsecond line'
  bodies[4]="$(printf 'x%.0s' $(seq 1 200000))"
  bodies[5]='単一引用符 '"'"' と絵文字 🔐 と改行なし'
  local i=0
  while [ "$i" -lt 6 ]; do
    storage_send demo alice bob "${bodies[$i]}" >/dev/null
    i=$((i + 1))
  done

  local prepare published
  prepare='{"type":"sync_prepare","envelope_v":1,"cipher":"none","key_id":null,
            "recipients":[],"max_blob_bytes":1048576,"allow_new":true}'
  published=$(printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 018f3f7e-0000-7000-8000-000000000001 1 100)
  [ "$(printf '%s\n' "$published" | grep -c sync_push_candidate)" -eq 6 ]

  # Open each envelope and compare the body against what was sent.
  i=0
  while [ "$i" -lt 6 ]; do
    local opened
    opened=$(printf '%s\n' "$published" | jq -sc --argjson n "$i" \
        '[.[] | select(.type=="sync_push_candidate")] | sort_by(.local_position|tonumber)
         | .[$n].envelope' \
      | node --input-type=module -e '
          const { openEnvelope } = await import(process.argv[1]);
          let input = "";
          for await (const chunk of process.stdin) input += chunk;
          const message = await openEnvelope({ envelope: JSON.parse(input),
            max_blob_bytes: 1048576 });
          process.stdout.write(message.body);
        ' "$SCRIPTS/internal/sync-cipher.mjs")
    [ "$opened" = "${bodies[$i]}" ]
    i=$((i + 1))
  done
}

@test "an interrupted bulk seal keeps its committed page and resumes" {
  require_age
  local prepare server_instance remote_team
  bulk_store 200
  local real_age db committed waited=0 before after
  real_age="${AGMSG_AGE_BIN:-$(command -v age)}"
  # Slow age down so the page takes long enough to be signalled in the middle of
  # it. Real backfills are slow for the same reason — one age fork per message.
  cat > "$BATS_TEST_TMPDIR/slow-age" <<SLOW
#!/usr/bin/env bash
sleep 0.3
exec "$real_age" "\$@"
SLOW
  chmod +x "$BATS_TEST_TMPDIR/slow-age"
  cat > "$BATS_TEST_TMPDIR/run-prepare.sh" <<RUN
#!/usr/bin/env bash
source "$SCRIPTS/lib/storage.sh"
agmsg_storage_load
printf '%s\n' '$prepare' | storage_sync_prepare_push demo \
  $server_instance $remote_team 1 500 >/dev/null
RUN
  db=$(agmsg_db_path demo)

  AGMSG_AGE_BIN="$BATS_TEST_TMPDIR/slow-age" \
    bash "$BATS_TEST_TMPDIR/run-prepare.sh" 3>&- 4>&- &
  local pid=$!
  # Wait for the first committed group, then interrupt the run for real. The
  # table itself only appears once prepare has created the schema, so a failed
  # count early on means "nothing committed yet", not a broken store.
  while [ "$waited" -lt 600 ]; do
    committed=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages;" 2>/dev/null | tr -d '\r')
    # An `A && B && break` list here would be a failing command under bats'
    # errexit on every iteration that finds nothing yet.
    if [ -n "$committed" ] && [ "$committed" -gt 0 ]; then break; fi
    sleep 0.1; waited=$((waited + 1))
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  before=$(agmsg_sqlite "$db" \
    "SELECT local_position||':'||wire_id FROM sync_messages ORDER BY local_position;")
  committed=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages;" | tr -d '\r')
  # The interrupt has to have landed mid-page: work survived it, and work was
  # left behind. A run that finished first would prove nothing about resuming.
  [ "$committed" -gt 0 ]
  [ "$committed" -lt 200 ]

  printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    "$server_instance" "$remote_team" 1 500 >/dev/null
  [ "$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sync_messages;" | tr -d '\r')" -eq 200 ]
  [ "$(agmsg_sqlite "$db" \
     "SELECT COUNT(DISTINCT local_position) FROM sync_messages;" | tr -d '\r')" -eq 200 ]
  # No message came back with a second wire id, and none went missing.
  [ "$(agmsg_sqlite "$db" \
     "SELECT COUNT(DISTINCT wire_id) FROM sync_messages;" | tr -d '\r')" -eq 200 ]
  # Reservations made before the interrupt are immutable — resuming re-seals
  # only what was left, it never re-issues a wire id that already exists.
  after=$(agmsg_sqlite "$db" \
    "SELECT local_position||':'||wire_id FROM sync_messages ORDER BY local_position;")
  [ -z "$(comm -23 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort))" ]
}

@test "sqlite prepare publishes one byte-stable age-v1 envelope" {
  require_age
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_SYNC_NODE_BIN=node
  export AGMSG_SYNC_CIPHER_HELPER="$SCRIPTS/internal/sync-cipher.mjs"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  storage_send demo alice bob "encrypted at the durability boundary" >/dev/null
  local recipient prepare first second
  recipient=$(jq -r '.recipient_sets.team_a.recipient' \
    "$BATS_TEST_DIRNAME/../docs/spec/vectors/age-v1-vectors.json")
  prepare=$(jq -nc --arg recipient "$recipient" '
    {type:"sync_prepare",envelope_v:1,cipher:"age-v1",key_id:"epoch-1",
     recipients:[$recipient],max_blob_bytes:1048576,allow_new:true}')
  first=$(printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100)
  second=$(printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100)
  [ "$first" = "$second" ]
  printf '%s\n' "$first" | jq -e 'select(.type=="sync_push_candidate")
    | .envelope.v==1 and .envelope.cipher=="age-v1"
      and .envelope.key_id=="epoch-1" and (.envelope.blob|length)>0' >/dev/null
}

@test "concurrent age-v1 sealers publish one transaction winner" {
  require_age
  export AGMSG_STORAGE_PATH="$BATS_TEST_TMPDIR/store"
  export AGMSG_STORAGE_DRIVER=sqlite
  export AGMSG_SYNC_NODE_BIN=node
  export AGMSG_SYNC_CIPHER_HELPER="$SCRIPTS/internal/sync-cipher.mjs"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init demo >/dev/null
  storage_send demo alice bob "one published ciphertext" >/dev/null
  local recipient prepare first_file second_file first_pid second_pid
  recipient=$(jq -r '.recipient_sets.team_a.recipient' \
    "$BATS_TEST_DIRNAME/../docs/spec/vectors/age-v1-vectors.json")
  prepare=$(jq -nc --arg recipient "$recipient" '
    {type:"sync_prepare",envelope_v:1,cipher:"age-v1",key_id:"epoch-1",
     recipients:[$recipient],max_blob_bytes:1048576,allow_new:true}')
  first_file="$BATS_TEST_TMPDIR/first.jsonl"
  second_file="$BATS_TEST_TMPDIR/second.jsonl"
  (printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100 >"$first_file") 3>&- 4>&- &
  first_pid=$!
  (printf '%s\n' "$prepare" | storage_sync_prepare_push demo \
    018f3f7e-0000-7000-8000-000000000000 \
    018f3f7e-0000-7000-8000-000000000001 1 100 >"$second_file") 3>&- 4>&- &
  second_pid=$!
  wait "$first_pid"
  wait "$second_pid"
  [ "$(cat "$first_file")" = "$(cat "$second_file")" ]
  [ "$(agmsg_sqlite "$(agmsg_db_path demo)" "SELECT COUNT(*) FROM sync_messages;" | tr -d '\r')" -eq 1 ]
}
