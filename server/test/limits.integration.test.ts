import { randomBytes } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { migrate } from "../src/db.js";

// A configured team limit refuses the connect that would pass it, with a stated
// error, and leaves nothing behind. No limit configured changes nothing.
const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

const headers = {
  "content-type": "application/json",
  "agmsg-protocol-version": "1",
};

function team(n: number) {
  const hex = n.toString(16).padStart(4, "0");
  return {
    team_id: `0198c300-0000-7000-8000-00000000${hex}`,
    team_name: `limit-team-${n}`,
    members: [{ member_id: `0198c301-0000-7000-8000-00000000${hex}`, name: "solo" }],
  };
}

describeDatabase("static limits", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  let admin: Pool;
  let pool: Pool;

  const config = (teams: bigint | null, liveMessages: bigint | null = null): Config => ({
    profile: "open",
    databaseUrl: databaseUrl ?? "",
    host: "127.0.0.1",
    port: 8788,
    logLevel: "silent",
    retentionMaxLiveMessages: liveMessages,
    limits: { devices: null, teams },
  });

  const connect = (app: ReturnType<typeof createApp>, n: number) =>
    app.inject({ method: "POST", url: "/v1/connect", headers, payload: team(n) });

  const count = async () =>
    Number((await pool.query<{ n: string }>("SELECT count(*)::text AS n FROM teams")).rows[0]?.n);

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
  });

  afterAll(async () => {
    await admin?.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await pool?.end();
    await admin?.end();
  });

  it("refuses the connect past the team limit, names the limit, and stores nothing", async () => {
    const app = createApp(pool, config(2n));
    await app.ready();
    try {
      expect((await connect(app, 1)).statusCode).toBe(200);
      expect((await connect(app, 2)).statusCode).toBe(200);
      const refused = await connect(app, 3);
      expect(refused.statusCode).toBe(403);
      expect(refused.json().error).toEqual({
        code: "limit-reached",
        message: "the teams limit of 2 is reached",
        details: { limit: "teams", value: "2" },
      });
      expect(refused.json().team_id).toBe(team(3).team_id);
      expect(await count()).toBe(2);
      const left = await pool.query("SELECT 1 FROM members WHERE team_id = $1", [team(3).team_id]);
      expect(left.rowCount).toBe(0);
    } finally {
      await app.close();
    }
  });

  it("still answers 409 for a team that exists once the limit is reached", async () => {
    const app = createApp(pool, config(2n));
    await app.ready();
    try {
      const again = await connect(app, 1);
      expect(again.statusCode).toBe(409);
      expect(again.json().error.code).toBe("team-already-exists");
    } finally {
      await app.close();
    }
  });

  it("lets a later connect through when the operator raises the limit", async () => {
    const app = createApp(pool, config(3n));
    await app.ready();
    try {
      expect((await connect(app, 3)).statusCode).toBe(200);
      expect(await count()).toBe(3);
    } finally {
      await app.close();
    }
  });

  it("never passes the limit under concurrent connects", async () => {
    const before = await count();
    const app = createApp(pool, config(BigInt(before + 2)));
    await app.ready();
    try {
      const responses = await Promise.all(
        Array.from({ length: 8 }, (_, i) => connect(app, 100 + i)),
      );
      const statuses = responses.map((response) => response.statusCode).sort();
      expect(statuses).toEqual([200, 200, 403, 403, 403, 403, 403, 403]);
      expect(await count()).toBe(before + 2);
    } finally {
      await app.close();
    }
  });

  it("lists the feature and the finite values in capabilities, and adds nothing when none is set", async () => {
    const limited = createApp(pool, config(3n, 100000n));
    await limited.ready();
    const plain = createApp(pool, config(null));
    await plain.ready();
    try {
      const id = team(1).team_id;
      const read = (app: ReturnType<typeof createApp>) => app.inject({
        method: "GET", url: "/v1/capabilities",
        headers: { ...headers, "agmsg-team-id": id },
      });
      const withLimits = (await read(limited)).json();
      expect(withLimits.features).toContain("limits");
      expect(withLimits.limits).toEqual({ teams: "3", live_messages: "100000" });
      const without = (await read(plain)).json();
      expect(without.features).not.toContain("limits");
      expect(without).not.toHaveProperty("limits");
    } finally {
      await limited.close();
      await plain.close();
    }
  });
});
