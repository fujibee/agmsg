import { randomBytes, randomUUID } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { insertDevice } from "../src/accounts/capability.js";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { migrate } from "../src/db.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

const team = "018f3f7e-0000-7000-8000-0000000000e1";
const wire = { "agmsg-protocol-version": "1" };

function row(overrides: Record<string, unknown> = {}) {
  const epoch = (overrides.epoch as number | undefined) ?? 1;
  return {
    team_id: team,
    epoch,
    wrap_kind: "keyfile",
    key_ref: "keyfile:0123456789abcdef",
    wrapped_key: Buffer.from("opaque"),
    recipient: "age1example",
    key_id: "team-key",
    snapshot: JSON.stringify({ epoch_revision: epoch - 1 }),
    ...overrides,
  };
}

describeDatabase("key escrow", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  let admin: Pool;
  let pool: Pool;
  let secret: string;

  const config = (escrowBackend: "none" | "keyfile"): Config => ({
    profile: "accounts",
    databaseUrl: databaseUrl ?? "",
    host: "127.0.0.1",
    port: 0,
    logLevel: "silent",
    retentionMaxLiveMessages: null,
    escrowBackend,
    escrowKeyfile: null,
  });

  async function insert(values: ReturnType<typeof row>): Promise<void> {
    await pool.query(
      `INSERT INTO team_key_epochs
         (team_id, epoch, wrap_kind, key_ref, wrapped_key, recipient, key_id, snapshot)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb)`,
      [values.team_id, values.epoch, values.wrap_kind, values.key_ref,
        values.wrapped_key, values.recipient, values.key_id, values.snapshot],
    );
  }

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    await pool.query(`INSERT INTO teams (team_id, team_name) VALUES ($1, 'team-e')`, [team]);
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id, policy_revision, effective_from_seq,
          accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
      [team],
    );
    secret = (await insertDevice(pool, {
      teamId: team, name: "laptop", deviceType: "claude-code", active: true,
    })).secret;
  });

  afterAll(async () => {
    await pool.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) throw new Error("refusing to remove an unexpected test schema");
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  it("applies again without error (idempotent migrations)", async () => {
    await migrate(pool);
  });

  it("stores one epoch per team and refuses a second row for the same epoch", async () => {
    await insert(row());
    await expect(insert(row())).rejects.toThrow(/duplicate key/u);
    await insert(row({ epoch: 2 }));
  });

  it("refuses rows that could never be part of a handoff bundle", async () => {
    const cases: Array<[string, Record<string, unknown>, RegExp]> = [
      ["unknown kind", { epoch: 3, wrap_kind: "vault" }, /team_key_epochs_known_kind/u],
      ["empty key ref", { epoch: 3, key_ref: "" }, /team_key_epochs_key_ref/u],
      ["empty wrap", { epoch: 3, wrapped_key: Buffer.alloc(0) }, /team_key_epochs_wrapped_size/u],
      ["huge wrap", { epoch: 3, wrapped_key: Buffer.alloc(8193) }, /team_key_epochs_wrapped_size/u],
      ["bad key id", { epoch: 3, key_id: "Bad Id" }, /team_key_epochs_key_id_shape/u],
      ["snapshot of another epoch", { epoch: 3, snapshot: JSON.stringify({ epoch_revision: 5 }) },
        /team_key_epochs_snapshot_revision/u],
      ["epoch 0", { epoch: 0, snapshot: JSON.stringify({ epoch_revision: -1 }) }, /check/u],
    ];
    for (const [label, overrides, pattern] of cases) {
      await expect(insert(row(overrides)), label).rejects.toThrow(pattern);
    }
  });

  it("refuses an epoch for a team that does not exist", async () => {
    await expect(insert(row({ team_id: randomUUID() }))).rejects.toThrow(/foreign key/u);
  });

  it("records a release with no foreign keys and refuses an unknown purpose or outcome", async () => {
    const release = (purpose: string, outcome: string) => pool.query(
      `INSERT INTO key_releases (id, team_id, epoch, principal, purpose, outcome)
       VALUES ($1, $2, 1, $3, $4, $5)`,
      [randomUUID(), randomUUID(), randomUUID(), purpose, outcome],
    );
    await release("enroll", "released");
    await expect(release("peek", "released")).rejects.toThrow(/key_releases_purpose/u);
    await expect(release("enroll", "maybe")).rejects.toThrow(/key_releases_outcome/u);
  });

  it("lists key-escrow in the team features only when a backend is set", async () => {
    for (const [backend, expected] of [["keyfile", true], ["none", false]] as const) {
      const app = createApp(pool, config(backend));
      await app.ready();
      const response = await app.inject({
        method: "GET", url: `/t/${secret}/v1/capabilities`, headers: wire,
      });
      expect(response.statusCode).toBe(200);
      expect(response.json().features.includes("key-escrow")).toBe(expected);
      await app.close();
    }
  });
});
