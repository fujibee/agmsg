import type { FastifyInstance, FastifyPluginAsync, FastifyRequest } from "fastify";
import type { Pool } from "pg";
import type { Config } from "../config.js";
import { ProtocolError, errorBody } from "../errors.js";
import { resolveSecret } from "./capability.js";

// <origin>/t/<secret>/v1/... is how a device reaches the data plane in the
// accounts profile. This scope resolves the secret to one live device and one
// team before any /v1 handler runs, and pins the request to that team.
//
// Answers that must not depend on why a request is refused:
//   - an unknown, malformed, provisional and revoked secret all answer the same
//     401, so a caller cannot probe which secrets once existed;
//   - a request for any team but the device's own answers exactly like a request
//     for a team that does not exist, so a device cannot learn another team is
//     there.

const SECRET_SEGMENT = /\/t\/[^/?#]+/u;

// Request logs must never carry the secret: it is in the path.
export function redactSecretPath(url: string): string {
  return url.replace(SECRET_SEGMENT, "/t/[REDACTED]");
}

function unauthenticated(): ProtocolError {
  return new ProtocolError(401, "unauthenticated", "capability URL is not valid");
}

// Carries no team id: a body that echoed the requested id would differ between
// a team that exists and one that does not, which is the one thing this answer
// must not do.
function teamNotFound(): ProtocolError {
  return new ProtocolError(404, "team-not-found", "team is not provisioned");
}

// The device each request resolved to, for the hooks after onRequest.
const deviceOf = new WeakMap<FastifyRequest, string>();

type Options = {
  pool: Pool;
  config: Config;
  // The data-plane plugin, passed in so this module does not import app.ts.
  dataPlane: FastifyPluginAsync<{ pool: Pool; config: Config }>;
};

export const registerCapabilityScope: FastifyPluginAsync<Options> = async (app, options) => {
  const { pool, config, dataPlane } = options;
  void app.register(async (scope: FastifyInstance) => {
    scope.addHook("onRequest", async (request: FastifyRequest, reply) => {
      const params = request.params as { secret?: string } | undefined;
      const device = await resolveSecret(pool, params?.secret ?? "");
      if (!device) {
        void reply.status(401).send(errorBody(unauthenticated()));
        return reply;
      }
      // The team is the device's, whatever the request says. A header naming
      // another team is a cross-team request, refused like an unknown team.
      const named = request.headers["agmsg-team-id"];
      if (named !== undefined && named !== device.teamId) {
        void reply.status(404).send(errorBody(teamNotFound()));
        return reply;
      }
      request.headers["agmsg-team-id"] = device.teamId;
      deviceOf.set(request, device.deviceId);
      const pathTeam = (request.params as { teamId?: string }).teamId;
      if (pathTeam !== undefined && pathTeam !== device.teamId) {
        void reply.status(404).send(errorBody(teamNotFound()));
        return reply;
      }
    });
    scope.addHook("preHandler", async (request, reply) => {
      const route = request.routeOptions.url ?? "";
      // A team lookup by name answers across every team on the server.
      if (route.endsWith("/v1/teams")) {
        void reply.status(404).send(errorBody(
          new ProtocolError(404, "not-found", "no such route"),
        ));
        return reply;
      }
      // A device may register only the team it is bound to.
      if (route.endsWith("/v1/connect")) {
        const body = request.body as { team_id?: unknown } | null;
        if (body?.team_id !== request.headers["agmsg-team-id"]) {
          void reply.status(404).send(errorBody(teamNotFound()));
          return reply;
        }
      }
    });
    // When a device last fetched, for the owner's device list. Written after a
    // SUCCESSFUL GET /v1/messages only (a refused request, whatever the reason,
    // records nothing), at most once a minute, so a polling client costs one
    // conditional UPDATE that almost always changes no row. It runs after the
    // response is sent, so a slow or failing write can neither delay nor fail the
    // fetch it describes; a failure is logged by class name only.
    scope.addHook("onResponse", async (request, reply) => {
      if (request.method !== "GET" || reply.statusCode !== 200 ||
          !(request.routeOptions.url ?? "").endsWith("/v1/messages")) return;
      const deviceId = deviceOf.get(request);
      if (!deviceId) return;
      try {
        await pool.query(
          `UPDATE devices SET last_fetch_at = clock_timestamp()
            WHERE device_id = $1
              AND (last_fetch_at IS NULL OR last_fetch_at < clock_timestamp() - interval '1 minute')`,
          [deviceId],
        );
      } catch (error) {
        request.log.warn({ event: "last-fetch-write-failed", error_name: error instanceof Error ? error.name : typeof error });
      }
    });
    void scope.register(dataPlane, { pool, config });
  }, { prefix: "/t/:secret" });
};
