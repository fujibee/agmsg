import Fastify from "fastify";
import { Pool } from "pg";
import { afterEach, describe, expect, it } from "vitest";
import { createApp, dataPlane } from "../src/app.js";
import type { Config } from "../src/config.js";

// The data-plane plugin's contract as an EMBEDDED plugin, plus createApp's
// unchanged standalone behaviour for the paths the existing integration tests
// don't touch. These need no database: a body-limit rejection and a 404 both
// resolve before any handler queries Postgres.

const config: Config = {
  databaseUrl: "postgres://unused",
  host: "127.0.0.1",
  port: 0,
  logLevel: "silent",
  retentionMaxLiveMessages: null,
};

const jsonHeaders = {
  "content-type": "application/json",
  "agmsg-protocol-version": "1",
  "agmsg-team-id": "018f3f7e-0000-7000-8000-000000000001",
};

describe("data-plane plugin embedding contract", () => {
  let pools: Pool[] = [];
  let apps: Array<{ close: () => Promise<void> }> = [];
  const track = <T extends { close: () => Promise<void> }>(app: T): T => {
    apps.push(app);
    return app;
  };
  const trackPool = (): Pool => {
    const pool = new Pool({ connectionString: config.databaseUrl });
    pools.push(pool);
    return pool;
  };

  afterEach(async () => {
    await Promise.all(apps.map((a) => a.close()));
    await Promise.all(pools.map((p) => p.end()));
    apps = [];
    pools = [];
  });

  // B1: the 2 MiB limit the 413 copy promises is the data plane's own, not the
  // host's — it must hold whether the host's default is larger or smaller.
  it("enforces the 2 MiB body limit when mounted in a host with a LARGER default", async () => {
    const host = track(Fastify({ bodyLimit: 16 * 1024 * 1024 }));
    void host.register(dataPlane, { pool: trackPool(), config });
    await host.ready();
    const res = await host.inject({
      method: "POST",
      url: "/v1/messages",
      headers: jsonHeaders,
      payload: "x".repeat(3 * 1024 * 1024), // 3 MiB > 2 MiB, but < the host's 16 MiB
    });
    expect(res.statusCode).toBe(413);
    expect(res.json().error.code).toBe("request-too-large");
  });

  it("does NOT prematurely reject a sub-2-MiB body in a host with a SMALLER default", async () => {
    const host = track(Fastify({ bodyLimit: 1024 })); // host default far below 2 MiB
    void host.register(dataPlane, { pool: trackPool(), config });
    await host.ready();
    const res = await host.inject({
      method: "POST",
      url: "/v1/messages",
      headers: jsonHeaders,
      payload: JSON.stringify({ pad: "y".repeat(8 * 1024) }), // ~8 KiB, valid JSON, > host 1 KiB
    });
    // The route's own 2 MiB limit governs, so an 8 KiB body is NOT rejected by
    // the host's 1 KiB default: it reaches the handler and is rejected there for
    // its shape (400 invalid-request), never a 413. The data plane no longer
    // authenticates, so the body reaches schema validation rather than a 401.
    // The property under test is only "not prematurely rejected".
    expect(res.statusCode).not.toBe(413);
    expect(res.statusCode).toBe(400);
  });

  // B2: standalone createApp still answers unknown routes exactly as before —
  // in particular the protocol header reaches a 404, which regressed when the
  // routes were first moved into an encapsulated child.
  it("keeps the protocol-version header on createApp's unknown-route 404", async () => {
    const app = track(createApp(trackPool(), config));
    await app.ready();
    const res = await app.inject({ method: "GET", url: "/no-such-route" });
    expect(res.statusCode).toBe(404);
    expect(res.headers["agmsg-protocol-version"]).toBe("1");
  });
});
