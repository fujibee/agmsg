import { z } from "zod";

const environmentSchema = z.object({
  DATABASE_URL: z.string().min(1),
  HOST: z.string().default("127.0.0.1"),
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  LOG_LEVEL: z
    .enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"])
    .default("info"),
  AGMSG_PROFILE: z.enum(["open", "accounts"]).default("open"),
  // accounts profile only (see loadConfig): the owner's sign-in secret, and the
  // public origin the approval page and capability URLs are built from.
  AGMSG_OWNER_SECRET: z.string().optional(),
  AGMSG_PUBLIC_URL: z.string().optional(),
  // Comma-separated client ids that may ask for a device code. Public
  // identifiers, not secrets; the default is the agmsg command-line client.
  AGMSG_DEVICE_CLIENT_IDS: z.string().optional(),
  AGMSG_RETENTION_MAX_LIVE_MESSAGES: z.string()
    .regex(/^[1-9][0-9]*$/u)
    .refine((value) => BigInt(value) <= 9_223_372_036_854_775_807n,
      "retention maximum exceeds signed BIGINT")
    .optional(),
});

export type Profile = "open" | "accounts";

export type Config = {
  // "open": no accounts, reaching the server is the permission. "accounts":
  // devices approved by the owner, data routes only under a capability URL.
  profile: Profile;
  // Set (and validated) only in the accounts profile; null in open.
  ownerSecret: string | null;
  // Origin only, no trailing slash: https://agmsg.example.com
  publicUrl: string | null;
  // Client ids accepted at POST /v1/device/code (accounts profile).
  deviceClientIds: string[];
  databaseUrl: string;
  host: string;
  port: number;
  logLevel: z.infer<typeof environmentSchema>["LOG_LEVEL"];
  retentionMaxLiveMessages: bigint | null;
};

const MIN_SECRET_LENGTH = 32;
const MIN_DISTINCT_CHARACTERS = 12;

// A floor, not a proof of entropy: 32 characters with a dozen distinct ones
// cannot be a word, a repeat or a short pin. Generating one properly is what
// the error says to do.
export function ownerSecretProblem(secret: string): string | null {
  if (secret.length >= MIN_SECRET_LENGTH && new Set(secret).size >= MIN_DISTINCT_CHARACTERS) {
    return null;
  }
  return "AGMSG_OWNER_SECRET must be at least 128 bits of randomness " +
    `(${MIN_SECRET_LENGTH}+ characters, ${MIN_DISTINCT_CHARACTERS}+ distinct). ` +
    "Make one with: openssl rand -hex 32";
}

function publicOrigin(value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("AGMSG_PUBLIC_URL must be an absolute http(s) URL");
  }
  if ((url.protocol !== "https:" && url.protocol !== "http:") ||
      url.pathname !== "/" || url.search !== "" || url.hash !== "" ||
      url.username !== "" || url.password !== "") {
    throw new Error("AGMSG_PUBLIC_URL must be an origin only, like https://agmsg.example.com");
  }
  return url.origin;
}

export function loadConfig(environment: NodeJS.ProcessEnv = process.env): Config {
  const parsed = environmentSchema.parse(environment);
  let ownerSecret: string | null = null;
  let publicUrl: string | null = null;
  if (parsed.AGMSG_PROFILE === "accounts") {
    if (parsed.AGMSG_OWNER_SECRET === undefined) {
      throw new Error("AGMSG_PROFILE=accounts needs AGMSG_OWNER_SECRET. " +
        "Make one with: openssl rand -hex 32");
    }
    const problem = ownerSecretProblem(parsed.AGMSG_OWNER_SECRET);
    if (problem) throw new Error(problem);
    ownerSecret = parsed.AGMSG_OWNER_SECRET;
    if (parsed.AGMSG_PUBLIC_URL === undefined) {
      throw new Error("AGMSG_PROFILE=accounts needs AGMSG_PUBLIC_URL, the origin devices reach this server at");
    }
    publicUrl = publicOrigin(parsed.AGMSG_PUBLIC_URL);
  }
  return {
    profile: parsed.AGMSG_PROFILE,
    ownerSecret,
    publicUrl,
    deviceClientIds: (parsed.AGMSG_DEVICE_CLIENT_IDS ?? "agmsg-cli")
      .split(",").map((id) => id.trim()).filter((id) => id !== ""),
    databaseUrl: parsed.DATABASE_URL,
    host: parsed.HOST,
    port: parsed.PORT,
    logLevel: parsed.LOG_LEVEL,
    retentionMaxLiveMessages: parsed.AGMSG_RETENTION_MAX_LIVE_MESSAGES === undefined
      ? null
      : BigInt(parsed.AGMSG_RETENTION_MAX_LIVE_MESSAGES),
  };
}
