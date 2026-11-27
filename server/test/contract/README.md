# Accounts and capability HTTP contract

`accounts.contract.mjs` is the shared, HTTP-only protocol test. It is unchanged across deployments. It uses the control-plane base URL supplied by the operator and the data-plane capability URLs supplied by fixtures or returned by device login. It never selects behavior from a host name or defaults to a hosted service.

Run only against an isolated test deployment with disposable state. The suite creates three device grants and activates one new capability. Fixture setup and teardown belong to the deployment running the test; this directory contains no adapter for a different server implementation.

## Run

From the repository root:

```sh
node server/test/contract/run.mjs \
  --base-url "$CONTRACT_BASE_URL" \
  --fixture-module /path/to/fixture.mjs
```

The module path is relative to the current directory unless absolute. A deployment whose adapter imports TypeScript can use its own loader, for example `node --import tsx ...`. The runner and the test itself need only Node 22 or later, with no additional package dependency. The runner registers Node's tests in its own process and spawns no child process per test or request.

The reference server runs this file automatically through `test/accounts-contract.integration.test.ts` in the existing PostgreSQL CI job. To run that case locally from `server/`, set `TEST_DATABASE_URL` to a disposable test database and run `npm test -- test/accounts-contract.integration.test.ts`. The wrapper creates one isolated schema, starts one loopback HTTP server, and launches one Node runner for the entire shared suite. `reference.fixture.mjs` seeds only that schema and injects the server's durable grant-decision helper; it does not implement protocol responses.

The base URL is the control origin, including any deployment prefix. Data requests use `<capability_url>/v1/...` and the `Agmsg-Team-ID` and `Agmsg-Protocol-Version` headers. They do not use an authorization header. The separate control endpoints `/v1/devices` and `/v1/device/activate` authenticate with `Authorization: Bearer <secret>`, as their protocol requires.

## Injected fixture module

Export one factory:

```js
export async function createFixture({ baseUrl }) {
  // Start or seed only this adapter's isolated test state.
  return {
    expectedLimits: {}, // Unlimited: omit the devices/teams/live_messages keys.
    primary: {
      capabilityUrl: "http://127.0.0.1:8788/t/<active-secret>",
      teamId: "<first-team-uuid-v7>",
      deviceId: "<registered-device-id>",
      devicePubkey: "<public-age-recipient>",
      label: "contract-primary",
    },
    foreign: {
      capabilityUrl: "http://127.0.0.1:8788/t/<other-active-secret>",
      teamId: "<separately-owned-team-uuid-v7>",
      deviceId: "<other-registered-device-id>",
      devicePubkey: "<different-public-age-recipient>",
      label: "contract-foreign",
    },
    revoked: {
      capabilityUrl: "http://127.0.0.1:8788/t/<revoked-secret>",
      teamId: "<first-team-uuid-v7>",
      deviceId: "<revoked-device-id>",
    },
    async approveGrant({ userCode, decision, teamId }) {
      // Use this implementation's own helper or isolated test database.
      // Resolve this user code and approve or deny it for the named team.
    },
    async dispose() {
      // Tear down only the state/processes this fixture created.
    },
  };
}
```

The strings above are placeholders, not runnable credentials. Actual secrets follow the protocol's `agsy_<8 lowercase hex>_<43 base64url>` format. Do not commit fixture secrets, browser cookies, or session tokens.

Fixture requirements:

- `primary` and `foreign` are activated capabilities across separate ownership boundaries. Their teams must already exist, and each capability must identify a live device. `devicePubkey` is the expected public key or `null` before key registration; non-null public keys must differ. The first team must be readable through `primary` and denied through the foreign ownership boundary. When enabling the deferred registration tests, use each team's original claimant with distinct registered public keys.
- `revoked` is a capability/device pair revoked through the normal implementation helper. It must no longer appear in `primary`'s active-device listing. The capability's activation route must report the known revoked record, rather than an unknown secret.
- `approveGrant` runs outside the shared HTTP contract: owner sign-in differs by deployment. It receives a code that the suite just issued to `agmsg-cli`, the decision (`approve` or `deny`), and the first team's ID. It must complete the corresponding durable grant transition before returning. Do not change the machine name fixed at issuance.
- The approved login must be able to mint one additional machine and read the first team after activation. Capacity-exhaustion and subscription refusal cases are tested separately from this successful-login fixture.
- `dispose` is always called after the registered suite, including failing tests. If fixture creation fails before returning, the factory must clean up its own partial setup.
- `expectedLimits` lists only configured finite limits, with decimal-string values: for example `{ devices: "8", teams: "8", live_messages: "1000" }`. Use `{}` when all are unlimited. `live_messages` describes oldest-message eviction, not refusal. Devices/team exhaustion is tested by the reference server's separate integration cases.
- Adapter errors must omit credentials. The shared HTTP helper never logs request URLs, bodies, cookie values, or raw response bodies on failure.

## Coverage

The file pins device-code request validation and its six response fields, pending/slow-down/denied/expired token answers, the approved token shape, provisional denial, idempotent activation, token replay, and activation error answers. GET `/v1/devices` pins camelCase device rows and the caller marker, allowing a null public key before key registration and optional `type` and `lastFetchAt` (null before a first fetch). Two POST `/v1/devices` cases retain the idempotent `201 {device_id}`, malformed, foreign-team, changed-key, and unauthenticated checks, explicitly skipped with the reason `lands with key routes` until the key surface lands.

The same suite verifies live capability access, cross-team read/write denial, identical unknown/revoked answers, absence of echoed secrets, unauthenticated origin `health.features`, and authenticated team `capabilities.features` and `capabilities.limits`. Feature arrays admit unknown additional names; the required names are `device-approval` on origin health and `devices`, `roster-snapshot`, and `limits` after connect.

Data-plane errors require `error.code` and allow typed optional protocol binding fields, `error.message`, and `error.details`. Unknown and revoked credentials must still return byte-identical complete bodies.

The approval endpoint itself, owner sign-in, key escrow, key routes, and configurable-limit exhaustion are outside this file. They must not be smuggled into the shared contract through an implementation-specific URL or a host-name condition.
