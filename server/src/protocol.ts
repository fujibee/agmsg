import { createHash } from "node:crypto";
import { z } from "zod";

export const MAX_SEQUENCE = 9_223_372_036_854_775_807n;
export const MAX_REQUEST_BYTES = 2 * 1024 * 1024;
export const MAX_BLOB_BYTES = 1024 * 1024;

const uuidV4Pattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const uuidV7Pattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const sequencePattern = /^(0|[1-9][0-9]*)$/;
const cipherPattern = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const timestampPattern =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;

export const uuidV4Schema = z.string().regex(uuidV4Pattern);
export const uuidV7Schema = z.string().regex(uuidV7Pattern);
export const timestampSchema = z.string().regex(timestampPattern);

export const teamNameSchema = z.string().refine((value) => {
  const scalars = [...value];
  return (
    value === value.normalize("NFC") &&
    scalars.length >= 1 &&
    scalars.length <= 128 &&
    !/[\u0000-\u001f\u007f]/u.test(value)
  );
});

export const sequenceSchema = z.string().regex(sequencePattern).refine((value) => {
  try {
    return BigInt(value) <= MAX_SEQUENCE;
  } catch {
    return false;
  }
});

export function parseSequence(value: string): bigint {
  return BigInt(sequenceSchema.parse(value));
}

function canonicalBlob(value: string): boolean {
  if (value.length < 1 || value.length > 1_398_104) return false;
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    return false;
  }
  const bytes = Buffer.from(value, "base64");
  return bytes.length <= MAX_BLOB_BYTES && bytes.toString("base64") === value;
}

const keyIdSchema = z.union([
  z.null(),
  z.string().refine((value) => {
    const bytes = Buffer.byteLength(value, "utf8");
    return (
      value === value.normalize("NFC") &&
      bytes >= 1 &&
      bytes <= 256 &&
      !/[\u0000-\u001f\u007f]/u.test(value)
    );
  }),
]);

export const envelopeSchema = z
  .object({
    v: z.number().int().min(0).max(0xffff_ffff),
    cipher: z.string().regex(cipherPattern),
    key_id: keyIdSchema,
    blob: z.string().refine(canonicalBlob),
  })
  .strict()
  .superRefine((value, context) => {
    if (value.cipher === "none" && value.key_id !== null) {
      context.addIssue({
        code: "custom",
        path: ["key_id"],
        message: "key_id must be null for cipher none",
      });
    }
    if (value.cipher !== "none" && value.key_id === null) {
      context.addIssue({
        code: "custom",
        path: ["key_id"],
        message: "key_id must be present for encrypted ciphers",
      });
    }
  });

export const messageInputSchema = z
  .object({ id: uuidV4Schema, envelope: envelopeSchema })
  .strict();

export const postMessagesSchema = z
  .object({ messages: z.array(messageInputSchema).min(1).max(1000) })
  .strict();

export type Envelope = z.infer<typeof envelopeSchema>;
export type MessageInput = z.infer<typeof messageInputSchema>;

export const messagesQuerySchema = z.object({
  after: sequenceSchema,
  limit: z.preprocess(
    (value) => value ?? "100",
    z
      .string()
      .regex(/^[1-9][0-9]*$/)
      .transform(Number)
      .refine((value) => value >= 1 && value <= 1000),
  ),
}).strict();

const readFrontierKeySchema = z
  .object({ member_id: uuidV7Schema, kind: z.literal("frontier") })
  .strict();
const readExactKeySchema = z
  .object({
    member_id: uuidV7Schema,
    kind: z.literal("exact"),
    wire_id: uuidV4Schema,
  })
  .strict();

export const readStateSyncSchema = z
  .object({
    updates: z
      .array(
        z
          .object({
            member_id: uuidV7Schema,
            server_seq: sequenceSchema,
            exact_wire_ids: z.array(uuidV4Schema).max(1000),
          })
          .strict()
          .refine(
            (value) => new Set(value.exact_wire_ids).size === value.exact_wire_ids.length,
            { message: "exact_wire_ids must be distinct" },
          ),
      )
      .max(1000),
    page_after: z.union([readFrontierKeySchema, readExactKeySchema]).nullable(),
    page_limit: z.number().int().min(1).max(1000),
  })
  .strict()
  .superRefine((value, context) => {
    if (new Set(value.updates.map((update) => update.member_id)).size !== value.updates.length) {
      context.addIssue({ code: "custom", path: ["updates"], message: "member IDs must be distinct" });
    }
    const exactCount = value.updates.reduce(
      (count, update) => count + update.exact_wire_ids.length,
      0,
    );
    if (exactCount > 1000) {
      context.addIssue({ code: "custom", path: ["updates"], message: "too many exact reads" });
    }
  });

export type ReadStateSyncInput = z.infer<typeof readStateSyncSchema>;

export const agentNameSchema = z.string().refine((value) => {
  const scalars = [...value];
  return (
    value === value.normalize("NFC") &&
    scalars.length >= 1 &&
    scalars.length <= 128 &&
    !value.startsWith("-") &&
    value !== "." &&
    value !== ".." &&
    !/[./\\"\[\]\u0000-\u001f\u007f]/u.test(value)
  );
});

// POST /v1/connect registers a team the client already owns. The team_id and
// every member_id are minted on the owning machine; the server records what it
// is sent, it never originates a team. A member is just an identity here —
// id + name — because with no server-side authentication there are no
// per-device credentials to attach.
const connectMemberSchema = z
  .object({
    member_id: uuidV7Schema,
    name: agentNameSchema,
  })
  .strict();

export const connectSchema = z
  .object({
    team_id: uuidV7Schema,
    team_name: teamNameSchema,
    members: z.array(connectMemberSchema).max(1000),
    // What this team uses — the connecting machine's own declaration, not a
    // guess. Optional so a client that predates it still connects; the team is
    // then recorded with no declaration rather than a wrong one.
    //
    // Not a secret: naming a cipher profile reveals nothing about the plaintext,
    // and the server already sees the per-envelope `cipher` on every message it
    // stores. What it could not see is a team that has sent none yet.
    cipher_profile: z.enum(["none", "age-v1"]).optional(),
  })
  .strict()
  .superRefine((value, context) => {
    if (new Set(value.members.map((member) => member.member_id)).size !== value.members.length) {
      context.addIssue({ code: "custom", path: ["members"], message: "member IDs must be distinct" });
    }
    if (new Set(value.members.map((member) => member.name)).size !== value.members.length) {
      context.addIssue({ code: "custom", path: ["members"], message: "member names must be distinct" });
    }
  });

export type ConnectInput = z.infer<typeof connectSchema>;

function u32(value: number): Buffer {
  const buffer = Buffer.allocUnsafe(4);
  buffer.writeUInt32BE(value);
  return buffer;
}

function sized(value: Buffer): Buffer {
  return Buffer.concat([u32(value.length), value]);
}

export function envelopeDigest(envelope: Envelope): Buffer {
  const cipher = Buffer.from(envelope.cipher, "utf8");
  const blob = Buffer.from(envelope.blob, "base64");
  const key =
    envelope.key_id === null
      ? Buffer.from([0])
      : Buffer.concat([Buffer.from([1]), sized(Buffer.from(envelope.key_id, "utf8"))]);
  return createHash("sha256")
    .update(
      Buffer.concat([
        Buffer.from("agmsg-envelope-v1\0", "ascii"),
        u32(envelope.v),
        sized(cipher),
        key,
        sized(blob),
      ]),
    )
    .digest();
}
