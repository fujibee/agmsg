import { randomBytes } from "node:crypto";
import { Decrypter, generateX25519Identity, identityToRecipient } from "age-encryption";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { insertDevice } from "../src/accounts/capability.js";
import { removeDevice } from "../src/accounts/device-removal.js";
import { snapshotDigest } from "../src/canonical.js";
import { migrate } from "../src/db.js";
import { createKeyfileBackend, type EscrowBackend } from "../src/escrow.js";
import { fencedKeyIds } from "../src/fence.js";
import { createRotator, rotateTeam, teamsNeedingRotation } from "../src/rotation.js";
import { testConfig } from "./helpers/config.js";
// The client's own validator (an untyped .mjs): the chain the server writes must pass it.
// @ts-expect-error TS7016: no declaration file
import { validateAgeConfiguration, ageSnapshotDigest } from "../../scripts/internal/remote-sync.mjs";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;
const origin = "https://agmsg.test";
const ownerSecret = "0123456789abcdef0123456789abcdef";
const wire = { "agmsg-protocol-version": "1" };
const json = { ...wire, "content-type": "application/json" };

describeDatabase("step 2 of device removal: the next epoch", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  const backend = createKeyfileBackend(randomBytes(32));
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;
  let cookie = "";
  let serverId = "";
  let counter = 0;
  let teamCounter = 0;

  const lines: object[] = [];
  const log = { info: (line: object) => { lines.push(line); }, warn: (line: object) => { lines.push(line); } };

  // A team holding epoch 1, one device that registered a recipient, and a second
  // device to remove. `seq` is how far the team's stream has moved.
  async function team(seq: number) {
    const teamId = `018f3f7e-0000-7000-8000-${(0xe000 + (teamCounter += 1)).toString(16).padStart(12, "0")}`;
    await pool.query(`INSERT INTO teams (team_id, team_name, current_seq) VALUES ($1, $2, $3)`, [teamId, `rot-${teamCounter}`, seq]);
    await pool.query(
      `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
         accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`, [teamId]);
    const keeper = await insertDevice(pool, { teamId, name: "keeper", deviceType: "test", active: true });
    const keeperIdentity = await generateX25519Identity();
    await pool.query(`UPDATE devices SET device_pubkey = $2 WHERE device_id = $1`,
      [keeper.deviceId, await identityToRecipient(keeperIdentity)]);
    const leaver = await insertDevice(pool, { teamId, name: "leaver", deviceType: "test", active: true });
    const identity = await generateX25519Identity();
    const recipient = await identityToRecipient(identity);
    const keyId = `first-${randomBytes(3).toString("hex")}`;
    const snapshot = {
      profile: "age-v1", server_instance_id: serverId, team_id: teamId,
      epoch_revision: "0", writer_generation: "0", authorized_writers: [keyId],
      previous_snapshot_sha256: null,
      history: [{ epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1", key_id: keyId, recipients: [recipient] }],
    };
    const posted = await app.inject({
      method: "POST", url: `/t/${keeper.secret}/v1/keys/epochs`, headers: json,
      payload: { epoch: 1, key_id: keyId, identity, recipient, snapshot },
    });
    expect(posted.statusCode).toBe(201);
    return { teamId, keeper, keeperIdentity, leaver, keyId, snapshot };
  }

  const epochs = async (teamId: string) =>
    (await pool.query(`SELECT epoch::int AS epoch, key_id, snapshot FROM team_key_epochs WHERE team_id = $1 ORDER BY epoch`, [teamId])).rows;

  async function until(check: () => Promise<boolean>) {
    for (let attempt = 0; attempt < 100; attempt += 1) {
      if (await check()) return;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error("condition not reached");
  }

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    serverId = (await pool.query(`SELECT server_instance_id FROM server_metadata`)).rows[0].server_instance_id;
    app = createApp(pool, testConfig({
      profile: "accounts", ownerSecret, publicUrl: origin, databaseUrl: databaseUrl ?? "",
    }), { escrow: backend });
    await app.ready();
    const signedIn = await app.inject({
      method: "POST", url: "/approve/signin", remoteAddress: "10.6.0.1",
      headers: { "content-type": "application/x-www-form-urlencoded" }, payload: `secret=${ownerSecret}`,
    });
    cookie = String(signedIn.headers["set-cookie"]).split(";")[0] ?? "";
  });

  afterAll(async () => {
    await app.close();
    await pool.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) throw new Error("refusing to remove an unexpected test schema");
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  it("publishes the next epoch after the owner removes a device, and the client accepts the chain", async () => {
    const t = await team(5);
    const removed = await app.inject({
      method: "DELETE", url: `/v1/devices/${t.leaver.deviceId}`, remoteAddress: "10.6.0.2",
      headers: { origin, cookie },
    });
    expect(removed.statusCode).toBe(204);
    await until(async () => (await epochs(t.teamId)).length === 2);
    expect(await fencedKeyIds(pool, t.teamId, [t.keyId])).toEqual([]);

    const rows = await epochs(t.teamId);
    const snapshots = rows.map((row) => row.snapshot);
    expect(() => validateAgeConfiguration({
      server_instance_id: serverId, remote_team_id: t.teamId,
      age_v1: {
        epoch_snapshots: snapshots, age_version: "test",
        identity_files: Object.fromEntries(snapshots.at(-1).history.map((h: { key_id: string }) => [h.key_id, "x"])),
        checkpoint: {
          epoch_revision: snapshots.at(-1).epoch_revision, writer_generation: snapshots.at(-1).writer_generation,
          snapshot_sha256: ageSnapshotDigest(snapshots.at(-1)), confirmed_at: new Date().toISOString(),
        },
      },
    })).not.toThrow();
    expect(snapshotDigest(snapshots[0])).toBe(snapshots[1].previous_snapshot_sha256);
    expect(snapshots[1].history.at(-1).effective_from_seq).toBe("6");

    // The device that remains opens both identities; the removed one is refused.
    const bundle = await app.inject({ method: "GET", url: `/t/${t.keeper.secret}/v1/keys/bundle`, headers: wire });
    const decrypter = new Decrypter();
    decrypter.addIdentity(t.keeperIdentity);
    const opened = JSON.parse(await decrypter.decrypt(Buffer.from(bundle.json().bundle, "base64"), "text"));
    expect(opened.identities.map((row: { key_id: string }) => row.key_id)).toEqual(rows.map((row) => row.key_id));
    expect((await app.inject({ method: "GET", url: `/t/${t.leaver.secret}/v1/keys/bundle`, headers: wire })).statusCode).toBe(401);
  });

  it("does nothing a second time, and nothing when a client published the next epoch first", async () => {
    const t = await team(5);
    await removeDevice(pool, t.leaver.deviceId);
    expect(await teamsNeedingRotation(pool)).toContain(t.teamId);
    expect(await rotateTeam(pool, backend, t.teamId)).toBe("rotated");
    expect(await rotateTeam(pool, backend, t.teamId)).toBe("idle");
    expect((await epochs(t.teamId)).length).toBe(2);
    expect(await teamsNeedingRotation(pool)).not.toContain(t.teamId);
  });

  it("keeps the fence and says so once when no message has followed the current epoch", async () => {
    const t = await team(0);
    await removeDevice(pool, t.leaver.deviceId);
    expect(await rotateTeam(pool, backend, t.teamId)).toBe("blocked");
    expect((await epochs(t.teamId)).length).toBe(1);
    expect(await fencedKeyIds(pool, t.teamId, [t.keyId])).toEqual([t.keyId]);

    lines.length = 0;
    const rotator = createRotator({ pool, backend, log, retryMs: 20 });
    await rotator.start();
    await new Promise((resolve) => setTimeout(resolve, 120));
    rotator.stop();
    expect(lines.filter((line) => (line as { event: string }).event === "key-rotation.blocked")).toHaveLength(1);
    // A client publishing the next epoch is still how this team recovers.
    expect((await epochs(t.teamId)).length).toBe(1);
  });

  it("finds what was pending when it starts, so a restart loses nothing", async () => {
    const t = await team(3);
    await removeDevice(pool, t.leaver.deviceId);
    const rotator = createRotator({ pool, backend, log });
    await rotator.start();
    rotator.stop();
    expect((await epochs(t.teamId)).length).toBe(2);
  });

  it("retries a failing step on its own and reports the failure once", async () => {
    const t = await team(4);
    await removeDevice(pool, t.leaver.deviceId);
    let failures = 2;
    const flaky: EscrowBackend = {
      ...backend,
      wrap: async (...args) => {
        if (failures > 0) { failures -= 1; throw new Error("backend unavailable"); }
        return backend.wrap(...args);
      },
    };
    lines.length = 0;
    const rotator = createRotator({ pool, backend: flaky, log, retryMs: 20 });
    await rotator.start();
    await until(async () => (await epochs(t.teamId)).length === 2);
    rotator.stop();
    expect(lines.filter((line) => (line as { event: string }).event === "key-rotation.failed")).toHaveLength(1);
    expect(await fencedKeyIds(pool, t.teamId, [t.keyId])).toEqual([]);
  });

  it("never undoes step 1 when step 2 fails: the device stays revoked and the fence stays", async () => {
    const t = await team(4);
    const broken: EscrowBackend = { ...backend, wrap: async () => { throw new Error("backend unavailable"); } };
    await removeDevice(pool, t.leaver.deviceId);
    const rotator = createRotator({ pool, backend: broken, log, retryMs: 1_000_000 });
    await rotator.start();
    rotator.stop();
    expect((await pool.query(`SELECT revoked_at FROM devices WHERE device_id = $1`, [t.leaver.deviceId])).rows[0].revoked_at).not.toBeNull();
    expect(await fencedKeyIds(pool, t.teamId, [t.keyId])).toEqual([t.keyId]);
    expect((await epochs(t.teamId)).length).toBe(1);
  });
});
