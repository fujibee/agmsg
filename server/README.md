# agmsg remote storage reference server

This directory contains the thin, self-hosted PostgreSQL reference
implementation of the [HTTP API v1 contract](spec/v1.md). It is independent of
the root installer package and desktop app.

The server stores every envelope blob opaquely and does not inspect sender,
recipient, body, or client creation time. New teams allow both `cipher: "none"`
and `cipher: "age-v1"` by default. Clients register local teams directly
through `/v1/connect`. The current reference profile has no authentication:
reaching the server is the permission.

## Self-host quickstart

The included Compose stack provides PostgreSQL 17 and the reference server.
Before exposing it outside a local development machine, change the database
password in `compose.yaml` and terminate TLS in front of the service.

1. From this directory, start PostgreSQL and the server:

   ```sh
   docker compose up -d --build
   ```

2. Confirm that the server and database are ready:

   ```sh
   curl -fsS http://127.0.0.1:8787/v1/health
   ```

   The response should contain `"status":"ok"` and `"database":"ok"`. If the
   containers are still starting, retry until the health check succeeds.

For client setup, follow [Remote setup](../docs/remote-setup.md).

## Network boundary

The no-auth profile is intended for a server on a network you control. Anyone
who can reach the server and identify a team can access that team's remote
stream. Restrict network access, and use HTTPS whenever traffic leaves
localhost. Encryption with `age-v1` protects envelope contents from the server,
but does not replace the network boundary.

## Compose configuration

`compose.yaml` contains local-development database defaults. Replace those
values before deploying the stack anywhere else. The server waits for
PostgreSQL health and applies its idempotent migrations at startup.

Live-envelope retention is disabled by default. To set a limit for the Compose
stack, export a canonical positive signed-BIGINT value before starting it:

```sh
export AGMSG_RETENTION_MAX_LIVE_MESSAGES=100000
docker compose up -d --build
```

## Run from source

Node.js 22 and PostgreSQL 17 are the reference versions. Create an empty
PostgreSQL database, then build and start the server:

```sh
npm ci
export DATABASE_URL="postgresql://<user>:<password>@127.0.0.1:5432/<db>"
export HOST=0.0.0.0
export PORT=8787
npm run build
npm start
```

Replace every value in angle brackets before running the command. Startup
applies the same idempotent migrations used by the Compose image.

## Retention

After a successful write, the reference server can apply a configured
live-message floor in the same team transaction as sequence allocation. It
keeps permanent idempotency tombstones and logs only the team ID, old and new
floors, and removed row count.

A window smaller than a device's offline interval, or small relative to an
active write burst, can require an explicit client resync. To apply retention
manually:

```sh
npm run retain -- <team-uuid> <through-sequence>
```

Retention holds the same team-row lock as writers, creates the tombstones,
removes the covered delivery prefix, and advances the team cursor floor.

## Verify

Integration tests use an isolated, randomly named PostgreSQL schema. The test
only removes the schema it created and validates its generated name first.

```sh
export TEST_DATABASE_URL="postgresql://<user>:<password>@127.0.0.1:5432/<db>"
npm run typecheck
npm test
npm run build
```

The integration suite covers health, client-owned team registration, opaque
message paging, transactional team sequence allocation, team discovery,
capability snapshots, retention tombstones and cursor floors, roster event
transport, and strict JSON framing.
