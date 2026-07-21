#!/usr/bin/env bash
# Optional Stage-1 remote synchronization extension for the SQLite driver.
# See docs/adr/0005-stage-1-remote-sync.md. All bulk input/output is JSONL.

_sqlite_sync_uuid4() {
  local h n variant
  h=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n') || return 1
  [ "${#h}" -eq 32 ] || return 1
  n=$((16#${h:16:1}))
  variant=$(printf '%x' $(((n & 3) | 8)))
  printf '%s-%s-4%s-%s%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "$variant" "${h:17:3}" "${h:20:12}"
}

_sqlite_sync_valid_binding() {
  printf '%s\n' "$1" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 1
  printf '%s\n' "$2" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 1
  case "$3" in ''|*[!0-9]*) return 1 ;; esac
}

_sqlite_sync_decimal_le() {
  local left right
  left=$(printf '%s' "$1" | sed 's/^0*//')
  right=$(printf '%s' "$2" | sed 's/^0*//')
  [ -n "$left" ] || left=0
  [ -n "$right" ] || right=0
  if [ "${#left}" -lt "${#right}" ] ||
     { [ "${#left}" -eq "${#right}" ] && [[ "$left" < "$right" || "$left" = "$right" ]]; }; then
    echo 1
  else
    echo 0
  fi
}

_sqlite_sync_sequence() {
  case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
  [ "$(_sqlite_sync_decimal_le "$1" 9223372036854775807)" = 1 ]
}

_sqlite_sync_schema() {
  command -v jq >/dev/null 2>&1 || {
    echo "agmsg: Stage-1 sync requires jq" >&2
    return 10
  }
  storage_init >/dev/null || return 13
  local db generation
  db="$(_sqlite_db)"
  agmsg_sqlite "$db" "
    CREATE TABLE IF NOT EXISTS sync_store_metadata (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      generation TEXT NOT NULL UNIQUE
    );
    CREATE TABLE IF NOT EXISTS sync_bindings (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      push_cursor INTEGER NOT NULL DEFAULT 0,
      transport_cursor TEXT NOT NULL DEFAULT '0',
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation)
    );
    CREATE TABLE IF NOT EXISTS sync_messages (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      local_position INTEGER NOT NULL,
      local_id TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      server_seq TEXT,
      direction TEXT NOT NULL CHECK(direction IN ('push','pull')),
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,local_position),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,wire_id)
    );
    CREATE TABLE IF NOT EXISTS sync_quarantine (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      server_received_at TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      status TEXT NOT NULL,
      policy_revision TEXT,
      local_security_revision TEXT,
      reason TEXT,
      PRIMARY KEY(server_instance_id,remote_team_id,protocol_version,wire_id),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,server_seq)
    );
    CREATE TABLE IF NOT EXISTS sync_conflicts (
      conflict_id INTEGER PRIMARY KEY AUTOINCREMENT,
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      envelope_v INTEGER NOT NULL,
      cipher TEXT NOT NULL,
      key_id TEXT,
      blob TEXT NOT NULL,
      reason TEXT NOT NULL,
      observed_at TEXT NOT NULL,
      UNIQUE(server_instance_id,remote_team_id,protocol_version,
             server_seq,wire_id,reason)
    );
    CREATE TABLE IF NOT EXISTS sync_resync_audits (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      expected_transport_cursor TEXT NOT NULL,
      accepted_floor TEXT NOT NULL,
      gap_start TEXT NOT NULL,
      gap_end TEXT NOT NULL,
      reason TEXT NOT NULL CHECK(reason='retention-gap-accepted'),
      accepted_at TEXT NOT NULL,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,accepted_floor)
    );
    CREATE TABLE IF NOT EXISTS sync_read_members (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      member_id TEXT NOT NULL,
      agent TEXT NOT NULL,
      remote_agent TEXT NOT NULL,
      active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0,1)),
      name_mismatch INTEGER NOT NULL DEFAULT 0 CHECK(name_mismatch IN (0,1)),
      blocked_reason TEXT,
      remote_server_seq TEXT NOT NULL DEFAULT '0',
      min_available_seq TEXT NOT NULL DEFAULT '0',
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,member_id),
      UNIQUE(local_team,server_instance_id,remote_team_id,
             protocol_version,driver_generation,agent)
    );
    CREATE TABLE IF NOT EXISTS sync_read_remote_exact (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      member_id TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,member_id,wire_id)
    );
    CREATE TABLE IF NOT EXISTS sync_read_aliases (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      agent TEXT NOT NULL,
      local_id TEXT NOT NULL,
      wire_id TEXT NOT NULL,
      server_seq TEXT,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,agent,local_id),
      UNIQUE(server_instance_id,remote_team_id,protocol_version,agent,wire_id)
    );
    CREATE TABLE IF NOT EXISTS sync_read_prepared (
      local_team TEXT NOT NULL,
      server_instance_id TEXT NOT NULL,
      remote_team_id TEXT NOT NULL,
      protocol_version INTEGER NOT NULL,
      driver_generation TEXT NOT NULL,
      member_id TEXT NOT NULL,
      server_seq TEXT NOT NULL,
      PRIMARY KEY(local_team,server_instance_id,remote_team_id,
                  protocol_version,driver_generation,member_id)
    );
  " >/dev/null 2>&1 || return 13
  if ! agmsg_sqlite "$db" "PRAGMA table_info(sync_read_members);" | cut -d'|' -f2 |
      grep -qx remote_agent; then
    agmsg_sqlite "$db" "BEGIN IMMEDIATE;
      ALTER TABLE sync_read_members ADD COLUMN remote_agent TEXT NOT NULL DEFAULT '';
      ALTER TABLE sync_read_members ADD COLUMN name_mismatch INTEGER NOT NULL DEFAULT 0
        CHECK(name_mismatch IN (0,1));
      ALTER TABLE sync_read_members ADD COLUMN blocked_reason TEXT;
      UPDATE sync_read_members SET remote_agent=agent;
      COMMIT;" >/dev/null 2>&1 || return 13
  fi
  generation=$(agmsg_sqlite "$db" \
    "SELECT generation FROM sync_store_metadata WHERE singleton=1;" 2>/dev/null | tr -d '\r')
  if [ -z "$generation" ]; then
    generation=$(_sqlite_sync_uuid4) || return 13
    agmsg_sqlite "$db" "INSERT OR IGNORE INTO sync_store_metadata(singleton,generation)
      VALUES(1,'$(_sqlite_lit "$generation")');" >/dev/null 2>&1 || return 13
  fi
}

# Read-only cursor/audit lookup for explicit retention-gap recovery. This
# deliberately does not call _sqlite_sync_schema or initialize a binding.
storage_sync_resync_status() {
  local team="$1" server="$2" remote="$3" protocol="$4" floor="$5"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_sequence "$floor" || return 13
  local db tl generation table_count
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"
  [ -f "$db" ] || return 13
  table_count=$(agmsg_sqlite "$db" "SELECT COUNT(*) FROM sqlite_master
    WHERE type='table' AND name IN ('sync_store_metadata','sync_bindings','sync_resync_audits');" \
    2>/dev/null | tr -d '\r') || return 13
  [ "$table_count" = 3 ] || return 13
  generation=$(agmsg_sqlite "$db" "SELECT generation FROM sync_store_metadata WHERE singleton=1;" \
    2>/dev/null | tr -d '\r') || return 13
  [ -n "$generation" ] || return 13
  local output
  output=$(_sqlite_data "SELECT json_object(
      'type','sync_resync_status','driver_generation',b.driver_generation,
      'transport_cursor',b.transport_cursor,'audit',CASE WHEN a.accepted_floor IS NULL
        THEN NULL ELSE json_object(
          'expected_transport_cursor',a.expected_transport_cursor,
          'accepted_floor',a.accepted_floor,'gap_start',a.gap_start,
          'gap_end',a.gap_end,'reason',a.reason) END)
    FROM sync_bindings b LEFT JOIN sync_resync_audits a
      ON a.local_team=b.local_team AND a.server_instance_id=b.server_instance_id
     AND a.remote_team_id=b.remote_team_id AND a.protocol_version=b.protocol_version
     AND a.driver_generation=b.driver_generation AND a.accepted_floor='$floor'
    WHERE b.local_team='$tl' AND b.server_instance_id='$server'
      AND b.remote_team_id='$remote' AND b.protocol_version=$protocol
      AND b.driver_generation='$(_sqlite_lit "$generation")';") || return 13
  [ -n "$output" ] || return 13
  printf '%s\n' "$output"
}

# Atomically records an operator-accepted unavailable interval and advances
# only the pull transport cursor.
storage_sync_resync() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  local line expected floor current reason generation db tl gap_start node_bin strict_parser
  node_bin="${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"
  strict_parser="$SKILL_DIR/scripts/internal/strict-jsonl.mjs"
  command -v "$node_bin" >/dev/null 2>&1 && [ -f "$strict_parser" ] || return 10
  line=$("$node_bin" "$strict_parser" current_seq expected_transport_cursor \
    min_available_seq reason type) || return 13
  printf '%s\n' "$line" | jq -e '
    (keys == ["current_seq","expected_transport_cursor","min_available_seq","reason","type"])
    and .type == "sync_resync" and .reason == "retention-gap-accepted"
    and (.expected_transport_cursor|type)=="string"
    and (.min_available_seq|type)=="string" and (.current_seq|type)=="string"' \
    >/dev/null 2>&1 || return 13
  expected=$(printf '%s\n' "$line" | jq -r '.expected_transport_cursor')
  floor=$(printf '%s\n' "$line" | jq -r '.min_available_seq')
  current=$(printf '%s\n' "$line" | jq -r '.current_seq')
  reason=$(printf '%s\n' "$line" | jq -r '.reason')
  _sqlite_sync_sequence "$expected" && _sqlite_sync_sequence "$floor" &&
    _sqlite_sync_sequence "$current" || return 13
  [ "$(_sqlite_sync_decimal_le "$expected" "$floor")" = 1 ] && [ "$expected" != "$floor" ] || return 13
  [ "$(_sqlite_sync_decimal_le "$floor" "$current")" = 1 ] || return 13
  gap_start=$((10#$expected + 1))
  _sqlite_sync_sequence "$gap_start" || return 13
  _sqlite_sync_schema || return $?
  generation=$(_sqlite_sync_generation); db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"

  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE resync_assert(ok INTEGER CHECK(ok=1));
    INSERT INTO resync_assert SELECT CASE WHEN COUNT(*)=1 THEN 1 ELSE 0 END
      FROM sync_bindings WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$(_sqlite_lit "$generation")'
       AND transport_cursor='$expected';
    INSERT INTO sync_resync_audits
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,expected_transport_cursor,accepted_floor,gap_start,
       gap_end,reason,accepted_at)
    VALUES('$tl','$server','$remote',$protocol,'$(_sqlite_lit "$generation")',
      '$expected','$floor','$gap_start','$floor','$reason',
      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
    UPDATE sync_bindings SET transport_cursor='$floor'
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$(_sqlite_lit "$generation")'
       AND transport_cursor='$expected';
    COMMIT;" >/dev/null 2>&1 || return 13

  _sqlite_data "SELECT json_object(
      'type','sync_resync_result','driver_generation',driver_generation,
      'expected_transport_cursor',expected_transport_cursor,
      'transport_cursor',accepted_floor,'accepted_floor',accepted_floor,
      'gap_start',gap_start,'gap_end',gap_end,'reason',reason)
    FROM sync_resync_audits WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$(_sqlite_lit "$generation")' AND accepted_floor='$floor';"
}

_sqlite_sync_generation() {
  agmsg_sqlite "$(_sqlite_db)" \
    "SELECT generation FROM sync_store_metadata WHERE singleton=1;" | tr -d '\r'
}

_sqlite_sync_ensure_binding() {
  local team="$1" server="$2" remote="$3" protocol="$4" generation="$5"
  agmsg_sqlite "$(_sqlite_db)" "INSERT OR IGNORE INTO sync_bindings
    (local_team,server_instance_id,remote_team_id,protocol_version,driver_generation)
    VALUES('$(_sqlite_lit "$team")','$server','$remote',$protocol,'$generation');" \
    >/dev/null 2>&1
}

# Emits sync_state followed by ordered, durable push reservations.
storage_sync_prepare_push() {
  local team="$1" server="$2" remote="$3" protocol="$4" limit="$5"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  case "$limit" in ''|*[!0-9]*) return 13 ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 1000 ] || return 13
  _sqlite_sync_schema || return $?

  local prepare generation db tl input_ok version cipher key_json key_id recipients max_blob allow_new
  prepare=$(cat)
  input_ok=$(printf '%s\n' "$prepare" | jq -r \
    'select(.type=="sync_prepare" and (.envelope_v|type)=="number" and
            (.cipher|type)=="string" and has("key_id") and
            (.max_blob_bytes|type)=="number" and (.allow_new|type)=="boolean") | "ok"' 2>/dev/null)
  [ "$input_ok" = ok ] || return 13
  version=$(printf '%s\n' "$prepare" | jq -r '.envelope_v')
  cipher=$(printf '%s\n' "$prepare" | jq -r '.cipher')
  key_json=$(printf '%s\n' "$prepare" | jq -c '.key_id')
  key_id=$(printf '%s\n' "$prepare" | jq -r '.key_id // empty')
  recipients=$(printf '%s\n' "$prepare" | jq -c '.recipients // []')
  max_blob=$(printf '%s\n' "$prepare" | jq -r '.max_blob_bytes')
  allow_new=$(printf '%s\n' "$prepare" | jq -r 'if .allow_new then 1 else 0 end')
  [ "$version" = 1 ] || return 13
  case "$cipher" in
    none) [ "$key_json" = null ] && [ "$recipients" = '[]' ] || return 13 ;;
    age-v1)
      printf '%s\n' "$key_id" | grep -Eq '^[a-z0-9][a-z0-9._-]{0,63}$' || return 13
      [ "$(printf '%s\n' "$recipients" | jq -r 'length >= 1 and length <= 256 and (all(.[]; type=="string"))')" = true ] || return 13
      ;;
    *) return 13 ;;
  esac
  case "$max_blob" in ''|*[!0-9]*) return 13 ;; esac

  generation=$(_sqlite_sync_generation) || return 13
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || return 13
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"

  local rows line pos local_id body at created envelope blob wire
  local cipher_helper node_bin seal_request q
  cipher_helper="${AGMSG_SYNC_CIPHER_HELPER:-$SKILL_DIR/scripts/internal/sync-cipher.mjs}"
  node_bin="${AGMSG_SYNC_NODE_BIN:-${AGMSG_NODE:-node}}"
  [ -f "$cipher_helper" ] || return 13
  rows=$(_sqlite_data "
    SELECT json_object('local_position',CAST(e.seq AS TEXT),'local_id',e.id,
                       'body',e.body,'at',e.at,'from_agent',e.from_agent,
                       'to_agent',e.to_agent)
      FROM events e
      JOIN sync_bindings b ON b.local_team='$tl'
       AND b.server_instance_id='$server' AND b.remote_team_id='$remote'
       AND b.protocol_version=$protocol AND b.driver_generation='$generation'
      LEFT JOIN sync_messages m ON m.local_team=b.local_team
       AND m.server_instance_id=b.server_instance_id
       AND m.remote_team_id=b.remote_team_id
       AND m.protocol_version=b.protocol_version
       AND m.driver_generation=b.driver_generation AND m.local_position=e.seq
     WHERE e.type='message_sent' AND e.team='$tl' AND e.seq>b.push_cursor
       AND m.server_seq IS NULL
       AND ($allow_new=1 OR m.wire_id IS NOT NULL)
     ORDER BY e.seq LIMIT $limit;
  ") || return 13

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    pos=$(printf '%s\n' "$line" | jq -r '.local_position')
    local_id=$(printf '%s\n' "$line" | jq -r '.local_id')
    # A reservation already produced by an earlier call is immutable.
    if [ -n "$(agmsg_sqlite "$db" "SELECT wire_id FROM sync_messages WHERE
        local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
        AND protocol_version=$protocol AND driver_generation='$generation'
        AND local_position=$pos;" 2>/dev/null)" ]; then
      continue
    fi
    body=$(printf '%s\n' "$line" | jq -r '.body')
    [ -n "$body" ] || return 13
    at=$(printf '%s\n' "$line" | jq -r '.at')
    case "$at" in ????-??-??T??:??:??Z) created="${at%Z}.000000Z" ;; *) created="$at" ;; esac
    wire=$(_sqlite_sync_uuid4) || return 13
    seal_request=$(printf '%s\n' "$line" | jq -c \
      --arg type sync_seal --arg cipher "$cipher" --arg key "$key_id" \
      --arg wire "$wire" --arg team_id "$remote" --arg created "$created" \
      --argjson version "$version" --argjson protocol "$protocol" \
      --argjson max_blob "$max_blob" --argjson recipients "$recipients" \
      '{type:$type,envelope_v:$version,cipher:$cipher,
        key_id:(if $key=="" then null else $key end),max_blob_bytes:$max_blob,
        wire_id:$wire,team_id:$team_id,protocol_version:$protocol,recipients:$recipients,
        projection:{body:.body,created_at:$created,from_agent:.from_agent,to_agent:.to_agent}}') || return 13
    envelope=$(printf '%s\n' "$seal_request" | "$node_bin" "$cipher_helper" seal) || return 13
    if ! printf '%s\n' "$envelope" | jq -e --arg cipher "$cipher" --argjson key "$key_json" \
      '.v==1 and .cipher==$cipher and .key_id==$key and (.blob|type)=="string" and (.blob|length)>0' \
      >/dev/null 2>&1; then
      printf 'agmsg: cipher helper returned an invalid envelope (%s)\n' \
        "$(printf '%s\n' "$envelope" | jq -c '{v,cipher,key_id,blob_type:(.blob|type),blob_length:(.blob|length)}' 2>/dev/null || echo unparseable)" >&2
      return 13
    fi
    blob=$(printf '%s\n' "$envelope" | jq -r '.blob // empty')
    if [ "${AGMSG_SYNC_TEST_ABORT_AFTER_SEAL:-}" = 1 ]; then
      return 75
    fi
    if [ -n "$key_id" ]; then q="'$(_sqlite_lit "$key_id")'"; else q="NULL"; fi
    # INSERT OR IGNORE makes concurrent prepare calls converge on one winner;
    # the final SELECT below always emits the committed winner's bytes.
    agmsg_sqlite "$db" "BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO sync_messages
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,local_position,local_id,wire_id,envelope_v,cipher,
         key_id,blob,direction)
      VALUES('$tl','$server','$remote',$protocol,'$generation',$pos,
             '$(_sqlite_lit "$local_id")','$wire',1,'$(_sqlite_lit "$cipher")',$q,
             '$(_sqlite_lit "$blob")','push');
      INSERT OR IGNORE INTO sync_read_aliases
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,agent,local_id,wire_id,server_seq)
      SELECT m.local_team,m.server_instance_id,m.remote_team_id,m.protocol_version,
             m.driver_generation,e.to_agent,m.local_id,m.wire_id,m.server_seq
        FROM sync_messages m JOIN events e ON e.seq=m.local_position
       WHERE m.local_team='$tl' AND m.server_instance_id='$server'
         AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
         AND m.driver_generation='$generation' AND m.local_position=$pos
         AND EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
           AND r.team=e.team AND r.agent=e.to_agent AND r.msg_id=e.id);
      COMMIT;" >/dev/null 2>&1 || return 13
  done <<EOF
$rows
EOF

  _sqlite_data "SELECT json_object('type','sync_state','driver_generation',
      '$generation','transport_cursor',transport_cursor)
    FROM sync_bindings WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$generation';
    SELECT json_object('type','sync_push_candidate','local_position',
      CAST(m.local_position AS TEXT),'local_id',m.local_id,'id',m.wire_id,
      'envelope',json_object('v',m.envelope_v,'cipher',m.cipher,
                             'key_id',m.key_id,'blob',m.blob))
    FROM sync_messages m JOIN sync_bindings b
      ON b.local_team=m.local_team AND b.server_instance_id=m.server_instance_id
     AND b.remote_team_id=m.remote_team_id AND b.protocol_version=m.protocol_version
     AND b.driver_generation=m.driver_generation
    WHERE m.local_team='$tl' AND m.server_instance_id='$server'
      AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
      AND m.driver_generation='$generation' AND m.local_position>b.push_cursor
      AND m.server_seq IS NULL ORDER BY m.local_position LIMIT $limit;"
}

# Reads complete server acknowledgements and advances only the contiguous prefix.
storage_sync_reconcile_push() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl line values="" pos wire seq disposition count=0
  generation=$(_sqlite_sync_generation); db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$(printf '%s\n' "$line" | jq -r '.type // empty')" = sync_push_ack ] || return 13
    pos=$(printf '%s\n' "$line" | jq -r '.local_position // empty')
    wire=$(printf '%s\n' "$line" | jq -r '.id // empty')
    seq=$(printf '%s\n' "$line" | jq -r '.server_seq // empty')
    disposition=$(printf '%s\n' "$line" | jq -r '.disposition // empty')
    case "$pos:$seq" in *[!0-9:]*) return 13 ;; esac
    case "$disposition" in stored|duplicate) ;; *) return 13 ;; esac
    printf '%s' "$wire" | grep -Eq '^[0-9a-f-]{36}$' || return 13
    values="${values}${values:+,}($pos,'$wire','$seq')"; count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 13

  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE incoming_sync_acks(
      local_position INTEGER UNIQUE,wire_id TEXT UNIQUE,server_seq TEXT UNIQUE);
    INSERT INTO incoming_sync_acks VALUES $values;
    CREATE TEMP TABLE sync_assert(ok INTEGER CHECK(ok=1));
    INSERT INTO sync_assert SELECT CASE WHEN COUNT(*)=$count THEN 1 ELSE 0 END
      FROM incoming_sync_acks a JOIN sync_messages m
        ON m.local_team='$tl' AND m.server_instance_id='$server'
       AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
       AND m.driver_generation='$generation' AND m.local_position=a.local_position
       AND m.wire_id=a.wire_id
       AND (m.server_seq IS NULL OR m.server_seq=a.server_seq);
    UPDATE sync_messages SET server_seq=(SELECT a.server_seq FROM incoming_sync_acks a
      WHERE a.local_position=sync_messages.local_position AND a.wire_id=sync_messages.wire_id)
      WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
        AND protocol_version=$protocol AND driver_generation='$generation'
        AND EXISTS(SELECT 1 FROM incoming_sync_acks a
          WHERE a.local_position=sync_messages.local_position AND a.wire_id=sync_messages.wire_id);
    UPDATE sync_read_aliases AS x SET server_seq=(
      SELECT m.server_seq FROM sync_messages m
       WHERE m.local_team=x.local_team AND m.server_instance_id=x.server_instance_id
         AND m.remote_team_id=x.remote_team_id AND m.protocol_version=x.protocol_version
         AND m.driver_generation=x.driver_generation AND m.local_id=x.local_id
         AND m.wire_id=x.wire_id)
     WHERE x.local_team='$tl' AND x.server_instance_id='$server'
       AND x.remote_team_id='$remote' AND x.protocol_version=$protocol
       AND x.driver_generation='$generation';
    UPDATE sync_bindings AS b SET push_cursor=COALESCE((
      SELECT MAX(e.seq) FROM events e
      WHERE e.type='message_sent' AND e.team='$tl' AND e.seq>b.push_cursor
        AND NOT EXISTS (
          SELECT 1 FROM events gap LEFT JOIN sync_messages gm
            ON gm.local_team='$tl' AND gm.server_instance_id='$server'
           AND gm.remote_team_id='$remote' AND gm.protocol_version=$protocol
           AND gm.driver_generation='$generation' AND gm.local_position=gap.seq
          WHERE gap.type='message_sent' AND gap.team='$tl'
            AND gap.seq>b.push_cursor AND gap.seq<=e.seq AND gm.server_seq IS NULL
        )),b.push_cursor)
    WHERE b.local_team='$tl' AND b.server_instance_id='$server'
      AND b.remote_team_id='$remote' AND b.protocol_version=$protocol
      AND b.driver_generation='$generation';
    COMMIT;" >/dev/null 2>&1 || return 12

  _sqlite_data "SELECT json_object('type','sync_reconcile_result','push_cursor',
    CAST(push_cursor AS TEXT)) FROM sync_bindings WHERE local_team='$tl'
    AND server_instance_id='$server' AND remote_team_id='$remote'
    AND protocol_version=$protocol AND driver_generation='$generation';"
}

# Reads a validated pull page, durably quarantines/reconciles/imports it, then
# advances the transport cursor in the same transaction.
storage_sync_apply_pull() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl sql_file line type final_cursor="" corrupt=0 outcome_ids=""
  local seq wire received v cipher key_id blob status policy local_rev reason
  local from to body at local_id q
  generation=$(_sqlite_sync_generation); db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || return 13
  sql_file=$(mktemp "${TMPDIR:-/tmp}/agmsg-sync-sql.XXXXXX") || return 13
  _AGMSG_SYNC_SQL_FILE="$sql_file"
  trap 'case "${_AGMSG_SYNC_SQL_FILE:-}" in "${TMPDIR:-/tmp}"/agmsg-sync-sql.*) rm -f "$_AGMSG_SYNC_SQL_FILE" ;; esac' EXIT INT TERM HUP
  printf '%s\n' 'BEGIN IMMEDIATE;' > "$sql_file"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    type=$(printf '%s\n' "$line" | jq -r '.type // empty')
    if [ "$type" = sync_pull_cursor ]; then
      final_cursor=$(printf '%s\n' "$line" | jq -r '.next_after // empty')
      case "$final_cursor" in ''|*[!0-9]*) rm -f "$sql_file"; return 13 ;; esac
      continue
    fi
    [ "$type" = sync_pull_message ] || { rm -f "$sql_file"; return 13; }
    seq=$(printf '%s\n' "$line" | jq -r '.server_seq // empty')
    wire=$(printf '%s\n' "$line" | jq -r '.id // empty')
    printf '%s\n' "$wire" | grep -Eq \
      '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
      || { rm -f "$sql_file"; trap - EXIT INT TERM HUP; return 13; }
    outcome_ids="${outcome_ids}${outcome_ids:+,}'$wire'"
    received=$(printf '%s\n' "$line" | jq -r '.server_received_at // empty')
    v=$(printf '%s\n' "$line" | jq -r '.envelope.v')
    cipher=$(printf '%s\n' "$line" | jq -r '.envelope.cipher')
    key_id=$(printf '%s\n' "$line" | jq -r '.envelope.key_id // empty')
    blob=$(printf '%s\n' "$line" | jq -r '.envelope.blob')
    status=$(printf '%s\n' "$line" | jq -r '.status')
    policy=$(printf '%s\n' "$line" | jq -r '.policy_revision // empty')
    local_rev=$(printf '%s\n' "$line" | jq -r '.local_security_revision // empty')
    reason=$(printf '%s\n' "$line" | jq -r '.reason // empty')
    case "$seq:$v" in *[!0-9:]*) rm -f "$sql_file"; return 13 ;; esac
    case "$status" in importable|unsupported_cipher|pending_key|authentication_failed|malformed|policy_violation) ;; *) rm -f "$sql_file"; return 13 ;; esac
    q="'$(_sqlite_lit "$key_id")'"; [ -n "$key_id" ] || q=NULL
    printf "%s\n" "
      INSERT OR IGNORE INTO sync_conflicts
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,envelope_v,cipher,key_id,blob,
         reason,observed_at)
      SELECT '$tl','$server','$remote',$protocol,'$generation','$seq','$wire',$v,
             '$(_sqlite_lit "$cipher")',$q,'$(_sqlite_lit "$blob")',
             'server sequence maps to another wire id',
             strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE EXISTS(SELECT 1 FROM sync_quarantine qx
        WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
          AND qx.protocol_version=$protocol AND qx.server_seq='$seq'
          AND qx.wire_id<>'$wire')
         OR EXISTS(SELECT 1 FROM sync_messages mx
        WHERE mx.server_instance_id='$server' AND mx.remote_team_id='$remote'
          AND mx.protocol_version=$protocol AND mx.server_seq='$seq'
          AND mx.wire_id<>'$wire');
      INSERT OR IGNORE INTO sync_conflicts
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,envelope_v,cipher,key_id,blob,
         reason,observed_at)
      SELECT '$tl','$server','$remote',$protocol,'$generation','$seq','$wire',$v,
             '$(_sqlite_lit "$cipher")',$q,'$(_sqlite_lit "$blob")',
             'wire id maps to another sequence or envelope',
             strftime('%Y-%m-%dT%H:%M:%fZ','now')
      WHERE EXISTS(SELECT 1 FROM sync_quarantine qx
        WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
          AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
          AND (qx.server_seq<>'$seq' OR qx.envelope_v<>$v
            OR qx.cipher<>'$(_sqlite_lit "$cipher")'
            OR COALESCE(qx.key_id,'')<>'$(_sqlite_lit "$key_id")'
            OR qx.blob<>'$(_sqlite_lit "$blob")'))
         OR EXISTS(SELECT 1 FROM sync_messages mx
        WHERE mx.server_instance_id='$server' AND mx.remote_team_id='$remote'
          AND mx.protocol_version=$protocol AND mx.wire_id='$wire'
          AND (mx.server_seq IS NOT NULL AND mx.server_seq<>'$seq'
            OR mx.envelope_v<>$v OR mx.cipher<>'$(_sqlite_lit "$cipher")'
            OR COALESCE(mx.key_id,'')<>'$(_sqlite_lit "$key_id")'
            OR mx.blob<>'$(_sqlite_lit "$blob")'));
      INSERT OR IGNORE INTO sync_quarantine
        (local_team,server_instance_id,remote_team_id,protocol_version,
         driver_generation,server_seq,wire_id,server_received_at,envelope_v,
         cipher,key_id,blob,status,policy_revision,local_security_revision,reason)
      VALUES('$tl','$server','$remote',$protocol,'$generation','$seq','$wire',
        '$(_sqlite_lit "$received")',$v,'$(_sqlite_lit "$cipher")',$q,
        '$(_sqlite_lit "$blob")','$status','$(_sqlite_lit "$policy")',
        '$(_sqlite_lit "$local_rev")','$(_sqlite_lit "$reason")');
      UPDATE sync_quarantine SET status='$status',
          policy_revision='$(_sqlite_lit "$policy")',
          local_security_revision='$(_sqlite_lit "$local_rev")',
          reason='$(_sqlite_lit "$reason")'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire'
         AND server_seq='$seq' AND envelope_v=$v
         AND cipher='$(_sqlite_lit "$cipher")'
         AND COALESCE(key_id,'')='$(_sqlite_lit "$key_id")'
         AND blob='$(_sqlite_lit "$blob")'
         AND status NOT IN ('corrupt_state','imported','reconciled');
      UPDATE sync_quarantine SET status='corrupt_state',reason='wire envelope mismatch'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire'
         AND (server_seq<>'$seq' OR envelope_v<>$v OR cipher<>'$(_sqlite_lit "$cipher")'
              OR COALESCE(key_id,'')<>'$(_sqlite_lit "$key_id")'
              OR blob<>'$(_sqlite_lit "$blob")');
      UPDATE sync_quarantine SET status='corrupt_state',reason='binding sequence conflict'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire'
         AND EXISTS(SELECT 1 FROM sync_conflicts cx
           WHERE cx.server_instance_id='$server' AND cx.remote_team_id='$remote'
             AND cx.protocol_version=$protocol AND cx.wire_id='$wire');
      UPDATE sync_quarantine SET status='corrupt_state',reason='mapped envelope mismatch'
       WHERE server_instance_id='$server' AND remote_team_id='$remote'
         AND protocol_version=$protocol AND wire_id='$wire' AND EXISTS(
           SELECT 1 FROM sync_messages m WHERE m.server_instance_id='$server'
             AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
             AND m.wire_id='$wire' AND (m.envelope_v<>$v OR m.cipher<>'$(_sqlite_lit "$cipher")'
               OR COALESCE(m.key_id,'')<>'$(_sqlite_lit "$key_id")'
               OR m.blob<>'$(_sqlite_lit "$blob")'
               OR (m.server_seq IS NOT NULL AND m.server_seq<>'$seq')));
      UPDATE sync_messages SET server_seq='$seq' WHERE server_instance_id='$server'
        AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
        AND envelope_v=$v AND cipher='$(_sqlite_lit "$cipher")'
        AND COALESCE(key_id,'')='$(_sqlite_lit "$key_id")'
        AND blob='$(_sqlite_lit "$blob")' AND (server_seq IS NULL OR server_seq='$seq')
        AND EXISTS(SELECT 1 FROM sync_quarantine qx
          WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
            AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
            AND qx.status='importable');
      UPDATE sync_quarantine SET status='reconciled' WHERE server_instance_id='$server'
        AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
        AND status='importable' AND EXISTS(SELECT 1 FROM sync_messages m
          WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
            AND m.protocol_version=$protocol AND m.wire_id='$wire' AND m.server_seq='$seq');" >> "$sql_file"

    if [ "$status" = importable ]; then
      from=$(printf '%s\n' "$line" | jq -r '.projection.from_agent // empty')
      to=$(printf '%s\n' "$line" | jq -r '.projection.to_agent // empty')
      body=$(printf '%s\n' "$line" | jq -r '.projection.body // empty')
      at=$(printf '%s\n' "$line" | jq -r '.projection.created_at // empty')
      [ -n "$from" ] && [ -n "$to" ] && [ -n "$body" ] && [ -n "$at" ] || { rm -f "$sql_file"; return 13; }
      local_id=$(_sqlite_uuid7) || { rm -f "$sql_file"; return 13; }
      printf "%s\n" "
        INSERT INTO events(type,id,team,from_agent,to_agent,body,at)
        SELECT 'message_sent','$local_id','$tl','$(_sqlite_lit "$from")',
               '$(_sqlite_lit "$to")','$(_sqlite_lit "$body")','$(_sqlite_lit "$at")'
        WHERE NOT EXISTS(SELECT 1 FROM sync_messages m
          WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
            AND m.protocol_version=$protocol AND m.wire_id='$wire')
          AND NOT EXISTS(SELECT 1 FROM sync_quarantine qx
          WHERE qx.server_instance_id='$server' AND qx.remote_team_id='$remote'
            AND qx.protocol_version=$protocol AND qx.wire_id='$wire'
            AND qx.status='corrupt_state')
          AND NOT EXISTS(SELECT 1 FROM sync_conflicts cx
          WHERE cx.server_instance_id='$server' AND cx.remote_team_id='$remote'
            AND cx.protocol_version=$protocol AND cx.wire_id='$wire');
        INSERT OR IGNORE INTO sync_messages
          (local_team,server_instance_id,remote_team_id,protocol_version,
           driver_generation,local_position,local_id,wire_id,envelope_v,cipher,
           key_id,blob,server_seq,direction)
        SELECT '$tl','$server','$remote',$protocol,'$generation',seq,id,'$wire',$v,
               '$(_sqlite_lit "$cipher")',$q,'$(_sqlite_lit "$blob")','$seq','pull'
          FROM events WHERE id='$local_id';
        UPDATE sync_quarantine SET status='imported' WHERE server_instance_id='$server'
          AND remote_team_id='$remote' AND protocol_version=$protocol AND wire_id='$wire'
          AND status<>'corrupt_state' AND EXISTS(SELECT 1 FROM sync_messages m
            WHERE m.server_instance_id='$server' AND m.remote_team_id='$remote'
              AND m.protocol_version=$protocol AND m.wire_id='$wire'
              AND m.direction='pull');" >> "$sql_file"
    fi
  done
  [ -n "$final_cursor" ] || { rm -f "$sql_file"; return 13; }
  printf "%s\n" "UPDATE sync_bindings SET transport_cursor='$final_cursor'
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    COMMIT;" >> "$sql_file"
  if ! agmsg_sqlite "$db" < "$sql_file" >/dev/null 2>&1; then
    rm -f "$sql_file"; trap - EXIT INT TERM HUP; return 13
  fi
  rm -f "$sql_file"
  trap - EXIT INT TERM HUP
  _AGMSG_SYNC_SQL_FILE=""
  corrupt=$(agmsg_sqlite "$db" "SELECT
    (SELECT COUNT(*) FROM sync_quarantine WHERE
    server_instance_id='$server' AND remote_team_id='$remote' AND protocol_version=$protocol
    AND status='corrupt_state') +
    (SELECT COUNT(*) FROM sync_conflicts WHERE server_instance_id='$server'
     AND remote_team_id='$remote' AND protocol_version=$protocol);" | tr -d '\r')
  _sqlite_data "SELECT json_object('type','sync_apply_result','transport_cursor',
    transport_cursor,'corrupt_count',$corrupt) FROM sync_bindings
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    SELECT json_object('type','sync_apply_outcome','id',wire_id,
                       'server_seq',server_seq,'status',status)
      FROM sync_quarantine WHERE server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND wire_id IN (${outcome_ids:-''})
    UNION ALL
    SELECT json_object('type','sync_apply_outcome','id',c.wire_id,
                       'server_seq',c.server_seq,'status','corrupt_state')
      FROM sync_conflicts c WHERE c.server_instance_id='$server'
       AND c.remote_team_id='$remote' AND c.protocol_version=$protocol
       AND c.wire_id IN (${outcome_ids:-''})
       AND NOT EXISTS(SELECT 1 FROM sync_quarantine qx
         WHERE qx.server_instance_id=c.server_instance_id
           AND qx.remote_team_id=c.remote_team_id
           AND qx.protocol_version=c.protocol_version AND qx.wire_id=c.wire_id);"
}

# Emits durable blocking envelopes for explicit decrypt/import reprocessing.
# This never changes the transport cursor; apply performs any resulting state
# transition atomically against that already-advanced cursor.
storage_sync_reprocess() {
  local team="$1" server="$2" remote="$3" protocol="$4" limit="$5"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  case "$limit" in ''|*[!0-9]*) return 13 ;; esac
  [ "$limit" -ge 1 ] && [ "$limit" -le 1000 ] || return 13
  _sqlite_sync_schema || return $?
  local generation tl
  generation=$(_sqlite_sync_generation) || return 13
  tl=$(_sqlite_lit "$team")
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || return 13
  _sqlite_data "SELECT json_object('type','sync_state','driver_generation',
      '$generation','transport_cursor',transport_cursor)
    FROM sync_bindings WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$generation';
    SELECT json_object('type','sync_reprocess_candidate','server_seq',server_seq,
      'id',wire_id,'server_received_at',server_received_at,
      'envelope',json_object('v',envelope_v,'cipher',cipher,'key_id',key_id,'blob',blob),
      'prior_status',status)
    FROM sync_quarantine WHERE local_team='$tl' AND server_instance_id='$server'
      AND remote_team_id='$remote' AND protocol_version=$protocol
      AND driver_generation='$generation'
      AND status IN ('unsupported_cipher','pending_key','authentication_failed',
                     'malformed','policy_violation')
    ORDER BY CAST(server_seq AS INTEGER),wire_id LIMIT $limit;"
}

# Derive the remote read frontier and exact wire exceptions from durable local
# outcomes. The authenticated member roster/floor is supplied by the engine.
storage_sync_prepare_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl context floor current members local_agents count values="" local_values=""
  local member id name agent insert_members="" insert_local_agents=""
  generation=$(_sqlite_sync_generation) || return 13
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"
  _sqlite_sync_ensure_binding "$team" "$server" "$remote" "$protocol" "$generation" || return 13
  context=$(cat)
  [ "$(printf '%s\n' "$context" | jq -r '
    select(.type=="sync_read_context" and (.min_available_seq|type)=="string" and
      (.current_seq|type)=="string" and (.members|type)=="array" and
      (.local_agents|type)=="array" and (.local_agents|length)<=1000 and
      ((.local_agents|unique|length)==(.local_agents|length)) and all(.local_agents[];
        (type=="string") and length>0) and
      (.members|length)<=1000 and all(.members[];
        ((.member_id|type)=="string") and ((.name|type)=="string") and (.name|length)>0)) | "ok"' \
      2>/dev/null)" = ok ] || return 13
  floor=$(printf '%s\n' "$context" | jq -r '.min_available_seq')
  current=$(printf '%s\n' "$context" | jq -r '.current_seq')
  case "$floor:$current" in *[!0-9:]*) return 13 ;; esac
  [ "$(_sqlite_sync_decimal_le "$floor" "$current")" = 1 ] &&
    [ "$(_sqlite_sync_decimal_le "$current" 9223372036854775807)" = 1 ] || return 13
  members=$(printf '%s\n' "$context" | jq -c '.members[]')
  count=0
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    id=$(printf '%s\n' "$member" | jq -r '.member_id')
    name=$(printf '%s\n' "$member" | jq -r '.name')
    printf '%s\n' "$id" | grep -Eq \
      '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 13
    values="${values}${values:+,}('$id','$(_sqlite_lit "$name")')"
    count=$((count + 1))
  done <<EOF
$members
EOF
  local_agents=$(printf '%s\n' "$context" | jq -r '.local_agents[]')
  while IFS= read -r agent; do
    [ -n "$agent" ] || continue
    local_values="${local_values}${local_values:+,}('$(_sqlite_lit "$agent")')"
  done <<EOF
$local_agents
EOF
  if [ "$count" -gt 0 ]; then
    insert_members="INSERT INTO incoming_read_members VALUES $values;"
  fi
  if [ -n "$local_values" ]; then
    insert_local_agents="INSERT INTO local_read_agents VALUES $local_values;"
  fi

  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE incoming_read_members(member_id TEXT UNIQUE,agent TEXT UNIQUE);
    CREATE TEMP TABLE local_read_agents(agent TEXT PRIMARY KEY);
    $insert_members
    $insert_local_agents
    UPDATE sync_read_members SET active=0 WHERE local_team='$tl'
      AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    INSERT INTO sync_read_members
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,member_id,agent,remote_agent,active,name_mismatch,
       remote_server_seq,min_available_seq)
    SELECT '$tl','$server','$remote',$protocol,'$generation',member_id,agent,agent,1,
           CASE WHEN EXISTS(SELECT 1 FROM local_read_agents l WHERE l.agent=incoming_read_members.agent)
                THEN 0 ELSE 1 END,
           '$floor','$floor' FROM incoming_read_members WHERE 1
    ON CONFLICT(local_team,server_instance_id,remote_team_id,protocol_version,
                driver_generation,member_id) DO UPDATE SET
      remote_agent=excluded.agent,active=1,
      name_mismatch=CASE WHEN sync_read_members.agent=excluded.agent
        AND EXISTS(SELECT 1 FROM local_read_agents l WHERE l.agent=excluded.agent)
        THEN 0 ELSE 1 END,
      remote_server_seq=CAST(MAX(CAST(sync_read_members.remote_server_seq AS INTEGER),$floor) AS TEXT),
      min_available_seq=CAST(MAX(CAST(sync_read_members.min_available_seq AS INTEGER),$floor) AS TEXT);
    INSERT OR IGNORE INTO sync_read_aliases
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,agent,local_id,wire_id,server_seq)
    SELECT m.local_team,m.server_instance_id,m.remote_team_id,m.protocol_version,
           m.driver_generation,e.to_agent,m.local_id,m.wire_id,m.server_seq
      FROM sync_messages m JOIN events e ON e.seq=m.local_position
     WHERE m.local_team='$tl' AND m.server_instance_id='$server'
       AND m.remote_team_id='$remote' AND m.protocol_version=$protocol
       AND m.driver_generation='$generation' AND m.server_seq IS NOT NULL
       AND EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team=e.team AND r.agent=e.to_agent AND r.msg_id=e.id);
    UPDATE sync_read_aliases AS x SET server_seq=(
      SELECT m.server_seq FROM sync_messages m
       WHERE m.local_team=x.local_team AND m.server_instance_id=x.server_instance_id
         AND m.remote_team_id=x.remote_team_id AND m.protocol_version=x.protocol_version
         AND m.driver_generation=x.driver_generation AND m.local_id=x.local_id
         AND m.wire_id=x.wire_id)
     WHERE x.local_team='$tl' AND x.server_instance_id='$server'
       AND x.remote_team_id='$remote' AND x.protocol_version=$protocol
       AND x.driver_generation='$generation' AND x.server_seq IS NULL;
    DELETE FROM sync_read_prepared WHERE local_team='$tl'
      AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation';
    INSERT INTO sync_read_prepared
      (local_team,server_instance_id,remote_team_id,protocol_version,
       driver_generation,member_id,server_seq)
    WITH ordered AS (
      SELECT rm.member_id,rm.agent,CAST(rm.remote_server_seq AS INTEGER) AS base,
             CAST(b.transport_cursor AS INTEGER) AS tip,
             CAST(q.server_seq AS INTEGER) AS seq,q.status,m.local_position,e.to_agent,
             ROW_NUMBER() OVER(PARTITION BY rm.member_id ORDER BY CAST(q.server_seq AS INTEGER)) AS rn
        FROM sync_read_members rm JOIN sync_bindings b
          ON b.local_team=rm.local_team AND b.server_instance_id=rm.server_instance_id
         AND b.remote_team_id=rm.remote_team_id AND b.protocol_version=rm.protocol_version
         AND b.driver_generation=rm.driver_generation
        LEFT JOIN sync_quarantine q ON q.local_team=rm.local_team
         AND q.server_instance_id=rm.server_instance_id AND q.remote_team_id=rm.remote_team_id
         AND q.protocol_version=rm.protocol_version AND q.driver_generation=rm.driver_generation
         AND CAST(q.server_seq AS INTEGER)>CAST(rm.remote_server_seq AS INTEGER)
         AND CAST(q.server_seq AS INTEGER)<=MIN(CAST(b.transport_cursor AS INTEGER),$current)
        LEFT JOIN sync_messages m ON m.server_instance_id=rm.server_instance_id
         AND m.remote_team_id=rm.remote_team_id AND m.protocol_version=rm.protocol_version
         AND m.wire_id=q.wire_id
        LEFT JOIN events e ON e.seq=m.local_position
       WHERE rm.local_team='$tl' AND rm.server_instance_id='$server'
         AND rm.remote_team_id='$remote' AND rm.protocol_version=$protocol
         AND rm.driver_generation='$generation' AND rm.active=1
         AND rm.name_mismatch=0
    ), bad AS (
      SELECT member_id,MIN(base+rn) AS seq FROM ordered
       WHERE seq IS NULL OR seq<>base+rn OR status NOT IN ('imported','reconciled')
          OR local_position IS NULL
          OR (to_agent=agent AND local_position>COALESCE((SELECT local_position
                FROM read_cursors c WHERE c.team='$tl' AND c.agent=ordered.agent),0)
              AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
                AND r.team='$tl' AND r.agent=ordered.agent
                AND r.msg_id=(SELECT id FROM events se WHERE se.seq=ordered.local_position)))
       GROUP BY member_id
    )
    SELECT '$tl','$server','$remote',$protocol,'$generation',rm.member_id,
      CAST(MAX(CAST(rm.remote_server_seq AS INTEGER),
      MIN(CAST(b.transport_cursor AS INTEGER),$current,COALESCE(bad.seq-1,$current))) AS TEXT)
      FROM sync_read_members rm JOIN sync_bindings b
        ON b.local_team=rm.local_team AND b.server_instance_id=rm.server_instance_id
       AND b.remote_team_id=rm.remote_team_id AND b.protocol_version=rm.protocol_version
       AND b.driver_generation=rm.driver_generation
      LEFT JOIN bad ON bad.member_id=rm.member_id
     WHERE rm.local_team='$tl' AND rm.server_instance_id='$server'
       AND rm.remote_team_id='$remote' AND rm.protocol_version=$protocol
       AND rm.driver_generation='$generation' AND rm.active=1
       AND rm.name_mismatch=0;
    COMMIT;" >/dev/null || return 13

  _sqlite_data "SELECT json_object('type','sync_read_frontier','member_id',f.member_id,
      'server_seq',f.server_seq) FROM sync_read_prepared f JOIN sync_read_members rm
      ON rm.local_team=f.local_team AND rm.server_instance_id=f.server_instance_id
     AND rm.remote_team_id=f.remote_team_id AND rm.protocol_version=f.protocol_version
     AND rm.driver_generation=f.driver_generation AND rm.member_id=f.member_id
     WHERE f.local_team='$tl' AND f.server_instance_id='$server' AND f.remote_team_id='$remote'
      AND f.protocol_version=$protocol AND f.driver_generation='$generation'
      AND rm.blocked_reason IS NULL ORDER BY f.member_id;
    SELECT json_object('type','sync_read_exact','member_id',rm.member_id,'wire_id',x.wire_id)
      FROM sync_read_aliases x JOIN sync_read_members rm
        ON rm.local_team=x.local_team AND rm.server_instance_id=x.server_instance_id
       AND rm.remote_team_id=x.remote_team_id AND rm.protocol_version=x.protocol_version
       AND rm.driver_generation=x.driver_generation AND rm.agent=x.agent AND rm.active=1
       AND rm.blocked_reason IS NULL
      JOIN sync_read_prepared f ON f.local_team=rm.local_team
       AND f.server_instance_id=rm.server_instance_id AND f.remote_team_id=rm.remote_team_id
       AND f.protocol_version=rm.protocol_version AND f.driver_generation=rm.driver_generation
       AND f.member_id=rm.member_id
     WHERE x.local_team='$tl' AND x.server_instance_id='$server'
       AND x.remote_team_id='$remote' AND x.protocol_version=$protocol
       AND x.driver_generation='$generation' AND x.server_seq IS NOT NULL
       AND CAST(x.server_seq AS INTEGER)>f.server_seq
     ORDER BY rm.member_id,x.wire_id;"
  _sqlite_data "SELECT json_object('type','sync_read_blocked','member_id',member_id,
      'reason',CASE WHEN name_mismatch=1 THEN 'member-name-mismatch' ELSE blocked_reason END)
      FROM sync_read_members WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND active=1
       AND (name_mismatch=1 OR blocked_reason IS NOT NULL) ORDER BY member_id;"
}

# Persist a server-declared exact-set limit for one member. Prepared local facts
# remain untouched and can be retried after operator remediation.
storage_sync_block_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl input member reason
  generation=$(_sqlite_sync_generation) || return 13
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"; input=$(cat)
  member=$(printf '%s\n' "$input" | jq -r 'select(.type=="sync_read_block")|.member_id // empty')
  reason=$(printf '%s\n' "$input" | jq -r 'select(.type=="sync_read_block")|.reason // empty')
  printf '%s\n' "$member" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 13
  [ "$reason" = read-state-limit-exceeded ] || return 13
  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE sync_read_block_assert(ok INTEGER CHECK(ok=1));
    UPDATE sync_read_members SET blocked_reason='$reason'
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND member_id='$member' AND active=1;
    INSERT INTO sync_read_block_assert VALUES(changes());
    COMMIT;" >/dev/null || return 13
  printf '{"type":"sync_read_blocked","member_id":"%s","reason":"%s"}\n' "$member" "$reason"
}

storage_sync_unblock_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl input member
  generation=$(_sqlite_sync_generation) || return 13
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"; input=$(cat)
  member=$(printf '%s\n' "$input" | jq -r 'select(.type=="sync_read_unblock")|.member_id // empty')
  printf '%s\n' "$member" | grep -Eq \
    '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' || return 13
  agmsg_sqlite "$db" "BEGIN IMMEDIATE;
    CREATE TEMP TABLE sync_read_unblock_assert(ok INTEGER CHECK(ok=1));
    INSERT INTO sync_read_unblock_assert SELECT COUNT(*) FROM sync_read_members
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND member_id='$member' AND active=1;
    UPDATE sync_read_members SET blocked_reason=NULL
     WHERE local_team='$tl' AND server_instance_id='$server'
       AND remote_team_id='$remote' AND protocol_version=$protocol
       AND driver_generation='$generation' AND member_id='$member' AND active=1
       AND blocked_reason='read-state-limit-exceeded';
    COMMIT;" >/dev/null || return 13
  printf '{"type":"sync_read_unblocked","member_id":"%s"}\n' "$member"
}

# Merge one authenticated server read-state page and project coverage only onto
# already imported/reconciled local messages. Transport/decrypt cursors are not
# touched by this operation.
storage_sync_apply_read_state() {
  local team="$1" server="$2" remote="$3" protocol="$4"
  _sqlite_sync_valid_binding "$server" "$remote" "$protocol" || return 13
  _sqlite_sync_schema || return $?
  local generation db tl sql_file line type floor="" current="" member seq wire
  generation=$(_sqlite_sync_generation) || return 13
  db="$(_sqlite_db)"; tl="$(_sqlite_lit "$team")"
  sql_file=$(mktemp "${TMPDIR:-/tmp}/agmsg-read-sync-sql.XXXXXX") || return 13
  _AGMSG_READ_SYNC_SQL_FILE="$sql_file"
  trap 'case "${_AGMSG_READ_SYNC_SQL_FILE:-}" in "${TMPDIR:-/tmp}"/agmsg-read-sync-sql.*) rm -f "$_AGMSG_READ_SYNC_SQL_FILE" ;; esac' EXIT INT TERM HUP
  printf '%s\n' 'BEGIN IMMEDIATE; CREATE TEMP TABLE sync_read_assert(ok INTEGER CHECK(ok=1));' > "$sql_file"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    type=$(printf '%s\n' "$line" | jq -r '.type // empty')
    case "$type" in
      sync_read_snapshot)
        [ -z "$floor" ] || { rm -f "$sql_file"; return 13; }
        floor=$(printf '%s\n' "$line" | jq -r '.min_available_seq // empty')
        current=$(printf '%s\n' "$line" | jq -r '.current_seq // empty')
        case "$floor:$current" in *[!0-9:]*) rm -f "$sql_file"; return 13 ;; esac
        [ "$(_sqlite_sync_decimal_le "$floor" "$current")" = 1 ] &&
          [ "$(_sqlite_sync_decimal_le "$current" 9223372036854775807)" = 1 ] || {
            rm -f "$sql_file"; return 13;
          }
        ;;
      sync_read_frontier)
        [ -n "$current" ] || { rm -f "$sql_file"; return 13; }
        member=$(printf '%s\n' "$line" | jq -r '.member_id // empty')
        seq=$(printf '%s\n' "$line" | jq -r '.server_seq // empty')
        case "$seq" in ''|*[!0-9]*) rm -f "$sql_file"; return 13 ;; esac
        printf '%s\n' "$member" | grep -Eq \
          '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
          || { rm -f "$sql_file"; return 13; }
        [ "$(_sqlite_sync_decimal_le "$seq" "$current")" = 1 ] || { rm -f "$sql_file"; return 13; }
        printf "%s\n" "INSERT INTO sync_read_assert SELECT CASE WHEN EXISTS(
          SELECT 1 FROM sync_read_members WHERE local_team='$tl'
            AND server_instance_id='$server' AND remote_team_id='$remote'
            AND protocol_version=$protocol AND driver_generation='$generation'
            AND member_id='$member' AND active=1) THEN 1 ELSE 0 END;
        UPDATE sync_read_members SET remote_server_seq=
          CAST(MAX(CAST(remote_server_seq AS INTEGER),$seq) AS TEXT)
          WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
            AND protocol_version=$protocol AND driver_generation='$generation'
            AND member_id='$member' AND active=1;" >> "$sql_file"
        ;;
      sync_read_exact)
        [ -n "$current" ] || { rm -f "$sql_file"; return 13; }
        member=$(printf '%s\n' "$line" | jq -r '.member_id // empty')
        wire=$(printf '%s\n' "$line" | jq -r '.wire_id // empty')
        printf '%s\n' "$member" | grep -Eq \
          '^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
          || { rm -f "$sql_file"; return 13; }
        printf '%s\n' "$wire" | grep -Eq \
          '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' \
          || { rm -f "$sql_file"; return 13; }
        printf "%s\n" "INSERT INTO sync_read_assert SELECT CASE WHEN EXISTS(
          SELECT 1 FROM sync_read_members WHERE local_team='$tl'
            AND server_instance_id='$server' AND remote_team_id='$remote'
            AND protocol_version=$protocol AND driver_generation='$generation'
            AND member_id='$member' AND active=1) THEN 1 ELSE 0 END;
        INSERT OR IGNORE INTO sync_read_remote_exact
          (local_team,server_instance_id,remote_team_id,protocol_version,
           driver_generation,member_id,wire_id)
          SELECT '$tl','$server','$remote',$protocol,'$generation','$member','$wire'
           WHERE EXISTS(SELECT 1 FROM sync_read_members rm WHERE rm.local_team='$tl'
             AND rm.server_instance_id='$server' AND rm.remote_team_id='$remote'
             AND rm.protocol_version=$protocol AND rm.driver_generation='$generation'
             AND rm.member_id='$member' AND rm.active=1);" >> "$sql_file"
        ;;
      *) rm -f "$sql_file"; return 13 ;;
    esac
  done
  [ -n "$floor" ] && [ -n "$current" ] || { rm -f "$sql_file"; return 13; }
  printf "%s\n" "
    UPDATE sync_read_members SET
      min_available_seq=CAST(MAX(CAST(min_available_seq AS INTEGER),$floor) AS TEXT),
      remote_server_seq=CAST(MAX(CAST(remote_server_seq AS INTEGER),$floor) AS TEXT)
     WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
       AND protocol_version=$protocol AND driver_generation='$generation' AND active=1;
    INSERT INTO events(type,id,team,agent,msg_id,at)
    SELECT 'message_read',lower(hex(randomblob(4)))||'-'||lower(hex(randomblob(2)))||
           '-7'||substr(lower(hex(randomblob(2))),2)||'-8'||substr(lower(hex(randomblob(2))),2)||
           '-'||lower(hex(randomblob(6))),e.team,rm.agent,e.id,
           strftime('%Y-%m-%dT%H:%M:%SZ','now')
      FROM sync_read_members rm JOIN sync_messages m
        ON m.local_team=rm.local_team AND m.server_instance_id=rm.server_instance_id
       AND m.remote_team_id=rm.remote_team_id AND m.protocol_version=rm.protocol_version
       AND m.driver_generation=rm.driver_generation AND m.server_seq IS NOT NULL
      JOIN events e ON e.seq=m.local_position
      LEFT JOIN sync_quarantine q ON q.server_instance_id=m.server_instance_id
       AND q.remote_team_id=m.remote_team_id AND q.protocol_version=m.protocol_version
       AND q.wire_id=m.wire_id
     WHERE rm.local_team='$tl' AND rm.server_instance_id='$server'
       AND rm.remote_team_id='$remote' AND rm.protocol_version=$protocol
       AND rm.driver_generation='$generation' AND rm.active=1 AND e.to_agent=rm.agent
       AND (m.direction='push' OR q.status IN ('imported','reconciled'))
       AND (CAST(m.server_seq AS INTEGER)<=CAST(rm.remote_server_seq AS INTEGER)
         OR EXISTS(SELECT 1 FROM sync_read_remote_exact x
           WHERE x.local_team=rm.local_team AND x.server_instance_id=rm.server_instance_id
             AND x.remote_team_id=rm.remote_team_id AND x.protocol_version=rm.protocol_version
             AND x.driver_generation=rm.driver_generation AND x.member_id=rm.member_id
             AND x.wire_id=m.wire_id))
       AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team=e.team AND r.agent=rm.agent AND r.msg_id=e.id);
    INSERT OR IGNORE INTO read_cursors(team,agent,local_position)
      SELECT '$tl',agent,0 FROM sync_read_members WHERE local_team='$tl'
       AND server_instance_id='$server' AND remote_team_id='$remote'
       AND protocol_version=$protocol AND driver_generation='$generation' AND active=1;
    UPDATE read_cursors SET local_position=MAX(local_position,COALESCE((
      SELECT MIN(e.seq)-1 FROM events e WHERE e.type='message_sent' AND e.team='$tl'
       AND e.to_agent=read_cursors.agent AND e.seq>read_cursors.local_position
       AND NOT EXISTS(SELECT 1 FROM events r WHERE r.type='message_read'
         AND r.team=e.team AND r.agent=read_cursors.agent AND r.msg_id=e.id)
    ),$(_sqlite_highwater))) WHERE team='$tl' AND agent IN (
      SELECT agent FROM sync_read_members WHERE local_team='$tl'
       AND server_instance_id='$server' AND remote_team_id='$remote'
       AND protocol_version=$protocol AND driver_generation='$generation' AND active=1);
    DELETE FROM sync_read_remote_exact AS x WHERE x.local_team='$tl'
      AND x.server_instance_id='$server' AND x.remote_team_id='$remote'
      AND x.protocol_version=$protocol AND x.driver_generation='$generation'
      AND EXISTS(SELECT 1 FROM sync_messages m JOIN sync_read_members rm
        ON rm.local_team=x.local_team AND rm.server_instance_id=x.server_instance_id
       AND rm.remote_team_id=x.remote_team_id AND rm.protocol_version=x.protocol_version
       AND rm.driver_generation=x.driver_generation AND rm.member_id=x.member_id
       WHERE m.server_instance_id=x.server_instance_id AND m.remote_team_id=x.remote_team_id
         AND m.protocol_version=x.protocol_version AND m.wire_id=x.wire_id
         AND m.server_seq IS NOT NULL
         AND CAST(m.server_seq AS INTEGER)<=CAST(rm.remote_server_seq AS INTEGER));
    DELETE FROM sync_read_aliases AS x WHERE x.local_team='$tl'
      AND x.server_instance_id='$server' AND x.remote_team_id='$remote'
      AND x.protocol_version=$protocol AND x.driver_generation='$generation'
      AND x.server_seq IS NOT NULL AND EXISTS(SELECT 1 FROM sync_read_members rm
        WHERE rm.local_team=x.local_team AND rm.server_instance_id=x.server_instance_id
          AND rm.remote_team_id=x.remote_team_id AND rm.protocol_version=x.protocol_version
          AND rm.driver_generation=x.driver_generation AND rm.agent=x.agent
          AND CAST(x.server_seq AS INTEGER)<=CAST(rm.remote_server_seq AS INTEGER));
    COMMIT;" >> "$sql_file"
  if ! agmsg_sqlite "$db" < "$sql_file" >/dev/null 2>&1; then
    rm -f "$sql_file"; trap - EXIT INT TERM HUP; return 13
  fi
  rm -f "$sql_file"; trap - EXIT INT TERM HUP; _AGMSG_READ_SYNC_SQL_FILE=""
  _sqlite_data "SELECT json_object('type','sync_read_apply_result','min_available_seq',
      MAX(min_available_seq),'member_count',COUNT(*)) FROM sync_read_members
    WHERE local_team='$tl' AND server_instance_id='$server' AND remote_team_id='$remote'
      AND protocol_version=$protocol AND driver_generation='$generation' AND active=1;"
}
