import type { Pool, PoolClient } from "pg";
import { v7 as uuidv7 } from "uuid";
import { inTransaction } from "../db.js";
import { SECRET_PATTERN, hashSecret, mintSecret } from "./capability.js";
import { deviceCodeHashOf, generateCodes, type CodeMaterial } from "./codes.js";

// Device authorization (RFC 8628 shaped). A machine asks for a code, the owner
// approves it in a browser, and the machine collects a capability URL. The
// secret in that URL is provisional until the machine confirms it stored it
// (activate), so a lost response never leaves a live credential nobody holds.
//
// Every transition is a row-locked compare-and-set, and the target (machine name,
// team) is fixed at issuance or approval: no later call substitutes it.

const GRANT_TTL_SECONDS = 900;
const POLL_INTERVAL_SECONDS = 5;
const ACTIVATE_WINDOW_MINUTES = 10;
// Resource bound: stop issuing new grants past this many outstanding ones.
// In-flight approvals and polls are never affected.
const MAX_OUTSTANDING_GRANTS = 5000;

export class AdmissionError extends Error {}

export type Issued = {
  material: CodeMaterial;
  expiresIn: number;
  interval: number;
};

export async function issueGrant(
  pool: Pool,
  input: { clientId: string; machineName: string; deviceType: string; teamId: string | null },
): Promise<Issued> {
  return inTransaction(pool, async (client) => {
    // Old finished grants carry nothing; drop them here rather than run a worker.
    await client.query(
      `DELETE FROM device_grants WHERE expires_at < clock_timestamp() - interval '1 day'`,
    );
    const outstanding = await client.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM device_grants
        WHERE state IN ('pending', 'approved') AND expires_at > clock_timestamp()`,
    );
    if (BigInt(outstanding.rows[0]?.n ?? "0") >= BigInt(MAX_OUTSTANDING_GRANTS)) {
      throw new AdmissionError("too many outstanding grants");
    }
    const material = generateCodes();
    await client.query(
      `INSERT INTO device_grants
         (grant_id, device_code_hash, user_code_digest, client_id, machine_name,
          device_type, team_id, expires_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7,
               clock_timestamp() + make_interval(secs => $8))`,
      [uuidv7(), material.deviceCodeHash, material.userCodeDigest, input.clientId,
        input.machineName, input.deviceType, input.teamId, GRANT_TTL_SECONDS],
    );
    return { material, expiresIn: GRANT_TTL_SECONDS, interval: POLL_INTERVAL_SECONDS };
  });
}

export type GrantView = {
  clientId: string;
  machineName: string;
  teamId: string | null;
};

// What the owner is shown before deciding: a pending, unexpired grant.
export async function findPendingGrant(
  pool: Pool,
  userCodeDigest: Buffer,
): Promise<GrantView | null> {
  const { rows } = await pool.query<{
    client_id: string; machine_name: string; team_id: string | null;
  }>(
    `SELECT client_id, machine_name, team_id FROM device_grants
      WHERE user_code_digest = $1 AND state = 'pending'
        AND expires_at > clock_timestamp()`,
    [userCodeDigest],
  );
  const row = rows[0];
  return row ? { clientId: row.client_id, machineName: row.machine_name, teamId: row.team_id } : null;
}

export async function listTeams(
  pool: Pool,
): Promise<Array<{ teamId: string; teamName: string }>> {
  const { rows } = await pool.query<{ team_id: string; team_name: string }>(
    `SELECT team_id, team_name FROM teams ORDER BY team_name, team_id LIMIT 200`,
  );
  return rows.map((row) => ({ teamId: row.team_id, teamName: row.team_name }));
}

// The advisory lock a mint takes while a device limit is set (an arbitrary,
// fixed key, distinct from the team limit's lock in storage.ts).
const DEVICES_LIMIT_LOCK = 4120300148;

export type DecideResult =
  | { ok: true }
  | { ok: false; reason: "not_found" | "already_decided" | "team_required" | "team_mismatch" | "unknown_team" };

export async function decideGrant(
  pool: Pool,
  input: {
    userCodeDigest: Buffer;
    decision: "approve" | "deny";
    teamId: string | null;
  },
): Promise<DecideResult> {
  return inTransaction(pool, async (client) => {
    const { rows } = await client.query<{
      grant_id: string; state: string; team_id: string | null; expired: boolean;
    }>(
      `SELECT grant_id, state, team_id, expires_at <= clock_timestamp() AS expired
         FROM device_grants WHERE user_code_digest = $1 FOR UPDATE`,
      [input.userCodeDigest],
    );
    const grant = rows[0];
    if (!grant || grant.expired) return { ok: false as const, reason: "not_found" as const };
    if (grant.state !== "pending") return { ok: false as const, reason: "already_decided" as const };
    if (input.decision === "deny") {
      await client.query(`UPDATE device_grants SET state = 'denied' WHERE grant_id = $1`, [grant.grant_id]);
      return { ok: true as const };
    }
    // The team a grant was issued for cannot be swapped at approval; a grant
    // issued without one takes the owner's choice, which must be a real team.
    let teamId = grant.team_id;
    if (teamId !== null) {
      if (input.teamId !== null && input.teamId !== teamId) {
        return { ok: false as const, reason: "team_mismatch" as const };
      }
    } else {
      if (input.teamId === null) return { ok: false as const, reason: "team_required" as const };
      const known = await client.query(`SELECT 1 FROM teams WHERE team_id = $1`, [input.teamId]);
      if (known.rowCount === 0) return { ok: false as const, reason: "unknown_team" as const };
      teamId = input.teamId;
    }
    await client.query(
      `UPDATE device_grants SET state = 'approved', team_id = $2 WHERE grant_id = $1`,
      [grant.grant_id, teamId],
    );
    return { ok: true as const };
  });
}

export type PollResult =
  | { status: "authorization_pending" | "access_denied" | "expired_token" | "machine_exists" }
  // The server's device limit is reached. The grant stays approved, so the same
  // machine succeeds on a later poll once a device is removed or the limit raised.
  | { status: "limit_reached"; value: bigint }
  // The same answer as expired_token on the wire; `unknown` lets the caller
  // count device codes that matched no grant at all.
  | { status: "expired_token"; unknown: true }
  | { status: "slow_down"; interval: number }
  | { status: "ready"; secret: string; machineName: string; teamId: string; accountId: string };

export async function pollToken(
  pool: Pool,
  input: { deviceCode: string; clientId: string; accountId: string },
  deviceLimit: bigint | null = null,
): Promise<PollResult> {
  return inTransaction(pool, async (client) => {
    const { rows } = await client.query<{
      grant_id: string; state: string; machine_name: string; device_type: string; team_id: string | null;
      expired: boolean; too_soon: boolean;
    }>(
      `SELECT grant_id, state, machine_name, device_type, team_id,
              expires_at <= clock_timestamp() AS expired,
              coalesce(last_poll_at > clock_timestamp() - make_interval(secs => $3), false) AS too_soon
         FROM device_grants
        WHERE device_code_hash = $1 AND client_id = $2 FOR UPDATE`,
      [deviceCodeHashOf(input.deviceCode), input.clientId, POLL_INTERVAL_SECONDS],
    );
    const grant = rows[0];
    if (!grant) return { status: "expired_token" as const, unknown: true as const };
    if (grant.expired || grant.state === "consumed") {
      return { status: "expired_token" as const };
    }
    if (grant.state === "denied") return { status: "access_denied" as const };
    if (grant.state === "pending") {
      await client.query(`UPDATE device_grants SET last_poll_at = clock_timestamp() WHERE grant_id = $1`, [grant.grant_id]);
      return grant.too_soon
        ? { status: "slow_down" as const, interval: POLL_INTERVAL_SECONDS * 2 }
        : { status: "authorization_pending" as const };
    }
    // approved: mint exactly once.
    if (grant.team_id === null) return { status: "expired_token" as const };
    const minted = await mintDevice(client, {
      grantId: grant.grant_id, teamId: grant.team_id, machineName: grant.machine_name,
      deviceType: grant.device_type,
    }, deviceLimit);
    if (minted === "limit") {
      return { status: "limit_reached" as const, value: deviceLimit ?? 0n };
    }
    if (!minted) return { status: "machine_exists" as const };
    return {
      status: "ready" as const,
      secret: minted.secret,
      machineName: grant.machine_name,
      teamId: grant.team_id,
      accountId: input.accountId,
    };
  });
}

// Inserts the device (provisional) and consumes the grant, inside the poll
// transaction under the grant's row lock. A machine name already held by a live
// device in the team is refused terminally: the machine starts a fresh login
// under another name instead of retrying this grant.
async function mintDevice(
  client: PoolClient,
  grant: { grantId: string; teamId: string; machineName: string; deviceType: string },
  deviceLimit: bigint | null,
): Promise<{ secret: string } | "limit" | null> {
  // A provisional device that never activated is dead past its deadline and
  // must not keep holding the name.
  await client.query(
    `UPDATE devices SET revoked_at = clock_timestamp()
      WHERE team_id = $1 AND name = $2 AND revoked_at IS NULL
        AND activated_at IS NULL AND activate_deadline <= clock_timestamp()`,
    [grant.teamId, grant.machineName],
  );
  // The device limit counts the devices that hold a slot now: not revoked, and
  // not a provisional one past its deadline. The count and the insert are
  // serialized on one lock the commit releases, so two machines polling at the
  // same moment cannot both take the last slot. Without a limit nothing is added.
  if (deviceLimit !== null) {
    await client.query("SELECT pg_advisory_xact_lock($1)", [DEVICES_LIMIT_LOCK]);
    const counted = await client.query<{ n: string }>(
      `SELECT count(*)::text AS n FROM devices
        WHERE revoked_at IS NULL
          AND NOT (activated_at IS NULL AND activate_deadline <= clock_timestamp())`,
    );
    if (BigInt(counted.rows[0]?.n ?? "0") >= deviceLimit) return "limit";
  }
  const minted = mintSecret();
  const deviceId = uuidv7();
  await client.query("SAVEPOINT mint");
  try {
    await client.query(
      `INSERT INTO devices (device_id, team_id, name, device_type, secret_prefix,
                            secret_hash, activate_deadline)
       VALUES ($1, $2, $3, $4, $5, $6,
               clock_timestamp() + make_interval(mins => $7))`,
      [deviceId, grant.teamId, grant.machineName, grant.deviceType, minted.prefix,
        minted.hash, ACTIVATE_WINDOW_MINUTES],
    );
  } catch (error) {
    if (typeof error === "object" && error !== null && "code" in error && error.code === "23505") {
      await client.query("ROLLBACK TO SAVEPOINT mint");
      await client.query(`UPDATE device_grants SET state = 'consumed' WHERE grant_id = $1`, [grant.grantId]);
      return null;
    }
    throw error;
  }
  await client.query(
    `UPDATE device_grants SET state = 'consumed', device_id = $2 WHERE grant_id = $1`,
    [grant.grantId, deviceId],
  );
  return { secret: minted.plaintext };
}

export type ActivateResult =
  | { ok: true; machineName: string }
  | { ok: false; reason: "not_found" | "expired" | "revoked" };

export async function activateSecret(pool: Pool, secret: string): Promise<ActivateResult> {
  if (!SECRET_PATTERN.test(secret)) return { ok: false, reason: "not_found" };
  return inTransaction(pool, async (client) => {
    const { rows } = await client.query<{
      device_id: string; name: string; activated: boolean; revoked: boolean; past_deadline: boolean;
    }>(
      `SELECT device_id, name, activated_at IS NOT NULL AS activated,
              revoked_at IS NOT NULL AS revoked,
              coalesce(activate_deadline <= clock_timestamp(), false) AS past_deadline
         FROM devices WHERE secret_hash = $1 FOR UPDATE`,
      [hashSecret(secret)],
    );
    const device = rows[0];
    if (!device) return { ok: false as const, reason: "not_found" as const };
    if (device.revoked) return { ok: false as const, reason: "revoked" as const };
    // Activation is idempotent: a machine that retries after a lost reply must
    // get the same answer.
    if (!device.activated) {
      if (device.past_deadline) return { ok: false as const, reason: "expired" as const };
      await client.query(`UPDATE devices SET activated_at = clock_timestamp() WHERE device_id = $1`, [device.device_id]);
    }
    return { ok: true as const, machineName: device.name };
  });
}
