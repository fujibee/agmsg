// Reference-server state adapter for the shared key contract. All protocol
// assertions stay in the shared file; this only owns database setup and real age
// key handling.
import { Decrypter, Encrypter, generateX25519Identity, identityToRecipient } from "age-encryption";
import { Pool } from "pg";
import { insertDevice } from "../../src/accounts/capability.ts";
import { snapshotDigest } from "../../src/canonical.ts";
import { inTransaction } from "../../src/db.ts";
import { fenceEpoch } from "../../src/fence.ts";

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
      await pool.query("INSERT INTO teams (team_id, team_name) VALUES ($1, $2)", [teamId, `keys-${index}`]);
      await pool.query(
        `INSERT INTO team_policy_history (team_id, policy_revision, effective_from_seq,
           accepted_envelope_versions, write_allowed_ciphers)
         VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`, [teamId],
      );
    }
    const { rows: [meta] } = await pool.query("SELECT server_instance_id FROM server_metadata");
    async function device(teamId, label, withKey) {
      const result = await insertDevice(pool, { teamId, name: label, deviceType: "test", active: true });
      const entry = { capabilityUrl: `${origin.origin}/t/${result.secret}`, teamId, deviceId: result.deviceId, label };
      if (withKey) {
        entry.deviceIdentity = await generateX25519Identity();
        entry.devicePubkey = await identityToRecipient(entry.deviceIdentity);
      }
      return entry;
    }
    const primary = await device(teams[0], "keys-primary", true);
    const foreign = await device(teams[1], "keys-foreign", true);
    const revoked = await device(teams[0], "keys-revoked", false);
    await pool.query("UPDATE devices SET revoked_at = clock_timestamp() WHERE device_id = $1", [revoked.deviceId]);
    const unregistered = await device(teams[0], "keys-unregistered", false);
    return {
      primary, foreign, revoked, unregistered,
      async newEpoch({ epoch, teamId, previous }) {
        const identity = await generateX25519Identity();
        const recipient = await identityToRecipient(identity);
        const key_id = `key-${epoch}-${Math.random().toString(36).slice(2, 10)}`;
        const entry = {
          epoch_revision: String(epoch - 1), effective_from_seq: String(epoch * 10 - 9),
          cipher: "age-v1", key_id, recipients: [recipient],
        };
        const snapshot = {
          profile: "age-v1", server_instance_id: meta.server_instance_id, team_id: teamId,
          epoch_revision: String(epoch - 1), writer_generation: String(epoch - 1),
          authorized_writers: [key_id],
          previous_snapshot_sha256: previous ? snapshotDigest(previous.snapshot) : null,
          history: [...(previous ? previous.snapshot.history : []), entry],
        };
        return { key_id, identity, recipient, snapshot };
      },
      async openSealed(base64, deviceIdentity) {
        const decrypter = new Decrypter();
        decrypter.addIdentity(deviceIdentity);
        return decrypter.decrypt(Buffer.from(base64, "base64"), "text");
      },
      async sealMessage(plaintext, recipient) {
        const encrypter = new Encrypter();
        encrypter.addRecipient(recipient);
        return Buffer.from(await encrypter.encrypt(plaintext)).toString("base64");
      },
      async revokeDevice({ teamId, keyId }) {
        try {
          if (teamId !== primary.teamId) throw new Error();
          // A controlled pause: owner removal and its optional automatic
          // rotation are tested separately, not raced by this HTTP contract.
          await inTransaction(pool, client => fenceEpoch(client, teamId, keyId));
        } catch { throw new Error("reference fixture could not establish the test epoch fence"); }
      },
      async dispose() { await pool.end(); },
    };
  } catch {
    await pool.end();
    throw new Error("reference keys fixture setup failed");
  }
}
