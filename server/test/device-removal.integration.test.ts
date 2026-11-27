import { randomBytes, randomUUID } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { insertDevice } from "../src/accounts/capability.js";
import { removeDevice } from "../src/accounts/device-removal.js";
import { liftEpochFence } from "../src/accounts/fence.js";
import type { Config } from "../src/config.js";
import { inTransaction, migrate } from "../src/db.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

const teamA = "018f3f7e-0000-7000-8000-0000000000a1";
const origin = "https://agmsg.test";
const ownerSecret = "0123456789abcdef0123456789abcdef";
const wire = { "agmsg-protocol-version": "1" };

describeDatabase("owner removal of a device", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;
  let cookie = "";
  let counter = 0;

  const config: Config = {
    profile: "accounts", ownerSecret, publicUrl: origin, deviceClientIds: ["agmsg-cli"],
    databaseUrl: databaseUrl ?? "", host: "127.0.0.1", port: 0,
    logLevel: "silent", retentionMaxLiveMessages: null,
  };
  const address = () => `10.5.0.${(counter += 1) % 250 + 1}`;
  const del = (id: string, headers: Record<string, string>, payload?: object) =>
    app.inject({
      method: "DELETE", url: `/v1/devices/${id}`, headers, remoteAddress: address(),
      ...(payload === undefined ? {} : { payload }),
    });
    const ownerHeaders = () => ({ origin, cookie });

  const device = (name: string) =>
    insertDevice(pool, { teamId: teamA, name, deviceType: "codex", active: true });

  function message(keyId: string | null) {
    return {
      messages: [{
        id: randomUUID(),
        envelope: {
          v: 1, cipher: keyId === null ? "none" : "age-v1", key_id: keyId,
          blob: Buffer.from("x").toString("base64"),
        },
      }],
    };
  }
  const post = (secret: string, payload: object) =>
    app.inject({
      method: "POST", url: `/t/${secret}/v1/messages`,
      headers: { ...wire, "content-type": "application/json" }, payload,
    });

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    await pool.query(`INSERT INTO teams (team_id, team_name) VALUES ($1, 'team-a')`, [teamA]);
    await pool.query(
      `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
         accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
      [teamA],
    );
    app = createApp(pool, config);
    await app.ready();
    const signedIn = await app.inject({
      method: "POST", url: "/approve/signin",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      payload: `secret=${ownerSecret}`, remoteAddress: address(),
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

  it("revokes at once: the secret then answers exactly like an unknown one", async () => {
    const gone = await device("to-remove");
    const kept = await device("kept");
    const before = await app.inject({ method: "GET", url: `/t/${gone.secret}/v1/capabilities`, headers: wire });
    expect(before.statusCode).toBe(200);
    expect((await del(gone.deviceId, ownerHeaders())).statusCode).toBe(204);
    const after = await app.inject({ method: "GET", url: `/t/${gone.secret}/v1/capabilities`, headers: wire });
    const unknown = await app.inject({ method: "GET", url: `/t/agsy_00000000_${"A".repeat(43)}/v1/capabilities`, headers: wire });
    expect(after.statusCode).toBe(401);
    expect(after.body).toBe(unknown.body);
    expect((await app.inject({ method: "GET", url: `/t/${kept.secret}/v1/capabilities`, headers: wire })).statusCode).toBe(200);
  });

  it("answers 404 the same for unknown, already removed and malformed ids", async () => {
    const once = await device("twice");
    expect((await del(once.deviceId, ownerHeaders())).statusCode).toBe(204);
    const again = await del(once.deviceId, ownerHeaders());
    const unknown = await del(randomUUID(), ownerHeaders());
    const malformed = await del("not-an-id", ownerHeaders());
    for (const answer of [again, unknown, malformed]) {
      expect(answer.statusCode).toBe(404);
      expect(answer.json()).toEqual({ error: "not_found" });
    }
  });

  it("is the owner's alone: no session, a forged cookie, another origin and no origin all refuse", async () => {
    const target = await device("guarded");
    expect((await del(target.deviceId, { origin })).statusCode).toBe(401);
    expect((await del(target.deviceId, { origin, cookie: "agmsg_owner=forged" })).statusCode).toBe(401);
    expect((await del(target.deviceId, { origin: "https://evil.test", cookie })).statusCode).toBe(403);
    expect((await del(target.deviceId, { cookie })).statusCode).toBe(403);
    // a device's own secret is not an owner session
    expect((await del(target.deviceId, { origin, authorization: `Bearer ${target.secret}` })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url: `/t/${target.secret}/v1/capabilities`, headers: wire })).statusCode).toBe(200);
  });

  it("accepts no body beyond an empty object: there is no abandon list", async () => {
    const target = await device("no-abandon");
    const refused = await del(target.deviceId, { ...ownerHeaders(), "content-type": "application/json" }, { abandon: [] });
    expect(refused.statusCode).toBe(400);
    expect(refused.json()).toEqual({ error: "bad_request" });
    expect((await del(target.deviceId, { ...ownerHeaders(), "content-type": "application/json" }, {})).statusCode).toBe(204);
  });

  describe("the epoch fence", () => {
    it("pauses writes sealed under the removed device's epoch, with a stated error, until rotation lifts it", async () => {
      const gone = await device("fenced-gone");
      const staying = await device("fenced-staying");
      const removed = await removeDevice(pool, gone.deviceId, async () => "epoch-1");
      expect(removed).toEqual({ ok: true, teamId: teamA });

      const fenced = await post(staying.secret, message("epoch-1"));
      expect(fenced.statusCode).toBe(409);
      expect(fenced.json().error.code).toBe("epoch-fenced");
      expect(fenced.json().error.details).toEqual({ team_id: teamA, key_id: "epoch-1" });
      expect(fenced.json().error.message).toMatch(/paused/u);

      // not fenced: plaintext, and a different (next) epoch
      const plain = await post(staying.secret, message(null));
      expect(plain.json().error?.code).not.toBe("epoch-fenced");
      const next = await post(staying.secret, message("epoch-2"));
      expect(next.json().error?.code).not.toBe("epoch-fenced");

      await inTransaction(pool, (client) => liftEpochFence(client, teamA, "epoch-1"));
      const lifted = await post(staying.secret, message("epoch-1"));
      expect(lifted.json().error?.code).not.toBe("epoch-fenced");
    });

    it("fences nothing for a team with no epoch key, and the removal still succeeds", async () => {
      const target = await device("no-epoch");
      expect((await del(target.deviceId, ownerHeaders())).statusCode).toBe(204);
      const rows = await pool.query(`SELECT 1 FROM team_epoch_fences WHERE key_id = 'none'`);
      expect(rows.rowCount).toBe(0);
    });

    it("does not touch the open profile's data plane", async () => {
      const open = createApp(pool, { ...config, profile: "open", ownerSecret: null, publicUrl: null });
      await open.ready();
      const table = open.printRoutes({ commonPrefix: false });
      expect(table).not.toMatch(/epoch|fence/u);
      expect(table).not.toMatch(/devices/u);
      await open.close();
    });
  });
});
