import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import {
  createTeam,
  exchangePairingToken,
  issuePairingToken,
} from "../src/credentials.js";
import { migrate } from "../src/db.js";
import { retainThrough } from "../src/storage.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;
const execFileAsync = promisify(execFile);

describeDatabase("remote storage HTTP API v1", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
  let token: string;
  const teamId = "018f3f7e-0000-7000-8000-000000000001";
  const memberId = "018f3f7e-0000-7000-8000-000000000010";
  const registrationId = "018f3f7e-0000-7000-8000-000000000011";
  const installationId = "018f3f7e-0000-7000-8000-000000000012";
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;

  const config: Config = {
    databaseUrl: databaseUrl ?? "",
    host: "127.0.0.1",
    port: 8787,
    logLevel: "silent",
  };

  let headers: Record<string, string>;

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({
      connectionString: databaseUrl,
      options: `-c search_path=${schema}`,
    });
    await migrate(pool);
    await pool.query(
      `INSERT INTO teams (team_id, team_name) VALUES ($1, 'example-team')`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id, policy_revision, effective_from_seq,
          accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO members (team_id, member_id, name)
       VALUES ($1, $2, 'worker-1')`,
      [teamId, memberId],
    );
    await pool.query(
      `INSERT INTO registrations
         (team_id, registration_id, member_id, installation_id, type)
       VALUES ($1, $2, $3, $4, 'codex')`,
      [teamId, registrationId, memberId, installationId],
    );
    const issued = await issuePairingToken(pool, teamId);
    token = String((await exchangePairingToken(pool, issued.token)).credential);
    headers = {
      authorization: `Bearer ${token}`,
      "agmsg-protocol-version": "1",
      "agmsg-team-id": teamId,
    };
    app = createApp(pool, config);
    await app.ready();
  });

  afterAll(async () => {
    await app.close();
    await pool.end();
    if (!/^agmsg_test_[0-9a-f]{16}$/.test(schema)) {
      throw new Error("refusing to remove an unexpected test schema");
    }
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
  });

  function message(id: string, text: string) {
    const plaintext = JSON.stringify({
      body: text,
      created_at: "2026-07-20T06:30:00.000000Z",
      from_agent: "leader",
      to_agent: "worker-1",
    });
    return {
      id,
      envelope: {
        v: 1,
        cipher: "none",
        key_id: null,
        blob: Buffer.from(plaintext).toString("base64"),
      },
    };
  }

  it("reports readiness and fixes the response protocol version", async () => {
    const response = await app.inject({ method: "GET", url: "/v1/health" });
    expect(response.statusCode).toBe(200);
    expect(response.headers["agmsg-protocol-version"]).toBe("1");
    expect(response.json()).toMatchObject({
      status: "ok",
      protocol: { supported_versions: [1] },
      database: "ok",
    });
  });

  it("requires matching protocol, credentials, and immutable team ID", async () => {
    const noVersion = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: { authorization: `Bearer ${token}`, "agmsg-team-id": teamId },
    });
    expect(noVersion.statusCode).toBe(426);
    expect(noVersion.json().error.code).toBe("unsupported-protocol-version");

    const noAuth = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: {
        "agmsg-protocol-version": "1",
        "agmsg-team-id": teamId,
      },
    });
    expect(noAuth.statusCode).toBe(401);
  });

  it("stores a batch atomically and returns complete input-order acknowledgements", async () => {
    const first = message("550e8400-e29b-41d4-a716-446655440000", "first");
    const response = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [first, first] },
    });
    expect(response.statusCode).toBe(200);
    expect(response.json().acks).toEqual([
      { id: first.id, server_seq: "1", disposition: "stored" },
      { id: first.id, server_seq: "1", disposition: "duplicate" },
    ]);

    const replay = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [first] },
    });
    expect(replay.json().acks[0]).toEqual({
      id: first.id,
      server_seq: "1",
      disposition: "duplicate",
    });

    const conflict = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [
          message("750e8400-e29b-41d4-a716-446655440001", "would-roll-back"),
          message(first.id, "different"),
        ],
      },
    });
    expect(conflict.statusCode).toBe(409);
    expect(conflict.json()).toMatchObject({
      team_id: teamId,
      error: { code: "message-uuid-conflict" },
    });

    const count = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM messages WHERE team_id = $1",
      [teamId],
    );
    expect(count.rows[0]?.count).toBe("1");
  });

  it("allocates team sequence without a rollback gap and pages one snapshot", async () => {
    const second = message("750e8400-e29b-41d4-a716-446655440002", "second");
    const stored = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [second] },
    });
    expect(stored.json().acks[0].server_seq).toBe("2");

    const page = await app.inject({
      method: "GET",
      url: "/v1/messages?after=0&limit=1",
      headers,
    });
    expect(page.statusCode).toBe(200);
    expect(page.json()).toMatchObject({
      next_after: "1",
      has_more: true,
      messages: [{ server_seq: "1" }],
    });
    expect(page.json().messages[0].server_received_at).toMatch(
      /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/,
    );
  });

  it("advertises one-snapshot capabilities and operator-provisioned members", async () => {
    const capabilities = await app.inject({
      method: "GET",
      url: "/v1/capabilities",
      headers,
    });
    expect(capabilities.statusCode).toBe(200);
    expect(capabilities.headers["cache-control"]).toBe("no-store");
    expect(capabilities.json()).toMatchObject({
      current_seq: "2",
      next_sequence_boundary: "3",
      accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none", "age-v1"],
      policy_revision: "0",
      effective_from_seq: "1",
      policy_history: [{ policy_revision: "0", effective_from_seq: "1" }],
    });

    const members = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers,
    });
    expect(members.json()).toMatchObject({
      members_revision: "0",
      members: [
        {
          member_id: memberId,
          name: "worker-1",
          registrations: [{ registration_id: registrationId, type: "codex" }],
        },
      ],
    });
  });

  it("max-merges and paginates composite read state", async () => {
    const exactId = "750e8400-e29b-41d4-a716-446655440002";
    const firstPage = await app.inject({
      method: "POST",
      url: "/v1/read-state/sync",
      headers,
      payload: {
        updates: [{ member_id: memberId, server_seq: "1", exact_wire_ids: [exactId] }],
        page_after: null,
        page_limit: 1,
      },
    });
    expect(firstPage.statusCode).toBe(200);
    expect(firstPage.headers["cache-control"]).toBe("no-store");
    expect(firstPage.json()).toMatchObject({
      min_available_seq: "0",
      current_seq: "2",
      items: [{ kind: "frontier", member_id: memberId, server_seq: "1" }],
      next_page_after: { member_id: memberId, kind: "frontier" },
      has_more: true,
    });

    const secondPage = await app.inject({
      method: "POST",
      url: "/v1/read-state/sync",
      headers,
      payload: {
        updates: [],
        page_after: firstPage.json().next_page_after,
        page_limit: 1,
      },
    });
    expect(secondPage.json()).toMatchObject({
      items: [{ kind: "exact", member_id: memberId, wire_id: exactId }],
      next_page_after: null,
      has_more: false,
    });

    const absorbed = await app.inject({
      method: "POST",
      url: "/v1/read-state/sync",
      headers,
      payload: {
        updates: [{ member_id: memberId, server_seq: "2", exact_wire_ids: [] }],
        page_after: null,
        page_limit: 10,
      },
    });
    expect(absorbed.json()).toMatchObject({
      items: [{ kind: "frontier", member_id: memberId, server_seq: "2" }],
      has_more: false,
    });
    const exactCount = await pool.query<{ count: string }>(
      "SELECT COUNT(*)::text AS count FROM read_exact WHERE team_id=$1",
      [teamId],
    );
    expect(exactCount.rows[0]?.count).toBe("0");

    const future = await app.inject({
      method: "POST",
      url: "/v1/read-state/sync",
      headers,
      payload: {
        updates: [{ member_id: memberId, server_seq: "3", exact_wire_ids: [] }],
        page_after: null,
        page_limit: 10,
      },
    });
    expect(future.statusCode).toBe(400);
    expect(future.json().error.code).toBe("invalid-request");
  });

  it("attributes a team-wide exact overflow to a causal request member", async () => {
    const coveredWire = "750e8400-e29b-41d4-a716-446655440008";
    const causalWire = "750e8400-e29b-41d4-a716-446655440009";
    const coveredMember = "018f3f7e-0000-7000-8000-000000000098";
    const causalMember = "018f3f7e-0000-7000-8000-000000000099";
    const previousSequence = (await pool.query<{ current_seq: string }>(
      "SELECT current_seq::text FROM teams WHERE team_id=$1", [teamId],
    )).rows[0]?.current_seq ?? "0";
    await pool.query("UPDATE teams SET current_seq=GREATEST(current_seq,2) WHERE team_id=$1", [teamId]);
    await pool.query(
      `INSERT INTO message_tombstones(team_id,id,original_team_seq,envelope_digest)
       VALUES($1,$2,1,decode(repeat('00',32),'hex')),
             ($1,$3,2,decode(repeat('11',32),'hex'))`,
      [teamId, coveredWire, causalWire],
    );
    await pool.query(
      `INSERT INTO members(team_id, member_id, name)
       SELECT $1,
         ('018f3f7e-0000-7000-8000-' || lpad(value::text, 12, '0'))::uuid,
         'limit-member-' || value::text
       FROM generate_series(100, 115) AS value`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO members(team_id,member_id,name) VALUES
       ($1,$2,'limit-covered-member'),($1,$3,'limit-causal-member')`,
      [teamId, coveredMember, causalMember],
    );
    await pool.query(
      `INSERT INTO read_exact(team_id, member_id, wire_id)
       SELECT $1,
         ('018f3f7e-0000-7000-8000-' ||
           lpad((100 + ((value - 1) / 4096))::text, 12, '0'))::uuid,
         ('550e8400-e29b-4000-8000-' || lpad(value::text, 12, '0'))::uuid
       FROM generate_series(1, 65536) AS value`,
      [teamId],
    );
    const seeded = await pool.query<{ count: string }>(
      "SELECT COUNT(*)::text AS count FROM read_exact WHERE team_id=$1",
      [teamId],
    );
    expect(seeded.rows[0]?.count).toBe("65536");
    try {
      const overflow = await app.inject({
        method: "POST",
        url: "/v1/read-state/sync",
        headers,
        payload: {
          updates: [
            { member_id: coveredMember, server_seq: "1", exact_wire_ids: [coveredWire] },
            { member_id: causalMember, server_seq: "0", exact_wire_ids: [causalWire] },
          ],
          page_after: null,
          page_limit: 1,
        },
      });
      expect(overflow.statusCode).toBe(409);
      expect(overflow.json().error).toMatchObject({
        code: "read-state-limit-exceeded",
        details: { member_id: causalMember, team_exact_count: "65537" },
      });
    } finally {
      await pool.query(
        `DELETE FROM members WHERE team_id=$1 AND name LIKE 'limit-%'`,
        [teamId],
      );
      await pool.query(
        "DELETE FROM message_tombstones WHERE team_id=$1 AND id=ANY($2::uuid[])",
        [teamId, [coveredWire, causalWire]],
      );
      await pool.query("UPDATE teams SET current_seq=$2 WHERE team_id=$1", [teamId, previousSequence]);
    }
  });

  it("serializes concurrent writers on the team row", async () => {
    const writes = await Promise.all(
      [
        message("750e8400-e29b-41d4-a716-446655440005", "concurrent-a"),
        message("750e8400-e29b-41d4-a716-446655440006", "concurrent-b"),
      ].map((entry) =>
        app.inject({
          method: "POST",
          url: "/v1/messages",
          headers,
          payload: { messages: [entry] },
        }),
      ),
    );
    expect(writes.map((response) => response.statusCode)).toEqual([200, 200]);
    expect(
      writes
        .map((response) => response.json().acks[0].server_seq)
        .sort((left, right) => Number(left) - Number(right)),
    ).toEqual(["3", "4"]);
  });

  it("retains atomically under the writer lock and keeps tombstones idempotent", async () => {
    await pool.query(
      `CREATE FUNCTION fail_tombstone_insert() RETURNS trigger AS $$
       BEGIN RAISE EXCEPTION 'injected retention failure'; END;
       $$ LANGUAGE plpgsql`,
    );
    await pool.query(
      `CREATE TRIGGER fail_tombstone_insert
       BEFORE INSERT ON message_tombstones
       FOR EACH ROW EXECUTE FUNCTION fail_tombstone_insert()`,
    );
    await expect(retainThrough(pool, teamId, 1n)).rejects.toThrow(
      /injected retention failure/,
    );
    const rolledBack = await pool.query<{
      messages: string;
      tombstones: string;
      floor: string;
    }>(
      `SELECT
         (SELECT count(*)::text FROM messages WHERE team_id = $1) AS messages,
         (SELECT count(*)::text FROM message_tombstones WHERE team_id = $1) AS tombstones,
         (SELECT min_available_seq::text FROM teams WHERE team_id = $1) AS floor`,
      [teamId],
    );
    expect(rolledBack.rows[0]).toEqual({ messages: "4", tombstones: "0", floor: "0" });
    await pool.query("DROP TRIGGER fail_tombstone_insert ON message_tombstones");
    await pool.query("DROP FUNCTION fail_tombstone_insert()");

    const concurrent = message("750e8400-e29b-41d4-a716-446655440007", "after-floor");
    const [retained, posted] = await Promise.all([
      retainThrough(pool, teamId, 4n),
      app.inject({
        method: "POST",
        url: "/v1/messages",
        headers,
        payload: { messages: [concurrent] },
      }),
    ]);
    expect(retained).toMatchObject({
      min_available_seq: "4",
      retained_through: "4",
      tombstones_created: "4",
    });
    expect(posted.statusCode).toBe(200);
    expect(posted.json().acks[0].server_seq).toBe("5");

    const readAfterRetention = await app.inject({
      method: "POST",
      url: "/v1/read-state/sync",
      headers,
      payload: { updates: [], page_after: null, page_limit: 10 },
    });
    expect(readAfterRetention.json()).toMatchObject({
      min_available_seq: "4",
      items: [{ kind: "frontier", member_id: memberId, server_seq: "4" }],
    });

    const belowFloor = await app.inject({
      method: "GET",
      url: "/v1/messages?after=0",
      headers,
    });
    expect(belowFloor.statusCode).toBe(410);
    expect(belowFloor.json().error.code).toBe("resync-required");

    const replay = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [message("550e8400-e29b-41d4-a716-446655440000", "first")],
      },
    });
    expect(replay.json().acks[0]).toMatchObject({
      server_seq: "1",
      disposition: "duplicate",
    });

    await pool.query(
      "UPDATE teams SET write_allowed_ciphers = ARRAY[]::TEXT[] WHERE team_id = $1",
      [teamId],
    );
    const duplicateUnderNewPolicy = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [message("550e8400-e29b-41d4-a716-446655440000", "first")],
      },
    });
    expect(duplicateUnderNewPolicy.statusCode).toBe(200);
    expect(duplicateUnderNewPolicy.json().acks[0].disposition).toBe("duplicate");
    const rejectedFresh = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [message("750e8400-e29b-41d4-a716-446655440008", "fresh")] },
    });
    expect(rejectedFresh.statusCode).toBe(403);
    await pool.query(
      "UPDATE teams SET write_allowed_ciphers = ARRAY['none']::TEXT[] WHERE team_id = $1",
      [teamId],
    );

    const invalidVersion = message(
      "550e8400-e29b-41d4-a716-446655440000",
      "first",
    );
    invalidVersion.envelope.v = 0x1_0000_0000;
    const outOfRange = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [invalidVersion] },
    });
    expect(outOfRange.statusCode).toBe(400);
    expect(outOfRange.json().error.code).toBe("invalid-request");
  });

  it("atomically provisions the operator roster and permanently retires IDs", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agmsg-provision-test-"));
    const manifestPath = join(directory, "team.json");
    const provisionTeam = "018f3f7e-0000-7000-8000-000000000101";
    const provisionMember = "018f3f7e-0000-7000-8000-000000000110";
    const provisionRegistration = "018f3f7e-0000-7000-8000-000000000111";
    const connection = new URL(databaseUrl ?? "");
    connection.searchParams.set("options", `-c search_path=${schema}`);
    const environment = {
      ...process.env,
      DATABASE_URL: connection.toString(),
    };
    const runProvision = () =>
      execFileAsync(
        process.execPath,
        ["node_modules/tsx/dist/cli.mjs", "src/provision.ts", manifestPath],
        { cwd: process.cwd(), env: environment },
      );

    try {
      const member = {
        member_id: provisionMember,
        name: "provisioned-worker",
        registrations: [
          {
            registration_id: provisionRegistration,
            installation_id: "018f3f7e-0000-7000-8000-000000000112",
            type: "codex",
          },
        ],
      };
      await writeFile(
        manifestPath,
        JSON.stringify({
          team_id: provisionTeam,
          team_name: "provisioned-team",
          members: [member],
        }),
      );
      const first = await runProvision();
      expect(JSON.parse(first.stdout)).toMatchObject({ members_revision: "0" });

      await pool.query(
        `INSERT INTO read_frontiers(team_id, member_id, server_seq)
         VALUES ($1, $2, 7)`,
        [provisionTeam, provisionMember],
      );
      const reprovisioned = await runProvision();
      expect(JSON.parse(reprovisioned.stdout)).toMatchObject({ members_revision: "1" });
      const preservedReadState = await pool.query<{ server_seq: string }>(
        `SELECT server_seq::text FROM read_frontiers
          WHERE team_id=$1 AND member_id=$2`,
        [provisionTeam, provisionMember],
      );
      expect(preservedReadState.rows[0]?.server_seq).toBe("7");

      await writeFile(
        manifestPath,
        JSON.stringify({
          team_id: provisionTeam,
          team_name: "provisioned-team",
          members: [],
        }),
      );
      const second = await runProvision();
      expect(JSON.parse(second.stdout)).toMatchObject({ members_revision: "2" });
      const retiredReadState = await pool.query<{ count: string }>(
        `SELECT COUNT(*)::text AS count FROM read_frontiers
          WHERE team_id=$1 AND member_id=$2`,
        [provisionTeam, provisionMember],
      );
      expect(retiredReadState.rows[0]?.count).toBe("0");

      await writeFile(
        manifestPath,
        JSON.stringify({
          team_id: provisionTeam,
          team_name: "provisioned-team",
          members: [member],
        }),
      );
      await expect(runProvision()).rejects.toThrow(/retired/);

      await writeFile(
        manifestPath,
        JSON.stringify({
          team_id: provisionTeam,
          team_name: "provisioned-team",
          members: Array.from({ length: 1001 }, (_, index) => ({
            member_id: `018f3f7e-0000-7000-8000-${String(index).padStart(12, "0")}`,
            name: `member-${index}`,
            registrations: [],
          })),
        }),
      );
      await expect(runProvision()).rejects.toThrow(/too_big|1000|Array/u);
    } finally {
      if (!directory.startsWith(join(tmpdir(), "agmsg-provision-test-"))) {
        throw new Error("refusing to remove an unexpected temporary directory");
      }
      await rm(directory, { recursive: true });
    }
  });

  it("onboards devices with one-time pairing and independently revocable credentials", async () => {
    const onboardingTeam = "018f3f7e-0000-7000-8000-000000000201";
    const onboardingName = "self-host-quickstart";
    const connection = new URL(databaseUrl ?? "");
    connection.searchParams.set("options", `-c search_path=${schema}`);
    const environment = { ...process.env, DATABASE_URL: connection.toString() };
    const runAdmin = (...args: string[]) =>
      execFileAsync(
        process.execPath,
        ["node_modules/tsx/dist/cli.mjs", "src/admin.ts", ...args],
        { cwd: process.cwd(), env: environment },
      );

    const created = await runAdmin(
      "team", "create", "--name", onboardingName, "--team-id", onboardingTeam,
    );
    expect(created.stdout).toBe(`${onboardingTeam}\n`);
    expect(created.stderr).toContain(`Created team ${onboardingName}`);

    const jsonTeamId = "018f3f7e-0000-7000-8000-000000000202";
    const jsonCreated = await runAdmin(
      "team", "create", "--name", "json-created-team",
      "--team-id", jsonTeamId, "--json",
    );
    expect(JSON.parse(jsonCreated.stdout)).toEqual({
      team_id: jsonTeamId,
      team_name: "json-created-team",
    });

    const duplicateNameResults = await Promise.allSettled([
      createTeam(pool, "concurrent-name", "018f3f7e-0000-7000-8000-000000000203"),
      createTeam(pool, "concurrent-name", "018f3f7e-0000-7000-8000-000000000204"),
    ]);
    expect(duplicateNameResults.map((result) => result.status).sort()).toEqual([
      "fulfilled",
      "rejected",
    ]);

    await expect(runAdmin(
      "token", "issue", "--team", onboardingName,
      "--endpoint", "ftp://sync.example.test",
    )).rejects.toThrow(/HTTP\(S\)/u);
    const noOrphanToken = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM pairing_tokens WHERE team_id = $1",
      [onboardingTeam],
    );
    expect(noOrphanToken.rows[0]?.count).toBe("0");

    const firstIssue = await runAdmin(
      "token", "issue", "--team", onboardingName,
      "--endpoint", "http://127.0.0.1:8787/",
    );
    expect(firstIssue.stdout).toMatch(
      /^agmsg remote connect --endpoint http:\/\/127\.0\.0\.1:8787 agmsg_pair_[A-Za-z0-9_-]+\n$/u,
    );
    const firstToken = firstIssue.stdout.trim().split(" ").at(-1) ?? "";
    expect(firstIssue.stderr).not.toContain(firstToken);

    const legacyGlobalToken = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: {
        authorization: "Bearer change-this-development-token",
        "agmsg-protocol-version": "1",
        "agmsg-team-id": onboardingTeam,
      },
    });
    expect(legacyGlobalToken.statusCode).toBe(401);

    const exchange = async (pairingToken: string) =>
      app.inject({
        method: "POST",
        url: "/v1/pairing/exchange",
        headers: { "agmsg-protocol-version": "1" },
        payload: { token: pairingToken },
      });
    const firstAttempts = await Promise.all([exchange(firstToken), exchange(firstToken)]);
    expect(firstAttempts.map((response) => response.statusCode).sort()).toEqual([200, 409]);
    const firstExchange = firstAttempts.find((response) => response.statusCode === 200);
    const consumed = firstAttempts.find((response) => response.statusCode === 409);
    expect(firstExchange).toBeDefined();
    expect(consumed?.json().error.code).toBe("pairing-token-consumed");
    if (!firstExchange) throw new Error("pairing exchange did not produce a winner");
    expect(firstExchange.statusCode).toBe(200);
    expect(firstExchange.headers["cache-control"]).toBe("no-store");
    const first = firstExchange.json();
    expect(first).toMatchObject({
      protocol_version: 1,
      remote_team_id: onboardingTeam,
      remote_team_name: onboardingName,
      capabilities: {
        write_allowed_ciphers: ["none", "age-v1"],
        current_seq: "0",
        next_sequence_boundary: "1",
      },
    });
    expect(first.credential).not.toBe(firstToken);
    expect(first.credential_id).toMatch(
      /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u,
    );
    const secretStorage = await pool.query<{
      credential_digest_bytes: number;
      token_digest_bytes: number;
      raw_credential_stored: boolean;
      raw_token_stored: boolean;
    }>(
      `SELECT
         octet_length(c.secret_digest) AS credential_digest_bytes,
         octet_length(p.token_digest) AS token_digest_bytes,
         c.secret_digest = convert_to($3, 'UTF8') AS raw_credential_stored,
         p.token_digest = convert_to($4, 'UTF8') AS raw_token_stored
       FROM credentials c
       JOIN pairing_tokens p
         ON p.team_id = c.team_id AND p.credential_id = c.credential_id
      WHERE c.team_id = $1 AND c.credential_id = $2`,
      [onboardingTeam, first.credential_id, first.credential, firstToken],
    );
    expect(secretStorage.rows[0]).toEqual({
      credential_digest_bytes: 32,
      token_digest_bytes: 32,
      raw_credential_stored: false,
      raw_token_stored: false,
    });
    const credentialHeaders = (secret: string) => ({
      authorization: `Bearer ${secret}`,
      "agmsg-protocol-version": "1",
      "agmsg-team-id": onboardingTeam,
    });
    const authorized = await app.inject({
      method: "GET", url: "/v1/members", headers: credentialHeaders(first.credential),
    });
    expect(authorized.statusCode).toBe(200);
    const canonicalCapabilities = await app.inject({
      method: "GET",
      url: "/v1/capabilities",
      headers: credentialHeaders(first.credential),
    });
    expect(canonicalCapabilities.statusCode).toBe(200);
    expect(first.capabilities).toEqual(canonicalCapabilities.json());
    const wrongTeam = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: {
        ...credentialHeaders(first.credential),
        "agmsg-team-id": teamId,
      },
    });
    expect(wrongTeam.statusCode).toBe(401);

    const secondIssue = await runAdmin(
      "token", "issue", "--team", onboardingTeam,
      "--endpoint", "https://sync.example.test/base", "--json",
    );
    const secondIssued = JSON.parse(secondIssue.stdout);
    expect(secondIssued.command).toBe(
      `agmsg remote connect --endpoint https://sync.example.test/base ${secondIssued.token}`,
    );
    const secondExchange = await exchange(secondIssued.token);
    const second = secondExchange.json();
    expect(second.credential_id).not.toBe(first.credential_id);

    const encrypted = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers: credentialHeaders(second.credential),
      payload: {
        messages: [{
          id: "550e8400-e29b-41d4-a716-446655440201",
          envelope: {
            v: 1,
            cipher: "age-v1",
            key_id: "epoch-1",
            blob: Buffer.from("opaque standard age file").toString("base64"),
          },
        }],
      },
    });
    expect(encrypted.statusCode).toBe(200);
    expect(encrypted.json().acks[0]).toMatchObject({
      server_seq: "1",
      disposition: "stored",
    });

    const cannotRevokeOther = await app.inject({
      method: "POST",
      url: `/v1/credentials/${second.credential_id}/revoke`,
      headers: credentialHeaders(first.credential),
    });
    expect(cannotRevokeOther.statusCode).toBe(403);
    expect(cannotRevokeOther.json().error.code).toBe("credential-scope-violation");
    expect(cannotRevokeOther.json()).toMatchObject({
      server_instance_id: first.server_instance_id,
      team_id: onboardingTeam,
    });
    const revokeWithBody = await app.inject({
      method: "POST",
      url: `/v1/credentials/${first.credential_id}/revoke`,
      headers: credentialHeaders(first.credential),
      payload: {},
    });
    expect(revokeWithBody.statusCode).toBe(400);

    const revokeSelf = () => app.inject({
      method: "POST",
      url: `/v1/credentials/${first.credential_id}/revoke`,
      headers: credentialHeaders(first.credential),
    });
    expect((await revokeSelf()).statusCode).toBe(200);
    expect((await revokeSelf()).statusCode).toBe(200);
    const revokedAuth = await app.inject({
      method: "GET", url: "/v1/members", headers: credentialHeaders(first.credential),
    });
    expect(revokedAuth.statusCode).toBe(401);
    expect((await app.inject({
      method: "GET", url: "/v1/members", headers: credentialHeaders(second.credential),
    })).statusCode).toBe(200);

    const listed = await runAdmin(
      "credential", "list", "--team", onboardingName, "--json",
    );
    expect(JSON.parse(listed.stdout).credentials).toMatchObject([
      { team_id: onboardingTeam, credential_id: first.credential_id, status: "revoked" },
      { team_id: onboardingTeam, credential_id: second.credential_id, status: "active" },
    ]);
    const adminRevoke = await runAdmin(
      "credential", "revoke", "--team", onboardingTeam,
      "--credential-id", second.credential_id, "--json",
    );
    expect(JSON.parse(adminRevoke.stdout)).toMatchObject({
      credential_id: second.credential_id,
      revoked: true,
    });

    const thirdIssue = JSON.parse((await runAdmin(
      "token", "issue", "--team", onboardingTeam,
      "--endpoint", "https://sync.example.test", "--json",
    )).stdout);
    await pool.query(
      "UPDATE pairing_tokens SET expires_at = created_at + interval '1 microsecond' WHERE team_id = $1 AND consumed_at IS NULL",
      [onboardingTeam],
    );
    const expired = await exchange(thirdIssue.token);
    expect(expired.statusCode).toBe(410);
    expect(expired.json().error.code).toBe("pairing-token-expired");

    const racedToken = (await issuePairingToken(pool, onboardingTeam)).token;
    const policyClient = await pool.connect();
    try {
      await policyClient.query("BEGIN");
      await policyClient.query("SELECT 1 FROM teams WHERE team_id = $1 FOR UPDATE", [
        onboardingTeam,
      ]);
      await policyClient.query(
        `UPDATE teams
            SET policy_revision = 1,
                write_allowed_ciphers = ARRAY['age-v1']::TEXT[]
          WHERE team_id = $1`,
        [onboardingTeam],
      );
      await policyClient.query(
        `INSERT INTO team_policy_history
           (team_id, policy_revision, effective_from_seq,
            accepted_envelope_versions, write_allowed_ciphers)
         VALUES ($1, 1, 2, ARRAY[1], ARRAY['age-v1']::TEXT[])`,
        [onboardingTeam],
      );
      const racedExchange = exchange(racedToken);
      await new Promise((resolve) => setTimeout(resolve, 20));
      await policyClient.query("COMMIT");
      const raced = await racedExchange;
      expect(raced.statusCode).toBe(200);
      expect(raced.json().capabilities).toMatchObject({
        protocol_version: 1,
        server_instance_id: raced.json().server_instance_id,
        team_id: onboardingTeam,
        team_name: onboardingName,
        policy_revision: "1",
        effective_from_seq: "2",
        write_allowed_ciphers: ["age-v1"],
        policy_history: [{ policy_revision: "0" }, { policy_revision: "1" }],
      });
    } catch (error) {
      await policyClient.query("ROLLBACK");
      throw error;
    } finally {
      policyClient.release();
    }
  }, 20_000);

  it("rejects duplicate JSON keys and rolls back a sequence-crossing batch", async () => {
    const duplicateKeys = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers: { ...headers, "content-type": "application/json" },
      payload: '{"messages":[],"messages":[]}',
    });
    expect(duplicateKeys.statusCode).toBe(400);

    await pool.query(
      "UPDATE teams SET current_seq = 9223372036854775806 WHERE team_id = $1",
      [teamId],
    );
    const exhausted = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: {
        messages: [
          message("750e8400-e29b-41d4-a716-446655440003", "a"),
          message("750e8400-e29b-41d4-a716-446655440004", "b"),
        ],
      },
    });
    expect(exhausted.statusCode).toBe(507);
    expect(exhausted.json().error.code).toBe("sequence-exhausted");
    const rows = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM messages WHERE id = ANY($1::uuid[])",
      [["750e8400-e29b-41d4-a716-446655440003", "750e8400-e29b-41d4-a716-446655440004"]],
    );
    expect(rows.rows[0]?.count).toBe("0");
  });
});
