-- Accounts profile, device flow. Idempotent like every migration here; created
-- in every profile and used only when AGMSG_PROFILE=accounts.

-- The single owner of the server. There is exactly one sign-in (the owner
-- secret from configuration), so one row; default_team preselects the team on
-- the approval page.
CREATE TABLE IF NOT EXISTS accounts (
  account_id UUID PRIMARY KEY,
  default_team UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Owner browser sessions. Only the sha256 of the cookie value is stored.
CREATE TABLE IF NOT EXISTS sessions (
  session_hash BYTEA PRIMARY KEY CHECK (octet_length(session_hash) = 32),
  account_id UUID NOT NULL REFERENCES accounts (account_id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  expires_at TIMESTAMPTZ NOT NULL
);

-- One device authorization request. The device code (polled by the machine) and
-- the user code (typed by the owner) are stored as digests only, so a database
-- read never yields an approvable code. The target (machine name, team) is
-- fixed when the grant is issued or approved and never taken from a later call.
CREATE TABLE IF NOT EXISTS device_grants (
  grant_id UUID PRIMARY KEY,
  device_code_hash BYTEA NOT NULL UNIQUE CHECK (octet_length(device_code_hash) = 32),
  user_code_digest BYTEA NOT NULL UNIQUE CHECK (octet_length(user_code_digest) = 32),
  client_id TEXT NOT NULL,
  machine_name TEXT NOT NULL,
  device_type TEXT NOT NULL DEFAULT 'unknown',
  team_id UUID,
  state TEXT NOT NULL DEFAULT 'pending'
    CHECK (state IN ('pending', 'approved', 'denied', 'consumed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  expires_at TIMESTAMPTZ NOT NULL,
  last_poll_at TIMESTAMPTZ,
  device_id UUID REFERENCES devices (device_id),
  CHECK (state <> 'approved' OR team_id IS NOT NULL)
);

-- A device is provisional until it confirms it stored its URL; one that never
-- does is dead after this deadline and stops holding its name.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS activate_deadline TIMESTAMPTZ;
