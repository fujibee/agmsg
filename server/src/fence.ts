import type { Pool, PoolClient } from "pg";
import { ProtocolError } from "./errors.js";

// The epoch fence, part of the data plane in every profile. When a device that
// could read a team's key is removed, the key is no longer secret from it. Until
// the key is rotated, writes sealed under that epoch are refused with a stated
// error (epoch-fenced) rather than accepted into a stream the removed device may
// still read. Rotation (publishing the next epoch) lifts the fence in the same
// transaction. A team with no fence rows behaves exactly as it did before.

// Records the fence for a team's current epoch. A team with no epoch key (a
// plaintext team, or one with no escrow) has nothing to fence and records none.
export async function fenceEpoch(
  client: PoolClient,
  teamId: string,
  keyId: string | null,
): Promise<void> {
  if (keyId === null) return;
  await client.query(
    `INSERT INTO team_epoch_fences (team_id, key_id) VALUES ($1, $2)
     ON CONFLICT (team_id, key_id) DO NOTHING`,
    [teamId, keyId],
  );
}

// Called by rotation, inside the transaction that publishes the new epoch.
export async function liftEpochFence(
  client: PoolClient,
  teamId: string,
  keyId: string,
): Promise<void> {
  await client.query(
    `UPDATE team_epoch_fences SET lifted_at = clock_timestamp()
      WHERE team_id = $1 AND key_id = $2 AND lifted_at IS NULL`,
    [teamId, keyId],
  );
}

// The key ids among `keyIds` that are currently fenced for the team.
export async function fencedKeyIds(
  pool: Pool,
  teamId: string,
  keyIds: readonly string[],
): Promise<string[]> {
  if (keyIds.length === 0) return [];
  const { rows } = await pool.query<{ key_id: string }>(
    `SELECT key_id FROM team_epoch_fences
      WHERE team_id = $1 AND key_id = ANY($2::text[]) AND lifted_at IS NULL`,
    [teamId, [...keyIds]],
  );
  return rows.map((row) => row.key_id);
}

// Refuses a write that carries an envelope sealed under a fenced key id.
// Plaintext (no key id) is never fenced. One indexed lookup, skipped when no
// envelope names a key.
export async function assertNotFenced(
  pool: Pool,
  teamId: string,
  keyIds: ReadonlyArray<string | null>,
): Promise<void> {
  const named = [...new Set(keyIds.filter((id): id is string => id !== null))];
  const first = (await fencedKeyIds(pool, teamId, named))[0];
  if (first === undefined) return;
  throw new ProtocolError(
    409,
    "epoch-fenced",
    "writes under this key epoch are paused while the key is rotated after a device was removed; try again shortly",
    { team_id: teamId, key_id: first },
  );
}
