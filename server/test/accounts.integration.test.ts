import { randomBytes } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import { insertDevice } from "../src/accounts/capability.js";
import type { Config } from "../src/config.js";
import { migrate } from "../src/db.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

const teamA = "018f3f7e-0000-7000-8000-0000000000a1";
const teamB = "018f3f7e-0000-7000-8000-0000000000b2";
const missing = "018f3f7e-0000-7000-8000-0000000000c3";
const wire = { "agmsg-protocol-version": "1" };

// Every route the accounts profile adds. In the open profile none of them may
// exist at all: this data plane is also mounted in-process by other hosts from a
// pinned dependency, so a stray GET /v1/devices here would reach a host that
// serves its own when the pin moves.
const accountsRoutes: Array<[string, string]> = [
  ["GET", "/v1/devices"],
  ["POST", "/v1/devices"],
  ["POST", "/v1/device/code"],
  ["POST", "/v1/device/token"],
  ["POST", "/v1/device/activate"],
  ["GET", "/approve"],
  ["GET", "/t/agsy_00000000_" + "A".repeat(43) + "/v1/health"],
];

describeDatabase("accounts profile", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  let admin: Pool;
  let pool: Pool;
  let live: { deviceId: string; secret: string };
  let provisional: { deviceId: string; secret: string };
  let revoked: { deviceId: string; secret: string };
  let otherTeam: { deviceId: string; secret: string };

  const config = (profile: "open" | "accounts"): Config => ({
    profile,
    ownerSecret: profile === "accounts" ? "0123456789abcdef0123456789abcdef" : null,
    publicUrl: profile === "accounts" ? "https://agmsg.test" : null,
    databaseUrl: databaseUrl ?? "",
    host: "127.0.0.1",
    port: 0,
    logLevel: "silent",
    retentionMaxLiveMessages: null,
  });

  async function addTeam(teamId: string, name: string): Promise<void> {
    await pool.query(`INSERT INTO teams (team_id, team_name) VALUES ($1, $2)`, [teamId, name]);
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id, policy_revision, effective_from_seq,
          accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
      [teamId],
    );
  }

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    await addTeam(teamA, "team-a");
    await addTeam(teamB, "team-b");
    live = await insertDevice(pool, { teamId: teamA, name: "laptop", deviceType: "claude-code", active: true });
    provisional = await insertDevice(pool, { teamId: teamA, name: "pending", deviceType: "codex", active: false });
    revoked = await insertDevice(pool, { teamId: teamA, name: "old", deviceType: "codex", active: true });
    await pool.query(`UPDATE devices SET revoked_at = now() WHERE device_id = $1`, [revoked.deviceId]);
    otherTeam = await insertDevice(pool, { teamId: teamB, name: "other", deviceType: "codex", active: true });
  });

  afterAll(async () => {
    await pool.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) throw new Error("refusing to remove an unexpected test schema");
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  describe("open profile", () => {
    it("has none of the accounts routes: not in the route table, and 404 when called", async () => {
      const app = createApp(pool, config("open"));
      await app.ready();
      const table = app.printRoutes({ commonPrefix: false });
      expect(table).not.toMatch(/device/u);
      expect(table).not.toMatch(/\/t\//u);
      expect(table).not.toMatch(/approve/u);
      for (const [method, url] of accountsRoutes) {
        const response = await app.inject({ method: method as "GET", url, headers: wire });
        expect(response.statusCode, `${method} ${url}`).toBe(404);
      }
      await app.close();
    });

    it("lists no features on health or capabilities", async () => {
      const app = createApp(pool, config("open"));
      await app.ready();
      expect((await app.inject({ method: "GET", url: "/v1/health" })).json().features).toEqual([]);
      const caps = await app.inject({
        method: "GET", url: "/v1/capabilities", headers: { ...wire, "agmsg-team-id": teamA },
      });
      expect(caps.statusCode).toBe(200);
      expect(caps.json().features).toEqual([]);
      await app.close();
    });
  });

  describe("accounts profile", () => {
    let app: ReturnType<typeof createApp>;
    beforeAll(async () => {
      app = createApp(pool, config("accounts"));
      await app.ready();
    });
    afterAll(async () => { await app.close(); });

    const at = (secret: string, path: string, headers: Record<string, string> = {}) =>
      app.inject({ method: "GET", url: `/t/${secret}${path}`, headers: { ...wire, ...headers } });

    it("answers health at the origin with the origin features, no credential needed", async () => {
      const response = await app.inject({ method: "GET", url: "/v1/health" });
      expect(response.statusCode).toBe(200);
      expect(response.json().features).toEqual(["device-approval"]);
      expect(response.headers["agmsg-protocol-version"]).toBe("1");
    });

    it("has no bare /v1 data route", async () => {
      for (const url of ["/v1/capabilities", "/v1/members", "/v1/messages", "/v1/teams", `/v1/teams/${teamA}`]) {
        const response = await app.inject({ method: "GET", url, headers: { ...wire, "agmsg-team-id": teamA } });
        expect(response.statusCode, url).toBe(404);
      }
      const connect = await app.inject({ method: "POST", url: "/v1/connect", headers: wire, payload: {} });
      expect(connect.statusCode).toBe(404);
    });

    it("resolves a live secret to its team without any team header, and lists the team features", async () => {
      const response = await at(live.secret, "/v1/capabilities");
      expect(response.statusCode).toBe(200);
      expect(response.json().team_id).toBe(teamA);
      expect(response.json().features).toEqual(["devices"]);
    });

    it("answers an unknown, malformed, provisional and revoked secret identically", async () => {
      const unknown = "agsy_00000000_" + "A".repeat(43);
      const answers = [];
      for (const secret of [unknown, "not-a-secret", provisional.secret, revoked.secret]) {
        const response = await at(secret, "/v1/capabilities");
        answers.push({ status: response.statusCode, body: response.body });
      }
      expect(answers[0]?.status).toBe(401);
      for (const answer of answers) expect(answer).toEqual(answers[0]);
      expect(JSON.parse(answers[0]?.body ?? "{}").error.code).toBe("unauthenticated");
    });

    it("refuses a request for another team exactly like a request for a team that does not exist", async () => {
      const other = await at(live.secret, "/v1/capabilities", { "agmsg-team-id": teamB });
      const none = await at(live.secret, "/v1/capabilities", { "agmsg-team-id": missing });
      expect(other.statusCode).toBe(404);
      expect(none.statusCode).toBe(404);
      expect(other.json().error.code).toBe(none.json().error.code);
      expect(other.json().error.message).toBe(none.json().error.message);
      // the whole body, not just the code: nothing may echo which team was asked for
      expect(other.body).toBe(none.body);
      expect(other.body).not.toContain("team-b");

      const pathOther = await at(live.secret, `/v1/teams/${teamB}`);
      const pathNone = await at(live.secret, `/v1/teams/${missing}`);
      expect(pathOther.statusCode).toBe(404);
      expect(pathNone.statusCode).toBe(404);
      expect(pathOther.json().error.code).toBe(pathNone.json().error.code);
      expect(pathOther.body).toBe(pathNone.body);
    });

    it("keeps one team per secret: the other team's device sees only its own", async () => {
      const response = await at(otherTeam.secret, "/v1/capabilities");
      expect(response.json().team_id).toBe(teamB);
      expect((await at(otherTeam.secret, "/v1/capabilities", { "agmsg-team-id": teamA })).statusCode).toBe(404);
    });

    it("refuses a name lookup across teams and a connect for another team", async () => {
      const lookup = await at(live.secret, "/v1/teams?name=team-b");
      expect(lookup.statusCode).toBe(404);
      const connect = await app.inject({
        method: "POST", url: `/t/${live.secret}/v1/connect`,
        headers: { ...wire, "content-type": "application/json" },
        payload: { team_id: teamB },
      });
      expect(connect.statusCode).toBe(404);
    });

    it("serves the team's own path and history under its secret", async () => {
      const own = await at(live.secret, `/v1/teams/${teamA}`);
      expect(own.statusCode).toBe(200);
      expect(own.json().team_id).toBe(teamA);
      const history = await at(live.secret, `/v1/teams/${teamA}/messages?after=0`);
      expect(history.statusCode).toBe(200);
    });

    it("does not reveal which teams exist through the open health probe", async () => {
      const known = await app.inject({ method: "GET", url: "/v1/health", headers: { ...wire, "agmsg-team-id": teamA } });
      const unknown = await app.inject({ method: "GET", url: "/v1/health", headers: { ...wire, "agmsg-team-id": missing } });
      expect(known.statusCode).toBe(200);
      expect(known.json().team_id).toBeUndefined();
      expect({ ...known.json(), server_instance_id: "x" }).toEqual({ ...unknown.json(), server_instance_id: "x" });
    });

    it("never writes a secret into the request log", async () => {
      const lines: string[] = [];
      const logged = createApp(pool, { ...config("accounts"), logLevel: "info" }, {
        logStream: { write: (line) => { lines.push(line); } },
      });
      await logged.ready();
      await logged.inject({ method: "GET", url: `/t/${live.secret}/v1/capabilities`, headers: wire });
      await logged.inject({ method: "GET", url: `/t/${revoked.secret}/v1/capabilities`, headers: wire });
      await logged.inject({ method: "GET", url: `/t/${live.secret}/v1/no-such-route`, headers: wire });
      await logged.inject({ method: "GET", url: `/t/${live.secret}/v1/teams/not-a-uuid`, headers: wire });
      await logged.close();
      const text = lines.join("");
      expect(text).toContain("/t/[REDACTED]/v1/capabilities");
      expect(text).not.toContain(live.secret);
      expect(text).not.toContain(revoked.secret);
      // the whole 43-character secret body, not a piece of it (the body can itself
      // contain an underscore, so splitting on "_" would test a fragment)
      expect(text).not.toContain(live.secret.slice(live.secret.indexOf("_", 5) + 1));
    });
  });
});
