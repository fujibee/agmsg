#!/usr/bin/env bats
# Driver-agnostic storage-contract tests (docs/spec/driver-interface.md §2,
# ADR 0003). They exercise the storage_* contract through the facade, so the
# SAME tests pin every driver: they run against the built-in sqlite driver here,
# and `AGMSG_STORAGE_DRIVER=<name> bats tests/test_storage_contract.bats` runs the
# identical contract against jsonl / redis once those land.

load test_helper

setup() {
  setup_test_env
  export SKILL_DIR="$TEST_SKILL_DIR"
  # shellcheck disable=SC1091
  source "$SCRIPTS/lib/storage.sh"
  agmsg_storage_load
  storage_init agsuite
}

teardown() { teardown_test_env; }

# pull the cursor token out of a watch_after stream's trailing cursor record
_cursor_of() { printf '%s\n' "$1" | sed -n 's/.*"type":"cursor","cursor":"\([^"]*\)".*/\1/p'; }

@test "contract: storage_check reports ok" {
  run storage_check
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "contract: storage_store_exists is true once the store is initialized" {
  # setup() ran storage_init, so the active driver's store is present.
  run storage_store_exists agsuite
  [ "$status" -eq 0 ]
}

@test "contract: send returns an id and list_unread shows the message" {
  local id; id=$(storage_send agsuite alice bob "hi")
  [ -n "$id" ]
  run storage_list_unread agsuite bob
  [ "$status" -eq 0 ]
  [[ "$output" == *'"body":"hi"'* ]]
  [[ "$output" == *"$id"* ]]
}

@test "contract: mark_read_batch is idempotent (double mark is a no-op)" {
  local id; id=$(storage_send agsuite alice bob "x")
  storage_mark_read_batch agsuite bob "$id"
  run storage_list_unread agsuite bob
  [ -z "$output" ]
  # Re-marking the same id changes nothing — still read, no error.
  storage_mark_read_batch agsuite bob "$id"
  run storage_list_unread agsuite bob
  [ -z "$output" ]
}

@test "contract: mark_read is recipient-scoped (one agent's read doesn't hide another's)" {
  local m; m=$(storage_send agsuite alice carol "for carol")
  # bob records a read of carol's message id — scoped to bob, so carol is unaffected.
  storage_mark_read_batch agsuite bob "$m"
  run storage_list_unread agsuite carol
  [[ "$output" == *"for carol"* ]]
}

@test "contract: read cursor is per-pair and advances only through a covered prefix" {
  local first second tip
  first=$(storage_send agsuite alice bob "cursor-first")
  second=$(storage_send agsuite alice bob "cursor-second")
  tip=$(storage_watch_tip agsuite:bob)

  [ "$(storage_read_cursor_get agsuite bob)" = "0" ]
  storage_read_cursor_consume agsuite bob "$tip" "$second" >/dev/null
  # Reading the later row creates an exact exception but cannot cross the first
  # unread hole. The later row is nevertheless not redelivered.
  [ "$(storage_read_cursor_get agsuite bob)" = "0" ]
  run storage_list_unread agsuite bob
  [[ "$output" == *cursor-first* ]]
  [[ "$output" != *cursor-second* ]]

  storage_read_cursor_consume agsuite bob "$tip" "$first" >/dev/null
  [ "$(storage_read_cursor_get agsuite bob)" = "$tip" ]
  [ "$(storage_read_cursor_get agsuite carol)" = "0" ]
  run storage_list_unread agsuite bob
  [ -z "$output" ]
}

@test "contract: read cursor max-merges and never moves backwards" {
  local first tip
  first=$(storage_send agsuite alice bob "cursor-monotonic")
  tip=$(storage_watch_tip agsuite:bob)
  storage_read_cursor_consume agsuite bob "$tip" "$first" >/dev/null
  storage_read_cursor_consume agsuite bob 0 >/dev/null
  [ "$(storage_read_cursor_get agsuite bob)" = "$tip" ]
}

@test "contract: read cursor cannot advance beyond the current driver tip" {
  storage_read_cursor_consume agsuite bob 999999 >/dev/null
  [ "$(storage_read_cursor_get agsuite bob)" = "0" ]
  storage_send agsuite alice bob "not-skipped-by-future-cursor" >/dev/null
  run storage_list_unread agsuite bob
  [[ "$output" == *not-skipped-by-future-cursor* ]]
}

@test "contract: watch_after excludes an exact read beyond an earlier gap" {
  local first second tip
  first=$(storage_send agsuite alice bob "watch-gap")
  second=$(storage_send agsuite alice bob "watch-exact")
  tip=$(storage_watch_tip agsuite:bob)
  storage_read_cursor_consume agsuite bob "$tip" "$second" >/dev/null

  run storage_watch_after 0 agsuite:bob
  [[ "$output" == *"$first"* ]]
  [[ "$output" != *"$second"* ]]
  [[ "$output" == *watch-gap* ]]
  [[ "$output" != *watch-exact* ]]
}

@test "contract: cursor migration consumes existing backlog but not later messages" {
  storage_send agsuite alice bob "before-cursor-migration" >/dev/null

  if [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ]; then
    local store_dir; store_dir="$(dirname "$(agmsg_db_path agsuite)")"
    rm -f "$store_dir/.read-cursor-v1" "$store_dir/read-cursors.tsv"
  else
    # A pre-cursor-era store also predates the schema-revision stamp (#1001);
    # without resetting it the next init would fast-path past the adoption.
    agmsg_sqlite "$(agmsg_db_path agsuite)" "
      PRAGMA user_version=0;
      DELETE FROM storage_metadata WHERE key='read_cursor_v1';
      DELETE FROM read_cursors;" >/dev/null
  fi

  storage_init agsuite >/dev/null
  run storage_list_unread agsuite bob
  [[ "$output" != *before-cursor-migration* ]]

  storage_send agsuite alice bob "after-cursor-migration" >/dev/null
  run storage_list_unread agsuite bob
  [[ "$output" == *after-cursor-migration* ]]
  [[ "$output" != *before-cursor-migration* ]]
}

@test "contract: watch_tip + watch_after deliver only post-tip messages, with a cursor" {
  storage_send agsuite alice bob "before"
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice bob "after"
  run storage_watch_after "$tip" agsuite:bob
  [ "$status" -eq 0 ]
  [[ "$output" == *'"body":"after"'* ]]
  [[ "$output" != *'"body":"before"'* ]]
  [[ "$output" == *'"type":"cursor"'* ]]
}

@test "contract: watch_after advances the cursor even with zero matching messages" {
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice carol "off-subscription"
  run storage_watch_after "$tip" agsuite:bob
  [ "$status" -eq 0 ]
  [[ "$output" != *message_sent* ]]
  local newcur; newcur=$(_cursor_of "$output")
  [ -n "$newcur" ]
  [ "$newcur" != "$tip" ]
}

@test "contract: cursor round-trips — re-watching from it does not re-scan" {
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice bob "m1"
  local out1; out1=$(storage_watch_after "$tip" agsuite:bob)
  [[ "$out1" == *m1* ]]
  local cur1; cur1=$(_cursor_of "$out1")
  run storage_watch_after "$cur1" agsuite:bob
  [[ "$output" != *m1* ]]
}

@test "contract: history returns messages involving the agent" {
  storage_send agsuite alice bob "h1"
  storage_send agsuite bob alice "h2"
  run storage_history agsuite bob
  [[ "$output" == *h1* ]]
  [[ "$output" == *h2* ]]
}

@test "contract: history without an agent returns the whole team (§2.1 G3)" {
  storage_send agsuite alice bob "tw1"
  storage_send agsuite carol dave "tw2"   # involves neither alice nor bob
  run storage_history agsuite              # omitted agent = whole team
  [ "$status" -eq 0 ]
  [[ "$output" == *tw1* ]]
  [[ "$output" == *tw2* ]]
  # the agent-scoped form still filters (additive, existing behaviour intact)
  run storage_history agsuite carol
  [[ "$output" == *tw2* ]]
  [[ "$output" != *tw1* ]]
}

@test "contract: history --limit returns the most recent N in chronological order" {
  storage_send agsuite alice bob "old1"
  storage_send agsuite alice bob "old2"
  storage_send agsuite alice bob "new3"
  run storage_history agsuite bob --limit 2
  [ "$status" -eq 0 ]
  [[ "$output" == *old2* ]]      # the two most recent
  [[ "$output" == *new3* ]]
  [[ "$output" != *old1* ]]      # the oldest dropped
  local l2 l3
  l2=$(printf '%s\n' "$output" | grep -n old2 | head -1 | cut -d: -f1)
  l3=$(printf '%s\n' "$output" | grep -n new3 | head -1 | cut -d: -f1)
  [ "$l2" -lt "$l3" ]            # chronological order, not reverse
}

@test "contract: history <team> --limit (no agent) treats --limit as a flag, not the agent" {
  storage_send agsuite alice bob "p1"
  storage_send agsuite carol dave "p2"
  run storage_history agsuite --limit 1     # --limit must NOT be consumed as <agent>
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]   # exactly one record (team-wide)
  [[ "$output" == *'"type":"message_sent"'* ]]         # pure JSONL, not a parse error
  [ "$(sqlite3 :memory: "SELECT json_valid('$(printf '%s' "$output" | sed "s/'/''/g")')")" = "1" ]
}

@test "contract: export then import round-trips the event log" {
  local id; id=$(storage_send agsuite alice bob "keep")
  storage_mark_read_batch agsuite bob "$id"
  local f="$TEST_SKILL_DIR/export.jsonl"
  storage_export agsuite "$f"
  [ -s "$f" ]
  rm -f "$TEST_SKILL_DIR"/db/messages.db*
  storage_init agsuite
  storage_import agsuite "$f"
  run storage_history agsuite bob
  [[ "$output" == *keep* ]]
}

@test "contract: record-returning ops emit pure JSONL (no status word on stdout)" {
  storage_send agsuite alice bob "j1"
  run storage_list_unread agsuite bob
  [ "$status" -eq 0 ]
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(sqlite3 :memory: "SELECT json_valid('$(printf '%s' "$line" | sed "s/'/''/g")')")" = "1" ]
  done <<< "$output"
}

@test "contract: list_unread / history records carry a type field" {
  storage_send agsuite alice bob "t1"
  run storage_list_unread agsuite bob
  [[ "$output" == *'"type":"message_sent"'* ]]
  run storage_history agsuite bob
  [[ "$output" == *'"type":"message_sent"'* ]]
}

@test "contract: the delivery cursor is a single whitespace-free token" {
  local tip; tip=$(storage_watch_tip agsuite:bob)
  [ -n "$tip" ]
  [ "$(printf '%s' "$tip" | wc -l | tr -d ' ')" = "0" ]   # one line, no trailing newline
  [[ "$tip" != *" "* ]]
  [[ "$tip" != *$'\t'* ]]
}

@test "contract: watch_after's trailing cursor record is the final line" {
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice bob "w1"
  local out; out=$(storage_watch_after "$tip" agsuite:bob)
  [[ "$(printf '%s\n' "$out" | tail -1)" == *'"type":"cursor"'* ]]
}

@test "contract: a data op fails non-zero on a broken store (no silent success)" {
  # A backend error must surface as a non-zero exit, never a silent empty result.
  # Corruption is store-specific, so break whichever store the active driver reads.
  if [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ]; then
    printf 'not json at all {{{\n' > "$(dirname "$(agmsg_db_path agsuite)")/events.jsonl"
  else
    local db; db="$(agmsg_db_path agsuite)"
    rm -f "$db"-wal "$db"-shm
    printf 'not a sqlite database' > "$db"
  fi
  run storage_list_unread agsuite bob
  [ "$status" -ne 0 ]
  run storage_watch_tip agsuite:bob   # the tip read must also fail, not report 0
  [ "$status" -ne 0 ]
}

@test "contract(jsonl): mark_read_batch fails non-zero when the lock is unavailable" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ] || skip "jsonl-specific (mkdir write lock)"
  local id; id=$(storage_send agsuite alice bob "x")
  # Hold the write lock so the mark can't acquire it; cap retries so it fails fast.
  mkdir "$(dirname "$(agmsg_db_path agsuite)")/events.jsonl.lock"
  AGMSG_JSONL_LOCK_TRIES=2 run storage_mark_read_batch agsuite bob "$id"
  rmdir "$(dirname "$(agmsg_db_path agsuite)")/events.jsonl.lock" 2>/dev/null || true
  [ "$status" -ne 0 ]                  # control op surfaces the failure
  [[ "$output" != *ok* ]]             # never a false "ok"
}

@test "contract(jsonl): compact keys reads by tuple, not a space-join (no collision)" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ] || skip "jsonl-specific (compaction key)"
  storage_init agsuite
  local log; log="$(dirname "$(agmsg_db_path agsuite)")/events.jsonl"
  # Two DISTINCT (team, agent, msg_id) tuples that a space-joined key would merge:
  #   ("a b","c","1")  and  ("a","b c","1")  both flatten to "a b c 1".
  printf '%s\n%s\n' \
    '{"type":"message_read","id":"r1","msg_id":"1","team":"a b","agent":"c","at":"x"}' \
    '{"type":"message_read","id":"r2","msg_id":"1","team":"a","agent":"b c","at":"y"}' >> "$log"
  storage_compact agsuite
  run grep -c '"type":"message_read"' "$log"   # both are distinct read-state; keep both
  [ "$output" -eq 2 ]
}

@test "contract(jsonl): mark_read_batch fails non-zero on a corrupt log" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = jsonl ] || skip "jsonl-specific (corrupt JSONL)"
  storage_send agsuite alice bob "x" >/dev/null
  printf 'not json {{{\n' > "$(dirname "$(agmsg_db_path agsuite)")/events.jsonl"
  run storage_mark_read_batch agsuite bob someid
  [ "$status" -ne 0 ]                  # the existing-reads scan failure aborts the mark
  [[ "$output" != *ok* ]]
}

# --- compaction contract (§2.7) --------------------------------------------
# These pin storage_compact's behavioural guarantees through the facade, so they
# hold for every driver: idempotent, state-preserving, cursor-safe, monotonic tip.

@test "contract: compact is state-preserving (unread + history unchanged)" {
  local a b c
  a=$(storage_send agsuite alice bob "p1")
  b=$(storage_send agsuite alice bob "p2")
  c=$(storage_send agsuite bob alice "p3")
  storage_mark_read_batch agsuite bob "$a"
  # redundant markers — fodder compaction should coalesce away invisibly
  storage_mark_read_batch agsuite bob "$a"
  storage_mark_read_batch agsuite bob "$a"
  local unread_before history_before
  unread_before=$(storage_list_unread agsuite bob)
  history_before=$(storage_history agsuite bob)
  storage_compact agsuite
  [ "$(storage_list_unread agsuite bob)" = "$unread_before" ]
  [ "$(storage_history agsuite bob)" = "$history_before" ]
}

@test "contract: compact is idempotent (second compact is a no-op for visible state)" {
  local id; id=$(storage_send agsuite alice bob "i1")
  storage_mark_read_batch agsuite bob "$id"
  storage_mark_read_batch agsuite bob "$id"
  storage_compact agsuite
  local after_one; after_one=$(storage_export agsuite "$TEST_SKILL_DIR/c1.jsonl"; cat "$TEST_SKILL_DIR/c1.jsonl")
  storage_compact agsuite
  storage_export agsuite "$TEST_SKILL_DIR/c2.jsonl"
  [ "$(cat "$TEST_SKILL_DIR/c2.jsonl")" = "$after_one" ]
}

@test "contract: compact is cursor-safe (a pre-compact cursor skips nothing)" {
  local tip; tip=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice bob "c1"
  storage_send agsuite alice bob "c2"
  # pile up redundant read markers AFTER the sends, so compaction deletes the
  # highest-seq rows — the case that would regress a naive MAX(seq) cursor.
  local x; x=$(storage_send agsuite alice carol "noise")
  storage_mark_read_batch agsuite carol "$x"
  storage_mark_read_batch agsuite carol "$x"
  storage_mark_read_batch agsuite carol "$x"
  storage_compact agsuite
  run storage_watch_after "$tip" agsuite:bob
  [ "$status" -eq 0 ]
  [[ "$output" == *"c1"* ]]
  [[ "$output" == *"c2"* ]]
}

@test "contract: the delivery tip never regresses across a compact (monotonic)" {
  storage_send agsuite alice bob "m1"
  local id; id=$(storage_send agsuite alice bob "m2")
  storage_mark_read_batch agsuite bob "$id"
  storage_mark_read_batch agsuite bob "$id"   # redundant tail markers
  local tip_before; tip_before=$(storage_watch_tip agsuite:bob)
  storage_compact agsuite
  local tip_after; tip_after=$(storage_watch_tip agsuite:bob)
  [ "$tip_after" -ge "$tip_before" ]
}

# --- sqlite-specific: compaction physically shrinks the log -----------------

@test "contract(sqlite): compact coalesces tail duplicates AND high-water keeps the tip/cursor safe" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = sqlite ] || skip "sqlite-specific (direct events-table injection / high-water)"
  # This is the test that actually EXERCISES cursor-safety: mark_read_batch is
  # write-idempotent, so the driver-agnostic cursor tests above never create the
  # tail-duplicate rows whose deletion would regress a naive MAX(seq) tip. Here we
  # inject those duplicates directly (the highest seqs in the log), then compact —
  # the case that distinguishes the AUTOINCREMENT high-water from MAX(seq).
  local db; db="$(agmsg_db_path agsuite)"
  storage_send agsuite alice bob "s1"
  # cursor taken before a later send — must still deliver that later message.
  local cur0; cur0=$(storage_watch_tip agsuite:bob)
  storage_send agsuite alice bob "s2-late"
  local id; id=$(storage_send agsuite alice bob "s3")
  # duplicate read markers as the TAIL rows (highest seq): compact deletes these,
  # dropping MAX(seq) but NOT the high-water.
  agmsg_sqlite "$db" "INSERT INTO events (type,id,team,agent,msg_id,at) VALUES
    ('message_read','r1','agsuite','bob','$id','2026-01-01T00:00:01Z'),
    ('message_read','r2','agsuite','bob','$id','2026-01-01T00:00:02Z'),
    ('message_read','r3','agsuite','bob','$id','2026-01-01T00:00:03Z');"
  local reads_before total_before tip_before
  reads_before=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM events WHERE type='message_read';" | tr -d '\r')
  total_before=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM events;" | tr -d '\r')
  tip_before=$(storage_watch_tip agsuite:bob)
  [ "$reads_before" -eq 3 ]

  storage_compact agsuite

  local reads_after total_after tip_after
  reads_after=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM events WHERE type='message_read';" | tr -d '\r')
  total_after=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM events;" | tr -d '\r')
  tip_after=$(storage_watch_tip agsuite:bob)
  [ "$reads_after" -eq 1 ]                 # coalesced to one
  [ "$total_after" -lt "$total_before" ]   # strictly shrank (2 tail dupes removed)
  # high-water: the tip did NOT regress even though the tail rows (= old MAX seq)
  # were deleted. A MAX(seq) implementation would fail here.
  [ "$tip_after" -ge "$tip_before" ]
  # and the cursor issued before s2-late still delivers it — no message_sent lost.
  run storage_watch_after "$cur0" agsuite:bob
  [[ "$output" == *"s2-late"* ]]
}

@test "contract(sqlite): forward-compat — export/list/history ignore an unknown event type" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = sqlite ] || skip "sqlite-specific (direct events-table injection)"
  local db; db="$(agmsg_db_path agsuite)"
  storage_send agsuite alice bob "known"
  # a v2-style event a v1 reader has never seen — must be skipped, not leaked.
  agmsg_sqlite "$db" "INSERT INTO events (type,id,team,from_agent,to_agent,body,at)
    VALUES ('message_reaction','x1','agsuite','bob','alice','👍','2026-02-02T00:00:00Z');"
  # export stays clean JSONL: no blank line, no unknown type, every line valid JSON.
  local f="$TEST_SKILL_DIR/fc.jsonl"
  storage_export agsuite "$f"
  [ "$(grep -c '^$' "$f")" -eq 0 ]          # no blank line leaked by the unknown type
  refute grep -q 'message_reaction' "$f"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(sqlite3 :memory: "SELECT json_valid('$(printf '%s' "$line" | sed "s/'/''/g")')")" = "1" ]
  done < "$f"
  # the known message is still visible; the unknown event perturbs nothing.
  run storage_list_unread agsuite bob
  [[ "$output" == *known* ]]
  [[ "$output" != *message_reaction* ]]
  run storage_history agsuite bob
  [[ "$output" == *known* ]]
  [[ "$output" != *message_reaction* ]]
}

# --- sqlite-specific: legacy messages-table compatibility (§2.4) ------------
# These assert the sqlite driver's read-only UNION of the pre-event-log store;
# they are intentionally NOT driver-agnostic (a fresh jsonl/redis store has no
# legacy table). Existing installs must keep their inbox + history at cutover.

@test "contract(sqlite): legacy messages rows surface in unread and history" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = sqlite ] || skip "sqlite-specific (legacy messages table)"
  local db; db="$(agmsg_db_path agsuite)"
  agmsg_sqlite "$db" "INSERT INTO messages (team,from_agent,to_agent,body,read_at)
    VALUES ('agsuite','alice','bob','legacy-unread',NULL),
           ('agsuite','alice','bob','legacy-read','2026-01-01T00:00:00Z');"
  run storage_list_unread agsuite bob
  [[ "$output" == *legacy-unread* ]]
  [[ "$output" != *legacy-read* ]]
  run storage_history agsuite bob
  [[ "$output" == *legacy-unread* ]]
  [[ "$output" == *legacy-read* ]]
}

@test "contract(sqlite): marking a legacy id read hides it without mutating the row" {
  [ "${AGMSG_STORAGE_DRIVER:-sqlite}" = sqlite ] || skip "sqlite-specific (legacy messages table)"
  local db; db="$(agmsg_db_path agsuite)"
  agmsg_sqlite "$db" "INSERT INTO messages (team,from_agent,to_agent,body)
    VALUES ('agsuite','alice','bob','legacy-x');"
  local lid; lid=$(agmsg_sqlite "$db" "SELECT id FROM messages WHERE body='legacy-x';" | tr -d '\r')
  storage_mark_read_batch agsuite bob "$lid"
  run storage_list_unread agsuite bob
  [[ "$output" != *legacy-x* ]]
  # the legacy row is never mutated (read_at stays NULL) — no destructive migration.
  [ -z "$(agmsg_sqlite "$db" "SELECT read_at FROM messages WHERE body='legacy-x';" | tr -d '\r')" ]
}
