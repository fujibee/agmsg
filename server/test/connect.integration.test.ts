import { randomBytes } from "node:crypto";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { migrate } from "../src/db.js";

// POST /v1/connect registers a team the client already owns: it writes the team
// row, its opening policy, and the roster, then returns the capability snapshot.
// The client mints every id, so the route takes no credential and scopes to no
// existing team.
const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;

describeDatabase("POST /v1/connect", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;

  const config: Config = {
    databaseUrl: databaseUrl ?? "",
    host: "127.0.0.1",
    port: 8788,
    logLevel: "silent",
    retentionMaxLiveMessages: null,
  };

  const teamId = "0198c200-0000-7000-8000-0000000000aa";
  const memberA = "0198c200-0000-7000-8000-0000000000b1";
  const memberB = "0198c200-0000-7000-8000-0000000000b2";
  const headers = {
    "content-type": "application/json",
    "agmsg-protocol-version": "1",
  };
  const body = {
    team_id: teamId,
    team_name: "connect-team",
    members: [
      { member_id: memberA, name: "worker-1" },
      { member_id: memberB, name: "worker-2" },
    ],
  };

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({
      connectionString: databaseUrl,
      options: `-c search_path=${schema}`,
    });
    await migrate(pool);
    app = createApp(pool, config);
    await app.ready();
  });

  afterAll(async () => {
    await app?.close();
    await admin?.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await pool?.end();
    await admin?.end();
  });

  it("registers a client-owned team and returns its capabilities", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/v1/connect",
      headers,
      payload: body,
    });
    expect(response.statusCode).toBe(200);
    expect(response.headers["agmsg-protocol-version"]).toBe("1");
    const json = response.json();
    // The capability snapshot the client reads back (same fields as
    // GET /v1/capabilities), which is only computable because the policy row
    // below was written.
    expect(json).toMatchObject({
      protocol_version: 1,
      team_id: teamId,
      team_name: "connect-team",
      min_available_seq: "0",
    });
    expect(typeof json.server_instance_id).toBe("string");

    // All four writes landed.
    const team = await pool.query<{ team_name: string }>(
      "SELECT team_name FROM teams WHERE team_id = $1",
      [teamId],
    );
    expect(team.rows[0]?.team_name).toBe("connect-team");
    const policy = await pool.query(
      "SELECT 1 FROM team_policy_history WHERE team_id = $1",
      [teamId],
    );
    expect(policy.rowCount).toBe(1);
    const members = await pool.query<{ name: string }>(
      "SELECT name FROM members WHERE team_id = $1 ORDER BY name",
      [teamId],
    );
    expect(members.rows.map((row) => row.name)).toEqual(["worker-1", "worker-2"]);
    const history = await pool.query(
      "SELECT 1 FROM member_identity_history WHERE team_id = $1",
      [teamId],
    );
    expect(history.rowCount).toBe(2);
  });

  it("refuses a second connect for the same team_id with 409, not a raw 500", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/v1/connect",
      headers,
      payload: body,
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("team-already-exists");
  });

  it("a repeat connect writes nothing at all, declaration included", async () => {
    // This route takes no credential, and its safety has always rested on a
    // repeat connect changing nothing about an existing team. A backfill here
    // would break that: anyone who knows a team_id could fix the profile before
    // the machine that owns the team, and 'none' fixed first is the direction
    // that hurts — a real second machine would then be told its sealed team is
    // plaintext.
    await pool.query("UPDATE teams SET cipher_profile = NULL WHERE team_id = $1", [teamId]);

    const response = await app.inject({
      method: "POST",
      url: "/v1/connect",
      headers,
      payload: { ...body, cipher_profile: "age-v1" },
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("team-already-exists");

    const after = await pool.query<{ cipher_profile: string | null }>(
      "SELECT cipher_profile FROM teams WHERE team_id = $1",
      [teamId],
    );
    expect(after.rows[0]?.cipher_profile).toBeNull();
  });

  it("rejects a roster with duplicate member names before touching the database", async () => {
    const response = await app.inject({
      method: "POST",
      url: "/v1/connect",
      headers,
      payload: {
        team_id: "0198c200-0000-7000-8000-0000000000cc",
        team_name: "dup-team",
        members: [
          { member_id: "0198c200-0000-7000-8000-0000000000d1", name: "same" },
          { member_id: "0198c200-0000-7000-8000-0000000000d2", name: "same" },
        ],
      },
    });
    expect(response.statusCode).toBe(400);
    // The rejected team was never written.
    const team = await pool.query(
      "SELECT 1 FROM teams WHERE team_id = $1",
      ["0198c200-0000-7000-8000-0000000000cc"],
    );
    expect(team.rowCount).toBe(0);
  });

  it("refuses concurrent duplicate connects with 409, never a raw 500", async () => {
    // Several connects for the same, not-yet-registered team_id in flight at
    // once — the retry-after-timeout case, where a client's later attempt races
    // its own earlier one. Exactly one wins; every loser is a uniqueness
    // conflict (409), never a server error. A check-then-insert lets multiple
    // reads miss and the losing INSERTs raise a raw primary-key violation (500).
    // Run a few rounds with distinct ids to make the race window reliably open.
    for (let round = 0; round < 5; round += 1) {
      const raceTeam = `0198c210-0000-7000-8000-00000000${round.toString().padStart(4, "0")}`;
      const payload = {
        team_id: raceTeam,
        team_name: `race-team-${round}`,
        members: [{ member_id: `0198c211-0000-7000-8000-00000000${round.toString().padStart(4, "0")}`, name: "solo" }],
      };
      const responses = await Promise.all(
        Array.from({ length: 6 }, () =>
          app.inject({ method: "POST", url: "/v1/connect", headers, payload }),
        ),
      );
      const statuses = responses.map((response) => response.statusCode).sort();
      expect(statuses).toEqual([200, 409, 409, 409, 409, 409]);
      for (const response of responses) {
        if (response.statusCode !== 200) {
          expect(response.json().error.code).toBe("team-already-exists");
        }
      }
    }
  });
});
