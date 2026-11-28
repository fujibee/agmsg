import type { FastifyInstance, FastifyRequest } from "fastify";
import type { Pool, PoolClient } from "pg";
import { v7 as uuidv7 } from "uuid";
import { z } from "zod";
import { AGE_IDENTITY, AGE_RECIPIENT, recipientOfIdentity, sealToRecipient } from "../age.js";
import { canonicalJson, snapshotDigest } from "../canonical.js";
import { inTransaction } from "../db.js";
import { listEpochs } from "../escrow-store.js";
import type { EscrowBackend } from "../escrow.js";
import { ProtocolError } from "../errors.js";
import { liftFencesBefore } from "../fence.js";
import { resolveSecret } from "./capability.js";

// A device's escrowed team key, over the capability URL:
//   POST <capability>/v1/keys/epochs   register the epoch a device generated
//   GET  <capability>/v1/keys/bundle   every retained epoch, sealed to the caller
// Both need a registered device recipient (POST /v1/devices). A key is only
// ever released sealed to a recipient the caller registered; the server never
// returns a private identity in the clear.

const KEY_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/u;
const MAX_EPOCH = 2_147_483_647;

// Strict on purpose: an unknown field is a 400, never dropped.
const epochBody = z.object({
  epoch: z.number().int(),
  key_id: z.string(),
  identity: z.string(),
  recipient: z.string(),
  snapshot: z.record(z.string(), z.unknown()),
}).strict();

function refuse(status: number, code: string, message: string): ProtocolError {
  return new ProtocolError(status, code, message);
}

const badRequest = () => refuse(400, "bad_request", "request is not valid");
const forbidden = () => refuse(403, "forbidden", "this device has not registered a key");

function requireProtocol(request: FastifyRequest): void {
  if (request.headers["agmsg-protocol-version"] !== "1") {
    throw new ProtocolError(426, "unsupported-protocol-version", "Agmsg-Protocol-Version must match /v1",
      { requested_version: request.headers["agmsg-protocol-version"] ?? null, supported_versions: [1] });
  }
}

type Caller = { deviceId: string; teamId: string; recipient: string };

export function registerKeyRoutes(
  app: FastifyInstance,
  options: { pool: Pool; escrow: EscrowBackend | null },
): void {
  const { pool, escrow } = options;

  // Keys never sit in a cache, whatever the answer.
  app.addHook("onRequest", async (_request, reply) => {
    void reply.header("Cache-Control", "no-store");
  });

  // The scope in front of this already resolved the capability and the team.
  // What is checked here is what only a key route needs: escrow is switched on,
  // and the device registered a recipient.
  async function caller(request: FastifyRequest): Promise<Caller & { backend: EscrowBackend }> {
    requireProtocol(request);
    if (escrow === null) throw refuse(503, "escrow_unavailable", "key escrow is not configured on this server");
    const device = await resolveSecret(pool, (request.params as { secret?: string }).secret ?? "");
    if (!device) throw refuse(401, "unauthenticated", "capability URL is not valid");
    const { rows } = await pool.query<{ device_pubkey: string | null }>(
      `SELECT device_pubkey FROM devices WHERE device_id = $1`, [device.deviceId]);
    const recipient = rows[0]?.device_pubkey ?? null;
    if (recipient === null) throw forbidden();
    return { ...device, recipient, backend: escrow };
  }

  // Locks the caller's device row and checks it is still live, inside the
  // caller's transaction. Removal locks the device row first and the team row
  // second; every key transaction takes them in that same order, so a removal
  // that committed first is seen here, and one that comes later waits. The
  // refusal is the same answer an unknown capability gets.
  async function lockLiveDevice(client: PoolClient, deviceId: string, mode: "UPDATE" | "SHARE"): Promise<void> {
    const { rowCount } = await client.query(
      `SELECT 1 FROM devices
        WHERE device_id = $1 AND activated_at IS NOT NULL AND revoked_at IS NULL FOR ${mode}`,
      [deviceId]);
    if (rowCount === 0) throw refuse(401, "unauthenticated", "capability URL is not valid");
  }

  app.post("/v1/keys/epochs", async (request, reply) => {
    const who = await caller(request);
    const parsed = epochBody.safeParse(request.body);
    if (!parsed.success) throw badRequest();
    const body = parsed.data;
    if (body.epoch < 1 || body.epoch > MAX_EPOCH) throw refuse(422, "epoch_invalid", "epoch is out of range");
    if (!KEY_ID.test(body.key_id)) throw refuse(422, "key_id_invalid", "key_id is not valid");
    if (!AGE_RECIPIENT.test(body.recipient)) throw refuse(422, "recipient_invalid", "recipient is not an age recipient");
    if (!AGE_IDENTITY.test(body.identity) || (await recipientOfIdentity(body.identity)) !== body.recipient) {
      throw refuse(422, "identity_mismatch", "identity does not belong to the recipient");
    }
    if (body.snapshot.epoch_revision !== String(body.epoch - 1)) {
      throw refuse(422, "snapshot_mismatch", "snapshot does not belong to this epoch");
    }
    const epoch = BigInt(body.epoch);
    const wrapped = Buffer.from(await who.backend.wrap(Buffer.from(body.identity, "utf8"), { teamId: who.teamId, epoch }));

    const result = await inTransaction(pool, async (client) => {
      await lockLiveDevice(client, who.deviceId, "SHARE");
      // The team lock removal takes: registration is ordered against it.
      const team = await client.query(`SELECT 1 FROM teams WHERE team_id = $1 FOR UPDATE`, [who.teamId]);
      if (team.rowCount === 0) throw refuse(404, "team-not-found", "team is not provisioned");
      const rows = await listEpochs(client, who.teamId);
      const existing = rows.find((row) => row.epoch === epoch);
      if (existing) return { status: 200 as const, row: existing };
      const previous = rows.find((row) => row.epoch === epoch - 1n);
      if (epoch > 1n && !previous) throw refuse(422, "previous_epoch_missing", "the previous epoch is not registered");
      if (previous && body.snapshot.previous_snapshot_sha256 !== snapshotDigest(previous.snapshot)) {
        throw refuse(422, "snapshot_mismatch", "snapshot does not extend the previous epoch");
      }
      if (rows.some((row) => row.keyId === body.key_id)) {
        throw refuse(422, "key_id_conflict", "key_id already names another epoch");
      }
      await client.query(
        `INSERT INTO team_key_epochs
           (team_id, epoch, wrap_kind, key_ref, wrapped_key, recipient, key_id, snapshot)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)`,
        [who.teamId, epoch.toString(), who.backend.kind, who.backend.keyRef, wrapped,
          body.recipient, body.key_id, JSON.stringify(body.snapshot)],
      );
      // Publishing the next epoch ends the pause a device removal put on any
      // earlier epoch, in this same transaction.
      await liftFencesBefore(client, who.teamId, epoch);
      return { status: 201 as const, row: null };
    });
    if (result.status === 201) return reply.status(201).send({ status: "registered", epoch: body.epoch });
    return reply.status(200).send({
      status: "exists", epoch: Number(result.row.epoch), key_id: result.row.keyId, recipient: result.row.recipient,
    });
  });

  app.get("/v1/keys/bundle", async (request, reply) => {
    const who = await caller(request);
    if (Object.keys((request.query ?? {}) as object).length > 0) throw badRequest();
    // One transaction holds the device row, so a removal cannot commit between
    // the check that the device is live and the release: it waits, and the next
    // request is refused. A failed release is recorded and committed, then
    // refused, so the record outlives the refusal.
    const outcome = await inTransaction(pool, async (client) => {
      await lockLiveDevice(client, who.deviceId, "SHARE");
      const rows = await listEpochs(client, who.teamId);
      const latest = rows.at(-1);
      if (!latest) throw refuse(409, "no_team_key", "this team has no escrowed key");
      // Recorded before anything leaves: a key that cannot be audited is not
      // released.
      const audit = (result: "released" | "failed") => client.query(
        `INSERT INTO key_releases (id, team_id, epoch, principal, device_id, purpose, outcome)
         VALUES ($1, $2, $3, $4, $4, 'enroll', $5)`,
        [uuidv7(), who.teamId, latest.epoch.toString(), who.deviceId, result]);
      try {
        const identities = [];
        for (const row of rows) {
          const identity = await who.backend.unwrap(row.wrappedKey, { teamId: who.teamId, epoch: row.epoch });
          identities.push({ key_id: row.keyId, identity: Buffer.from(identity).toString("utf8") });
        }
        const sealed = await sealToRecipient(canonicalJson({
          format_version: 1,
          type: "agmsg_age_v1_handoff",
          snapshots: rows.map((row) => row.snapshot),
          identities,
        }), who.recipient);
        await audit("released");
        return { sealed, rows, latest };
      } catch {
        await audit("failed");
        return null;
      }
    });
    if (outcome === null) throw refuse(500, "internal-error", "the key could not be released");
    const { sealed, rows, latest } = outcome;
    return reply.status(200).send({
      format: "agmsg_age_v1_handoff",
      epochs: rows.map((row) => Number(row.epoch)),
      snapshot_sha256: snapshotDigest(latest.snapshot),
      bundle: Buffer.from(sealed).toString("base64"),
    });
  });
}
