#!/usr/bin/env bash
# delivery daemon 向け unread message claim API。

if ! type agmsg_db_path >/dev/null 2>&1; then
  _agmsg_claims_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_agmsg_claims_dir/storage.sh"
fi

_agmsg_claim_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

_agmsg_claim_init() {
  local scripts_dir
  scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  bash "$scripts_dir/internal/init-db.sh" >/dev/null
}

# stdout: id US from US body US created_at。空 output は claim 対象なし。
agmsg_claim_next() {
  local team="$1" agent="$2" owner="$3" ttl="${4:-30}" db
  db="$(agmsg_db_path)"; _agmsg_claim_init
  agmsg_sqlite "$db" <<SQL
BEGIN IMMEDIATE;
DELETE FROM claims WHERE expires_at <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
INSERT OR IGNORE INTO claims(message_id, owner, expires_at)
SELECT id, $(_agmsg_claim_quote "$owner"), strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '+${ttl} seconds')
FROM messages WHERE team=$(_agmsg_claim_quote "$team") AND to_agent=$(_agmsg_claim_quote "$agent") AND read_at IS NULL
AND NOT EXISTS (SELECT 1 FROM claims WHERE claims.message_id=messages.id)
ORDER BY created_at, id LIMIT 1;
SELECT m.id || char(31) || m.from_agent || char(31) || replace(replace(m.body, char(10), '\\n'), char(9), '\\t') || char(31) || m.created_at
FROM messages m JOIN claims c ON c.message_id=m.id WHERE c.owner=$(_agmsg_claim_quote "$owner") AND m.read_at IS NULL
ORDER BY m.id LIMIT 1;
COMMIT;
SQL
}

agmsg_release_claim() {
  local id="$1" owner="$2" db
  db="$(agmsg_db_path)"; _agmsg_claim_init
  agmsg_sqlite "$db" "DELETE FROM claims WHERE message_id=$(printf '%d' "$id") AND owner=$(_agmsg_claim_quote "$owner");"
}

agmsg_ack_claim() {
  local id="$1" owner="$2" db
  db="$(agmsg_db_path)"; _agmsg_claim_init
  agmsg_sqlite "$db" <<SQL
BEGIN IMMEDIATE;
UPDATE messages SET read_at=strftime('%Y-%m-%dT%H:%M:%SZ', 'now') WHERE id=$(printf '%d' "$id")
AND EXISTS (SELECT 1 FROM claims WHERE message_id=$(printf '%d' "$id") AND owner=$(_agmsg_claim_quote "$owner"));
DELETE FROM claims WHERE message_id=$(printf '%d' "$id") AND owner=$(_agmsg_claim_quote "$owner");
COMMIT;
SQL
}
