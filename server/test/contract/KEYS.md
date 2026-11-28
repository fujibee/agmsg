# Device registration and escrow key contract

`keys.contract.mjs` is the shared HTTP contract for POST `/v1/devices`, POST `<capability_url>/v1/keys/epochs`, GET `<capability_url>/v1/keys/bundle`, and controlled epoch fencing on POST `<capability_url>/v1/messages`. It has a separate runner because deployments implement these routes after the initial accounts contract. Run it only against an isolated disposable deployment with escrow configured. Owner deletion and automatic rotation remain implementation-specific integration tests.

```sh
node server/test/contract/keys.run.mjs \
  --base-url "$CONTRACT_BASE_URL" \
  --fixture-module /path/to/keys-fixture.mjs
```

The shared file imports the existing `canonicalJson`, `ageSnapshotDigest`, and `validateAgeConfiguration` helpers from this repository. Run it from this checkout, or its equivalent vendored tree; do not copy or replace its canonicalization rule. Like the accounts runner, this runner launches no process per request. An adapter importing TypeScript can use its own loader.

## Fixture interface

Export `createFixture({baseUrl})`. Return `primary`, `foreign`, and `revoked` identities with the same capability URL, team ID, and device ID fields as the accounts fixture. `primary` and `foreign` additionally require `label`, `devicePubkey` (a real age recipient), and `deviceIdentity` (its matching private age identity). Both are activated original claimants of their separately owned teams, with registered devices. The primary team starts with no escrowed epochs; never point the suite at an existing user's team. The revoked fixture names a previously activated, revoked capability. Setup owns any claim creation, device registration prerequisites, and database isolation.

Also return `unregistered: {capabilityUrl}`: a live, activated capability authorized for the primary team, but with no registered device recipient. Both key routes must refuse it with 403 `forbidden`, rather than confusing the missing registration with an invalid capability.

The required callbacks are:

```js
{
  async newEpoch({ epoch, teamId, previous }) {
    // Generate real age keys. Return exactly these fields:
    return { key_id, identity, recipient, snapshot };
  },
  async openSealed(base64Ciphertext, deviceIdentity) {
    // Real age decryption; return canonical plaintext text, not parsed JSON.
  },
  async sealMessage(plaintext, recipient) {
    // Real age encryption; return base64 ciphertext for an ordinary message.
  },
  async revokeDevice({ teamId, keyId }) {
    // Establish a controlled fence through the core fenceEpoch helper.
    // Return only after that fence is committed; do not rotate it here.
  },
  async dispose() {
    // Remove only this fixture's disposable state and stop its processes.
  },
}
```

`previous` is null for each competing epoch-1 candidate. For epoch 2 it is the winning epoch-1 object, including `epoch`, `key_id`, `identity`, `recipient`, and `snapshot`. A generated epoch must use a fresh key ID and key, and a complete existing-format age snapshot with `epoch_revision === String(epoch - 1)`. Discover `server_instance_id` from authenticated capabilities. Extend the preceding snapshot's immutable history, hash link, and writer generation; minimal snapshots containing only a revision are insufficient. The suite runs the existing local chain validator before uploading material and after decrypting a bundle.

The suite uses one ordered chain on the primary team: empty bundle, concurrent first registration, repeated registration, winner bundle, second epoch, complete retained bundle, a controlled fence, and a third epoch that lifts it. Fixture callbacks must not pre-register those epochs. Independent cases must not reuse a primary team with existing epochs.

`revokeDevice` isolates the fence mechanism, not a deployment's owner-auth route. Both adapters call the core fence helper directly so a production automatic rotator cannot race the assertion. Owner DELETE and its automatic-rotation behavior, including empty-epoch policy, are tested separately in the [reference removal tests](../device-removal.integration.test.ts). The shared case requires the controlled fence to return 409 until the explicit next-epoch POST; a 200 before that POST is a failure, not an alternate success path. `sealMessage` and `openSealed` use real age encryption/decryption to check ordinary message envelopes as well as bundles.

Adapter setup, key generation, and decryption failures must omit credentials and plaintext. The shared request helper never prints URLs, request bodies, or raw response bodies. It checks responses for reflected capability secrets and private identities. `dispose` runs after the suite; a factory that fails before returning must clean up its own partial setup.

## Assertions

- Unauthenticated origin GET `/v1/health` returns string feature names including `key-escrow`. This suite requires a configured escrow backend, so the advertisement is mandatory and never selected by host name.
- Device registration is idempotent and returns `201 {device_id}`; malformed, foreign-team, changed-key, unknown, and revoked credentials retain the established control-plane error shapes.
- A claimed empty escrow team returns nested `409 error.code: "no_team_key"`.
- Malformed requests, non-integer epochs, and unknown request fields return 400 `bad_request`. Invalid epoch range (including zero), key IDs, recipients, identity bindings, snapshot revision, and missing previous epochs return their agreed 422 codes. Reusing a retained key ID for a new private key returns 422 `key_id_conflict`. Refused candidates must not create an escrowed epoch.
- Concurrent first registrations produce exactly one `201 {status:"registered", epoch}` and one `200 {status:"exists", epoch, key_id, recipient}`. Both later candidates get the winner's public half, never a private identity. Optional typed protocol metadata is allowed.
- GET bundle returns `{format:"agmsg_age_v1_handoff", epochs, snapshot_sha256, bundle}` with optional protocol metadata. `bundle` is base64 age ciphertext sealed to the caller's own registered recipient. The foreign device identity must fail real decryption.
- Decrypted bytes equal the existing canonical JSON encoding and contain exactly `{format_version:1, type:"agmsg_age_v1_handoff", snapshots, identities}`. Every registered epoch's snapshot and private identity must be retained, with no duplicate identities. The latest digest is recomputed locally and compared; server-supplied digest text is never accepted on its own.
- Key data requests use protocol/team headers and the capability path, never a bearer header. Unknown and revoked credentials return identical complete 401 bodies. Foreign existing and nonexistent teams return identical complete 404 bodies.
- A live capability without a registered recipient receives 403 `forbidden` on both key routes, including an otherwise valid epoch registration request.
- A current-key write succeeds before the fixture fences it. The same controlled fence repeatedly returns 409 `epoch-fenced`, with exact `{team_id, key_id}` details, while an older retained key still writes. A separate case publishes epoch 3, retries the identical previously refused message with a `stored` acknowledgement, confirms a replay is `duplicate` at the same sequence, writes under the new key, and verifies the complete three-epoch bundle. The refused message must not have consumed its ID or been stored. These message errors use the existing data-plane envelope; the key routes' cache-header requirement is not imposed on them.

These executable cases cover the configured-escrow path, material validation, registration requirements, and isolation. A separate escrow-disabled deployment and its 503 response are explicitly not covered by this fixture. Bundle assertions concern retained content and recipient sealing, not the implementation's unwrap mechanism or audit-call count per read. Do not replace a real deployment with mocked HTTP to claim this contract passes.
