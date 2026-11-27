import type { Pool, PoolClient } from "pg";
import { inTransaction } from "../db.js";
import { currentEpochKeyId, fenceEpoch } from "./fence.js";

// Step 1 of removing a device, always succeeding once the device exists: mark
// it revoked, so its capability secret stops at once, and fence its team's
// current key epoch, so nothing more is written under a key the removed device
// can still read. Step 2 (a new epoch, wrapped and published) belongs to key
// rotation and lifts the fence in the transaction that publishes it. A failure
// in step 2 never undoes this step.

export type RemovalResult = { ok: true; teamId: string } | { ok: false };

export async function removeDevice(
  pool: Pool,
  deviceId: string,
  keyIdOf: (client: PoolClient, teamId: string) => Promise<string | null> = currentEpochKeyId,
): Promise<RemovalResult> {
  return inTransaction(pool, async (client) => {
    // Lock the row first: two removals of one device, or a removal racing an
    // activation, see each other's committed state.
    const { rows } = await client.query<{ team_id: string }>(
      `SELECT team_id FROM devices WHERE device_id = $1 AND revoked_at IS NULL FOR UPDATE`,
      [deviceId],
    );
    const device = rows[0];
    if (!device) return { ok: false as const };
    await client.query(
      `UPDATE devices SET revoked_at = clock_timestamp() WHERE device_id = $1`,
      [deviceId],
    );
    await fenceEpoch(client, device.team_id, await keyIdOf(client, device.team_id));
    return { ok: true as const, teamId: device.team_id };
  });
}
