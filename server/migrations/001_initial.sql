CREATE TABLE IF NOT EXISTS server_metadata (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  server_instance_id UUID NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS teams (
  team_id UUID PRIMARY KEY,
  team_name TEXT NOT NULL,
  current_seq BIGINT NOT NULL DEFAULT 0 CHECK (current_seq >= 0),
  min_available_seq BIGINT NOT NULL DEFAULT 0,
  policy_revision BIGINT NOT NULL DEFAULT 0 CHECK (policy_revision >= 0),
  accepted_envelope_versions INTEGER[] NOT NULL DEFAULT ARRAY[1],
  write_allowed_ciphers TEXT[] NOT NULL DEFAULT ARRAY['none', 'age-v1']::TEXT[],
  max_blob_bytes INTEGER NOT NULL DEFAULT 1048576
    CHECK (max_blob_bytes BETWEEN 1 AND 1048576),
  members_revision BIGINT NOT NULL DEFAULT 0 CHECK (members_revision >= 0),
  CHECK (min_available_seq >= 0 AND min_available_seq <= current_seq)
);

ALTER TABLE teams ALTER COLUMN write_allowed_ciphers
  SET DEFAULT ARRAY['none', 'age-v1']::TEXT[];

-- What this team actually uses, as DECLARED by the machine that connected it.
-- `write_allowed_ciphers` above is a different thing: it is what the server
-- will ACCEPT. A team may be allowed both and use one, so the allowed set can
-- never answer "is this team encrypted" — which is exactly what a second
-- machine must know to tell a sealed history from an empty one.
--
-- NULLABLE ON PURPOSE, and with no default. NULL means "connected before the
-- declaration was carried, and nobody has said yet". Migration cannot fill it:
-- the server never stored the answer, and deriving one from messages.cipher at
-- migration time would be the same guess this column replaces — a team with no
-- messages would be declared unencrypted. A default of 'none' would turn every
-- such row into a confident, wrong statement no later reader could tell from a
-- real declaration.
--
-- It is settled instead when the team next stores a message, from that
-- message's own cipher (see postMessages). NOT by a repeat connect: that route
-- carries no credential and deliberately writes nothing about a team that
-- already exists.
ALTER TABLE teams ADD COLUMN IF NOT EXISTS cipher_profile TEXT
  CHECK (cipher_profile IN ('none', 'age-v1'));

-- Name lookup is an equality probe from an unauthenticated route, so it must
-- not be a sequential scan over every team.
CREATE INDEX IF NOT EXISTS teams_name_idx ON teams(team_name);

CREATE TABLE IF NOT EXISTS team_policy_history (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  policy_revision BIGINT NOT NULL CHECK (policy_revision >= 0),
  effective_from_seq BIGINT NOT NULL CHECK (effective_from_seq >= 1),
  accepted_envelope_versions INTEGER[] NOT NULL,
  write_allowed_ciphers TEXT[] NOT NULL,
  PRIMARY KEY (team_id, policy_revision)
);

CREATE INDEX IF NOT EXISTS team_policy_history_effective_idx
  ON team_policy_history(team_id, effective_from_seq, policy_revision DESC);

CREATE TABLE IF NOT EXISTS messages (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  id UUID NOT NULL,
  team_seq BIGINT NOT NULL CHECK (team_seq >= 1),
  server_received_at TIMESTAMPTZ(6) NOT NULL DEFAULT clock_timestamp(),
  envelope_v INTEGER NOT NULL,
  cipher TEXT NOT NULL,
  key_id TEXT,
  blob TEXT NOT NULL,
  envelope_digest BYTEA NOT NULL,
  PRIMARY KEY (team_id, id),
  UNIQUE (team_id, team_seq)
);

CREATE TABLE IF NOT EXISTS message_tombstones (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  id UUID NOT NULL,
  original_team_seq BIGINT NOT NULL CHECK (original_team_seq >= 1),
  envelope_digest BYTEA NOT NULL,
  PRIMARY KEY (team_id, id)
);

CREATE TABLE IF NOT EXISTS members (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  member_id UUID NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (team_id, member_id),
  UNIQUE (team_id, name)
);

CREATE TABLE IF NOT EXISTS member_identity_history (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  member_id UUID NOT NULL,
  name TEXT NOT NULL,
  PRIMARY KEY (team_id, name)
);

CREATE INDEX IF NOT EXISTS member_identity_history_member_idx
  ON member_identity_history(team_id, member_id);

CREATE TABLE IF NOT EXISTS registrations (
  team_id UUID NOT NULL,
  registration_id UUID NOT NULL,
  member_id UUID NOT NULL,
  installation_id UUID NOT NULL,
  type TEXT NOT NULL,
  PRIMARY KEY (team_id, registration_id),
  FOREIGN KEY (team_id, member_id)
    REFERENCES members(team_id, member_id) ON DELETE CASCADE
);

-- Stage-2 read state stays opaque: the server stores only immutable member and
-- wire identities plus monotonic sequence frontiers, never message recipients.
CREATE TABLE IF NOT EXISTS read_frontiers (
  team_id UUID NOT NULL,
  member_id UUID NOT NULL,
  server_seq BIGINT NOT NULL CHECK (server_seq >= 0),
  PRIMARY KEY (team_id, member_id),
  FOREIGN KEY (team_id, member_id)
    REFERENCES members(team_id, member_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS read_exact (
  team_id UUID NOT NULL,
  member_id UUID NOT NULL,
  wire_id UUID NOT NULL,
  PRIMARY KEY (team_id, member_id, wire_id),
  FOREIGN KEY (team_id, member_id)
    REFERENCES members(team_id, member_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS read_exact_team_wire_idx
  ON read_exact(team_id, wire_id);

CREATE TABLE IF NOT EXISTS registration_identity_history (
  team_id UUID NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  registration_id UUID NOT NULL,
  member_id UUID NOT NULL,
  PRIMARY KEY (team_id, registration_id)
);

-- Pairing codes are short-lived bootstrap capabilities. Long-lived bearer
-- secrets are stored only as domain-separated digests and are independently
-- revocable per connected device.

-- Column additions that read another table live here, after every table above
-- exists. This file runs top to bottom against a database that may be empty, so
-- a backfill placed beside the table it extends can reference a table that has
-- not been created yet -- which fails only on a first-ever start, never against
-- a database that has been up before.

-- When this team was registered, so a human choosing between two teams that
-- share a name has something to choose by. Added in three steps rather than one
-- because this file is re-executed on every start: the column arrives nullable,
-- rows without a value are filled once, and only then does it become NOT NULL.
--
-- The backfill takes the team's first message rather than the migration clock.
-- Stamping "now" would say a team registered in July was registered today,
-- which is a lie told by the exact field a human is about to trust. It is also
-- why the fill is restricted to NULL rows: retention can delete old messages,
-- so MIN() moves forward over time, and an unrestricted UPDATE would push a
-- team's registration date later on every restart.
ALTER TABLE teams ADD COLUMN IF NOT EXISTS registered_at TIMESTAMPTZ(6);

UPDATE teams t
   SET registered_at = COALESCE(
         (SELECT MIN(m.server_received_at) FROM messages m
           WHERE m.team_id = t.team_id),
         clock_timestamp())
 WHERE t.registered_at IS NULL;

ALTER TABLE teams ALTER COLUMN registered_at SET DEFAULT clock_timestamp();
ALTER TABLE teams ALTER COLUMN registered_at SET NOT NULL;

-- The pre-connect pairing path is gone: /v1/connect mints nothing and the data
-- plane takes its team from a header, so nothing issues a token or a credential
-- any more. Dropped here, in the tail section, because this file runs top to
-- bottom on every start -- the tables above are no longer created, and these
-- statements clear them from a database that has been up before.
--
-- pairing_tokens first: it carries the foreign key onto credentials.
DROP TABLE IF EXISTS pairing_tokens;
DROP TABLE IF EXISTS credentials;
