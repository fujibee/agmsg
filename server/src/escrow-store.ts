import type { Pool, PoolClient } from "pg";

/**
 * The key id the team's active epoch is filed under, or null when the team has
 * no escrowed epoch. The active epoch is the highest one stored. Takes the
 * caller's client so it reads inside the caller's transaction.
 */
export async function currentEpochKeyId(
  client: PoolClient,
  teamId: string,
): Promise<string | null> {
  const { rows } = await client.query<{ key_id: string }>(
    `SELECT key_id FROM team_key_epochs
      WHERE team_id = $1
      ORDER BY epoch DESC
      LIMIT 1`,
    [teamId],
  );
  return rows[0]?.key_id ?? null;
}

export type EpochRow = {
  epoch: bigint;
  keyId: string;
  recipient: string;
  snapshot: unknown;
  wrappedKey: Buffer;
};

/** Every retained epoch of a team, oldest first. */
export async function listEpochs(
  db: Pick<Pool, "query">,
  teamId: string,
): Promise<EpochRow[]> {
  const { rows } = await db.query<{
    epoch: string; key_id: string; recipient: string; snapshot: unknown; wrapped_key: Buffer;
  }>(
    `SELECT epoch::TEXT AS epoch, key_id, recipient, snapshot, wrapped_key
       FROM team_key_epochs WHERE team_id = $1 ORDER BY epoch`,
    [teamId],
  );
  return rows.map((row) => ({
    epoch: BigInt(row.epoch), keyId: row.key_id, recipient: row.recipient,
    snapshot: row.snapshot, wrappedKey: row.wrapped_key,
  }));
}
