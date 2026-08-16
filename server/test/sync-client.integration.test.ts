import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { migrate } from "../src/db.js";
import { envelopeDigest } from "../src/protocol.js";
import { retainThrough } from "../src/storage.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;
const execFileAsync = promisify(execFile);
const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));

describeDatabase("Stage-1 polling sync client", () => {
  const schema = `agmsg_sync_${randomBytes(8).toString("hex")}`;
  const teamId = "018f3f7e-0000-7000-8000-000000000101";
  const memberA = "018f3f7e-0000-7000-8000-000000000110";
  const memberB = "018f3f7e-0000-7000-8000-000000000120";
  const localTeam = "dogfood-team";
  const crossTeamId = "018f3f7e-0000-7000-8000-000000000102";
  const crossTeam = "cross-driver-team";
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;
  let serverUrl: string;
  let root: string;
  let storeA: string;
  let storeB: string;
  let crossStoreSqlite: string;
  let crossStoreJsonl: string;
  let connectionA: string;
  let connectionB: string;
  let crossConnectionSqlite: string;
  let crossConnectionJsonl: string;
  let rosterFile: string;

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    // No team is pre-inserted server-side. In the register model the team,
    // its opening policy row, and its members are all created by connectTeam
    // from the connect body — the first machine's `connect` below registers
    // the team it owns. Pre-creating it here (the pairing-era assumption) would
    // make that first connect a 409.
    const config: Config = {
      databaseUrl: databaseUrl ?? "",
      host: "127.0.0.1", port: 8787, logLevel: "silent",
      retentionMaxLiveMessages: null,
    };
    app = createApp(pool, config);
    serverUrl = await app.listen({ host: "127.0.0.1", port: 0 });
    root = await mkdtemp(join(tmpdir(), "agmsg-stage1-sync-"));
    storeA = join(root, "machine-a");
    storeB = join(root, "machine-b");
    crossStoreSqlite = join(root, "cross-sqlite");
    crossStoreJsonl = join(root, "cross-jsonl");
    connectionA = join(root, "connection-a");
    connectionB = join(root, "connection-b");
    crossConnectionSqlite = join(root, "connection-cross-sqlite");
    crossConnectionJsonl = join(root, "connection-cross-jsonl");
    // The first machine for a team owns it: it writes a locally-minted team and
    // `connect` registers that team server-side. A second machine for the same
    // team_id cannot connect again — a repeat team_id is a 409 by design — so it
    // `pull`s the team the first machine registered (#527). That is why the two
    // machines bound to one team_id take different paths here. Each uses the same
    // per-machine environment as the sync operations below (isolated store +
    // connection dir).
    const members = [
      { member_id: memberA, name: "machine-a" },
      { member_id: memberB, name: "machine-b" },
    ];
    const remoteSh = join(repositoryRoot, "scripts/remote.sh");
    const machines: Array<[string, string, string, "connect" | "pull"]> = [
      [storeA, teamId, localTeam, "connect"],
      [storeB, teamId, localTeam, "pull"],
      [crossStoreSqlite, crossTeamId, crossTeam, "connect"],
      [crossStoreJsonl, crossTeamId, crossTeam, "pull"],
    ];
    for (const [store, boundTeamId, boundTeam, mode] of machines) {
      const env = environment(store);
      if (mode === "connect") {
        // The registering machine needs an initialized store (so the connect-
        // time per-team migration has a shared store to move from) and a local
        // team config that connect POSTs to /v1/connect to register.
        const initStore = `. "$1/scripts/lib/storage.sh"
agmsg_storage_load
storage_init "$2" >/dev/null`;
        await execFileAsync("bash", ["-c", initStore, "stage1-test", repositoryRoot, boundTeam],
          { cwd: repositoryRoot, env });
        const teamConfig = join(env.AGMSG_SYNC_CONNECTION_DIR, "teams", boundTeam, "config.json");
        await mkdir(dirname(teamConfig), { recursive: true });
        await writeFile(teamConfig, JSON.stringify({
          name: boundTeam,
          team_id: boundTeamId,
          agents: Object.fromEntries(members.map((m) => [m.name, { member_id: m.member_id }])),
          created_at: new Date().toISOString(),
        }));
        await execFileAsync("bash", [remoteSh, "connect", "--endpoint", serverUrl, boundTeam],
          { cwd: repositoryRoot, env });
      } else {
        await execFileAsync("bash", [remoteSh, "pull", "--endpoint", serverUrl,
          "--team-id", boundTeamId, boundTeam], { cwd: repositoryRoot, env });
      }
    }
    rosterFile = join(root, "local-roster.json");
    await writeFile(rosterFile, JSON.stringify({
      agents: { "machine-a": {}, "machine-b": {} },
    }));
  });

  afterAll(async () => {
    await app.close();
    await pool.end();
    if (!/^agmsg_sync_[0-9a-f]{16}$/.test(schema)) throw new Error("unsafe sync test schema");
    await admin.query(`DROP SCHEMA ${schema} CASCADE`);
    await admin.end();
    if (!root.startsWith(join(tmpdir(), "agmsg-stage1-sync-"))) throw new Error("unsafe sync test root");
    await rm(root, { recursive: true });
  });

  // Where a team's rows live depends on its partition driver. These teams are on
  // the default `shared` partition — nothing here connects through a path that
  // moves them — so this is the one store, the same file the client writes.
  // A team that had moved would answer differently, which is why this asks
  // rather than spelling the path out at each call site.
  function teamStore(store: string, _team = localTeam) {
    return join(store, "messages.db");
  }

  function environment(store: string) {
    const connectionRoot = store === storeA ? connectionA
      : store === storeB ? connectionB
        : store === crossStoreSqlite ? crossConnectionSqlite : crossConnectionJsonl;
    return {
      ...process.env,
      AGMSG_STORAGE_PATH: store,
      AGMSG_STORAGE_DRIVER: store === crossStoreJsonl ? "jsonl" : "sqlite",
      AGMSG_SYNC_CONNECTION_DIR: connectionRoot,
      AGMSG_SYNC_LOCAL_ROSTER_FILE: rosterFile,
      AGMSG_NODE: process.execPath,
      HOME: join(store, "home"),
    };
  }

  async function sync(store: string, ...args: string[]) {
    return execFileAsync("bash", [join(repositoryRoot, "scripts/remote-sync.sh"), ...args], {
      cwd: repositoryRoot,
      env: environment(store),
      maxBuffer: 4 * 1024 * 1024,
    });
  }

  async function localSend(store: string, from: string, to: string, body: string, team = localTeam) {
    // storage_init takes the team even on the shared partition: which store to
    // initialize is a question about a team, and calling it without one reaches
    // the resolver with an empty selector and fails under set -u.
    const script = `. "$1/scripts/lib/storage.sh"
agmsg_storage_load
storage_init "$2" >/dev/null
storage_send "$2" "$3" "$4" "$5"`;
    return execFileAsync("bash", ["-c", script, "stage1-test", repositoryRoot, team, from, to, body], {
      cwd: repositoryRoot,
      env: environment(store),
    });
  }

  async function history(store: string, team = localTeam) {
    const script = `. "$1/scripts/lib/storage.sh"
agmsg_storage_load
storage_history "$2"`;
    const result = await execFileAsync("bash", ["-c", script, "stage1-test", repositoryRoot, team], {
      cwd: repositoryRoot,
      env: environment(store),
    });
    return result.stdout.trim().split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
  }

  async function markRead(store: string, agent: string, id: string) {
    const script = `. "$1/scripts/lib/storage.sh"
agmsg_storage_load
storage_mark_read_batch "$2" "$3" "$4" >/dev/null`;
    await execFileAsync("bash", ["-c", script, "stage2-test", repositoryRoot,
      localTeam, agent, id], { cwd: repositoryRoot, env: environment(store) });
  }

  async function unread(store: string, agent: string) {
    const script = `. "$1/scripts/lib/storage.sh"
agmsg_storage_load
storage_list_unread "$2" "$3"`;
    const result = await execFileAsync("bash", ["-c", script, "stage2-test", repositoryRoot,
      localTeam, agent], { cwd: repositoryRoot, env: environment(store) });
    return result.stdout.trim().split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
  }

  it("synchronizes two isolated AGMSG_STORAGE_PATH stores without echo duplicates", async () => {
    await localSend(storeA, "machine-a", "machine-b", "fixture from machine A");
    const pushedA = await sync(storeA, "once", "--team", localTeam);
    expect(pushedA.stdout).toContain('"event":"push.ack"');
    expect(pushedA.stdout).toContain('"event":"pull.applied"');

    const pulledB = await sync(storeB, "once", "--team", localTeam);
    expect(pulledB.stdout).toContain('"event":"pull.import"');
    expect(await history(storeB)).toMatchObject([
      { from: "machine-a", to: "machine-b", body: "fixture from machine A" },
    ]);
    const receivedOnB = (await history(storeB))[0];
    await markRead(storeB, "machine-b", receivedOnB.id);
    await sync(storeB, "once", "--team", localTeam);
    await sync(storeA, "once", "--team", localTeam);
    expect(await unread(storeA, "machine-b")).toEqual([]);

    await localSend(storeB, "machine-b", "machine-a", "fixture reply from machine B");
    await sync(storeB, "once", "--team", localTeam);
    await sync(storeA, "once", "--team", localTeam);

    const a = await history(storeA);
    const b = await history(storeB);
    expect(a.map((message) => message.body)).toEqual([
      "fixture from machine A", "fixture reply from machine B",
    ]);
    expect(b.map((message) => message.body)).toEqual([
      "fixture from machine A", "fixture reply from machine B",
    ]);

    const futureEnvelope = {
      v: 1, cipher: "future-aead", key_id: "epoch-1",
      blob: Buffer.from("opaque future ciphertext").toString("base64"),
    };
    await pool.query("BEGIN");
    // The next free sequence, read rather than assumed. How many rows the syncs
    // above pushed is not this test's subject — it moves whenever the client's
    // batching or the set of axes it syncs changes, and a literal here turns any
    // such change into a unique-constraint violation with nothing to do with
    // ciphers. Both the team's current_seq and the row land on this position, so
    // the pulled page stays contiguous; a gap fails the engine's continuity
    // check instead of exercising the unreadable envelope.
    const { rows: [head] } = await pool.query<{ next: string }>(
      "SELECT (current_seq + 1)::text AS next FROM teams WHERE team_id=$1 FOR UPDATE",
      [teamId],
    );
    const futureSeq = head!.next;
    await pool.query(
      `UPDATE teams SET current_seq=$2::bigint,policy_revision=1,
         accepted_envelope_versions=ARRAY[1],
         write_allowed_ciphers=ARRAY['future-aead']::TEXT[]
       WHERE team_id=$1`,
      [teamId, futureSeq],
    );
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id,policy_revision,effective_from_seq,
          accepted_envelope_versions,write_allowed_ciphers)
       VALUES($1,1,$2::bigint,ARRAY[1],ARRAY['future-aead']::TEXT[])`,
      [teamId, futureSeq],
    );
    await pool.query(
      `INSERT INTO messages
         (team_id,id,team_seq,envelope_v,cipher,key_id,blob,envelope_digest)
       VALUES($1,'550e8400-e29b-41d4-a716-446655440099',$4::bigint,1,
              'future-aead','epoch-1',$2,$3)`,
      [teamId, futureEnvelope.blob, envelopeDigest(futureEnvelope), futureSeq],
    );
    await pool.query("COMMIT");

    const policyTransition = await sync(storeA, "once", "--team", localTeam);
    expect(policyTransition.stdout).toContain('"event":"push.blocked"');
    expect(policyTransition.stdout).toContain('"event":"pull.quarantined"');
    expect(policyTransition.stdout).toContain('"status":"unsupported_cipher"');
    const quarantined = await execFileAsync("sqlite3", [teamStore(storeA),
      "SELECT status || ':' || server_seq FROM sync_quarantine WHERE wire_id='550e8400-e29b-41d4-a716-446655440099';"]);
    expect(quarantined.stdout.trim()).toBe(`unsupported_cipher:${futureSeq}`);
    expect((await history(storeA)).map((message) => message.body)).toEqual([
      "fixture from machine A", "fixture reply from machine B",
    ]);

    // storeB has not seen this message — the sync above was storeA's — so
    // retaining through it lands past storeB's cursor, which is what makes the
    // next pull a 410. The old literal 3 was this same position by coincidence;
    // the relationship is what matters, since retaining through something storeB
    // already holds would ask it to recover from nothing and no 410 would come.
    // The assertion below pins that relationship rather than trusting it.
    const cursorB = await execFileAsync("sqlite3", [teamStore(storeB),
      "SELECT transport_cursor FROM sync_bindings;"]);
    expect(BigInt(cursorB.stdout.trim())).toBeLessThan(BigInt(futureSeq));
    const retainFloor = BigInt(futureSeq);
    await retainThrough(pool, teamId, retainFloor);
    await expect(sync(storeB, "once", "--team", localTeam)).rejects.toMatchObject({
      stderr: expect.stringContaining("HTTP 410 resync-required"),
    });
    const beforeResync = await history(storeB);
    const recovered = await sync(storeB, "resync", "--team", localTeam,
      "--accept-floor", retainFloor.toString());
    expect(recovered.stdout).toContain('"event":"resync.complete"');
    expect(recovered.stdout).toContain('"disposition":"accepted"');
    expect(await history(storeB)).toEqual(beforeResync);
    const resyncState = await execFileAsync("sqlite3", [teamStore(storeB),
      `SELECT transport_cursor || ':' ||
         (SELECT count(*) FROM sync_resync_audits) FROM sync_bindings;`]);
    expect(resyncState.stdout.trim()).toBe(`${retainFloor}:1`);
    const retried = await sync(storeB, "resync", "--team", localTeam,
      "--accept-floor", retainFloor.toString());
    expect(retried.stdout).toContain('"disposition":"already-accepted"');

    const disconnected = await execFileAsync("bash", [join(repositoryRoot, "scripts/remote.sh"),
      "disconnect", localTeam], {
      cwd: repositoryRoot,
      env: { ...process.env, AGMSG_SYNC_CONNECTION_DIR: connectionB },
    });
    // The register model's disconnect stops the engine and clears local state;
    // it does not revoke server-side (there is no credential), so we assert the
    // disconnect confirmation, not the old "Revoking credential..." line — that
    // is old-path output removed with the credential/E2EE cleanup.
    expect(disconnected.stdout).toContain(`Disconnected '${localTeam}'. Local sync state cleared`);
    await expect(sync(storeB, "once", "--team", localTeam)).rejects.toMatchObject({
      stderr: expect.stringContaining("invalid or disconnected"),
    });
  }, 20_000);

  it("synchronizes a SQLite and JSONL peer in both directions without duplicates", async () => {
    const fromSqlite = "heterogeneous message from SQLite";
    const fromJsonl = "heterogeneous reply from JSONL";

    await localSend(crossStoreSqlite, "machine-a", "machine-b", fromSqlite, crossTeam);
    await sync(crossStoreSqlite, "once", "--team", crossTeam);
    await sync(crossStoreJsonl, "once", "--team", crossTeam);
    expect((await history(crossStoreJsonl, crossTeam)).filter((message) => message.body === fromSqlite)).toHaveLength(1);

    await localSend(crossStoreJsonl, "machine-b", "machine-a", fromJsonl, crossTeam);
    await sync(crossStoreJsonl, "once", "--team", crossTeam);
    await sync(crossStoreSqlite, "once", "--team", crossTeam);
    const expectedBodies = [fromSqlite, fromJsonl];
    expect((await history(crossStoreSqlite, crossTeam)).map((message) => message.body)).toEqual(expectedBodies);
    expect((await history(crossStoreJsonl, crossTeam)).map((message) => message.body)).toEqual(expectedBodies);
  }, 20_000);
});
