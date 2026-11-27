// Reference-server state adapter. All protocol assertions stay in the shared file.
import { Pool } from "pg";
import { insertDevice } from "../../src/accounts/capability.ts";
import { userCodeDigestOf } from "../../src/accounts/codes.ts";
import { decideGrant } from "../../src/accounts/device-flow.ts";

export async function createFixture({ baseUrl }) {
  const origin = new URL(baseUrl);
  if (origin.protocol !== "http:" || origin.hostname !== "127.0.0.1") {
    throw new Error("the reference adapter requires an isolated loopback server");
  }
  const schema = process.env.CONTRACT_TEST_SCHEMA;
  const databaseUrl = process.env.CONTRACT_TEST_DATABASE_URL;
  if (!databaseUrl || !/^agmsg_contract_[a-f0-9]{16}$/.test(schema ?? "")) {
    throw new Error("the reference adapter requires its integration test database and schema");
  }
  const pool = new Pool({ connectionString: databaseUrl, options: `-c search_path=${schema}` });
  try {
    const teams = ["018f3f7e-0000-7000-8000-0000000000a1", "018f3f7e-0000-7000-8000-0000000000b2"];
    for (const [index, teamId] of teams.entries()) {
      await pool.query("INSERT INTO teams (team_id, team_name) VALUES ($1, $2)", [teamId, `contract-${index}`]);
      await pool.query(
        `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
           accepted_envelope_versions, write_allowed_ciphers)
         VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`, [teamId],
      );
    }
    async function device(teamId, label) {
      const result = await insertDevice(pool, { teamId, name: label, deviceType: "test", active: true });
      return { capabilityUrl: `${origin.origin}/t/${result.secret}`, teamId, deviceId: result.deviceId, devicePubkey: null, label };
    }
    const primary = await device(teams[0], "contract-primary");
    const foreign = await device(teams[1], "contract-foreign");
    const revoked = await device(teams[0], "contract-revoked");
    await pool.query("UPDATE devices SET revoked_at = clock_timestamp() WHERE device_id = $1", [revoked.deviceId]);
    return {
      primary, foreign, revoked, expectedLimits: {},
      async approveGrant({ userCode, decision, teamId }) {
        try {
          const digest = userCodeDigestOf(userCode);
          if (!digest) throw new Error();
          const result = await decideGrant(pool, { userCodeDigest: digest, decision, teamId });
          if (!result.ok) throw new Error();
        } catch {
          throw new Error("reference fixture could not decide the test grant");
        }
      },
      async dispose() { await pool.end(); },
    };
  } catch {
    await pool.end();
    // The parent integration test owns and drops this whole disposable schema.
    throw new Error("reference fixture setup failed");
  }
}
