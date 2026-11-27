import type { Pool, PoolClient } from "pg";

// After an owner removes a device, the key the removed device could read is no
// longer secret from it. Until the key is rotated, writes sealed under that
// epoch are refused with a stated error (epoch-fenced) rather than accepted
// into a stream the removed device may still read. Rotation (publishing the next
// epoch) lifts the fence in the same transaction.

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
