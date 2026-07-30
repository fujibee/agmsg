# agmsg remote storage reference server

This directory contains the thin, self-hosted PostgreSQL reference
implementation of the [HTTP API v1 contract](spec/v1.md). It is independent of
the root installer package and desktop app.

The server stores every envelope blob opaquely and does not inspect sender,
recipient, body, or client creation time. New teams allow both `cipher: "none"`
and `cipher: "age-v1"` by default. Clients register local teams directly
through `/v1/connect`; reaching the server is the permission, with no pairing
token or per-device credential.

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

   The response should contain `"status":"ok"` and `"database":"ok"`.

For client setup, follow [Remote setup](../docs/remote-setup.md).

## Run with Compose

Change the database password in `compose.yaml` and terminate TLS in front of the
service before exposing it outside a local development machine. Apply a
reverse-proxy request-rate limit to the public pairing exchange route and do
not capture request or response bodies there. Then run:

```sh
docker compose up --build
```

Live-envelope retention is disabled by default. To bound each team's live
payload rows while keeping permanent idempotency tombstones, set a canonical
positive signed-BIGINT value before starting Compose:

```sh
export AGMSG_RETENTION_MAX_LIVE_MESSAGES=100000
docker compose up --build
```

After a successful write, the reference server applies the configured floor in
the same team transaction as sequence allocation and logs only the team ID, old
and new floors, and removed row count. Tombstones and other protocol metadata
remain durable, so this is not a hard bound on total database bytes. A window
smaller than a device's offline interval—or small relative to an active write
burst—causes `410 resync-required`; recovery requires the client's explicit
operator-approved `remote-sync.sh resync --accept-floor` flow.

`GET /v1/health` is available without credentials. The message, member, and
capability endpoints require the credential returned by pairing plus these
headers:

```http
Authorization: Bearer <device credential>
Agmsg-Protocol-Version: 1
Agmsg-Team-ID: <immutable UUIDv7 team ID>
```

## Run from source

Node.js 22 and PostgreSQL 17 are the reference versions.

```sh
npm install
export DATABASE_URL=postgresql://localhost/agmsg
npm run migrate
npm run provision -- example/team.json
npm run build
npm run dev
```

The server also runs the idempotent migration at startup. Team creation and
roster mutation remain outside HTTP v1: the provisioning command atomically
applies the complete operator-owned roster manifest. IDs and retired names are
checked against permanent identity history before replacement.

## Admin commands

Admin commands are non-interactive and use noun + verb consistently. Human
explanations go to stderr. Primary output goes to stdout so it can be piped;
`token issue` emits exactly the same `agmsg remote connect` block as a hosted
console. Every command supports `--json`.

```sh
npm run --silent admin -- team create --name TEAM [--team-id UUID] [--json]
npm run --silent admin -- token issue --team TEAM_OR_ID --endpoint URL [--json]
npm run --silent admin -- credential list --team TEAM_OR_ID [--json]
npm run --silent admin -- credential revoke --team TEAM_OR_ID \
  --credential-id UUID [--json]
```

The credential list is keyed by `(team, credential_id)`: three connected
devices produce three independently revocable rows with connected and
last-active timestamps. Pairing tokens and bearer secrets are stored only as
domain-separated SHA-256 digests. Raw pairing tokens appear only in the
one-time admin output; raw bearer credentials appear only in the exchange
response. Do not enable request/response-body capture for the exchange route.

The client-side disconnect operation revokes its own credential through:

```http
POST /v1/credentials/<credential_id>/revoke
Authorization: Bearer <that device credential>
Agmsg-Protocol-Version: 1
Agmsg-Team-ID: <immutable UUIDv7 team ID>
```

Self-revoke is idempotent: retrying with the same now-revoked credential returns
success, while that credential is rejected by every sync endpoint. The local
admin command uses the same revoke operation for a lost device.

The paste command sends the opaque code once:

```http
POST /v1/pairing/exchange
Agmsg-Protocol-Version: 1
Content-Type: application/json

{"token":"agmsg_pair_..."}
```

The `200` response is `Cache-Control: no-store` and contains
`credential_id`, the one-time-visible bearer `credential`,
`server_instance_id`, `remote_team_id`, `remote_team_name`, `protocol_version`,
and the authenticated `capabilities` snapshot. Unknown, consumed, and expired
codes fail as `invalid-pairing-token`, `pairing-token-consumed`, and
`pairing-token-expired`; credential creation and token consumption share one
database transaction.

If the exchange response is lost, the consumed token cannot recover the raw
credential because the server never stores it. Use `credential list` to find
and revoke the orphan, then issue a new token.

## Pre-release authentication cutover

The reference server stack is still an unmerged dogfood track and has no public
deployment compatibility contract. This branch intentionally removes the old
global `AGMSG_SERVER_TOKEN`; it does not accept that value as a fallback or
seed credentials from it. A team with no device credentials fails closed with
`401` on every team data endpoint while health and pairing exchange remain
available for bootstrap.

Existing disposable dogfood deployments must be rebuilt or re-paired under the
per-device model. Start the upgraded server, issue one token per device, and
run the connect command once the client-side dependency noted above lands.
There is no global-token compatibility window. A future post-release auth
migration requires a separately specified cutover rather than silently
reintroducing a cross-team master credential.

Retention is also an operator operation. It atomically creates permanent
idempotency tombstones, removes the covered delivery prefix, and advances the
team cursor floor while holding the same team-row lock as writers:

```sh
npm run retain -- <team-uuid> <through-sequence>
```

## Verify

Integration tests use an isolated, randomly named PostgreSQL schema. The test
only removes the schema it created and validates its generated name first.

```sh
export TEST_DATABASE_URL=postgresql://localhost/agmsg_test
npm run typecheck
npm test
npm run build
```

The integration suite covers atomic batch rollback, complete input-order ack
mapping, transactional team sequence allocation, UUID conflict handling,
retention tombstones, cursor floors, capability snapshots, roster reads,
one-time pairing, per-device credential revocation, admin CLI output, and strict
JSON framing.
