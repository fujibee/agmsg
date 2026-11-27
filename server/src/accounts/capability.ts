import { createHash, randomBytes } from "node:crypto";
import type { Pool } from "pg";
import { v7 as uuidv7 } from "uuid";

// A device's credential rides in the URL path: <origin>/t/<secret>/v1/...
// The format is part of the protocol: agsy_<8 hex prefix>_<43 base64url>. The prefix is
// for display only; lookup is one hit on the unique index over
// sha256(full secret), so the database never holds a usable secret.
export const SECRET_PATTERN = /^agsy_[a-f0-9]{8}_[A-Za-z0-9_-]{43}$/u;

export type MintedSecret = { plaintext: string; prefix: string; hash: Buffer };

export function hashSecret(plaintext: string): Buffer {
  return createHash("sha256").update(plaintext, "utf8").digest();
}

export function mintSecret(): MintedSecret {
  const prefix = `agsy_${randomBytes(4).toString("hex")}`;
  const plaintext = `${prefix}_${randomBytes(32).toString("base64url")}`;
  return { plaintext, prefix, hash: hashSecret(plaintext) };
}

export type LiveDevice = { deviceId: string; teamId: string };

// The one live device a secret names, or null. "Live" is activated and not
// revoked. An unknown, malformed, provisional or revoked secret all give the
// same null, so a caller cannot tell them apart.
export async function resolveSecret(
  pool: Pool,
  plaintext: string,
): Promise<LiveDevice | null> {
  if (!SECRET_PATTERN.test(plaintext)) return null;
  const { rows } = await pool.query<{ device_id: string; team_id: string }>(
    `SELECT device_id, team_id FROM devices
      WHERE secret_hash = $1 AND activated_at IS NOT NULL AND revoked_at IS NULL`,
    [hashSecret(plaintext)],
  );
  const row = rows[0];
  return row ? { deviceId: row.device_id, teamId: row.team_id } : null;
}

// Inserts a device with a fresh secret. The caller (the approval flow) decides
// whether it starts provisional.
export async function insertDevice(
  pool: Pool,
  input: { teamId: string; name: string; deviceType: string; active: boolean },
): Promise<{ deviceId: string; secret: string }> {
  const minted = mintSecret();
  const deviceId = uuidv7();
  await pool.query(
    `INSERT INTO devices (device_id, team_id, name, device_type, secret_prefix,
                          secret_hash, activated_at)
     VALUES ($1, $2, $3, $4, $5, $6, CASE WHEN $7 THEN clock_timestamp() END)`,
    [deviceId, input.teamId, input.name, input.deviceType, minted.prefix,
      minted.hash, input.active],
  );
  return { deviceId, secret: minted.plaintext };
}
