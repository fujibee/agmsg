-- Accounts profile: the environment markers a machine reported when it asked for
-- a device code (ids of matched markers only, never values). Kept on the grant and
-- copied to the device it becomes; the server does not interpret them. Idempotent.
ALTER TABLE device_grants ADD COLUMN IF NOT EXISTS env_markers TEXT[] NOT NULL DEFAULT '{}';
ALTER TABLE devices ADD COLUMN IF NOT EXISTS env_markers TEXT[] NOT NULL DEFAULT '{}';
