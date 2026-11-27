import { randomBytes } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { migrate } from "../src/db.js";

// The device limit refuses the grant that would pass it, at the moment the device
// would be minted, and leaves the grant approved so a later poll can succeed.
const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

const team = "018f3f7e-0000-7000-8000-0000000000c1";
const origin = "https://agmsg.test";
const ownerSecret = "0123456789abcdef0123456789abcdef";
const form = { "content-type": "application/x-www-form-urlencoded" };
const json = { "content-type": "application/json" };

describeDatabase("device limit", () => {
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
    limits: { devices: 2n, teams: null },
  };

  const address = () => `10.1.${Math.floor(counter / 250)}.${(counter += 1) % 250 + 1}`;
  const post = (url: string, payload: unknown, headers = json) =>
    app.inject({ method: "POST", url, headers, payload: payload as object, remoteAddress: address() });

  // Code and approval for one machine; the poll is left to the caller.
  async function approved(name: string) {
    const code = (await post("/v1/device/code", {
      client_id: "agmsg-cli", machine_name: name, team_id: team,
    })).json();
    const decision = await app.inject({
      method: "POST", url: "/v1/device/approve",
      headers: { ...json, origin, cookie },
      payload: { user_code: code.user_code, decision: "approve" },
      remoteAddress: address(),
    });
    expect(decision.statusCode).toBe(200);
    return code.device_code as string;
  }
  const poll = (deviceCode: string) =>
    post("/v1/device/token", { device_code: deviceCode, client_id: "agmsg-cli" });
  const live = async () => Number((await pool.query<{ n: string }>(
    "SELECT count(*)::text AS n FROM devices WHERE revoked_at IS NULL")).rows[0]?.n);

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    await pool.query(`INSERT INTO teams (team_id, team_name) VALUES ($1, 'limit-team')`, [team]);
    await pool.query(
      `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
         accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`, [team]);
    app = createApp(pool, config);
    await app.ready();
    const signedIn = await app.inject({
      method: "POST", url: "/approve/signin", headers: form,
      payload: `secret=${ownerSecret}`, remoteAddress: address(),
    });
    expect(signedIn.statusCode).toBe(303);
    cookie = String(signedIn.headers["set-cookie"]).split(";")[0] ?? "";
  });

  afterAll(async () => {
    await app?.close();
    await pool?.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) throw new Error("refusing to remove an unexpected test schema");
    await admin?.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin?.end();
  });

  it("mints up to the limit, then refuses with the stated error and mints nothing", async () => {
    expect((await poll(await approved("m1"))).statusCode).toBe(200);
    expect((await poll(await approved("m2"))).statusCode).toBe(200);
    const third = await approved("m3");
    const refused = await poll(third);
    expect(refused.statusCode).toBe(403);
    expect(refused.json()).toEqual({ error: "limit-reached", limit: "devices", value: "2" });
    expect(await live()).toBe(2);
    const left = await pool.query("SELECT 1 FROM devices WHERE name = 'm3'");
    expect(left.rowCount).toBe(0);
  });

  it("still answers machine_exists for a name a live device holds, even when the server is full", async () => {
    const again = await approved("m1");
    const answer = await poll(again);
    expect(answer.statusCode).toBe(400);
    expect(answer.json().error).toBe("machine_exists");
    // terminal like without a limit: the grant is consumed, not left waiting
    const next = await poll(again);
    expect(next.json().error).toBe("expired_token");
  });

  it("keeps the grant approved: the same machine gets its device once a slot is free", async () => {
    const waiting = await approved("m4");
    expect((await poll(waiting)).statusCode).toBe(403);
    await pool.query(
      `UPDATE devices SET revoked_at = now() WHERE name = 'm1' AND revoked_at IS NULL`);
    const ready = await poll(waiting);
    expect(ready.statusCode, ready.body).toBe(200);
    expect(await live()).toBe(2);
  });

  it("does not count a provisional device past its activation deadline", async () => {
    await pool.query(
      `UPDATE devices SET activated_at = NULL, activate_deadline = now() - interval '1 minute'
        WHERE name = 'm2'`);
    const ready = await poll(await approved("m5"));
    expect(ready.statusCode, ready.body).toBe(200);
  });

  it("never passes the limit when machines poll at the same moment", async () => {
    await pool.query("UPDATE devices SET revoked_at = now() WHERE revoked_at IS NULL");
    const codes = await Promise.all(["r1", "r2", "r3", "r4", "r5"].map(approved));
    const answers = await Promise.all(codes.map((code) => poll(code)));
    const statuses = answers.map((answer) => answer.statusCode).sort();
    expect(statuses).toEqual([200, 200, 403, 403, 403]);
    expect(await live()).toBe(2);
  });
});
