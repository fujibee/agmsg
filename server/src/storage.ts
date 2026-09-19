import type { Pool, PoolClient } from "pg";
import { DatabaseUnavailableError, ProtocolError } from "./errors.js";
import {
  MAX_SEQUENCE,
  type ConnectInput,
  envelopeDigest,
  type Envelope,
  type MessageInput,
  type ReadStateSyncInput,
} from "./protocol.js";
import { inTransaction } from "./db.js";

type TeamRow = {
  team_id: string;
  team_name: string;
  current_seq: string;
  min_available_seq: string;
  policy_revision: string;
  accepted_envelope_versions: number[];
  write_allowed_ciphers: string[];
  max_blob_bytes: number;
  members_revision: string;
  // Null until a machine declares it. Not the same as 'none'.
  cipher_profile: string | null;
};

type LiveMessageRow = {
  id: string;
  team_seq: string;
  server_received_at: string;
  envelope_v: number;
  cipher: string;
  key_id: string | null;
  blob: string;
  envelope_digest: Buffer;
};

type ExistingRecord =
  | { kind: "live"; row: LiveMessageRow }
  | { kind: "tombstone"; sequence: string; digest: Buffer };

// Takes the column, the way credentials.ts already does: this file needs the
// same rendering for more than one timestamp now, and two spellings of the same
// format string is how they drift apart.
const timestampSql = (column: string) => `to_char(${column} AT TIME ZONE 'UTC',
  'YYYY-MM-DD"T"HH24:MI:SS.US"Z"')`;
const MAX_EXACT_PER_MEMBER = 4096;
const MAX_EXACT_PER_TEAM = 65536;
// A name matching more teams than this is answered with an error, not a
// truncated list. Truncation would be the worse failure: a caller shown "the
// first N" cannot tell whether its own team is among them, so it would choose
// from a set that may not contain the right answer. The bound is also what
// keeps the row count of an unauthenticated response from being chosen by
// outside input -- every other public route answers about one known team.
const MAX_TEAMS_PER_NAME = 16;

async function serverInstanceId(client: PoolClient): Promise<string> {
  const result = await client.query<{ server_instance_id: string }>(
    "SELECT server_instance_id::text FROM server_metadata WHERE singleton = TRUE",
  );
  const id = result.rows[0]?.server_instance_id;
  if (!id) throw new Error("server metadata is not initialized");
  return id;
}

async function teamRow(
  client: PoolClient,
  id: string,
  lock = false,
): Promise<TeamRow | undefined> {
  const result = await client.query<TeamRow>(
    `SELECT team_id::text, team_name, current_seq::text, min_available_seq::text,
            policy_revision::text, accepted_envelope_versions,
            write_allowed_ciphers, max_blob_bytes, members_revision::text,
            cipher_profile
       FROM teams WHERE team_id = $1${lock ? " FOR UPDATE" : ""}`,
    [id],
  );
  return result.rows[0];
}

function common(serverId: string, team: TeamRow): Record<string, unknown> {
  return {
    protocol_version: 1,
    server_instance_id: serverId,
    team_id: team.team_id,
    team_name: team.team_name,
    min_available_seq: team.min_available_seq,
    // The DECLARED profile, distinct from write_allowed_ciphers, which says
    // only what the server would accept. `null` is a real answer here — "no
    // machine has declared it yet" — and a client must not read it as 'none'.
    cipher_profile: team.cipher_profile ?? null,
  };
}

function notFound(serverId: string, teamId: string): ProtocolError {
  return new ProtocolError(
    404,
    "team-not-found",
    "team is not provisioned",
    {},
    {
      serverInstanceId: serverId,
      teamId,
    },
  );
}

function envelopeMatches(row: LiveMessageRow, envelope: Envelope): boolean {
  return (
    row.envelope_v === envelope.v &&
    row.cipher === envelope.cipher &&
    row.key_id === envelope.key_id &&
    row.blob === envelope.blob
  );
}

function inputFingerprint(message: MessageInput): string {
  return JSON.stringify([
    message.envelope.v,
    message.envelope.cipher,
    message.envelope.key_id,
    message.envelope.blob,
  ]);
}

export async function postMessages(
  pool: Pool,
  teamId: string,
  messages: MessageInput[],
  retentionMaxLiveMessages: bigint | null = null,
  retentionObserver?: (notice: RetentionNotice) => void,
): Promise<Record<string, unknown>> {
  let retentionNotice: RetentionNotice | undefined;
  const response = await inTransaction(pool, async (client) => {
    const serverId = await serverInstanceId(client);
    const team = await teamRow(client, teamId, true);
    if (!team) throw notFound(serverId, teamId);
    const binding = { serverInstanceId: serverId, teamId };

    const firstById = new Map<string, MessageInput>();
    for (const message of messages) {
      const first = firstById.get(message.id);
      if (first && inputFingerprint(first) !== inputFingerprint(message)) {
        throw new ProtocolError(
          409,
          "message-uuid-conflict",
          "message id is repeated with a different payload",
          { id: message.id },
          binding,
        );
      }
      firstById.set(message.id, first ?? message);
    }

    const ids = [...firstById.keys()];
    const liveResult = await client.query<LiveMessageRow>(
      `SELECT id::text, team_seq::text, ${timestampSql("server_received_at")} AS server_received_at,
              envelope_v, cipher, key_id, blob, envelope_digest
         FROM messages WHERE team_id = $1 AND id = ANY($2::uuid[])`,
      [teamId, ids],
    );
    const tombstoneResult = await client.query<{
      id: string;
      original_team_seq: string;
      envelope_digest: Buffer;
    }>(
      `SELECT id::text, original_team_seq::text, envelope_digest
         FROM message_tombstones WHERE team_id = $1 AND id = ANY($2::uuid[])`,
      [teamId, ids],
    );
    const existing = new Map<string, ExistingRecord>();
    for (const row of liveResult.rows)
      existing.set(row.id, { kind: "live", row });
    for (const row of tombstoneResult.rows) {
      existing.set(row.id, {
        kind: "tombstone",
        sequence: row.original_team_seq,
        digest: row.envelope_digest,
      });
    }

    for (const [id, message] of firstById) {
      const record = existing.get(id);
      if (!record) continue;
      const matches =
        record.kind === "live"
          ? envelopeMatches(record.row, message.envelope)
          : record.digest.equals(envelopeDigest(message.envelope));
      if (!matches) {
        throw new ProtocolError(
          409,
          "message-uuid-conflict",
          "message id already exists with a different payload",
          { id },
          binding,
        );
      }
    }

    const fresh = [...firstById.values()].filter(
      (message) => !existing.has(message.id),
    );
    for (const message of fresh) {
      const { envelope, id } = message;
      if (envelope.v !== 1 || !["none", "age-v1"].includes(envelope.cipher)) {
        throw new ProtocolError(
          422,
          "unsupported-cipher",
          "envelope version or cipher is not supported",
          {
            id,
            v: envelope.v,
            cipher: envelope.cipher,
            accepted_envelope_versions: team.accepted_envelope_versions,
            write_allowed_ciphers: team.write_allowed_ciphers,
            policy_revision: team.policy_revision,
          },
          binding,
        );
      }
      if (
        !team.accepted_envelope_versions.includes(envelope.v) ||
        !team.write_allowed_ciphers.includes(envelope.cipher)
      ) {
        throw new ProtocolError(
          403,
          "cipher-policy-violation",
          "cipher is not currently write-allowed",
          {
            id,
            v: envelope.v,
            cipher: envelope.cipher,
            write_allowed_ciphers: team.write_allowed_ciphers,
            policy_revision: team.policy_revision,
          },
          binding,
        );
      }
      if (Buffer.from(envelope.blob, "base64").length > team.max_blob_bytes) {
        throw new ProtocolError(
          413,
          "request-too-large",
          "message blob exceeds the team capability limit",
          { id, max_blob_bytes: String(team.max_blob_bytes) },
          binding,
        );
      }
    }

    // The team's single cipher, enforced before anything is stored.
    //
    // `write_allowed_ciphers` above is a different question — what the server
    // will ACCEPT — and it permits both. `cipher_profile` is what this team
    // chose, and a client reads it to decide whether plaintext may be pushed at
    // all. A value that traffic is free to contradict is not a fact about the
    // team, and a safety decision resting on it would be worse than none: it
    // reads as dependable precisely because writes went through.
    //
    // So a batch that disagrees with the team, or with itself while the team is
    // undeclared, is refused whole. Fail-closed and before the writes: a
    // partial store would leave the team holding messages under a cipher it
    // does not use, which is the state this column exists to make impossible.
    if (fresh.length > 0) {
      const ciphers = new Set(fresh.map((message) => message.envelope.cipher));
      const expected = team.cipher_profile ?? (ciphers.size === 1 ? [...ciphers][0]! : null);
      if (expected === null || ciphers.size !== 1 || !ciphers.has(expected)) {
        // The refusal carries its own way out. One path here is reachable by a
        // machine that has done nothing wrong: the team declared age-v1 after
        // this machine last looked, so it is still sending plaintext. Blocking
        // that write is right — it would be readable by the server — but the
        // sender cannot act on "mismatch" alone. `remedy` names what makes it
        // send the right thing, and `cipher_profile` says what to send.
        throw new ProtocolError(
          409,
          "cipher-profile-mismatch",
          team.cipher_profile === null
            ? "an undeclared team cannot be settled by a batch that mixes ciphers"
            : "message cipher does not match the team's declared cipher profile",
          {
            cipher_profile: team.cipher_profile,
            batch_ciphers: [...ciphers].sort(),
            remedy:
              team.cipher_profile === null
                ? "send one batch whose messages all use the same cipher; that settles the team"
                : "re-read this team (remote.sh pull, or unlock if you hold the key) and send under its declared cipher",
          },
          binding,
        );
      }
    }

    let next = BigInt(team.current_seq);
    if (BigInt(fresh.length) > MAX_SEQUENCE - next) {
      throw new ProtocolError(
        507,
        "sequence-exhausted",
        "team sequence is exhausted",
        {},
        binding,
      );
    }

    const inserted = new Map<string, LiveMessageRow>();
    for (const message of fresh) {
      next += 1n;
      const digest = envelopeDigest(message.envelope);
      const result = await client.query<LiveMessageRow>(
        `INSERT INTO messages
           (team_id, id, team_seq, envelope_v, cipher, key_id, blob, envelope_digest)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id::text, team_seq::text, ${timestampSql("server_received_at")} AS server_received_at,
                   envelope_v, cipher, key_id, blob, envelope_digest`,
        [
          teamId,
          message.id,
          next.toString(),
          message.envelope.v,
          message.envelope.cipher,
          message.envelope.key_id,
          message.envelope.blob,
          digest,
        ],
      );
      const row = result.rows[0];
      if (!row) throw new Error("insert did not return a message");
      inserted.set(message.id, row);
      existing.set(message.id, { kind: "live", row });
    }
    if (fresh.length > 0) {
      await client.query(
        "UPDATE teams SET current_seq = $2 WHERE team_id = $1",
        [teamId, next.toString()],
      );
      // A team registered before declarations were carried has cipher_profile
      // NULL, and connect cannot fill it: that route takes no credential, so a
      // write there would let anyone who knows a team_id fix the profile ahead
      // of the machine that owns the team. It is settled here instead — by what
      // the team actually stores — on a route that already writes to this same
      // row (current_seq, one line above) and has already run every check.
      //
      // The batch is known to agree with itself by now: the guard above refused
      // it otherwise, so this cannot be decided by which message came first.
      //
      // `IS NULL` only. Once declared, a team is not reclassified by later
      // traffic — and traffic that disagrees never reaches this point at all.
      await client.query(
        `UPDATE teams SET cipher_profile = $2
          WHERE team_id = $1 AND cipher_profile IS NULL`,
        [teamId, fresh[0]!.envelope.cipher],
      );
    }

    const seen = new Set<string>();
    const acks = messages.map((message) => {
      const record = existing.get(message.id);
      if (!record) throw new Error("missing canonical ack record");
      const stored = inserted.has(message.id) && !seen.has(message.id);
      seen.add(message.id);
      return {
        id: message.id,
        server_seq:
          record.kind === "live" ? record.row.team_seq : record.sequence,
        disposition: stored ? "stored" : "duplicate",
      };
    });

    let effectiveFloor = BigInt(team.min_available_seq);
    if (retentionMaxLiveMessages !== null && next > retentionMaxLiveMessages) {
      const target = next - retentionMaxLiveMessages;
      if (target > effectiveFloor) {
        retentionNotice = await retainThroughLocked(
          client,
          teamId,
          effectiveFloor,
          target,
        );
        effectiveFloor = target;
      }
    }

    return {
      ...common(serverId, {
        ...team,
        current_seq: next.toString(),
        min_available_seq: effectiveFloor.toString(),
      }),
      policy_revision: team.policy_revision,
      acks,
    };
  });
  if (retentionNotice) retentionObserver?.(retentionNotice);
  return response;
}

export async function syncReadState(
  pool: Pool,
  teamId: string,
  input: ReadStateSyncInput,
): Promise<Record<string, unknown>> {
  return inTransaction(pool, async (client) => {
    const serverId = await serverInstanceId(client);
    const team = await teamRow(client, teamId, true);
    if (!team) throw notFound(serverId, teamId);
    const binding = { serverInstanceId: serverId, teamId };
    const floor = BigInt(team.min_available_seq);
    const current = BigInt(team.current_seq);

    const memberIds = input.updates.map((update) => update.member_id);
    if (memberIds.length > 0) {
      const members = await client.query<{ member_id: string }>(
        `SELECT member_id::text FROM members
          WHERE team_id = $1 AND member_id = ANY($2::uuid[])`,
        [teamId, memberIds],
      );
      if (members.rows.length !== memberIds.length) {
        throw new ProtocolError(
          400,
          "invalid-request",
          "read-state update contains an inactive member",
          {},
          binding,
        );
      }
    }

    for (const update of input.updates) {
      if (BigInt(update.server_seq) > current) {
        throw new ProtocolError(
          400,
          "invalid-request",
          "read frontier exceeds the current team sequence",
          { member_id: update.member_id, server_seq: update.server_seq },
          binding,
        );
      }
    }

    const exactMembers: string[] = [];
    const exactWires: string[] = [];
    for (const update of input.updates) {
      for (const wireId of update.exact_wire_ids) {
        exactMembers.push(update.member_id);
        exactWires.push(wireId);
      }
    }
    const exactIds = [...new Set(exactWires)];
    const novelExactPairs = new Set<string>();
    if (exactIds.length > 0) {
      const resolved = await client.query<{ id: string }>(
        `SELECT id::text FROM messages WHERE team_id = $1 AND id = ANY($2::uuid[])
         UNION
         SELECT id::text FROM message_tombstones
          WHERE team_id = $1 AND id = ANY($2::uuid[])`,
        [teamId, exactIds],
      );
      const found = new Set(resolved.rows.map((row) => row.id));
      const missing = exactIds.find((id) => !found.has(id));
      if (missing) {
        throw new ProtocolError(
          400,
          "invalid-request",
          "exact read refers to an unknown wire id",
          { wire_id: missing },
          binding,
        );
      }
      const novel = await client.query<{ member_id: string; wire_id: string }>(
        `SELECT incoming.member_id::text, incoming.wire_id::text
           FROM unnest($2::uuid[], $3::uuid[]) AS incoming(member_id, wire_id)
           LEFT JOIN read_exact existing
             ON existing.team_id=$1 AND existing.member_id=incoming.member_id
            AND existing.wire_id=incoming.wire_id
          WHERE existing.wire_id IS NULL`,
        [teamId, exactMembers, exactWires],
      );
      for (const row of novel.rows)
        novelExactPairs.add(`${row.member_id}:${row.wire_id}`);
    }

    // The authenticated retention floor is a safe baseline for every existing
    // row. Members without a row receive the same floor logically in the page
    // query below.
    await client.query(
      `UPDATE read_frontiers SET server_seq = GREATEST(server_seq, $2::bigint)
        WHERE team_id = $1`,
      [teamId, floor.toString()],
    );

    if (input.updates.length > 0) {
      await client.query(
        `INSERT INTO read_frontiers(team_id, member_id, server_seq)
         SELECT $1, member_id, GREATEST(server_seq, $4::bigint)
           FROM unnest($2::uuid[], $3::bigint[]) AS incoming(member_id, server_seq)
         ON CONFLICT (team_id, member_id) DO UPDATE
           SET server_seq = GREATEST(read_frontiers.server_seq, EXCLUDED.server_seq, $4::bigint)`,
        [
          teamId,
          input.updates.map((update) => update.member_id),
          input.updates.map((update) => update.server_seq),
          floor.toString(),
        ],
      );
    }

    if (exactWires.length > 0) {
      await client.query(
        `INSERT INTO read_exact(team_id, member_id, wire_id)
         SELECT $1, member_id, wire_id
           FROM unnest($2::uuid[], $3::uuid[]) AS incoming(member_id, wire_id)
         ON CONFLICT DO NOTHING`,
        [teamId, exactMembers, exactWires],
      );
    }

    await deleteCoveredExact(client, teamId, floor);

    const survivingRequestExact =
      exactWires.length === 0
        ? new Set<string>()
        : new Set(
            (
              await client.query<{ member_id: string; wire_id: string }>(
                `SELECT incoming.member_id::text, incoming.wire_id::text
           FROM unnest($2::uuid[], $3::uuid[]) AS incoming(member_id, wire_id)
           JOIN read_exact current
             ON current.team_id=$1 AND current.member_id=incoming.member_id
            AND current.wire_id=incoming.wire_id`,
                [teamId, exactMembers, exactWires],
              )
            ).rows
              .filter((row) =>
                novelExactPairs.has(`${row.member_id}:${row.wire_id}`),
              )
              .map((row) => row.member_id),
          );

    const memberOverflow = await client.query<{
      member_id: string;
      exact_count: string;
    }>(
      `SELECT member_id::text, COUNT(*)::text AS exact_count
         FROM read_exact WHERE team_id = $1
        GROUP BY member_id HAVING COUNT(*) > $2
        ORDER BY COUNT(*) DESC, member_id LIMIT 1`,
      [teamId, MAX_EXACT_PER_MEMBER],
    );
    const teamCountResult = await client.query<{ exact_count: string }>(
      "SELECT COUNT(*)::text AS exact_count FROM read_exact WHERE team_id = $1",
      [teamId],
    );
    const teamCount = Number(teamCountResult.rows[0]?.exact_count ?? "0");
    if (memberOverflow.rows[0] || teamCount > MAX_EXACT_PER_TEAM) {
      const causalMemberId = input.updates.find((update) =>
        survivingRequestExact.has(update.member_id),
      )?.member_id;
      const offender =
        memberOverflow.rows[0] ??
        (
          await client.query<{ member_id: string; exact_count: string }>(
            `SELECT member_id::text, COUNT(*)::text AS exact_count
           FROM read_exact WHERE team_id = $1
            AND ($2::uuid IS NULL OR member_id=$2::uuid)
          GROUP BY member_id ORDER BY COUNT(*) DESC, member_id LIMIT 1`,
            [teamId, causalMemberId ?? null],
          )
        ).rows[0];
      throw new ProtocolError(
        409,
        "read-state-limit-exceeded",
        "unabsorbed exact read state exceeds the protocol limit",
        {
          member_id: offender?.member_id ?? null,
          member_exact_count: offender?.exact_count ?? "0",
          team_exact_count: String(teamCount),
          max_exact_per_member: MAX_EXACT_PER_MEMBER,
          max_exact_per_team: MAX_EXACT_PER_TEAM,
        },
        binding,
      );
    }

    const after = input.page_after;
    const afterKind = after?.kind === "exact" ? 1 : 0;
    const afterWire = after?.kind === "exact" ? after.wire_id : null;
    const result = await client.query<{
      member_id: string;
      kind_order: number;
      server_seq: string | null;
      wire_id: string | null;
    }>(
      `WITH items AS (
         SELECT m.member_id, 0 AS kind_order,
                GREATEST(COALESCE(f.server_seq, 0), $2::bigint) AS server_seq,
                NULL::uuid AS wire_id
           FROM members m LEFT JOIN read_frontiers f
             ON f.team_id=m.team_id AND f.member_id=m.member_id
          WHERE m.team_id=$1
         UNION ALL
         SELECT e.member_id, 1 AS kind_order, NULL::bigint AS server_seq, e.wire_id
           FROM read_exact e WHERE e.team_id=$1
       )
       SELECT member_id::text, kind_order, server_seq::text, wire_id::text
         FROM items
        WHERE $3::uuid IS NULL OR member_id > $3::uuid
           OR (member_id = $3::uuid AND
               (kind_order > $4 OR
                (kind_order = $4 AND kind_order = 1 AND wire_id > $5::uuid)))
        ORDER BY member_id, kind_order, wire_id NULLS FIRST
        LIMIT $6`,
      [
        teamId,
        floor.toString(),
        after?.member_id ?? null,
        afterKind,
        afterWire,
        input.page_limit + 1,
      ],
    );
    const hasMore = result.rows.length > input.page_limit;
    const page = result.rows.slice(0, input.page_limit);
    const items = page.map((row) =>
      row.kind_order === 0
        ? {
            kind: "frontier",
            member_id: row.member_id,
            server_seq: row.server_seq,
          }
        : { kind: "exact", member_id: row.member_id, wire_id: row.wire_id },
    );
    const last = items.at(-1);
    const nextPageAfter =
      hasMore && last
        ? last.kind === "frontier"
          ? { member_id: last.member_id, kind: "frontier" }
          : { member_id: last.member_id, kind: "exact", wire_id: last.wire_id }
        : null;

    return {
      ...common(serverId, team),
      current_seq: team.current_seq,
      items,
      next_page_after: nextPageAfter,
      has_more: hasMore,
    };
  });
}

async function deleteCoveredExact(
  client: PoolClient,
  teamId: string,
  floor: bigint,
): Promise<void> {
  await client.query(
    `DELETE FROM read_exact e
      WHERE e.team_id = $1
        AND COALESCE(
          (SELECT m.team_seq FROM messages m
            WHERE m.team_id=e.team_id AND m.id=e.wire_id),
          (SELECT t.original_team_seq FROM message_tombstones t
            WHERE t.team_id=e.team_id AND t.id=e.wire_id)
        ) <= GREATEST(COALESCE(
          (SELECT f.server_seq FROM read_frontiers f
            WHERE f.team_id=e.team_id AND f.member_id=e.member_id), 0), $2::bigint)`,
    [teamId, floor.toString()],
  );
}

export type RetentionNotice = {
  team_id: string;
  old_floor: string;
  new_floor: string;
  removed_live_rows: number;
};

async function retainThroughLocked(
  client: PoolClient,
  teamId: string,
  currentFloor: bigint,
  through: bigint,
): Promise<RetentionNotice> {
  const tombstones = await client.query(
    `INSERT INTO message_tombstones
       (team_id, id, original_team_seq, envelope_digest)
     SELECT team_id, id, team_seq, envelope_digest
       FROM messages
      WHERE team_id = $1 AND team_seq <= $2::bigint
     RETURNING id`,
    [teamId, through.toString()],
  );
  const deleted = await client.query(
    "DELETE FROM messages WHERE team_id = $1 AND team_seq <= $2::bigint",
    [teamId, through.toString()],
  );
  if (deleted.rowCount !== tombstones.rowCount) {
    throw new Error("retention tombstone and deletion counts differ");
  }
  await client.query(
    "UPDATE teams SET min_available_seq = $2 WHERE team_id = $1",
    [teamId, through.toString()],
  );
  await client.query(
    `UPDATE read_frontiers SET server_seq = GREATEST(server_seq, $2::bigint)
      WHERE team_id = $1`,
    [teamId, through.toString()],
  );
  await deleteCoveredExact(client, teamId, through);
  return {
    team_id: teamId,
    old_floor: currentFloor.toString(),
    new_floor: through.toString(),
    removed_live_rows: deleted.rowCount ?? 0,
  };
}

export async function retainThrough(
  pool: Pool,
  teamId: string,
  through: bigint,
): Promise<Record<string, unknown>> {
  return inTransaction(pool, async (client) => {
    const serverId = await serverInstanceId(client);
    const team = await teamRow(client, teamId, true);
    if (!team) throw notFound(serverId, teamId);
    const currentFloor = BigInt(team.min_available_seq);
    const currentSequence = BigInt(team.current_seq);
    if (through < currentFloor || through > currentSequence) {
      throw new ProtocolError(
        400,
        "invalid-request",
        "retention floor must be between the current floor and current sequence",
        {
          through: through.toString(),
          min_available_seq: team.min_available_seq,
          current_seq: team.current_seq,
        },
        { serverInstanceId: serverId, teamId },
      );
    }

    const notice = await retainThroughLocked(
      client,
      teamId,
      currentFloor,
      through,
    );
    return {
      ...common(serverId, { ...team, min_available_seq: through.toString() }),
      retained_through: through.toString(),
      tombstones_created: String(notice.removed_live_rows),
    };
  });
}

export async function getMessages(
  pool: Pool,
  teamId: string,
  after: bigint,
  limit: number,
): Promise<Record<string, unknown>> {
  return inTransaction(
    pool,
    async (client) => {
      const serverId = await serverInstanceId(client);
      const team = await teamRow(client, teamId);
      if (!team) throw notFound(serverId, teamId);
      if (after < BigInt(team.min_available_seq)) {
        throw new ProtocolError(
          410,
          "resync-required",
          "cursor predates retained history",
          {
            after: after.toString(),
            min_available_seq: team.min_available_seq,
          },
          { serverInstanceId: serverId, teamId },
        );
      }
      const result = await client.query<LiveMessageRow>(
        `SELECT id::text, team_seq::text, ${timestampSql("server_received_at")} AS server_received_at,
                envelope_v, cipher, key_id, blob, envelope_digest
           FROM messages
          WHERE team_id = $1 AND team_seq > $2::bigint
          ORDER BY team_seq::bigint ASC
          LIMIT $3`,
        [teamId, after.toString(), limit + 1],
      );
      const hasMore = result.rows.length > limit;
      const page = result.rows.slice(0, limit);
      return {
        ...common(serverId, team),
        messages: page.map((row) => ({
          server_seq: row.team_seq,
          id: row.id,
          server_received_at: row.server_received_at,
          envelope: {
            v: row.envelope_v,
            cipher: row.cipher,
            key_id: row.key_id,
            blob: row.blob,
          },
        })),
        next_after: page.at(-1)?.team_seq ?? after.toString(),
        has_more: hasMore,
      };
    },
    { readOnly: true, repeatableRead: true },
  );
}

export async function capabilitySnapshot(
  client: PoolClient,
  teamId: string,
  lockTeam = false,
): Promise<Record<string, unknown>> {
  const serverId = await serverInstanceId(client);
  const team = await teamRow(client, teamId, lockTeam);
  if (!team) throw notFound(serverId, teamId);
  const historyResult = await client.query<{
    policy_revision: string;
    effective_from_seq: string;
    accepted_envelope_versions: number[];
    write_allowed_ciphers: string[];
  }>(
    `SELECT policy_revision::text, effective_from_seq::text,
            accepted_envelope_versions, write_allowed_ciphers
       FROM (
         SELECT DISTINCT ON (effective_from_seq)
                policy_revision, effective_from_seq,
                accepted_envelope_versions, write_allowed_ciphers
           FROM team_policy_history
          WHERE team_id = $1
          ORDER BY effective_from_seq, policy_revision DESC
       ) effective
      ORDER BY effective_from_seq, policy_revision`,
    [teamId],
  );
  if (historyResult.rows.length < 1 || historyResult.rows.length > 4096) {
    throw new Error("team policy history is outside the protocol bounds");
  }
  const current = BigInt(team.current_seq);
  return {
    ...common(serverId, team),
    current_seq: team.current_seq,
    next_sequence_boundary:
      current === MAX_SEQUENCE ? null : (current + 1n).toString(),
    accepted_envelope_versions: team.accepted_envelope_versions,
    write_allowed_ciphers: team.write_allowed_ciphers,
    policy_revision: team.policy_revision,
    effective_from_seq: historyResult.rows.at(-1)?.effective_from_seq,
    max_blob_bytes: String(team.max_blob_bytes),
    policy_history: historyResult.rows,
  };
}

export async function getCapabilities(
  pool: Pool,
  teamId: string,
): Promise<Record<string, unknown>> {
  return inTransaction(pool, (client) => capabilitySnapshot(client, teamId), {
    readOnly: true,
    repeatableRead: true,
  });
}

// Registers a team the client already owns: the team row and its opening
// policy, plus the roster. The team_id is the client's — the server records it,
// it never mints one. Returns the capability snapshot the client reads back to
// confirm what the server now holds.
export async function connectTeam(
  pool: Pool,
  input: ConnectInput,
): Promise<Record<string, unknown>> {
  return inTransaction(pool, async (client) => {
      const serverId = await serverInstanceId(client);
      // The team and its opening policy row.
      // team_policy_history is required: capabilitySnapshot (and so
      // GET /v1/capabilities) reads it, and a team without it is out of bounds.
      //
      // ON CONFLICT makes the primary key the sole arbiter of "already
      // registered", so the refusal holds under concurrency, not just serially: a
      // second connect for the same team_id inserts nothing, and a concurrent one
      // blocks on the first transaction's commit before it resolves to the same.
      // A read-then-insert would instead let two connects both miss the row and
      // the losing INSERT raise a raw primary-key violation (500) — the retry a
      // timed-out client sends races its own first attempt exactly this way.
      const inserted = await client.query(
        `INSERT INTO teams
         (team_id, team_name, members_revision,
          accepted_envelope_versions, write_allowed_ciphers, cipher_profile)
       VALUES ($1, $2, 0, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[], $3)
       ON CONFLICT (team_id) DO NOTHING`,
        // A client that sends no declaration leaves NULL. Nothing stands in for
        // it: an absent declaration and a declared 'none' are different facts,
        // and only one of them is safe to act on.
        [input.team_id, input.team_name, input.cipher_profile ?? null],
      );
      // A repeat connect writes NOTHING, including no declaration. This route
      // carries no credential, and its safety rests on exactly that: knowing a
      // team_id is not permission to change an existing team. One write here —
      // even one narrowed to `IS NULL` — would let anyone holding a team_id
      // fix the profile before the machine that owns the team, and 'none' fixed
      // first is the dangerous direction. A team already registered is settled
      // by a message it stores, below, not by being named again.
      //
      // Refused as a uniqueness conflict, the same reason git refuses a
      // non-fast-forward push — not an authorization decision.
      if (inserted.rowCount === 0) {
        throw new ProtocolError(
          409,
          "team-already-exists",
          "a team with this id is already registered",
          { team_id: input.team_id },
          { serverInstanceId: serverId, teamId: input.team_id },
        );
      }
      await client.query(
        `INSERT INTO team_policy_history
         (team_id, policy_revision, effective_from_seq,
          accepted_envelope_versions, write_allowed_ciphers)
       VALUES ($1, 0, 1, ARRAY[1], ARRAY['none', 'age-v1']::TEXT[])`,
        [input.team_id],
      );
      // The roster the client owns. member_identity_history is append-only and
      // retires a (team, name) for the life of the team; members is the live set.
      // The schema has already rejected duplicate ids or names within the batch.
      for (const member of input.members) {
        await client.query(
          `INSERT INTO member_identity_history (team_id, member_id, name)
         VALUES ($1, $2, $3)`,
          [input.team_id, member.member_id, member.name],
        );
        await client.query(
          `INSERT INTO members (team_id, member_id, name) VALUES ($1, $2, $3)`,
          [input.team_id, member.member_id, member.name],
        );
      }
    return capabilitySnapshot(client, input.team_id);
  });
}

async function roster(
  client: PoolClient,
  teamId: string,
): Promise<Record<string, unknown>[]> {
  const members = await client.query<{ member_id: string; name: string }>(
    `SELECT member_id::text, name FROM members
      WHERE team_id = $1 ORDER BY member_id`,
    [teamId],
  );
  const registrations = await client.query<{
    registration_id: string;
    member_id: string;
    installation_id: string;
    type: string;
  }>(
    `SELECT registration_id::text, member_id::text, installation_id::text, type
       FROM registrations WHERE team_id = $1
      ORDER BY registration_id`,
    [teamId],
  );
  return members.rows.map((member) => ({
    member_id: member.member_id,
    name: member.name,
    registrations: registrations.rows
      .filter((registration) => registration.member_id === member.member_id)
      .map(({ member_id: _memberId, ...registration }) => registration),
  }));
}

// What a machine that has none of this needs before it can read history: which
// team it is and what the server will accept.
//
// Deliberately NOT who is in it. Membership changes travel inside the envelope,
// so under e2ee this server cannot read them -- a roster it handed out would be
// the one frozen at connect, served confidently to every machine that arrives
// later. Removing the roster from the answer removes that failure rather than
// managing it, and it follows from what e2ee is for here: if encryption
// protects you from whoever runs the server, who is on the team is theirs to
// know too. Each machine derives the roster by replaying the team journal.
// Every team registered under a name. A name is not unique -- only team_id is
// -- so this answers with a list and lets the caller decide, rather than
// picking one and being right most of the time.
//
// What comes back is deliberately thin: the id to pull with, when the team was
// registered, and how much history it holds. That is enough for a human to tell
// two same-named teams apart, and it is all operational metadata that lives
// outside the envelope. The roster is not here, and must not be: it travels
// inside the envelope, so an e2ee team could not offer it and a plaintext one
// offering it anyway would make plaintext the better-featured choice.
export async function resolveTeamsByName(
  pool: Pool,
  teamName: string,
): Promise<Record<string, unknown>> {
  return inTransaction(
    pool,
    async (client) => {
      const serverId = await serverInstanceId(client);
      const rows = await client.query<{
        team_id: string;
        team_name: string;
        registered_at: string;
        current_seq: string;
      }>(
        `SELECT team_id::text, team_name,
                ${timestampSql("registered_at")} AS registered_at,
                current_seq::text
           FROM teams WHERE team_name = $1
          ORDER BY registered_at, team_id
          LIMIT $2`,
        [teamName, MAX_TEAMS_PER_NAME + 1],
      );
      if (rows.rows.length > MAX_TEAMS_PER_NAME) {
        throw new ProtocolError(
          409,
          "team-name-match-limit-exceeded",
          "too many teams share this name to choose between them",
          { team_name: teamName, limit: MAX_TEAMS_PER_NAME },
          { serverInstanceId: serverId },
        );
      }
      return {
        protocol_version: 1,
        server_instance_id: serverId,
        team_name: teamName,
        teams: rows.rows,
      };
    },
    { readOnly: true, repeatableRead: true },
  );
}

export async function getTeamSnapshot(
  pool: Pool,
  teamId: string,
): Promise<Record<string, unknown>> {
  return inTransaction(pool, (client) => capabilitySnapshot(client, teamId), {
    readOnly: true,
    repeatableRead: true,
  });
}

export async function getMembers(
  pool: Pool,
  teamId: string,
): Promise<Record<string, unknown>> {
  return inTransaction(
    pool,
    async (client) => {
      const serverId = await serverInstanceId(client);
      const team = await teamRow(client, teamId);
      if (!team) throw notFound(serverId, teamId);
      return {
        ...common(serverId, team),
        members_revision: team.members_revision,
        members: await roster(client, teamId),
      };
    },
    { readOnly: true, repeatableRead: true },
  );
}

// `teamId` asks a second question: does this server actually have that team?
//
// The answer comes from the database, never from the request. Echoing the header
// back would let a client compare its own value with itself and call that
// agreement — true even for a team this server has never heard of, which is the
// case the check exists for.
//
// An unknown team is a 200 without `team_id`, not a 404. Health stays a liveness
// answer: an edge in front of this may route by team and cannot always turn "no
// such team" into a status code, and a 404 here would be indistinguishable from
// "no such route" to a client checking whether the server is up at all. Absence
// carries the disagreement instead, and the client — which knows which team it
// expects — is where that is judged.
export async function health(
  pool: Pool,
  teamId?: string,
): Promise<{
  status: "ok";
  server_instance_id: string;
  protocol: { supported_versions: number[] };
  database: "ok";
  team_id?: string;
}> {
  // Only a failure HERE means the database is actually unreachable. Anything
  // that goes wrong after a client is in hand -- a query bug, an unexpected
  // row shape -- had a working connection, so it is not this.
  let client: PoolClient;
  try {
    client = await pool.connect();
  } catch (error) {
    throw new DatabaseUnavailableError(error);
  }
  try {
    const serverId = await serverInstanceId(client);
    const base = {
      status: "ok" as const,
      server_instance_id: serverId,
      protocol: { supported_versions: [1] },
      database: "ok" as const,
    };
    if (teamId === undefined) return base;
    const team = await teamRow(client, teamId);
    return team ? { ...base, team_id: team.team_id } : base;
  } finally {
    client.release();
  }
}
