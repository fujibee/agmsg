import { readFile } from "node:fs/promises";
import * as duplicateKeyJson from "json-dup-key-validator";
import { z } from "zod";
import { loadConfig } from "./config.js";
import { createPool, inTransaction, migrate } from "./db.js";
import {
  agentNameSchema,
  MAX_SEQUENCE,
  teamNameSchema,
  uuidV7Schema,
} from "./protocol.js";

const registrationSchema = z
  .object({
    registration_id: uuidV7Schema,
    installation_id: uuidV7Schema,
    type: z.string().min(1).max(64).regex(/^[a-z0-9][a-z0-9._-]*$/),
  })
  .strict();

const memberSchema = z
  .object({
    member_id: uuidV7Schema,
    name: agentNameSchema,
    registrations: z.array(registrationSchema),
  })
  .strict();

const manifestSchema = z
  .object({
    team_id: uuidV7Schema,
    team_name: teamNameSchema,
    members: z.array(memberSchema).max(1000),
  })
  .strict();

const manifestPath = process.argv[2];
if (!manifestPath) {
  throw new Error("Usage: npm run provision -- <manifest.json>");
}

const manifestSource = await readFile(manifestPath, "utf8");
const manifest = manifestSchema.parse(duplicateKeyJson.parse(manifestSource, false));
const memberIds = new Set<string>();
const memberNames = new Set<string>();
const registrationIds = new Set<string>();
for (const member of manifest.members) {
  if (memberIds.has(member.member_id) || memberNames.has(member.name)) {
    throw new Error("manifest contains duplicate member ID or name");
  }
  memberIds.add(member.member_id);
  memberNames.add(member.name);
  for (const registration of member.registrations) {
    if (registrationIds.has(registration.registration_id)) {
      throw new Error("manifest contains a duplicate registration ID");
    }
    registrationIds.add(registration.registration_id);
  }
}

const config = loadConfig();
const pool = createPool(config.databaseUrl);
try {
  await migrate(pool);
  const revision = await inTransaction(pool, async (client) => {
    const existing = await client.query<{ members_revision: string }>(
      `SELECT members_revision::text FROM teams
        WHERE team_id = $1 FOR UPDATE`,
      [manifest.team_id],
    );
    const currentMembers = new Set(
      (
        await client.query<{ member_id: string }>(
          "SELECT member_id::text FROM members WHERE team_id = $1",
          [manifest.team_id],
        )
      ).rows.map((row) => row.member_id),
    );
    const currentRegistrations = new Set(
      (
        await client.query<{ registration_id: string }>(
          "SELECT registration_id::text FROM registrations WHERE team_id = $1",
          [manifest.team_id],
        )
      ).rows.map((row) => row.registration_id),
    );

    let nextRevision = 0n;
    if (existing.rows[0]) {
      const current = BigInt(existing.rows[0].members_revision);
      if (current === MAX_SEQUENCE) throw new Error("members revision is exhausted");
      nextRevision = current + 1n;
      await client.query(
        "UPDATE teams SET team_name = $2, members_revision = $3 WHERE team_id = $1",
        [manifest.team_id, manifest.team_name, nextRevision.toString()],
      );
    } else {
      await client.query(
        `INSERT INTO teams
           (team_id, team_name, members_revision,
            accepted_envelope_versions, write_allowed_ciphers)
         VALUES ($1, $2, 0, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
        [manifest.team_id, manifest.team_name],
      );
      await client.query(
        `INSERT INTO team_policy_history
           (team_id, policy_revision, effective_from_seq,
            accepted_envelope_versions, write_allowed_ciphers)
         VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
        [manifest.team_id],
      );
    }

    for (const member of manifest.members) {
      const memberSeen = await client.query<{ present: boolean }>(
        `SELECT TRUE AS present FROM member_identity_history
          WHERE team_id = $1 AND member_id = $2 LIMIT 1`,
        [manifest.team_id, member.member_id],
      );
      if (memberSeen.rows[0] && !currentMembers.has(member.member_id)) {
        throw new Error(`member ${member.member_id} is retired`);
      }
      const nameOwner = await client.query<{ member_id: string }>(
        `SELECT member_id::text FROM member_identity_history
          WHERE team_id = $1 AND name = $2`,
        [manifest.team_id, member.name],
      );
      if (nameOwner.rows[0] && nameOwner.rows[0].member_id !== member.member_id) {
        throw new Error(`member name ${member.name} is retired by another member`);
      }
      await client.query(
        `INSERT INTO member_identity_history (team_id, member_id, name)
         VALUES ($1, $2, $3) ON CONFLICT (team_id, name) DO NOTHING`,
        [manifest.team_id, member.member_id, member.name],
      );
      for (const registration of member.registrations) {
        const owner = await client.query<{ member_id: string }>(
          `SELECT member_id::text FROM registration_identity_history
            WHERE team_id = $1 AND registration_id = $2`,
          [manifest.team_id, registration.registration_id],
        );
        if (owner.rows[0] && !currentRegistrations.has(registration.registration_id)) {
          throw new Error(`registration ${registration.registration_id} is retired`);
        }
        if (owner.rows[0] && owner.rows[0].member_id !== member.member_id) {
          throw new Error(
            `registration ${registration.registration_id} is retired by another member`,
          );
        }
        await client.query(
          `INSERT INTO registration_identity_history
             (team_id, registration_id, member_id)
           VALUES ($1, $2, $3)
           ON CONFLICT (team_id, registration_id) DO NOTHING`,
          [manifest.team_id, registration.registration_id, member.member_id],
        );
      }
    }

    await client.query("DELETE FROM registrations WHERE team_id = $1", [manifest.team_id]);
    await client.query(
      "DELETE FROM members WHERE team_id = $1 AND NOT (member_id = ANY($2::uuid[]))",
      [manifest.team_id, manifest.members.map((member) => member.member_id)],
    );
    for (const member of manifest.members) {
      await client.query(
        `INSERT INTO members (team_id, member_id, name) VALUES ($1, $2, $3)
         ON CONFLICT (team_id, member_id) DO UPDATE SET name = EXCLUDED.name`,
        [manifest.team_id, member.member_id, member.name],
      );
      for (const registration of member.registrations) {
        await client.query(
          `INSERT INTO registrations
             (team_id, registration_id, member_id, installation_id, type)
           VALUES ($1, $2, $3, $4, $5)`,
          [
            manifest.team_id,
            registration.registration_id,
            member.member_id,
            registration.installation_id,
            registration.type,
          ],
        );
      }
    }
    return nextRevision.toString();
  });
  process.stdout.write(
    `${JSON.stringify({ team_id: manifest.team_id, members_revision: revision })}\n`,
  );
} finally {
  await pool.end();
}
