import { randomBytes } from "node:crypto";
import { generateX25519Identity, identityToRecipient } from "age-encryption";
import type { Pool } from "pg";
import { snapshotDigest } from "./canonical.js";
import { inTransaction } from "./db.js";
import { listEpochs } from "./escrow-store.js";
import type { EscrowBackend } from "./escrow.js";
import { fencedKeyIds, liftEpochFence } from "./fence.js";

// Step 2 of removing a device: publish the team's next key epoch and lift the
// fence step 1 put on the current one. The state is the fence itself. A team
// needs rotation exactly when its CURRENT epoch's key has an unlifted fence, so
// there is no job table to lose: a restart, a retry and a second server all
// start from the same question and answer it the same way.

export type RotationResult = "rotated" | "idle" | "blocked";

/** Teams whose current epoch is fenced. */
export async function teamsNeedingRotation(pool: Pool): Promise<string[]> {
  const { rows } = await pool.query<{ team_id: string }>(
    `SELECT DISTINCT f.team_id::text AS team_id
       FROM team_epoch_fences f
      WHERE f.lifted_at IS NULL
        AND f.key_id = (SELECT e.key_id FROM team_key_epochs e
                         WHERE e.team_id = f.team_id ORDER BY e.epoch DESC LIMIT 1)`,
  );
  return rows.map((row) => row.team_id);
}

/**
 * Rotates one team in one transaction, or does nothing:
 *   rotated  the next epoch is stored and the fence is lifted;
 *   idle     nothing to do (no epoch, no live fence, or a client got there first);
 *   blocked  a new epoch cannot start yet: its first sequence would not come
 *            after the previous epoch's, which a client refuses. The fence stays
 *            and the next epoch has to come from a client (POST /v1/keys/epochs).
 */
export async function rotateTeam(
  pool: Pool,
  backend: EscrowBackend,
  teamId: string,
): Promise<RotationResult> {
  return inTransaction(pool, async (client) => {
    // The lock removal and every write take: a client publishing the next epoch
    // is ordered against this, and the checks below see its result.
    const team = await client.query<{ current_seq: string }>(
      `SELECT current_seq::text AS current_seq FROM teams WHERE team_id = $1 FOR UPDATE`, [teamId]);
    if (team.rowCount === 0) return "idle" as const;
    const rows = await listEpochs(client, teamId);
    const current = rows.at(-1);
    if (!current || (await fencedKeyIds(client, teamId, [current.keyId])).length === 0) return "idle" as const;

    const previous = current.snapshot as {
      writer_generation: string; history: Array<{ effective_from_seq: string }>;
    };
    const boundary = BigInt(team.rows[0]!.current_seq) + 1n;
    const priorBoundary = BigInt(previous.history.at(-1)!.effective_from_seq);
    if (boundary <= priorBoundary) return "blocked" as const;

    const { rows: [meta] } = await client.query<{ server_instance_id: string }>(
      `SELECT server_instance_id FROM server_metadata`);
    const identity = await generateX25519Identity();
    const recipient = await identityToRecipient(identity);
    const epoch = current.epoch + 1n;
    const keyId = `epoch-${epoch}-${randomBytes(4).toString("hex")}`;
    const snapshot = {
      ...(current.snapshot as Record<string, unknown>),
      epoch_revision: current.epoch.toString(),
      writer_generation: (BigInt(previous.writer_generation) + 1n).toString(),
      authorized_writers: [keyId],
      previous_snapshot_sha256: snapshotDigest(current.snapshot),
      history: [...(previous.history as unknown[]), {
        epoch_revision: current.epoch.toString(),
        effective_from_seq: boundary.toString(),
        cipher: "age-v1",
        key_id: keyId,
        recipients: [recipient],
      }],
      server_instance_id: meta!.server_instance_id,
    };
    const wrapped = Buffer.from(await backend.wrap(Buffer.from(identity, "utf8"), { teamId, epoch }));
    await client.query(
      `INSERT INTO team_key_epochs
         (team_id, epoch, wrap_kind, key_ref, wrapped_key, recipient, key_id, snapshot)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)`,
      [teamId, epoch.toString(), backend.kind, backend.keyRef, wrapped, recipient, keyId, JSON.stringify(snapshot)],
    );
    await liftEpochFence(client, teamId, current.keyId);
    return "rotated" as const;
  });
}

type Log = { info: (value: object) => void; warn: (value: object) => void };

/**
 * Runs rotations: once at start (a restart picks up what was pending), after a
 * removal (kick), and again every `retryMs` only while something is failing or
 * blocked. A failure is logged once per kind of failure, not every cycle.
 */
export function createRotator(options: {
  pool: Pool; backend: EscrowBackend; log: Log; retryMs?: number;
}) {
  const { pool, backend, log } = options;
  const retryMs = options.retryMs ?? 30_000;
  let timer: NodeJS.Timeout | null = null;
  let running = false;
  let again = false;
  let stopped = false;
  const reported = new Set<string>();

  const once = (key: string, line: object, level: "info" | "warn") => {
    if (reported.has(key)) return;
    reported.add(key);
    log[level](line);
  };

  async function sweep(): Promise<void> {
    if (running) { again = true; return; }
    running = true;
    let retry = false;
    try {
      do {
        again = false;
        let teams: string[];
        try {
          teams = await teamsNeedingRotation(pool);
        } catch (error) {
          retry = true;
          once(`sweep:${errorClass(error)}`, { event: "key-rotation.failed", step: "find", error_name: errorClass(error) }, "warn");
          continue;
        }
        const pending = new Set(teams);
        // A team that no longer needs rotation may be reported again if it does.
        for (const key of [...reported]) {
          const [kind, team] = key.split(":");
          if (kind !== "sweep" && team && !pending.has(team)) reported.delete(key);
        }
        for (const key of [...reported]) if (key.startsWith("sweep:")) reported.delete(key);
        for (const teamId of teams) {
          try {
            const result = await rotateTeam(pool, backend, teamId);
            if (result === "rotated") log.info({ event: "key-rotation.rotated", team_id: teamId });
            if (result === "blocked") {
              retry = true;
              once(`blocked:${teamId}`, {
                event: "key-rotation.blocked", team_id: teamId,
                reason: "no message since the current epoch began; the next epoch must come from a client",
              }, "warn");
            }
          } catch (error) {
            retry = true;
            once(`failed:${teamId}:${errorClass(error)}`, {
              event: "key-rotation.failed", team_id: teamId, error_name: errorClass(error),
            }, "warn");
          }
        }
      } while (again && !stopped);
    } finally {
      running = false;
    }
    if (retry && !stopped) {
      timer = setTimeout(() => { timer = null; void sweep(); }, retryMs);
      timer.unref();
    }
  }

  return {
    start: () => sweep(),
    kick: () => { if (timer) { clearTimeout(timer); timer = null; } return sweep(); },
    stop: () => { stopped = true; if (timer) clearTimeout(timer); timer = null; },
  };
}

function errorClass(error: unknown): string {
  return error instanceof Error ? error.name : typeof error;
}
