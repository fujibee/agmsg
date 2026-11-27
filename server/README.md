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

## Profiles

`AGMSG_PROFILE=open` (default) is the no-auth profile above. `AGMSG_PROFILE=accounts`
serves the data routes only under a per-device capability URL
(`/t/<secret>/v1/...`); see the profiles section of `spec/v1.md`. A device is
bound to one team, and an unknown or revoked secret is refused without saying
which. In that profile set `AGMSG_OWNER_SECRET` (make one with
`openssl rand -hex 32`; the server refuses a weak one) and `AGMSG_PUBLIC_URL`
(the origin devices reach the server at, for example `https://agmsg.example.com`;
serve it over TLS). The owner approves new devices at `<AGMSG_PUBLIC_URL>/approve`. `AGMSG_DEVICE_CLIENT_IDS` (comma separated, default `agmsg-cli`) lists the client ids that may ask for a device code; any other id gets `invalid_client`.

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

## Limits

Unset means unlimited, which is the default. A configured limit is refused with
`403 limit-reached` whose body names the limit and its value; nothing is capped
silently.

| Variable | Limit | Where it applies |
| --- | --- | --- |
| `AGMSG_LIMIT_TEAMS` | teams on the server | `POST /v1/connect` refuses the team that would pass it |
| `AGMSG_LIMIT_DEVICES` | devices | read and listed; enforced where devices are approved |
| `AGMSG_RETENTION_MAX_LIVE_MESSAGES` | live messages per team | retains the oldest instead of refusing (see Retention) |

A limit that is set is enforced in every profile (`AGMSG_PROFILE=open` as well
as `accounts`); a configured value is never silently ignored.

Each value is a canonical positive integer that fits a signed BIGINT. The
limits that are set appear under `limits` in `GET /v1/capabilities`; see
`spec/v1.md`.

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

## Key escrow

`AGMSG_ESCROW_BACKEND` chooses whether the server keeps a wrapped copy of a
team's key so it can hand that key to the next approved device. It applies only
to the accounts profile.

- `none` (default): the server holds nothing it could open. This is the only
  setting where the operator cannot read the key.
- `keyfile`: the wrapped keys are sealed under a master key in the file named by
  `AGMSG_ESCROW_KEYFILE` (at least 32 bytes, for example
  `openssl rand -out escrow.key 32`). The server refuses to start if the file is
  missing, unreadable or too short.

A key file on the same host as the database protects only against a leaked
database dump. Anyone who can read both the file and the database can open every
wrapped key, and so can the operator.

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
