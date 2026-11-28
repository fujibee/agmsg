-- Accounts profile: writes under a key epoch are paused after a device is
-- removed, until the key has been rotated. One row per (team, key id); lifted_at
-- is set when rotation publishes the next epoch. Idempotent like every migration.
CREATE TABLE IF NOT EXISTS team_epoch_fences (
  team_id UUID NOT NULL,
  key_id TEXT NOT NULL,
  fenced_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  lifted_at TIMESTAMPTZ,
  PRIMARY KEY (team_id, key_id)
);
