PRAGMA journal_mode=WAL;
CREATE TABLE events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL,
  id TEXT NOT NULL,
  team TEXT,
  from_agent TEXT,
  to_agent TEXT,
  body TEXT,
  msg_id TEXT,
  agent TEXT,
  at TEXT NOT NULL,
  legacy_id INTEGER
);
CREATE INDEX events_sent ON events(type, team, to_agent, seq);
CREATE INDEX events_read ON events(type, team, agent, msg_id);
CREATE INDEX events_legacy ON events(legacy_id);
CREATE INDEX events_id ON events(id);
CREATE TABLE read_cursors (
  team TEXT NOT NULL,
  agent TEXT NOT NULL,
  local_position INTEGER NOT NULL DEFAULT 0 CHECK(local_position >= 0),
  PRIMARY KEY(team, agent)
);
CREATE TABLE storage_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  team TEXT NOT NULL,
  from_agent TEXT NOT NULL,
  to_agent TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
  read_at TEXT
);
INSERT INTO messages(id,team,from_agent,to_agent,body,created_at,read_at)
VALUES(41,'agsuite','alice','bob','rev1-body','2026-01-01T00:00:00Z','2026-01-01T00:01:00Z');
INSERT INTO events(type,id,team,from_agent,to_agent,body,at,legacy_id)
VALUES('message_sent','rev1-message','agsuite','alice','bob','rev1-body','2026-01-01T00:00:00Z',41);
INSERT INTO events(type,id,team,agent,msg_id,at)
VALUES('message_read','rev1-read','agsuite','bob','rev1-message','2026-01-01T00:01:00Z');
INSERT INTO read_cursors(team,agent,local_position) VALUES('agsuite','bob',2);
INSERT INTO storage_metadata(key,value) VALUES('read_cursor_v1','1');
PRAGMA user_version=1;
