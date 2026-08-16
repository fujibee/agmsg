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
import { migrate } from "../src/db.js";
import { postMessages, retainThrough } from "../src/storage.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;
const execFileAsync = promisify(execFile);

describeDatabase("remote storage HTTP API v1", () => {
  const schema = `agmsg_test_${randomBytes(8).toString("hex")}`;
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
    retentionMaxLiveMessages: null,
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
    // No credential: the data plane takes the team from its header alone.
    headers = {
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

  // Puts the shared team back into a state where a fresh message can be stored.
  // The cases above deliberately break it — one empties the cipher policy, one
  // exhausts the sequence — and they run first, so a declaration case that did
  // not reset would be asserting on a 403 or a 507 instead of on a stored
  // message.
  async function resetTeamForDeclarationCase(
    declaration: string | null,
  ): Promise<void> {
    await pool.query(
      `UPDATE teams
          SET cipher_profile = $2,
              write_allowed_ciphers = ARRAY['none', 'age-v1']::TEXT[],
              current_seq = (SELECT coalesce(max(team_seq), 0) FROM messages WHERE team_id = $1)
        WHERE team_id = $1`,
      [teamId, declaration],
    );
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

  it("echoes the team on health when asked about one, and stays answerable when not", async () => {
    // Two questions share this route. "Is the server up" is asked before any
    // team exists — by an operator, a probe, a client that has not connected —
    // so the header is optional and its absence must not be an error. "Am I
    // still bound to the team I think I am" comes from a configured client,
    // which always has one; that answer is what makes the client's check
    // possible at all.
    // The provisioned team, so the answer comes from a row that exists.
    const withTeam = await app.inject({
      method: "GET",
      url: "/v1/health",
      headers: { "Agmsg-Team-ID": teamId },
    });
    expect(withTeam.statusCode).toBe(200);
    expect(withTeam.json()).toMatchObject({ status: "ok", team_id: teamId });

    // The case that separates a real answer from an echo: a well-formed id this
    // server does not have. Still 200 — health is a liveness answer, and an edge
    // routing by team cannot always turn "no such team" into a status code — but
    // with no team_id. Echoing the header would make this indistinguishable from
    // the provisioned case, and the client would compare its own value with
    // itself and call it agreement.
    const unknown = await app.inject({
      method: "GET",
      url: "/v1/health",
      headers: { "Agmsg-Team-ID": "018f3f7e-0000-7000-8000-0000000000c1" },
    });
    expect(unknown.statusCode).toBe(200);
    expect(unknown.json()).toMatchObject({ status: "ok" });
    expect(unknown.json()).not.toHaveProperty("team_id");

    // Without the header: still 200, and no team_id invented. A client that
    // sends the header and gets nothing back treats that as disagreement, so
    // answering with someone else's team would be worse than answering with
    // none.
    const withoutTeam = await app.inject({ method: "GET", url: "/v1/health" });
    expect(withoutTeam.statusCode).toBe(200);
    expect(withoutTeam.json()).not.toHaveProperty("team_id");

    // A malformed header is a bad request, not a dead database. The 503 handler
    // wraps everything thrown inside the route, so validating in there would
    // report "database unavailable" for a client's typo.
    const malformed = await app.inject({
      method: "GET",
      url: "/v1/health",
      headers: { "Agmsg-Team-ID": "not-a-uuid" },
    });
    expect(malformed.statusCode).toBe(400);
  });

  it("reports database unavailable only when the connection itself fails, not for a failure after connecting (#705)", async () => {
    // Negative control, both directions -- proving the two are actually told
    // apart, not that one of them merely happens to be untested.

    // Direction 1: the database really is unreachable.
    const unreachablePool = new Pool({
      host: "127.0.0.1",
      port: 1, // nothing listens here
      connectionTimeoutMillis: 500,
    });
    const unreachableApp = createApp(unreachablePool, config);
    await unreachableApp.ready();
    try {
      const response = await unreachableApp.inject({ method: "GET", url: "/v1/health" });
      expect(response.statusCode).toBe(503);
      expect(response.json()).toMatchObject({
        status: "unavailable",
        database: "unavailable",
      });
    } finally {
      await unreachableApp.close();
      await unreachablePool.end();
    }

    // Direction 2: the connection succeeds, but the query behind it fails --
    // a real, non-hypothetical instance of "something else went wrong". This
    // must not be reported as the database being unavailable; the connection
    // worked fine.
    await pool.query(`ALTER TABLE server_metadata RENAME TO server_metadata_moved`);
    try {
      const response = await app.inject({ method: "GET", url: "/v1/health" });
      expect(response.statusCode).toBe(500);
      expect(response.json()).not.toHaveProperty("database");
      expect(response.json()).toMatchObject({ error: { code: "internal-error" } });
    } finally {
      await pool.query(`ALTER TABLE server_metadata_moved RENAME TO server_metadata`);
    }
  });

  it("answers a name lookup, and refuses more names than it can disambiguate", async () => {
    const lookupName = "lookup-by-name";
    const ids = Array.from({ length: 17 }, (_, index) =>
      `018f3f7e-0000-7000-8000-0000000004${(index + 10).toString()}`);
    await pool.query(
      "INSERT INTO teams(team_id, team_name) SELECT unnest($1::uuid[]), $2",
      [ids.slice(0, 1), lookupName],
    );

    const one = await app.inject({
      method: "GET",
      url: `/v1/teams?name=${encodeURIComponent(lookupName)}`,
      headers: { "agmsg-protocol-version": "1" },
    });
    expect(one.statusCode).toBe(200);
    expect(one.json().teams).toHaveLength(1);
    // Exactly the four agreed fields travel. The roster is absent by design: it
    // lives inside the envelope, so an e2ee team could not offer it and a
    // plaintext one offering it anyway would be the better-featured choice.
    expect(Object.keys(one.json().teams[0]).sort()).toEqual([
      "current_seq", "registered_at", "team_id", "team_name",
    ]);

    // One past the bound. The answer has to be an error, not the first sixteen:
    // a caller cannot tell whether a truncated list contains its own team, so it
    // would be choosing from a set that may not hold the right answer.
    await pool.query(
      "INSERT INTO teams(team_id, team_name) SELECT unnest($1::uuid[]), $2",
      [ids.slice(1), lookupName],
    );
    const tooMany = await app.inject({
      method: "GET",
      url: `/v1/teams?name=${encodeURIComponent(lookupName)}`,
      headers: { "agmsg-protocol-version": "1" },
    });
    expect(tooMany.statusCode).toBe(409);
    expect(tooMany.json().error.code).toBe("team-name-match-limit-exceeded");
  });

  it("requires a matching protocol and a valid team ID, with no data-plane credential", async () => {
    const noVersion = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: { "agmsg-team-id": teamId },
    });
    expect(noVersion.statusCode).toBe(426);
    expect(noVersion.json().error.code).toBe("unsupported-protocol-version");

    // The data plane does not authenticate: a valid protocol + team id, with no
    // Authorization, succeeds. Reaching the server is the permission (see
    // scopedTeamId / docs/design/remote-sync.md).
    const noAuth = await app.inject({
      method: "GET",
      url: "/v1/members",
      headers: {
        "agmsg-protocol-version": "1",
        "agmsg-team-id": teamId,
      },
    });
    expect(noAuth.statusCode).toBe(200);
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

  it("pages by numeric sequence, not lexical order, past ten messages", async () => {
    // The pull cursor is `team_seq > $after`; passing $after as text coerced the
    // comparison and ORDER BY to string order (1, 10, 11, ..., 2, ...), so paging
    // stalled at "9" once a team crossed ten messages — invisible under ten, and
    // first seen in dogfood at ~80. A dedicated team keeps these twelve messages
    // out of the shared team's sequence, which other tests assert exact values on.
    const orderTeam = "018f3f7e-0000-7000-8000-0000000000a1";
    await pool.query(`INSERT INTO teams (team_id, team_name) VALUES ($1, 'order-team')`, [orderTeam]);
    await pool.query(
      `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
         accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none','age-v1']::TEXT[])`,
      [orderTeam],
    );
    const entries = Array.from({ length: 12 }, (_, i) =>
      message(`900e8400-e29b-41d4-a716-4466554400${(i + 10).toString().padStart(2, "0")}`, `m${i}`));
    await postMessages(pool, orderTeam, entries);

    const orderHeaders = { ...headers, "agmsg-team-id": orderTeam };
    const seqs: number[] = [];
    let after = "0";
    for (;;) {
      const page = await app.inject({
        method: "GET", url: `/v1/messages?after=${after}&limit=5`, headers: orderHeaders,
      });
      expect(page.statusCode).toBe(200);
      const body = page.json();
      for (const row of body.messages) seqs.push(Number(row.server_seq));
      after = body.next_after;
      if (!body.has_more) break;
    }
    // Contiguous 1..12 in ascending numeric order — nothing skipped past nine.
    expect(seqs).toEqual(Array.from({ length: 12 }, (_, i) => i + 1));
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
    expect(belowFloor.json().min_available_seq).toBe("4");

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

  it("applies configured live-message retention in the writer transaction", async () => {
    const automaticTeam = "018f3f7e-0000-7000-8000-000000000051";
    await pool.query("INSERT INTO teams(team_id,team_name) VALUES($1,'automatic-retention')",
      [automaticTeam]);
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id,policy_revision,effective_from_seq,
          accepted_envelope_versions,write_allowed_ciphers)
       VALUES($1,0,1,ARRAY[1],ARRAY['none','age-v1']::TEXT[])`,
      [automaticTeam],
    );
    const notices: unknown[] = [];
    const entries = [
      message("750e8400-e29b-41d4-a716-446655440051", "retained-1"),
      message("750e8400-e29b-41d4-a716-446655440052", "live-2"),
      message("750e8400-e29b-41d4-a716-446655440053", "live-3"),
    ];
    const response = await postMessages(pool, automaticTeam, entries, 2n,
      (notice) => notices.push(notice));
    expect(response).toMatchObject({ min_available_seq: "1",
      acks: [{ server_seq: "1" }, { server_seq: "2" }, { server_seq: "3" }] });
    expect(notices).toEqual([{ team_id: automaticTeam, old_floor: "0",
      new_floor: "1", removed_live_rows: 1 }]);
    const stored = await pool.query<{ live: string; tombstones: string; floor: string }>(
      `SELECT (SELECT count(*)::text FROM messages WHERE team_id=$1) AS live,
              (SELECT count(*)::text FROM message_tombstones WHERE team_id=$1) AS tombstones,
              (SELECT min_available_seq::text FROM teams WHERE team_id=$1) AS floor`,
      [automaticTeam],
    );
    expect(stored.rows[0]).toEqual({ live: "2", tombstones: "1", floor: "1" });
    const replay = await postMessages(pool, automaticTeam, [entries[0]!], 2n);
    expect(replay.acks).toEqual([
      { id: entries[0]!.id, server_seq: "1", disposition: "duplicate" },
    ]);
  });

  it("rolls automatic retention back with the triggering message batch", async () => {
    const rollbackTeam = "018f3f7e-0000-7000-8000-000000000052";
    await pool.query("INSERT INTO teams(team_id,team_name) VALUES($1,'retention-rollback')",
      [rollbackTeam]);
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id,policy_revision,effective_from_seq,
          accepted_envelope_versions,write_allowed_ciphers)
       VALUES($1,0,1,ARRAY[1],ARRAY['none','age-v1']::TEXT[])`,
      [rollbackTeam],
    );
    await pool.query(
      `CREATE FUNCTION fail_automatic_retention() RETURNS trigger AS $$
       BEGIN
         IF OLD.team_id = '${rollbackTeam}'::uuid THEN
           RAISE EXCEPTION 'injected automatic retention failure';
         END IF;
         RETURN OLD;
       END;
       $$ LANGUAGE plpgsql`,
    );
    await pool.query(
      `CREATE TRIGGER fail_automatic_retention BEFORE DELETE ON messages
       FOR EACH ROW EXECUTE FUNCTION fail_automatic_retention()`,
    );
    const notices: unknown[] = [];
    await expect(postMessages(pool, rollbackTeam, [
      message("750e8400-e29b-41d4-a716-446655440061", "rollback-1"),
      message("750e8400-e29b-41d4-a716-446655440062", "rollback-2"),
    ], 1n, (notice) => notices.push(notice))).rejects.toThrow(
      /injected automatic retention failure/,
    );
    expect(notices).toEqual([]);
    const state = await pool.query<{
      messages: string; tombstones: string; current: string; floor: string;
    }>(
      `SELECT (SELECT count(*)::text FROM messages WHERE team_id=$1) AS messages,
              (SELECT count(*)::text FROM message_tombstones WHERE team_id=$1) AS tombstones,
              current_seq::text AS current,min_available_seq::text AS floor
         FROM teams WHERE team_id=$1`,
      [rollbackTeam],
    );
    expect(state.rows[0]).toEqual({ messages: "0", tombstones: "0", current: "0", floor: "0" });
    await pool.query("DROP TRIGGER fail_automatic_retention ON messages");
    await pool.query("DROP FUNCTION fail_automatic_retention()");
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

  // Last on purpose: the cases above assert exact sequence numbers against a
  // team they share, so a message stored here would move every one of them.
  // Placing these first is what broke nine of them.
  it("settles an undeclared team's cipher from the first message it stores", async () => {
    // Teams registered before declarations were carried have cipher_profile
    // NULL, and `connect` must not fill it — that route takes no credential, so
    // a write there would let anyone holding a team_id fix the profile ahead of
    // the machine that owns the team. This is where it is settled instead: a
    // route that already writes to the existing team (current_seq), reached by
    // a caller whose message got past the policy check.
    await resetTeamForDeclarationCase(null);

    const settling = message("750e8400-e29b-41d4-a716-4466554400a1", "settles it");
    const response = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [settling] },
    });
    expect(response.statusCode).toBe(200);

    const after = await pool.query<{ cipher_profile: string | null }>(
      "SELECT cipher_profile FROM teams WHERE team_id = $1",
      [teamId],
    );
    expect(after.rows[0]?.cipher_profile).toBe("none");
  });

  it("refuses a batch that disagrees with itself, storing none of it", async () => {
    // cipher_profile exists so a client can decide whether plaintext may be
    // pushed at all. A value that traffic is free to contradict is not a fact
    // about the team, and a safety decision resting on it would be worse than
    // none — it reads as dependable precisely because writes went through. So
    // a mix is refused whole, before anything is stored.
    await resetTeamForDeclarationCase(null);

    const plain = message("750e8400-e29b-41d4-a716-4466554400b1", "plain");
    const sealed = {
      id: "750e8400-e29b-41d4-a716-4466554400b2",
      envelope: {
        v: 1,
        cipher: "age-v1",
        key_id: "epoch-1",
        blob: Buffer.from("opaque").toString("base64"),
      },
    };
    const response = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [plain, sealed] },
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("cipher-profile-mismatch");
    // A refusal a sender can act on.
    expect(response.json().error.details.remedy).toBeTruthy();

    const after = await pool.query<{ cipher_profile: string | null }>(
      "SELECT cipher_profile FROM teams WHERE team_id = $1",
      [teamId],
    );
    expect(after.rows[0]?.cipher_profile).toBeNull();
    // Nothing from the batch landed: a partial store would leave the team
    // holding messages under a cipher it does not use.
    const stored = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM messages WHERE id = ANY($1::uuid[])",
      [[plain.id, sealed.id]],
    );
    expect(stored.rows[0]?.count).toBe("0");
  });

  it("refuses plaintext for a team that declared age-v1, and says what to do", async () => {
    // Reachable by a machine that has done nothing wrong: the team declared
    // age-v1 after it last looked. Blocking the write is right — the server
    // could read it — but "mismatch" alone is not actionable, so the refusal
    // names the declared profile and how to get back in step.
    await resetTeamForDeclarationCase("age-v1");

    const plain = message("750e8400-e29b-41d4-a716-4466554400c1", "plain");
    const response = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [plain] },
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.code).toBe("cipher-profile-mismatch");
    expect(response.json().error.details.cipher_profile).toBe("age-v1");
    expect(response.json().error.details.remedy).toContain("pull");

    const stored = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM messages WHERE id = $1",
      [plain.id],
    );
    expect(stored.rows[0]?.count).toBe("0");
  });

  it("refuses age-v1 for a team that declared none", async () => {
    await resetTeamForDeclarationCase("none");

    const sealed = {
      id: "750e8400-e29b-41d4-a716-4466554400c2",
      envelope: {
        v: 1,
        cipher: "age-v1",
        key_id: "epoch-1",
        blob: Buffer.from("opaque").toString("base64"),
      },
    };
    const response = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [sealed] },
    });
    expect(response.statusCode).toBe(409);
    expect(response.json().error.details.cipher_profile).toBe("none");

    const stored = await pool.query<{ count: string }>(
      "SELECT count(*)::text AS count FROM messages WHERE id = $1",
      [sealed.id],
    );
    expect(stored.rows[0]?.count).toBe("0");
  });

  it("leaves an existing declaration alone even when traffic agrees with it", async () => {
    // Traffic that disagrees is refused above, so the remaining question is
    // whether an agreeing batch can still rewrite the column — it must not. The
    // fill is `IS NULL` only: a declared team is settled, and changing it is a
    // declaration, never a side effect of sending.
    await resetTeamForDeclarationCase("none");

    const later = message("750e8400-e29b-41d4-a716-4466554400a2", "plaintext");
    const response = await app.inject({
      method: "POST",
      url: "/v1/messages",
      headers,
      payload: { messages: [later] },
    });
    expect(response.statusCode).toBe(200);

    const after = await pool.query<{ cipher_profile: string | null }>(
      "SELECT cipher_profile FROM teams WHERE team_id = $1",
      [teamId],
    );
    expect(after.rows[0]?.cipher_profile).toBe("none");
  });
});
