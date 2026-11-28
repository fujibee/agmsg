# Device registration and escrow key contract

`keys.contract.mjs` is the shared HTTP contract for POST `/v1/devices`, POST `<capability_url>/v1/keys/epochs`, and GET `<capability_url>/v1/keys/bundle`. It has a separate runner because deployments implement these routes after the initial accounts contract. Run it only against an isolated disposable deployment with escrow configured. Owner deletion and epoch fencing are separate follow-ups.

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
  async dispose() {
    // Remove only this fixture's disposable state and stop its processes.
  },
}
```

`previous` is null for each competing epoch-1 candidate. For epoch 2 it is the winning epoch-1 object, including `epoch`, `key_id`, `identity`, `recipient`, and `snapshot`. A generated epoch must use a fresh key ID and key, and a complete existing-format age snapshot with `epoch_revision === String(epoch - 1)`. Discover `server_instance_id` from authenticated capabilities. Extend the preceding snapshot's immutable history, hash link, and writer generation; minimal snapshots containing only a revision are insufficient. The suite runs the existing local chain validator before uploading material and after decrypting a bundle.

The suite uses one ordered chain on the primary team: empty bundle, concurrent first registration, repeated registration, winner bundle, second epoch, and complete retained bundle. Fixture callbacks must not pre-register those epochs. Independent cases must not reuse a primary team with existing epochs.

Adapter setup, key generation, and decryption failures must omit credentials and plaintext. The shared request helper never prints URLs, request bodies, or raw response bodies. It checks responses for reflected capability secrets and private identities. `dispose` runs after the suite; a factory that fails before returning must clean up its own partial setup.

## Assertions

- Device registration is idempotent and returns `201 {device_id}`; malformed, foreign-team, changed-key, unknown, and revoked credentials retain the established control-plane error shapes.
- A claimed empty escrow team returns nested `409 error.code: "no_team_key"`.
- Malformed requests, non-integer epochs, and unknown request fields return 400 `bad_request`. Invalid epoch range (including zero), key IDs, recipients, identity bindings, snapshot revision, and missing previous epochs return their agreed 422 codes. Reusing a retained key ID for a new private key returns 422 `key_id_conflict`. Refused candidates must not create an escrowed epoch.
- Concurrent first registrations produce exactly one `201 {status:"registered", epoch}` and one `200 {status:"exists", epoch, key_id, recipient}`. Both later candidates get the winner's public half, never a private identity. Optional typed protocol metadata is allowed.
- GET bundle returns `{format:"agmsg_age_v1_handoff", epochs, snapshot_sha256, bundle}` with optional protocol metadata. `bundle` is base64 age ciphertext sealed to the caller's own registered recipient. The foreign device identity must fail real decryption.
- Decrypted bytes equal the existing canonical JSON encoding and contain exactly `{format_version:1, type:"agmsg_age_v1_handoff", snapshots, identities}`. Every registered epoch's snapshot and private identity must be retained, with no duplicate identities. The latest digest is recomputed locally and compared; server-supplied digest text is never accepted on its own.
- Key data requests use protocol/team headers and the capability path, never a bearer header. Unknown and revoked credentials return identical complete 401 bodies. Foreign existing and nonexistent teams return identical complete 404 bodies.
- A live capability without a registered recipient receives 403 `forbidden` on both key routes, including an otherwise valid epoch registration request.

These executable cases cover the configured-escrow path, material validation, registration requirements, and isolation. A separate escrow-disabled deployment and its 503 response are explicitly not covered by this fixture. Bundle assertions concern retained content and recipient sealing, not the implementation's unwrap mechanism or audit-call count per read. Do not replace a real deployment with mocked HTTP to claim this contract passes.
