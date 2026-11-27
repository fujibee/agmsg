-- One latest roster snapshot per team (design doc §4): a client that already
-- has the roster writes it after any roster change; a new machine reads it
-- instead of replaying the whole stream. The row is replaced wholesale, never
-- appended to -- there is no history here, only "the latest one".
--
-- `blob` is sealed by the client the same way a message is; the server
-- stores and returns it without reading it. `epoch` is exposed in the clear
-- alongside the seal so a new machine knows which key epoch to fetch before
-- it can open the blob at all.
CREATE TABLE IF NOT EXISTS roster_snapshots (
  team_id UUID PRIMARY KEY REFERENCES teams(team_id) ON DELETE RESTRICT,
  sequence BIGINT NOT NULL CHECK (sequence >= 0),
  epoch INTEGER NOT NULL CHECK (epoch >= 0),
  blob TEXT NOT NULL
);
