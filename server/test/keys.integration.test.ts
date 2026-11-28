import { randomBytes } from "node:crypto";
import { Decrypter, generateX25519Identity, identityToRecipient } from "age-encryption";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { insertDevice } from "../src/accounts/capability.js";
import { removeDevice } from "../src/accounts/device-removal.js";
import { snapshotDigest } from "../src/canonical.js";
import { migrate } from "../src/db.js";
import { createKeyfileBackend } from "../src/escrow.js";
import { fencedKeyIds } from "../src/fence.js";
import { testConfig } from "./helpers/config.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

const team = "018f3f7e-0000-7000-8000-0000000000c3";
const origin = "https://agmsg.test";
const wire = { "agmsg-protocol-version": "1" };
const json = { ...wire, "content-type": "application/json" };

async function epochOf(epoch: number, previous: { snapshot: Record<string, unknown> } | null) {
  const identity = await generateX25519Identity();
  const recipient = await identityToRecipient(identity);
  const keyId = `k${epoch}-${randomBytes(3).toString("hex")}`;
  const history = [
    ...((previous?.snapshot.history as unknown[]) ?? []),
    { epoch_revision: String(epoch - 1), effective_from_seq: String(epoch * 10 - 9),
      cipher: "age-v1", key_id: keyId, recipients: [recipient] },
  ];
  const snapshot = {
    profile: "age-v1", team_id: team, epoch_revision: String(epoch - 1),
    writer_generation: String(epoch - 1), authorized_writers: [keyId],
    previous_snapshot_sha256: previous ? snapshotDigest(previous.snapshot) : null, history,
  };
  return { epoch, key_id: keyId, identity, recipient, snapshot };
}

describeDatabase("escrowed team keys over a capability URL", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  const backend = createKeyfileBackend(randomBytes(32));
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;
  let off: ReturnType<typeof createApp>;
  let device: { secret: string; deviceId: string };
  let deviceIdentity: string;

  const post = (secret: string, url: string, payload: object, target = app) =>
    target.inject({ method: "POST", url: `/t/${secret}/v1/keys/${url}`, headers: json, payload });
  const bundle = (secret: string, target = app) =>
    target.inject({ method: "GET", url: `/t/${secret}/v1/keys/bundle`, headers: wire });

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    await pool.query(`INSERT INTO teams (team_id, team_name) VALUES ($1, 'keys-team')`, [team]);
    await pool.query(
      `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
         accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`, [team]);
    const config = testConfig({
      profile: "accounts", ownerSecret: "0123456789abcdef0123456789abcdef",
      publicUrl: origin, databaseUrl: databaseUrl ?? "",
    });
    app = createApp(pool, config, { escrow: backend });
    off = createApp(pool, config);
    await app.ready();
    await off.ready();
    device = await insertDevice(pool, { teamId: team, name: "d1", deviceType: "test", active: true });
    deviceIdentity = await generateX25519Identity();
    const registered = await app.inject({
      method: "POST", url: "/v1/devices",
      headers: { authorization: `Bearer ${device.secret}`, "content-type": "application/json" },
      payload: { team_id: team, device_pubkey: await identityToRecipient(deviceIdentity), label: "d1" },
    });
    expect(registered.statusCode).toBe(201);
  });

  afterAll(async () => {
    await app.close();
    await off.close();
    await pool.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) throw new Error("refusing to remove an unexpected test schema");
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  it("stores the identity wrapped, never in the clear, and the recipient shows in the device list", async () => {
    const first = await epochOf(1, null);
    const answer = await post(device.secret, "epochs", first);
    expect(answer.statusCode).toBe(201);
    const { rows } = await pool.query(
      `SELECT wrap_kind, key_ref, wrapped_key FROM team_key_epochs WHERE team_id = $1 AND epoch = 1`, [team]);
    expect(rows[0].wrap_kind).toBe("keyfile");
    expect(rows[0].key_ref).toBe(backend.keyRef);
    expect(Buffer.from(rows[0].wrapped_key).includes(Buffer.from(first.identity))).toBe(false);
    const listed = await app.inject({
      method: "GET", url: "/v1/devices", headers: { authorization: `Bearer ${device.secret}` } });
    expect(listed.json().devices[0].devicePubkey).toMatch(/^age1/u);
  });

  it("opens the bundle with the device's own identity and records the release", async () => {
    const before = await pool.query(`SELECT count(*)::int AS n FROM key_releases WHERE device_id = $1`, [device.deviceId]);
    const answer = await bundle(device.secret);
    expect(answer.statusCode).toBe(200);
    expect(answer.headers["cache-control"]).toContain("no-store");
    const decrypter = new Decrypter();
    decrypter.addIdentity(deviceIdentity);
    const opened = JSON.parse(await decrypter.decrypt(Buffer.from(answer.json().bundle, "base64"), "text"));
    expect(opened.identities).toHaveLength(1);
    expect(opened.identities[0].identity).toMatch(/^AGE-SECRET-KEY-1/u);
    const after = await pool.query(
      `SELECT outcome FROM key_releases WHERE device_id = $1 ORDER BY created_at DESC`, [device.deviceId]);
    expect(after.rowCount).toBe(before.rows[0].n + 1);
    expect(after.rows[0].outcome).toBe("released");
  });

  it("publishing the next epoch lifts the fence a device removal put on the one before", async () => {
    const gone = await insertDevice(pool, { teamId: team, name: "gone", deviceType: "test", active: true });
    const current = (await pool.query(`SELECT key_id, snapshot FROM team_key_epochs WHERE team_id = $1 AND epoch = 1`, [team])).rows[0];
    expect((await removeDevice(pool, gone.deviceId)).ok).toBe(true);
    expect(await fencedKeyIds(pool, team, [current.key_id])).toEqual([current.key_id]);
    const second = await epochOf(2, { snapshot: current.snapshot });
    expect((await post(device.secret, "epochs", second)).statusCode).toBe(201);
    expect(await fencedKeyIds(pool, team, [current.key_id])).toEqual([]);
  });

  it("refuses a snapshot that does not extend the previous epoch's digest", async () => {
    const stored = (await pool.query(`SELECT snapshot FROM team_key_epochs WHERE team_id = $1 AND epoch = 2`, [team])).rows[0];
    const third = await epochOf(3, { snapshot: stored.snapshot });
    third.snapshot.previous_snapshot_sha256 = "0".repeat(64);
    const answer = await post(device.secret, "epochs", third);
    expect(answer.statusCode).toBe(422);
    expect(answer.json().error.code).toBe("snapshot_mismatch");
    expect((await pool.query(`SELECT 1 FROM team_key_epochs WHERE team_id = $1 AND epoch = 3`, [team])).rowCount).toBe(0);
  });

  it("records a failed release and returns no key when the wrap cannot be opened", async () => {
    await pool.query(`UPDATE team_key_epochs SET wrapped_key = '\\x00112233445566778899aabbccddeeff00112233' WHERE team_id = $1 AND epoch = 2`, [team]);
    const answer = await bundle(device.secret);
    expect(answer.statusCode).toBe(500);
    expect(answer.body).not.toContain("AGE-SECRET-KEY");
    const last = await pool.query(`SELECT outcome FROM key_releases WHERE device_id = $1 ORDER BY created_at DESC LIMIT 1`, [device.deviceId]);
    expect(last.rows[0].outcome).toBe("failed");
  });

  it("answers 503 on both key routes when no escrow backend is configured", async () => {
    for (const answer of [await bundle(device.secret, off), await post(device.secret, "epochs", {}, off)]) {
      expect(answer.statusCode).toBe(503);
      expect(answer.json().error.code).toBe("escrow_unavailable");
    }
  });

  it("registers a recipient once: the same key again is fine, another key is refused", async () => {
    const other = await insertDevice(pool, { teamId: team, name: "d2", deviceType: "test", active: true });
    const key = await identityToRecipient(await generateX25519Identity());
    const send = (pubkey: string) => app.inject({
      method: "POST", url: "/v1/devices",
      headers: { authorization: `Bearer ${other.secret}`, "content-type": "application/json" },
      payload: { team_id: team, device_pubkey: pubkey, label: "d2" },
    });
    expect((await send(key)).statusCode).toBe(201);
    expect((await send(key)).statusCode).toBe(201);
    const changed = await send(await identityToRecipient(await generateX25519Identity()));
    expect(changed.statusCode).toBe(409);
    expect(changed.json()).toEqual({ error: "device_key_mismatch" });
  });
});
