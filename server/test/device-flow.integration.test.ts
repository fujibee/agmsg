import { randomBytes } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { insertDevice } from "../src/accounts/capability.js";
import { testConfig } from "./helpers/config.js";
import { migrate } from "../src/db.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

const teamA = "018f3f7e-0000-7000-8000-0000000000a1";
const teamB = "018f3f7e-0000-7000-8000-0000000000b2";
const origin = "https://agmsg.test";
const ownerSecret = "0123456789abcdef0123456789abcdef";
const form = { "content-type": "application/x-www-form-urlencoded" };
const json = { "content-type": "application/json" };

describeDatabase("device flow", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;
  let cookie = "";
  let addressCounter = 0;

  const config = testConfig({
    profile: "accounts", ownerSecret, publicUrl: origin, databaseUrl: databaseUrl ?? "",
  });

  // Each flow comes from its own source address so the per-address limits
  // (which have their own tests) never bleed between cases.
  const address = () => `10.0.${Math.floor(addressCounter / 250)}.${(addressCounter += 1) % 250 + 1}`;

  async function addTeam(teamId: string, name: string): Promise<void> {
    await pool.query(`INSERT INTO teams (team_id, team_name) VALUES ($1, $2)`, [teamId, name]);
    await pool.query(
      `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
         accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
      [teamId],
    );
  }

  const post = (url: string, payload: unknown, remoteAddress: string, headers = json) =>
    app.inject({ method: "POST", url, headers, payload: payload as object, remoteAddress });

  const requestCode = (body: Record<string, unknown>, remoteAddress = address()) =>
    post("/v1/device/code", { client_id: "agmsg-cli", machine_name: "laptop", ...body }, remoteAddress);

  const approve = (userCode: string, extra: Record<string, unknown> = {}, headers: Record<string, string> = {}) =>
    app.inject({
      method: "POST", url: "/v1/device/approve",
      headers: { ...json, origin, cookie, ...headers },
      payload: { user_code: userCode, decision: "approve", ...extra },
      remoteAddress: address(),
    });

  const poll = (deviceCode: string, clientId = "agmsg-cli") =>
    post("/v1/device/token", { device_code: deviceCode, client_id: clientId }, address());

  // Runs a whole grant to a ready token, returning the pieces.
  async function mint(name: string, body: Record<string, unknown> = {}) {
    const code = (await requestCode({ machine_name: name, team_id: teamA, ...body })).json();
    expect((await approve(code.user_code)).statusCode).toBe(200);
    const ready = await poll(code.device_code);
    expect(ready.statusCode, ready.body).toBe(200);
    return { code, ready: ready.json() as { capability_url: string; machine_name: string; scope: string; org: string } };
  }

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    await addTeam(teamA, "team-a");
    await addTeam(teamB, "team-b");
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
    await app.close();
    await pool.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) throw new Error("refusing to remove an unexpected test schema");
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  it("runs code, approval, token and activate, and the URL then reaches the team's data", async () => {
    const { code, ready } = await mint("laptop", { device_type: "claude-code" });
    expect(code.verification_uri).toBe(`${origin}/approve`);
    expect(code.verification_uri_complete).toContain("user_code=");
    expect(ready.scope).toBe("login");
    expect(ready.machine_name).toBe("laptop");
    expect(typeof ready.org).toBe("string");
    expect(ready.capability_url.startsWith(`${origin}/t/agsy_`)).toBe(true);
    const path = ready.capability_url.slice(origin.length);

    const before = await app.inject({ method: "GET", url: `${path}/v1/capabilities`, headers: { "agmsg-protocol-version": "1" } });
    expect(before.statusCode).toBe(401); // provisional until activated
    const activated = await app.inject({
      method: "POST", url: "/v1/device/activate",
      headers: { authorization: `Bearer ${path.split("/")[2]}` },
    });
    expect(activated.statusCode).toBe(200);
    expect(activated.json()).toEqual({ activated: true, machine_name: "laptop" });
    const after = await app.inject({ method: "GET", url: `${path}/v1/capabilities`, headers: { "agmsg-protocol-version": "1" } });
    expect(after.statusCode).toBe(200);
    expect(after.json().team_id).toBe(teamA);

    // activation is idempotent: a lost reply can be retried
    const again = await app.inject({
      method: "POST", url: "/v1/device/activate",
      headers: { authorization: `Bearer ${path.split("/")[2]}` },
    });
    expect(again.statusCode).toBe(200);

    const list = await app.inject({
      method: "GET", url: "/v1/devices", headers: { authorization: `Bearer ${path.split("/")[2]}` },
    });
    expect(list.statusCode).toBe(200);
    const mine = list.json().devices.find((d: { thisMachine: boolean }) => d.thisMachine);
    expect(mine).toMatchObject({ label: "laptop", type: "claude-code", devicePubkey: null, lastFetchAt: null });
  });

  it("keeps a code single-use, and a consumed grant cannot be collected twice", async () => {
    const { code } = await mint("single-use");
    expect((await approve(code.user_code)).statusCode).toBe(409);
    const second = await poll(code.device_code);
    expect(second.statusCode).toBe(400);
    expect(second.json().error).toBe("expired_token");
  });

  it("takes the team from the owner when the machine named none, and refuses one that is not a team", async () => {
    const code = (await requestCode({ machine_name: "no-team" })).json();
    expect((await approve(code.user_code)).json().error).toBe("team_required");
    expect((await approve(code.user_code, { team_id: "018f3f7e-0000-7000-8000-0000000000ff" })).json().error).toBe("unknown_team");
    expect((await approve(code.user_code, { team_id: teamB })).statusCode).toBe(200);
    const ready = (await poll(code.device_code)).json();
    const path = new URL(ready.capability_url).pathname;
    await app.inject({ method: "POST", url: "/v1/device/activate", headers: { authorization: `Bearer ${path.split("/")[2]}` } });
    const caps = await app.inject({ method: "GET", url: `${path}/v1/capabilities`, headers: { "agmsg-protocol-version": "1" } });
    expect(caps.json().team_id).toBe(teamB);
  });

  it("does not let approval swap the team a grant was issued for", async () => {
    const code = (await requestCode({ machine_name: "fixed", team_id: teamA })).json();
    const swapped = await approve(code.user_code, { team_id: teamB });
    expect(swapped.statusCode).toBe(409);
    expect(swapped.json().error).toBe("team_mismatch");
  });

  it("reports pending, then slow_down on an immediate repoll, and denial", async () => {
    const code = (await requestCode({ machine_name: "waiting" })).json();
    expect((await poll(code.device_code)).json().error).toBe("authorization_pending");
    const quick = await poll(code.device_code);
    expect(quick.json()).toEqual({ error: "slow_down", interval: 10 });
    const denied = (await requestCode({ machine_name: "refused" })).json();
    const decision = await app.inject({
      method: "POST", url: "/v1/device/approve", headers: { ...json, origin, cookie },
      payload: { user_code: denied.user_code, decision: "deny" }, remoteAddress: address(),
    });
    expect(decision.statusCode).toBe(200);
    expect((await poll(denied.device_code)).json().error).toBe("access_denied");
  });

  it("refuses a second live device under the same name, and frees the name when a provisional one lapses", async () => {
    await insertDevice(pool, { teamId: teamA, name: "taken", deviceType: "codex", active: true });
    const code = (await requestCode({ machine_name: "taken", team_id: teamA })).json();
    expect((await approve(code.user_code)).statusCode).toBe(200);
    expect((await poll(code.device_code)).json().error).toBe("machine_exists");

    const stale = await insertDevice(pool, { teamId: teamA, name: "lapsed", deviceType: "codex", active: false });
    await pool.query(`UPDATE devices SET activate_deadline = now() - interval '1 minute' WHERE device_id = $1`, [stale.deviceId]);
    const { ready } = await mint("lapsed");
    expect(ready.machine_name).toBe("lapsed");
  });

  it("answers a wrong, foreign-client and expired device code the same way", async () => {
    const code = (await requestCode({ machine_name: "expiring" })).json();
    const wrong = await poll("x".repeat(43));
    const foreign = await poll(code.device_code, "some-other-client");
    await pool.query(`UPDATE device_grants SET expires_at = now() - interval '1 second' WHERE client_id = 'agmsg-cli' AND machine_name = 'expiring'`);
    const expired = await poll(code.device_code);
    for (const answer of [wrong, foreign, expired]) {
      expect(answer.statusCode).toBe(400);
      expect(answer.json()).toEqual({ error: "expired_token" });
    }
  });

  it("refuses a client id that is not on the list", async () => {
    const answer = await requestCode({ client_id: "stranger" });
    expect(answer.statusCode).toBe(400);
    expect(answer.json()).toEqual({ error: "invalid_client" });
  });

  it("limits unknown device codes per address without slowing a real machine's polling", async () => {
    const guesser = "10.77.0.1";
    const guess = () => post("/v1/device/token", { device_code: randomBytes(32).toString("base64url"), client_id: "agmsg-cli" }, guesser);
    for (let i = 0; i < 60; i += 1) expect((await guess()).statusCode).toBe(400);
    expect((await guess()).statusCode).toBe(429);
    expect((await guess()).json()).toEqual({ error: "slow_down" });
    // another address is unaffected, and so is a real code from the same one
    const code = (await requestCode({ machine_name: "patient" }, "10.77.0.2")).json();
    const real = await post("/v1/device/token", { device_code: code.device_code, client_id: "agmsg-cli" }, "10.77.0.2");
    expect(real.json().error).toBe("authorization_pending");
    const blockedReal = await post("/v1/device/token", { device_code: code.device_code, client_id: "agmsg-cli" }, guesser);
    expect(blockedReal.statusCode).toBe(429);
  });

  it("rejects an unknown field and a machine name that could fake page copy", async () => {
    expect((await requestCode({ surprise: 1 })).statusCode).toBe(400);
    expect((await requestCode({ machine_name: " padded" })).statusCode).toBe(400);
    expect((await requestCode({ machine_name: "line\nbreak" })).statusCode).toBe(400);
    expect((await post("/v1/device/token", { device_code: "a", client_id: "b", extra: 1 }, address())).statusCode).toBe(400);
  });

  it("activate refuses unknown and revoked secrets, and /v1/devices needs a live one", async () => {
    const unknown = "agsy_00000000_" + "A".repeat(43);
    const none = await app.inject({ method: "POST", url: "/v1/device/activate", headers: { authorization: `Bearer ${unknown}` } });
    expect(none.statusCode).toBe(401);
    const missing = await app.inject({ method: "POST", url: "/v1/device/activate" });
    expect(missing.statusCode).toBe(401);
    const gone = await insertDevice(pool, { teamId: teamA, name: "gone", deviceType: "codex", active: false });
    await pool.query(`UPDATE devices SET revoked_at = now() WHERE device_id = $1`, [gone.deviceId]);
    const revoked = await app.inject({ method: "POST", url: "/v1/device/activate", headers: { authorization: `Bearer ${gone.secret}` } });
    expect(revoked.statusCode).toBe(410);
    expect((await app.inject({ method: "GET", url: "/v1/devices" })).statusCode).toBe(401);
    expect((await app.inject({ method: "GET", url: "/v1/devices", headers: { authorization: `Bearer ${unknown}` } })).statusCode).toBe(401);
  });

  describe("the owner's side", () => {
    it("refuses approval without a session, from another origin, and with no origin", async () => {
      const code = (await requestCode({ machine_name: "guarded", team_id: teamA })).json();
      const send = (headers: Record<string, string>) => app.inject({
        method: "POST", url: "/v1/device/approve", headers: { ...json, ...headers },
        payload: { user_code: code.user_code, decision: "approve" }, remoteAddress: address(),
      });
      expect((await send({ origin })).statusCode).toBe(401);
      expect((await send({ origin: "https://evil.test", cookie })).statusCode).toBe(403);
      expect((await send({ cookie })).statusCode).toBe(403);
      expect((await send({ origin, cookie: "agmsg_owner=forged" })).statusCode).toBe(401);
      expect((await send({ origin, cookie })).statusCode).toBe(200);
    });

    it("signs in only with the owner secret, and limits attempts per address", async () => {
      const wrong = await app.inject({ method: "POST", url: "/approve/signin", headers: form, payload: "secret=nope", remoteAddress: "10.9.9.9" });
      expect(wrong.statusCode).toBe(401);
      expect(wrong.headers["set-cookie"]).toBeUndefined();
      let last = wrong;
      for (let i = 0; i < 10; i += 1) {
        last = await app.inject({ method: "POST", url: "/approve/signin", headers: form, payload: "secret=nope", remoteAddress: "10.9.9.9" });
      }
      expect(last.statusCode).toBe(429);
      const right = await app.inject({ method: "POST", url: "/approve/signin", headers: form, payload: `secret=${ownerSecret}`, remoteAddress: "10.9.9.9" });
      expect(right.statusCode).toBe(429); // over the limit even with the right secret
    });

    it("sets a session cookie that cannot be read by script or sent cross-site", async () => {
      const signedIn = await app.inject({
        method: "POST", url: "/approve/signin", headers: form,
        payload: `secret=${ownerSecret}&user_code=ABCD-1234`, remoteAddress: address(),
      });
      const setCookie = String(signedIn.headers["set-cookie"]);
      expect(setCookie).toMatch(/HttpOnly/u);
      expect(setCookie).toMatch(/SameSite=Strict/u);
      expect(setCookie).toMatch(/Secure/u);
      expect(signedIn.headers.location).toBe("/approve?user_code=ABCD-1234");
    });

    it("escapes what a machine says about itself on the approval page", async () => {
      const code = (await requestCode({ machine_name: '<script>alert(1)</script>"' })).json();
      const page = await app.inject({
        method: "GET", url: `/approve?user_code=${code.user_code}`, headers: { cookie }, remoteAddress: address(),
      });
      expect(page.statusCode).toBe(200);
      expect(page.body).not.toContain("<script>");
      expect(page.body).toContain("&lt;script&gt;");
      expect(String(page.headers["content-security-policy"])).toContain("default-src 'none'");
      const anonymous = await app.inject({ method: "GET", url: `/approve?user_code=${code.user_code}`, remoteAddress: address() });
      expect(anonymous.body).toContain('type="password"');
      expect(anonymous.body).not.toContain("alert");
    });

    it("decides through the page form too", async () => {
      const code = (await requestCode({ machine_name: "by-form", team_id: teamA })).json();
      const decided = await app.inject({
        method: "POST", url: "/approve/decision", headers: { ...form, origin, cookie },
        payload: `user_code=${encodeURIComponent(code.user_code)}&decision=approve&team_id=${teamA}`, remoteAddress: address(),
      });
      expect(decided.statusCode).toBe(200);
      expect(decided.body).toContain("Approved");
      expect((await poll(code.device_code)).statusCode).toBe(200);
    });
  });
});
