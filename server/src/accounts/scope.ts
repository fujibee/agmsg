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

function teamNotFound(teamId: string): ProtocolError {
  return new ProtocolError(404, "team-not-found", "team is not provisioned", {}, { teamId });
}

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
        void reply.status(404).send(errorBody(teamNotFound(String(named))));
        return reply;
      }
      request.headers["agmsg-team-id"] = device.teamId;
      const pathTeam = (request.params as { teamId?: string }).teamId;
      if (pathTeam !== undefined && pathTeam !== device.teamId) {
        void reply.status(404).send(errorBody(teamNotFound(pathTeam)));
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
          void reply.status(404).send(errorBody(teamNotFound(String(body?.team_id))));
          return reply;
        }
      }
    });
    void scope.register(dataPlane, { pool, config });
  }, { prefix: "/t/:secret" });
};
