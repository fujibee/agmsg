import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Pool } from "pg";
import { z } from "zod";
import type { Config } from "../config.js";
import { resolveSecret } from "./capability.js";
import { removeDevice } from "./device-removal.js";
import { userCodeDigestOf } from "./codes.js";
import {
  AdmissionError, activateSecret, decideGrant, findPendingGrant, issueGrant,
  listTeams, pollToken,
} from "./device-flow.js";
import { DEVICE_LIMITS, FixedWindowCounter } from "./limits.js";
import {
  accountOfSession, createSession, ensureOwnerAccount, readCookie, secretsMatch,
  SESSION_COOKIE, sessionCookie,
} from "./owner.js";
import {
  PAGE_HEADERS, codeEntryPage, decisionPage, messagePage, signInPage,
} from "./page.js";

// Routes that exist only in the accounts profile, at the origin:
//   POST /v1/device/code, /v1/device/token, /v1/device/activate   (the machine)
//   GET  /approve, POST /approve/signin, /approve/decision, /v1/device/approve (the owner)
//   GET  /v1/devices                                            (a device, by its secret)
// The machine-facing bodies are strict: an unknown field is a 400, never dropped.

const uuid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu);

const codeBody = z.object({
  client_id: z.string().min(1).max(128),
  scope: z.enum(["login"]).default("login"),
  // The machine's own label. Rendered to the owner as a claim, so nothing that
  // could fake page copy: no control characters, no edge whitespace, NFC only.
  machine_name: z.string().min(1).max(128).refine(
    (name) => name === name.trim() && !/[\u0000-\u001f\u007f]/u.test(name) && name === name.normalize("NFC"),
  ),
  client_version: z.string().max(64).optional(),
  // What kind of agent this is (claude-code, codex, ...). Shown in the device list.
  device_type: z.string().min(1).max(64).regex(/^[A-Za-z0-9._-]+$/u).optional(),
  // The team the machine wants to join. Fixed here and not changeable at
  // approval; omitted when the owner should choose.
  team_id: uuid.optional(),
  // Ids of the environment markers that matched on the machine: ids only, never
  // values. At most 8, unique; the server stores them and does not interpret them.
  env_markers: z.array(z.string().regex(/^[a-z][a-z0-9-]{0,31}$/u)).max(8)
    .refine((ids) => new Set(ids).size === ids.length).optional(),
}).strict();

const tokenBody = z.object({
  device_code: z.string().min(1).max(512),
  client_id: z.string().min(1).max(128),
}).strict();

const registerBody = z.object({
  team_id: uuid,
  device_pubkey: z.string().regex(/^age1[0-9a-z]{58}$/u),
  // The device's own name for itself. The name it was approved under stays the
  // one the owner sees; this is accepted so a client can send one.
  label: z.string().min(1).max(128),
}).strict();

const approveBody = z.object({
  user_code: z.string().min(1).max(64),
  decision: z.enum(["approve", "deny"]),
  team_id: uuid.optional(),
}).strict();

function bearer(request: FastifyRequest): string | null {
  const header = request.headers.authorization;
  return header?.startsWith("Bearer ") ? header.slice("Bearer ".length) : null;
}

function noStore(reply: FastifyReply): void {
  void reply.header("cache-control", "no-store").header("pragma", "no-cache");
}

export async function registerDeviceRoutes(
  app: FastifyInstance,
  options: { pool: Pool; config: Config; onRemoved?: () => void },
): Promise<void> {
  const { pool, config } = options;
  const accountId = await ensureOwnerAccount(pool);
  const publicUrl = config.publicUrl ?? "";
  const secureCookie = publicUrl.startsWith("https:");
  const ownerSecret = config.ownerSecret ?? "";

  const issueLimiter = new FixedWindowCounter();
  const signInLimiter = new FixedWindowCounter();
  const actionLimiter = new FixedWindowCounter();
  const attemptLimiter = new FixedWindowCounter();
  const tokenLimiter = new FixedWindowCounter();
  const unknownCodeLimiter = new FixedWindowCounter();
  const sweeper = setInterval(() => {
    const now = Date.now();
    for (const limiter of [issueLimiter, signInLimiter, actionLimiter, attemptLimiter, tokenLimiter, unknownCodeLimiter]) limiter.sweep(now);
  }, 10 * 60 * 1000);
  sweeper.unref();
  app.addHook("onClose", async () => { clearInterval(sweeper); });

  // The approval page posts forms; JSON is already parsed by Fastify.
  app.addContentTypeParser(
    "application/x-www-form-urlencoded",
    { parseAs: "string" },
    (_request, body, done) => {
      done(null, Object.fromEntries(new URLSearchParams(typeof body === "string" ? body : body.toString("utf8"))));
    },
  );

  // ---- the machine ----------------------------------------------------

  app.post("/v1/device/code", async (request, reply) => {
    noStore(reply);
    const body = codeBody.safeParse(request.body);
    if (!body.success) return reply.status(400).send({ error: "bad_request" });
    if (!config.deviceClientIds.includes(body.data.client_id)) {
      return reply.status(400).send({ error: "invalid_client" });
    }
    if (!issueLimiter.hit(`ip:${request.ip}`, DEVICE_LIMITS.issuePerAddressPerHour, Date.now())) {
      return reply.status(429).send({ error: "slow_down" });
    }
    let issued;
    try {
      issued = await issueGrant(pool, {
        clientId: body.data.client_id,
        machineName: body.data.machine_name,
        deviceType: body.data.device_type ?? "unknown",
        teamId: body.data.team_id ?? null,
        envMarkers: body.data.env_markers ?? [],
      });
    } catch (error) {
      if (error instanceof AdmissionError) {
        return reply.status(503).send({ error: "temporarily_unavailable" });
      }
      throw error;
    }
    const verificationUri = `${publicUrl}/approve`;
    return reply.status(200).send({
      device_code: issued.material.deviceCode,
      user_code: issued.material.userCode,
      verification_uri: verificationUri,
      verification_uri_complete: `${verificationUri}?user_code=${encodeURIComponent(issued.material.userCode)}`,
      expires_in: issued.expiresIn,
      interval: issued.interval,
    });
  });

  app.post("/v1/device/token", async (request, reply) => {
    noStore(reply);
    const body = tokenBody.safeParse(request.body);
    if (!body.success) return reply.status(400).send({ error: "bad_request" });
    const now = Date.now();
    if (!tokenLimiter.hit(`tok:${request.ip}`, DEVICE_LIMITS.tokenPollsPerAddressPerHour, now) ||
        unknownCodeLimiter.over(`unk:${request.ip}`, DEVICE_LIMITS.unknownDeviceCodesPerAddressPerHour, now)) {
      return reply.status(429).send({ error: "slow_down" });
    }
    const result = await pollToken(pool, {
      deviceCode: body.data.device_code, clientId: body.data.client_id, accountId,
    }, config.limits.devices);
    if ("unknown" in result) {
      unknownCodeLimiter.hit(`unk:${request.ip}`, DEVICE_LIMITS.unknownDeviceCodesPerAddressPerHour, now);
    }
    switch (result.status) {
      case "slow_down":
        return reply.status(400).send({ error: "slow_down", interval: result.interval });
      case "limit_reached":
        // The stated refusal, in this endpoint's flat error shape: the limit and
        // its value are named. 403 like every limit-reached; the grant is not
        // consumed, so a later poll succeeds once a device is removed.
        return reply.status(403).send({
          error: "limit-reached", limit: "devices", value: result.value.toString(),
        });
      case "ready":
        // The secret's only appearance. The machine stores the URL, then activates.
        return reply.status(200).send({
          capability_url: `${publicUrl}/t/${result.secret}`,
          machine_name: result.machineName,
          scope: "login",
          // The approval binds one team, so the machine learns it here and needs
          // no name lookup under its capability URL. The pair is both or neither:
          // a team the machine named before this server has a row for it (first
          // connect) has no name yet, so both are left out rather than invented,
          // and the machine already holds the id it asked for.
          ...(result.teamName === null ? {} : { team_id: result.teamId, team_name: result.teamName }),
          // Opaque. The single owner account stands where a hosted service
          // names the organisation.
          org: result.accountId,
        });
      default:
        return reply.status(400).send({ error: result.status });
    }
  });

  app.post("/v1/device/activate", async (request, reply) => {
    noStore(reply);
    const secret = bearer(request);
    if (!secret) return reply.status(401).send({ error: "unauthenticated" });
    const result = await activateSecret(pool, secret);
    if (!result.ok) {
      return reply.status(result.reason === "not_found" ? 401 : 410).send({ error: result.reason });
    }
    return reply.status(200).send({ activated: true, machine_name: result.machineName });
  });

  // A device lists the live devices of its own team. `devicePubkey` stays null
  // until a key is registered; `type` and `lastFetchAt` (null when never) extend
  // the row for the owner's view.
  app.get("/v1/devices", async (request, reply) => {
    noStore(reply);
    const secret = bearer(request);
    const device = secret ? await resolveSecret(pool, secret) : null;
    if (!device) return reply.status(401).send({ error: "unauthenticated" });
    const { rows } = await pool.query<{
      device_id: string; name: string; device_type: string; created_at: Date; last_fetch_at: Date | null;
      device_pubkey: string | null;
    }>(
      `SELECT device_id, name, device_type, created_at, last_fetch_at, device_pubkey FROM devices
        WHERE team_id = $1 AND revoked_at IS NULL AND activated_at IS NOT NULL
        ORDER BY created_at, device_id`,
      [device.teamId],
    );
    return reply.status(200).send({
      devices: rows.map((row) => ({
        id: row.device_id,
        devicePubkey: row.device_pubkey,
        label: row.name,
        createdAt: row.created_at.toISOString(),
        thisMachine: row.device_id === device.deviceId,
        type: row.device_type,
        lastFetchAt: row.last_fetch_at ? row.last_fetch_at.toISOString() : null,
      })),
    });
  });

  // A device registers the age recipient a key handoff is sealed to. Idempotent
  // for the same key; a different key for a device that already registered one
  // is refused, never replaced. Flat errors, like the rest of this control plane.
  app.post("/v1/devices", async (request, reply) => {
    noStore(reply);
    const secret = bearer(request);
    const device = secret ? await resolveSecret(pool, secret) : null;
    if (!device) return reply.status(401).send({ error: "unauthenticated" });
    const body = registerBody.safeParse(request.body);
    if (!body.success) return reply.status(400).send({ error: "bad_request" });
    if (body.data.team_id !== device.teamId) return reply.status(403).send({ error: "forbidden" });
    // Only ever fills an empty slot, so two racing registrations cannot swap a key.
    const set = await pool.query(
      `UPDATE devices SET device_pubkey = $2 WHERE device_id = $1 AND device_pubkey IS NULL`,
      [device.deviceId, body.data.device_pubkey],
    );
    if (set.rowCount === 0) {
      const { rows } = await pool.query<{ device_pubkey: string | null }>(
        `SELECT device_pubkey FROM devices WHERE device_id = $1`, [device.deviceId]);
      if (rows[0]?.device_pubkey !== body.data.device_pubkey) {
        return reply.status(409).send({ error: "device_key_mismatch" });
      }
    }
    return reply.status(201).send({ device_id: device.deviceId });
  });

  // ---- the owner ------------------------------------------------------

  const ownerOf = async (request: FastifyRequest): Promise<string | null> =>
    accountOfSession(pool, readCookie(request.headers.cookie, SESSION_COOKIE));

  // A cookie-authenticated POST must come from the page itself: SameSite=Strict
  // keeps the cookie off cross-site requests, and the Origin check refuses the
  // rest (including a non-browser caller that has no Origin).
  const sameOrigin = (request: FastifyRequest): boolean => request.headers.origin === publicUrl;

  const sendPage = (reply: FastifyReply, status: number, html: string) =>
    reply.status(status).headers(PAGE_HEADERS).send(html);

  app.get("/approve", async (request, reply) => {
    if (!actionLimiter.hit(`act:${request.ip}`, DEVICE_LIMITS.actionsPerAddressPerHour, Date.now())) {
      return sendPage(reply, 429, messagePage("Slow down", "Too many requests. Try again later."));
    }
    const query = z.object({ user_code: z.string().max(64).optional() }).safeParse(request.query);
    const userCode = query.success ? (query.data.user_code ?? "") : "";
    if (!(await ownerOf(request))) return sendPage(reply, 200, signInPage(userCode, false));
    if (userCode === "") return sendPage(reply, 200, codeEntryPage(null));
    if (!attemptLimiter.hit(`code:${request.ip}`, DEVICE_LIMITS.codeAttemptsPerAddressPerHour, Date.now())) {
      return sendPage(reply, 429, messagePage("Slow down", "Too many codes entered. Try again later."));
    }
    const digest = userCodeDigestOf(userCode);
    const grant = digest ? await findPendingGrant(pool, digest) : null;
    if (!grant) return sendPage(reply, 404, codeEntryPage("That code is not valid or has expired."));
    return sendPage(reply, 200, decisionPage({
      userCode, clientId: grant.clientId, machineName: grant.machineName,
      teamId: grant.teamId, teams: grant.teamId === null ? await listTeams(pool) : [],
    }));
  });

  app.post("/approve/signin", async (request, reply) => {
    const form = (request.body ?? {}) as Record<string, unknown>;
    const userCode = typeof form.user_code === "string" ? form.user_code.slice(0, 64) : "";
    if (!signInLimiter.hit(`in:${request.ip}`, DEVICE_LIMITS.signInPerAddressPerHour, Date.now())) {
      return sendPage(reply, 429, messagePage("Slow down", "Too many sign-in attempts. Try again later."));
    }
    const given = typeof form.secret === "string" ? form.secret.slice(0, 512) : "";
    if (!secretsMatch(given, ownerSecret)) {
      return sendPage(reply, 401, signInPage(userCode, true));
    }
    const value = await createSession(pool, accountId);
    const target = userCode === "" ? "/approve" : `/approve?user_code=${encodeURIComponent(userCode)}`;
    return reply.status(303).header("set-cookie", sessionCookie(value, secureCookie))
      .header("location", target).header("cache-control", "no-store").send();
  });

  // The decision itself, shared by the page form and the JSON route.
  async function decide(
    request: FastifyRequest,
    input: { userCode: string; decision: "approve" | "deny"; teamId: string | null },
  ): Promise<{ status: number; reason: string | null }> {
    if (!sameOrigin(request)) return { status: 403, reason: "forbidden" };
    if (!(await ownerOf(request))) return { status: 401, reason: "unauthenticated" };
    if (!actionLimiter.hit(`act:${request.ip}`, DEVICE_LIMITS.actionsPerAddressPerHour, Date.now()) ||
        !attemptLimiter.hit(`code:${request.ip}`, DEVICE_LIMITS.codeAttemptsPerAddressPerHour, Date.now())) {
      return { status: 429, reason: "slow_down" };
    }
    const digest = userCodeDigestOf(input.userCode);
    if (!digest) return { status: 404, reason: "not_found" };
    const result = await decideGrant(pool, {
      userCodeDigest: digest, decision: input.decision, teamId: input.teamId,
    });
    if (result.ok) return { status: 200, reason: null };
    return { status: result.reason === "not_found" ? 404 : 409, reason: result.reason };
  }

  app.post("/approve/decision", async (request, reply) => {
    const form = (request.body ?? {}) as Record<string, unknown>;
    const parsed = approveBody.safeParse({
      user_code: form.user_code,
      decision: form.decision,
      ...(typeof form.team_id === "string" && form.team_id !== "" ? { team_id: form.team_id } : {}),
    });
    if (!parsed.success) return sendPage(reply, 400, messagePage("Not understood", "The form was incomplete."));
    const outcome = await decide(request, {
      userCode: parsed.data.user_code, decision: parsed.data.decision, teamId: parsed.data.team_id ?? null,
    });
    if (outcome.status === 200) {
      return sendPage(reply, 200, messagePage(
        parsed.data.decision === "approve" ? "Approved" : "Denied",
        parsed.data.decision === "approve" ? "You can return to the device." : "The device was refused.",
      ));
    }
    return sendPage(reply, outcome.status, messagePage("Not done", `The request was refused (${outcome.reason}).`));
  });

  // The owner removes a device (step 1, see device-removal.ts). The secret stops
  // at once with the same answer as an unknown one; unknown, already removed and
  // not-ours are all 404. No body is accepted beyond an empty object.
  app.delete("/v1/devices/:id", async (request, reply) => {
    noStore(reply);
    if (!sameOrigin(request)) return reply.status(403).send({ error: "forbidden" });
    if (!(await ownerOf(request))) return reply.status(401).send({ error: "unauthenticated" });
    if (!actionLimiter.hit(`act:${request.ip}`, DEVICE_LIMITS.actionsPerAddressPerHour, Date.now())) {
      return reply.status(429).send({ error: "slow_down" });
    }
    if (!z.object({}).strict().safeParse(request.body ?? {}).success) {
      return reply.status(400).send({ error: "bad_request" });
    }
    const id = uuid.safeParse((request.params as { id?: string }).id);
    if (!id.success) return reply.status(404).send({ error: "not_found" });
    const removed = await removeDevice(pool, id.data);
    if (!removed.ok) return reply.status(404).send({ error: "not_found" });
    // Step 2 starts after step 1 has committed, and never decides its answer.
    options.onRemoved?.();
    return reply.status(204).send();
  });

  app.post("/v1/device/approve", async (request, reply) => {
    noStore(reply);
    const body = approveBody.safeParse(request.body);
    if (!body.success) return reply.status(400).send({ error: "bad_request" });
    const outcome = await decide(request, {
      userCode: body.data.user_code, decision: body.data.decision, teamId: body.data.team_id ?? null,
    });
    return outcome.status === 200
      ? reply.status(200).send({ ok: true })
      : reply.status(outcome.status).send({ error: outcome.reason });
  });
}
