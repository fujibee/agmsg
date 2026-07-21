import Fastify, {
  type FastifyInstance,
  type FastifyRequest,
} from "fastify";
import * as duplicateKeyJson from "json-dup-key-validator";
import type { Pool } from "pg";
import { ZodError, z } from "zod";
import type { Config } from "./config.js";
import {
  authenticateCredential,
  credentialBinding,
  exchangePairingToken,
  revokeCredential,
  type CredentialIdentity,
} from "./credentials.js";
import { errorBody, ProtocolError } from "./errors.js";
import {
  MAX_REQUEST_BYTES,
  messagesQuerySchema,
  parseSequence,
  postMessagesSchema,
  readStateSyncSchema,
  uuidV7Schema,
} from "./protocol.js";
import {
  getCapabilities,
  getMembers,
  getMessages,
  health,
  postMessages,
  syncReadState,
} from "./storage.js";

const emptyQuerySchema = z.object({}).strict();
const pairingExchangeSchema = z.object({ token: z.string().min(32).max(256) }).strict();
const credentialParamsSchema = z.object({ credentialId: uuidV7Schema }).strict();

function requireProtocol(request: FastifyRequest): void {
  const version = request.headers["agmsg-protocol-version"];
  if (version !== "1") {
    throw new ProtocolError(
      426,
      "unsupported-protocol-version",
      "Agmsg-Protocol-Version must match /v1",
      { requested_version: version ?? null, supported_versions: [1] },
    );
  }
}

function requestedTeamId(request: FastifyRequest): string {
  const parsed = uuidV7Schema.safeParse(request.headers["agmsg-team-id"]);
  if (!parsed.success) {
    throw new ProtocolError(400, "invalid-request", "Agmsg-Team-ID is invalid");
  }
  return parsed.data;
}

function bearerSecret(request: FastifyRequest): string | undefined {
  const authorization = request.headers.authorization;
  return typeof authorization === "string" && authorization.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : undefined;
}

async function scopedCredential(
  pool: Pool,
  request: FastifyRequest,
  includeRevoked = false,
): Promise<{ teamId: string; credential?: CredentialIdentity }> {
  requireProtocol(request);
  const teamId = requestedTeamId(request);
  const secret = bearerSecret(request);
  if (!secret) {
    throw new ProtocolError(401, "unauthenticated", "valid credentials are required");
  }
  const credential = await authenticateCredential(pool, teamId, secret, includeRevoked);
  if (!credential) {
    throw new ProtocolError(401, "unauthenticated", "valid credentials are required");
  }
  return { teamId, credential };
}

async function scopedTeamId(
  pool: Pool,
  request: FastifyRequest,
): Promise<string> {
  return (await scopedCredential(pool, request)).teamId;
}

export function createApp(pool: Pool, config: Config): FastifyInstance {
  const app = Fastify({
    logger: config.logLevel === "silent" ? false : {
      level: config.logLevel,
      redact: {
        paths: [
          "req.headers.authorization",
          "req.body.token",
          "res.body.credential",
          "token",
          "credential",
        ],
        censor: "[REDACTED]",
      },
    },
    bodyLimit: MAX_REQUEST_BYTES,
  });

  app.removeContentTypeParser("application/json");
  app.addContentTypeParser(
    "application/json",
    { parseAs: "buffer" },
    (_request, body, done) => {
      try {
        const bytes = typeof body === "string" ? Buffer.from(body) : body;
        const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
        done(null, duplicateKeyJson.parse(source, false));
      } catch (error) {
        const parsingError = error instanceof Error ? error : new Error("invalid JSON");
        Object.assign(parsingError, { statusCode: 400 });
        done(parsingError, undefined);
      }
    },
  );

  app.addHook("onRequest", async (request) => {
    const encoding = request.headers["content-encoding"];
    if (encoding !== undefined && encoding !== "identity") {
      throw new ProtocolError(
        400,
        "invalid-request",
        "Content-Encoding must be identity",
      );
    }
  });

  app.addHook("onSend", async (_request, reply, payload) => {
    reply.header("Agmsg-Protocol-Version", "1");
    return payload;
  });

  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ProtocolError) {
      void reply.status(error.statusCode).send(errorBody(error));
      return;
    }
    if (
      error instanceof ZodError ||
      error instanceof SyntaxError ||
      statusCode(error) === 400 ||
      statusCode(error) === 415
    ) {
      const protocolError = new ProtocolError(
        400,
        "invalid-request",
        "request body, query, or JSON framing is invalid",
      );
      void reply.status(400).send(errorBody(protocolError));
      return;
    }
    if (statusCode(error) === 413) {
      const protocolError = new ProtocolError(
        413,
        "request-too-large",
        "request body exceeds 2 MiB",
      );
      void reply.status(413).send(errorBody(protocolError));
      return;
    }
    requestLog(reply, error);
    const protocolError = new ProtocolError(
      500,
      "internal-error",
      "an internal server error occurred",
    );
    void reply.status(500).send(errorBody(protocolError));
  });

  app.get("/v1/health", async (_request, reply) => {
    try {
      return await health(pool);
    } catch {
      return reply.status(503).send({
        status: "unavailable",
        protocol: { supported_versions: [1] },
        database: "unavailable",
      });
    }
  });

  app.get("/v1/capabilities", async (request, reply) => {
    emptyQuerySchema.parse(request.query);
    const teamId = await scopedTeamId(pool, request);
    reply.header("Cache-Control", "no-store");
    return getCapabilities(pool, teamId);
  });

  app.get("/v1/members", async (request) => {
    emptyQuerySchema.parse(request.query);
    return getMembers(pool, await scopedTeamId(pool, request));
  });

  app.get("/v1/messages", async (request) => {
    const teamId = await scopedTeamId(pool, request);
    const query = messagesQuerySchema.parse(request.query);
    return getMessages(pool, teamId, parseSequence(query.after), query.limit);
  });

  app.post("/v1/messages", async (request) => {
    const teamId = await scopedTeamId(pool, request);
    const body = postMessagesSchema.parse(request.body);
    return postMessages(pool, teamId, body.messages);
  });

  app.post("/v1/read-state/sync", async (request, reply) => {
    emptyQuerySchema.parse(request.query);
    const teamId = await scopedTeamId(pool, request);
    const body = readStateSyncSchema.parse(request.body);
    reply.header("Cache-Control", "no-store");
    return syncReadState(pool, teamId, body);
  });

  app.post("/v1/pairing/exchange", async (request, reply) => {
    requireProtocol(request);
    emptyQuerySchema.parse(request.query);
    const body = pairingExchangeSchema.parse(request.body);
    reply.header("Cache-Control", "no-store");
    return exchangePairingToken(pool, body.token);
  });

  app.post("/v1/credentials/:credentialId/revoke", async (request, reply) => {
    emptyQuerySchema.parse(request.query);
    z.undefined().parse(request.body);
    const params = credentialParamsSchema.parse(request.params);
    const authenticated = await scopedCredential(pool, request, true);
    if (
      authenticated.credential &&
      authenticated.credential.credentialId !== params.credentialId
    ) {
      const binding = await credentialBinding(pool, authenticated.teamId);
      throw new ProtocolError(
        403,
        "credential-scope-violation",
        "a credential may revoke only itself",
        { credential_id: params.credentialId },
        binding,
      );
    }
    reply.header("Cache-Control", "no-store");
    return revokeCredential(pool, authenticated.teamId, params.credentialId);
  });

  return app;
}

function requestLog(reply: { log: { error: (value: unknown) => void } }, error: unknown) {
  reply.log.error(error);
}

function statusCode(error: unknown): number | undefined {
  if (typeof error !== "object" || error === null || !("statusCode" in error)) {
    return undefined;
  }
  return typeof error.statusCode === "number" ? error.statusCode : undefined;
}
