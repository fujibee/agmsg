import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { Pool } from "pg";
import { v7 as uuidv7 } from "uuid";

// The owner: one account, one sign-in (the secret from configuration), browser
// sessions held as sha256 of the cookie value.

const SESSION_HOURS = 12;
export const SESSION_COOKIE = "agmsg_owner";

export async function ensureOwnerAccount(pool: Pool): Promise<string> {
  const existing = await pool.query<{ account_id: string }>(
    `SELECT account_id FROM accounts ORDER BY created_at, account_id LIMIT 1`,
  );
  const row = existing.rows[0];
  if (row) return row.account_id;
  const accountId = uuidv7();
  await pool.query(`INSERT INTO accounts (account_id) VALUES ($1)`, [accountId]);
  // Two processes starting together may both insert; the oldest row wins, and
  // there is exactly one owner either way.
  const settled = await pool.query<{ account_id: string }>(
    `SELECT account_id FROM accounts ORDER BY created_at, account_id LIMIT 1`,
  );
  return settled.rows[0]?.account_id ?? accountId;
}

// Constant-time comparison of two secrets of any length: both are reduced to
// fixed-size digests first, so neither the length nor the first differing byte
// shows in the time taken.
export function secretsMatch(given: string, expected: string): boolean {
  const left = createHash("sha256").update(given, "utf8").digest();
  const right = createHash("sha256").update(expected, "utf8").digest();
  return timingSafeEqual(left, right);
}

function sessionHash(cookieValue: string): Buffer {
  return createHash("sha256").update(cookieValue, "utf8").digest();
}

export async function createSession(pool: Pool, accountId: string): Promise<string> {
  const value = randomBytes(32).toString("base64url");
  await pool.query(`DELETE FROM sessions WHERE expires_at < clock_timestamp()`);
  await pool.query(
    `INSERT INTO sessions (session_hash, account_id, expires_at)
     VALUES ($1, $2, clock_timestamp() + make_interval(hours => $3))`,
    [sessionHash(value), accountId, SESSION_HOURS],
  );
  return value;
}

export async function accountOfSession(
  pool: Pool,
  cookieValue: string | null,
): Promise<string | null> {
  if (!cookieValue || cookieValue.length > 128) return null;
  const { rows } = await pool.query<{ account_id: string }>(
    `SELECT account_id FROM sessions
      WHERE session_hash = $1 AND expires_at > clock_timestamp()`,
    [sessionHash(cookieValue)],
  );
  return rows[0]?.account_id ?? null;
}

export function readCookie(header: string | undefined, name: string): string | null {
  if (!header) return null;
  for (const part of header.split(";")) {
    const at = part.indexOf("=");
    if (at < 0) continue;
    if (part.slice(0, at).trim() === name) return part.slice(at + 1).trim();
  }
  return null;
}

export function sessionCookie(value: string, secure: boolean): string {
  return `${SESSION_COOKIE}=${value}; Path=/; HttpOnly; SameSite=Strict; ` +
    `Max-Age=${SESSION_HOURS * 3600}${secure ? "; Secure" : ""}`;
}
