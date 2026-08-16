import { z } from "zod";

const environmentSchema = z.object({
  DATABASE_URL: z.string().min(1),
  HOST: z.string().default("127.0.0.1"),
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  LOG_LEVEL: z
    .enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"])
    .default("info"),
  AGMSG_RETENTION_MAX_LIVE_MESSAGES: z.string()
    .regex(/^[1-9][0-9]*$/u)
    .refine((value) => BigInt(value) <= 9_223_372_036_854_775_807n,
      "retention maximum exceeds signed BIGINT")
    .optional(),
});

export type Config = {
  databaseUrl: string;
  host: string;
  port: number;
  logLevel: z.infer<typeof environmentSchema>["LOG_LEVEL"];
  retentionMaxLiveMessages: bigint | null;
};

export function loadConfig(environment: NodeJS.ProcessEnv = process.env): Config {
  const parsed = environmentSchema.parse(environment);
  return {
    databaseUrl: parsed.DATABASE_URL,
    host: parsed.HOST,
    port: parsed.PORT,
    logLevel: parsed.LOG_LEVEL,
    retentionMaxLiveMessages: parsed.AGMSG_RETENTION_MAX_LIVE_MESSAGES === undefined
      ? null
      : BigInt(parsed.AGMSG_RETENTION_MAX_LIVE_MESSAGES),
  };
}
