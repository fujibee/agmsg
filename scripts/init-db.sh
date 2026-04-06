#!/usr/bin/env bash
set -euo pipefail

DB_DIR="$(cd "$(dirname "$0")/../db" && pwd)"
DB="$DB_DIR/messages.db"

if [ ! -f "$DB" ]; then
  sqlite3 "$DB" <<'SQL'
PRAGMA journal_mode=WAL;

CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  team TEXT NOT NULL,
  from_agent TEXT NOT NULL,
  to_agent TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
  read_at TEXT
);

CREATE INDEX idx_unread ON messages(team, to_agent, read_at) WHERE read_at IS NULL;
CREATE INDEX idx_history ON messages(team, created_at DESC);
SQL
  echo "DB initialized: $DB"
fi
