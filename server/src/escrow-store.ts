import type { PoolClient } from "pg";

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
