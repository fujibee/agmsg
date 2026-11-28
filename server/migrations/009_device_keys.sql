-- Accounts profile: a device's age recipient, and one key id per team's epoch.
-- Idempotent like every migration here; applied in every profile and used only
-- when AGMSG_PROFILE=accounts.

-- The public age recipient a device registers so a key handoff can be sealed to
-- it. Public by nature; the private half never leaves the device.
ALTER TABLE devices ADD COLUMN IF NOT EXISTS device_pubkey TEXT;
DO $$ BEGIN
  ALTER TABLE devices ADD CONSTRAINT devices_pubkey_shape
    CHECK (device_pubkey IS NULL OR device_pubkey ~ '^age1[0-9a-z]{58}$');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

-- A key id names one key within a team. Reusing it for a later epoch would let
-- two different private keys answer to one id.
CREATE UNIQUE INDEX IF NOT EXISTS team_key_epochs_one_key_id
  ON team_key_epochs (team_id, key_id);
