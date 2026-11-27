-- Used only by the accounts profile. Like the other migrations it is applied in
-- every profile (the runner is profile-blind); the tables stay empty and unused
-- unless escrow is switched on.
--
-- Escrowed team-key epochs and the audit of every unwrap.
--
-- WRAPPING IS A KIND, NOT A COLUMN LAYOUT. `wrap_kind` says which backend sealed
-- the row; today the only kind is 'keyfile'. A later kind adds a value to the
-- check below and, if it needs other fields, its own nullable columns.
CREATE TABLE IF NOT EXISTS team_key_epochs (
  team_id      UUID   NOT NULL REFERENCES teams(team_id) ON DELETE RESTRICT,
  epoch        BIGINT NOT NULL CHECK (epoch >= 1),
  wrap_kind    TEXT   NOT NULL,
  -- Public identifier of the master key that wrapped this row, recorded per row
  -- so replacing the master key later does not orphan an old row.
  key_ref      TEXT   NOT NULL,
  wrapped_key  BYTEA  NOT NULL,
  -- The age recipient (public) of this epoch's team identity.
  recipient    TEXT   NOT NULL,
  -- The id the identity is filed under, and the public snapshot that was
  -- current when this epoch began. A handoff bundle for epoch N is the
  -- snapshots and identities of epochs 1..N, in order.
  key_id       TEXT   NOT NULL,
  snapshot     JSONB  NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (team_id, epoch),
  CONSTRAINT team_key_epochs_known_kind CHECK (wrap_kind IN ('keyfile')),
  CONSTRAINT team_key_epochs_key_ref CHECK (key_ref <> ''),
  CONSTRAINT team_key_epochs_wrapped_size
    CHECK (octet_length(wrapped_key) BETWEEN 1 AND 8192),
  CONSTRAINT team_key_epochs_key_id_shape
    CHECK (key_id ~ '^[a-z0-9][a-z0-9._-]{0,63}$'),
  -- Epoch N is the snapshot's epoch_revision N-1.
  CONSTRAINT team_key_epochs_snapshot_revision
    CHECK (snapshot ->> 'epoch_revision' = (epoch - 1)::TEXT)
);

-- One row per unwrap, whatever the outcome. No foreign keys, on purpose: an
-- audit row must neither block nor vanish with the epoch, device or account it
-- names.
CREATE TABLE IF NOT EXISTS key_releases (
  id          UUID PRIMARY KEY,
  team_id     UUID   NOT NULL,
  epoch       BIGINT NOT NULL CHECK (epoch >= 1),
  principal   UUID   NOT NULL,
  device_id   UUID,
  purpose     TEXT   NOT NULL,
  grant_id    UUID,
  -- released: sealed and handed on. denied: authorisation failed before the
  -- backend was called. failed: the backend or sealing failed after the request
  -- was authorised.
  outcome     TEXT   NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  CONSTRAINT key_releases_purpose CHECK (purpose IN ('enroll', 'rotate', 'recover')),
  CONSTRAINT key_releases_outcome CHECK (outcome IN ('released', 'denied', 'failed'))
);

CREATE INDEX IF NOT EXISTS key_releases_team_idx ON key_releases (team_id, created_at);
CREATE INDEX IF NOT EXISTS key_releases_principal_idx ON key_releases (principal, created_at);
