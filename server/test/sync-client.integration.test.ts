import { randomBytes } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { Pool } from "pg";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import { exchangePairingToken, issuePairingToken } from "../src/credentials.js";
import { migrate } from "../src/db.js";
import { envelopeDigest } from "../src/protocol.js";
import { retainThrough } from "../src/storage.js";

const databaseUrl = process.env.TEST_DATABASE_URL;
const describeDatabase = databaseUrl ? describe : describe.skip;
const execFileAsync = promisify(execFile);
const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));

describeDatabase("Stage-1 polling sync client", () => {
  const schema = `agmsg_sync_${randomBytes(8).toString("hex")}`;
  let token: string;
  const teamId = "018f3f7e-0000-7000-8000-000000000101";
  const memberA = "018f3f7e-0000-7000-8000-000000000110";
  const memberB = "018f3f7e-0000-7000-8000-000000000120";
  const localTeam = "dogfood-team";
  let admin: Pool;
  let pool: Pool;
  let app: ReturnType<typeof createApp>;
  let serverUrl: string;
  let root: string;
  let storeA: string;
  let storeB: string;
  let rosterFile: string;

  beforeAll(async () => {
    admin = new Pool({ connectionString: databaseUrl });
    await admin.query(`CREATE SCHEMA ${schema}`);
    pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
    await migrate(pool);
    await pool.query("INSERT INTO teams(team_id,team_name) VALUES($1,$2)", [teamId, localTeam]);
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id,policy_revision,effective_from_seq,
          accepted_envelope_versions,write_allowed_ciphers)
       VALUES($1,0,1,ARRAY[1],ARRAY['none','age-v1']::TEXT[])`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO members(team_id,member_id,name) VALUES
       ($1,$2,'machine-a'),($1,$3,'machine-b')`,
      [teamId, memberA, memberB],
    );
    const config: Config = {
      databaseUrl: databaseUrl ?? "",
      host: "127.0.0.1", port: 8787, logLevel: "silent",
      retentionMaxLiveMessages: null,
    };
    const issued = await issuePairingToken(pool, teamId);
    token = String((await exchangePairingToken(pool, issued.token)).credential);
    app = createApp(pool, config);
    serverUrl = await app.listen({ host: "127.0.0.1", port: 0 });
    root = await mkdtemp(join(tmpdir(), "agmsg-stage1-sync-"));
    storeA = join(root, "machine-a");
    storeB = join(root, "machine-b");
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

  function environment(store: string) {
    return {
      ...process.env,
      AGMSG_STORAGE_PATH: store,
      AGMSG_STORAGE_DRIVER: "sqlite",
      AGMSG_SYNC_TOKEN: token,
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

  async function localSend(store: string, from: string, to: string, body: string) {
    const script = `. "$1/scripts/lib/storage.sh"
agmsg_storage_load
storage_init >/dev/null
storage_send "$2" "$3" "$4" "$5"`;
    return execFileAsync("bash", ["-c", script, "stage1-test", repositoryRoot, localTeam, from, to, body], {
      cwd: repositoryRoot,
      env: environment(store),
    });
  }

  async function history(store: string) {
    const script = `. "$1/scripts/lib/storage.sh"
agmsg_storage_load
storage_history "$2"`;
    const result = await execFileAsync("bash", ["-c", script, "stage1-test", repositoryRoot, localTeam], {
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
    for (const store of [storeA, storeB]) {
      await sync(store, "configure", "--team", localTeam, "--server", serverUrl,
        "--team-id", teamId, "--minimum-security", "plaintext-allowed");
    }

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
    await pool.query(
      `UPDATE teams SET current_seq=3,policy_revision=1,
         accepted_envelope_versions=ARRAY[1],
         write_allowed_ciphers=ARRAY['future-aead']::TEXT[]
       WHERE team_id=$1`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO team_policy_history
         (team_id,policy_revision,effective_from_seq,
          accepted_envelope_versions,write_allowed_ciphers)
       VALUES($1,1,3,ARRAY[1],ARRAY['future-aead']::TEXT[])`,
      [teamId],
    );
    await pool.query(
      `INSERT INTO messages
         (team_id,id,team_seq,envelope_v,cipher,key_id,blob,envelope_digest)
       VALUES($1,'550e8400-e29b-41d4-a716-446655440099',3,1,
              'future-aead','epoch-1',$2,$3)`,
      [teamId, futureEnvelope.blob, envelopeDigest(futureEnvelope)],
    );
    await pool.query("COMMIT");

    const policyTransition = await sync(storeA, "once", "--team", localTeam);
    expect(policyTransition.stdout).toContain('"event":"push.blocked"');
    expect(policyTransition.stdout).toContain('"event":"pull.quarantined"');
    expect(policyTransition.stdout).toContain('"status":"unsupported_cipher"');
    const quarantined = await execFileAsync("sqlite3", [join(storeA, "messages.db"),
      "SELECT status || ':' || server_seq FROM sync_quarantine WHERE wire_id='550e8400-e29b-41d4-a716-446655440099';"]);
    expect(quarantined.stdout.trim()).toBe("unsupported_cipher:3");
    expect((await history(storeA)).map((message) => message.body)).toEqual([
      "fixture from machine A", "fixture reply from machine B",
    ]);

    await retainThrough(pool, teamId, 3n);
    await expect(sync(storeB, "once", "--team", localTeam)).rejects.toMatchObject({
      stderr: expect.stringContaining("HTTP 410 resync-required"),
    });
    const beforeResync = await history(storeB);
    const recovered = await sync(storeB, "resync", "--team", localTeam,
      "--accept-floor", "3");
    expect(recovered.stdout).toContain('"event":"resync.complete"');
    expect(recovered.stdout).toContain('"disposition":"accepted"');
    expect(await history(storeB)).toEqual(beforeResync);
    const resyncState = await execFileAsync("sqlite3", [join(storeB, "messages.db"),
      `SELECT transport_cursor || ':' ||
         (SELECT count(*) FROM sync_resync_audits) FROM sync_bindings;`]);
    expect(resyncState.stdout.trim()).toBe("3:1");
    const retried = await sync(storeB, "resync", "--team", localTeam,
      "--accept-floor", "3");
    expect(retried.stdout).toContain('"disposition":"already-accepted"');
  }, 20_000);
});
