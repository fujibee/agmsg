-- Accounts profile: one row per approved device. A device is one machine bound
-- to one team; its capability secret is the only credential it holds. Only the
-- sha256 of the secret is stored, so a database read never yields a usable URL.
-- Created in every profile (the migration runner is profile-blind) and used
-- only when AGMSG_PROFILE=accounts.
CREATE TABLE IF NOT EXISTS devices (
  device_id UUID PRIMARY KEY,
  team_id UUID NOT NULL,
  name TEXT NOT NULL CHECK (char_length(name) BETWEEN 1 AND 128),
  device_type TEXT NOT NULL CHECK (char_length(device_type) BETWEEN 1 AND 64),
  secret_prefix TEXT NOT NULL,
  secret_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(secret_hash) = 32),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  -- NULL until the device confirms it stored its URL; a provisional secret is
  -- refused like an unknown one.
  activated_at TIMESTAMPTZ,
  revoked_at TIMESTAMPTZ,
  last_fetch_at TIMESTAMPTZ
);

-- One live device per (team, name); a revoked row frees the name.
CREATE UNIQUE INDEX IF NOT EXISTS devices_one_live_name
  ON devices (team_id, name) WHERE revoked_at IS NULL;
