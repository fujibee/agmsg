// HTTP-only key contract. Fixtures own key generation and real age decryption.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { after, before, describe, it } from "node:test";
import { canonicalJson, ageSnapshotDigest, validateAgeConfiguration } from "../../../scripts/internal/remote-sync.mjs";

const SECRET = /^agsy_[a-f0-9]{8}_[A-Za-z0-9_-]{43}$/;
const KEY_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const RECIPIENT = /^age1[0-9a-z]{58}$/;
const METADATA = ["protocol_version", "server_instance_id", "team_id"];

function object(value, required, label, optional = []) {
  assert.ok(value && typeof value === "object" && !Array.isArray(value), `${label}: expected an object`);
  assert.ok(required.every(name => Object.hasOwn(value, name)) && Object.keys(value).every(name => required.includes(name) || optional.includes(name)), `${label}: unexpected response fields`);
}
function nonempty(value, label) {
  assert.ok(typeof value === "string" && value.length > 0, `${label}: expected a nonempty string`);
}
function urlOf(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error("invalid contract URL"); }
  assert.ok(["http:", "https:"].includes(url.protocol) && !url.username && !url.password && !url.search && !url.hash, "contract URL must use HTTP(S) without extra credentials");
  return url;
}
function credential(value) {
  const url = urlOf(value);
  const match = /\/t\/([^/]+)$/.exec(url.pathname);
  assert.ok(match && SECRET.test(match[1]), "fixture must provide a capability URL");
  return { url: url.href, secret: match[1] };
}

// These validate untrusted HTTP/plaintext values. Keep diagnostics fixed:
// equality assertions would include the server-controlled actual value.
export function assertKeyMetadata(body, teamId) {
  if (Object.hasOwn(body, "protocol_version")) assert.ok(body.protocol_version === 1, "response protocol version differs");
  if (Object.hasOwn(body, "team_id")) assert.ok(body.team_id === teamId, "response team binding differs");
  if (Object.hasOwn(body, "server_instance_id")) nonempty(body.server_instance_id, "response server ID");
}
export function assertKeyEpoch(body, epoch) {
  assert.ok(body.epoch === epoch, "response epoch differs");
}
export function assertKeyHandoffHeader(body) {
  object(body, ["format_version", "type", "snapshots", "identities"], "handoff plaintext");
  assert.ok(body.format_version === 1, "handoff format version differs");
  assert.ok(body.type === "agmsg_age_v1_handoff", "handoff type differs");
}

export function defineKeysContract({ baseUrl, fixture, requestTimeoutMs = 5000 }) {
  const controlOrigin = urlOf(baseUrl).href.replace(/\/$/, "");
  for (const name of ["primary", "foreign", "revoked"]) {
    object(fixture[name], ["capabilityUrl", "teamId", "deviceId"], `fixture.${name}`, ["devicePubkey", "deviceIdentity", "label", "teamName"]);
    nonempty(fixture[name].teamId, "fixture team ID");
    nonempty(fixture[name].deviceId, "fixture device ID");
  }
  for (const identity of [fixture.primary, fixture.foreign]) {
    assert.ok(RECIPIENT.test(identity.devicePubkey), "fixture must provide a real device age recipient");
    nonempty(identity.deviceIdentity, "fixture device identity");
    nonempty(identity.label, "fixture device label");
  }
  assert.notEqual(fixture.primary.teamId, fixture.foreign.teamId, "fixtures must cross an ownership boundary");
  assert.ok(fixture.primary.deviceIdentity !== fixture.foreign.deviceIdentity && fixture.primary.devicePubkey !== fixture.foreign.devicePubkey, "fixture devices must use different age keys");
  for (const name of ["newEpoch", "openSealed", "dispose"]) assert.equal(typeof fixture[name], "function", `fixture.${name} is required`);
  const primary = credential(fixture.primary.capabilityUrl);
  const foreign = credential(fixture.foreign.capabilityUrl);
  const revoked = credential(fixture.revoked.capabilityUrl);
  const unregistered = credential(fixture.unregistered?.capabilityUrl);
  const unknownSecret = `agsy_${randomBytes(4).toString("hex")}_${randomBytes(32).toString("base64url")}`;
  const unknown = { url: primary.url.replace(/\/t\/[^/]+$/, `/t/${unknownSecret}`), secret: unknownSecret };
  const forbiddenText = new Set([primary.secret, foreign.secret, revoked.secret, unregistered.secret, unknown.secret, fixture.primary.deviceIdentity, fixture.foreign.deviceIdentity]);
  let serverId;

  async function request(root, path, { method = "GET", headers = {}, body } = {}) {
    let response, raw;
    try {
      response = await fetch(`${root}${path}`, {
        method, headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(requestTimeoutMs), redirect: "error",
      });
      raw = await response.text();
    } catch { throw new Error(`${method} key contract request failed or timed out`); }
    let bodyJson;
    try { bodyJson = JSON.parse(raw); } catch { throw new Error(`${method} key contract response is not JSON`); }
    return { status: response.status, headers: response.headers, body: bodyJson, raw };
  }
  const data = (caller, path, teamId, options = {}) => request(caller.url, `/v1${path}`, {
    ...options,
    headers: { "agmsg-protocol-version": "1", "agmsg-team-id": teamId, ...options.headers },
  });
  const device = (caller, options = {}) => request(controlOrigin, "/v1/devices", {
    ...options, headers: { authorization: `Bearer ${caller.secret}`, ...options.headers },
  });
  function noStore(response) {
    assert.ok(response.headers.get("cache-control")?.split(/\s*,\s*/).includes("no-store"), "key response must be no-store");
  }
  function noSecretEcho(response) {
    assert.ok([...forbiddenText].every(value => !response.raw.includes(value)), "response reflected private key material or a capability secret");
  }
  function metadata(response, teamId) {
    assertKeyMetadata(response.body, teamId);
  }
  function error(response, status, codes, teamId) {
    noSecretEcho(response);
    assert.equal(response.status, status, "key refusal status");
    object(response.body, ["error"], "key refusal", METADATA);
    object(response.body.error, ["code"], "key error", ["message", "details"]);
    assert.ok([codes].flat().includes(response.body.error.code), "key error code differs");
    if (Object.hasOwn(response.body.error, "message")) assert.equal(typeof response.body.error.message, "string");
    if (Object.hasOwn(response.body.error, "details")) {
      const details = response.body.error.details;
      assert.ok(details && typeof details === "object" && !Array.isArray(details), "key error details must be an object");
    }
    metadata(response, teamId); noStore(response);
  }
  function flatError(response, status, code) {
    noSecretEcho(response);
    assert.equal(response.status, status);
    object(response.body, ["error"], "device refusal");
    assert.ok(response.body.error === code, "device error code differs");
  }
  function validateChain(snapshots) {
    const latest = snapshots.at(-1);
    try {
      validateAgeConfiguration({
        server_instance_id: serverId, remote_team_id: fixture.primary.teamId,
        age_v1: {
          epoch_snapshots: snapshots, age_version: "contract",
          identity_files: Object.fromEntries(latest.history.map(row => [row.key_id, `fixture:${row.key_id}`])),
          checkpoint: {
            epoch_revision: latest.epoch_revision, writer_generation: latest.writer_generation,
            snapshot_sha256: ageSnapshotDigest(latest), confirmed_at: new Date().toISOString(),
          },
        },
      });
    } catch { throw new Error("handoff snapshot chain failed the existing local validator"); }
  }
  async function material(epoch, previous) {
    let value;
    try { value = await fixture.newEpoch({ epoch, teamId: fixture.primary.teamId, previous }); }
    catch { throw new Error("fixture could not create a real key epoch"); }
    object(value, ["key_id", "identity", "recipient", "snapshot"], "fixture epoch");
    assert.ok(KEY_ID.test(value.key_id) && RECIPIENT.test(value.recipient), "fixture epoch has invalid public material");
    nonempty(value.identity, "fixture epoch identity");
    forbiddenText.add(value.identity);
    assert.ok(value.snapshot.epoch_revision === String(epoch - 1), "fixture snapshot revision differs");
    return { ...value, epoch };
  }
  function epochResponse(response, status, epoch, winner) {
    noSecretEcho(response);
    assert.equal(response.status, status);
    object(response.body, status === 201 ? ["status", "epoch"] : ["status", "epoch", "key_id", "recipient"], "epoch result", METADATA);
    assert.ok(response.body.status === (status === 201 ? "registered" : "exists"), "epoch result status differs");
    assertKeyEpoch(response.body, epoch);
    if (status === 200) assert.ok(response.body.key_id === winner.key_id && response.body.recipient === winner.recipient, "existing epoch must return the winner's public half");
    metadata(response, fixture.primary.teamId); noStore(response);
  }
  async function bundle(expected) {
    const response = await data(primary, "/keys/bundle", fixture.primary.teamId);
    noSecretEcho(response);
    assert.equal(response.status, 200);
    object(response.body, ["format", "epochs", "snapshot_sha256", "bundle"], "sealed bundle", METADATA);
    assert.ok(response.body.format === "agmsg_age_v1_handoff", "bundle format differs");
    assert.ok(canonicalJson(response.body.epochs) === canonicalJson(expected.map(row => row.epoch)), "bundle must retain all registered epochs in order");
    assert.ok(typeof response.body.bundle === "string" && response.body.bundle.length > 0 && Buffer.from(response.body.bundle, "base64").toString("base64") === response.body.bundle, "bundle must be base64 ciphertext");
    const sealed = response.body.bundle;
    noStore(response); metadata(response, fixture.primary.teamId);
    forbiddenText.add(sealed);
    let plaintext, opened;
    try {
      plaintext = await fixture.openSealed(sealed, fixture.primary.deviceIdentity);
      opened = JSON.parse(plaintext);
      assert.ok(plaintext === canonicalJson(opened));
    } catch { throw new Error("bundle must decrypt to canonical JSON for the calling device"); }
    assertKeyHandoffHeader(opened);
    assert.ok(canonicalJson(opened.snapshots) === canonicalJson(expected.map(row => row.snapshot)), "handoff must contain exactly the retained snapshots");
    validateChain(opened.snapshots);
    assert.ok(response.body.snapshot_sha256 === ageSnapshotDigest(opened.snapshots.at(-1)), "returned digest must match the locally computed latest snapshot digest");
    assert.ok(Array.isArray(opened.identities) && opened.identities.length === expected.length, "handoff must contain every retained identity");
    const seen = new Set();
    for (const row of opened.identities) {
      object(row, ["key_id", "identity"], "handoff identity");
      const known = expected.find(epoch => epoch.key_id === row.key_id);
      assert.ok(known && !seen.has(row.key_id) && row.identity === known.identity, "handoff identity must match its retained epoch");
      seen.add(row.key_id);
    }
    let wrongRecipientRejected = false;
    try { await fixture.openSealed(sealed, fixture.foreign.deviceIdentity); } catch { wrongRecipientRejected = true; }
    assert.ok(wrongRecipientRejected, "bundle must be sealed only to the calling device");
  }

  describe("device registration and escrow HTTP contract", { concurrency: false }, () => {
    after(async () => { await fixture.dispose(); });
    before(async () => {
      const response = await data(primary, "/capabilities", fixture.primary.teamId);
      assert.equal(response.status, 200);
      serverId = response.body.server_instance_id;
      nonempty(serverId, "capabilities server ID");
    });

    it("registers device recipients idempotently and pins control-plane refusals", async () => {
      for (const [identity, caller] of [[fixture.primary, primary], [fixture.foreign, foreign]]) {
        const body = { team_id: identity.teamId, device_pubkey: identity.devicePubkey, label: identity.label };
        for (let index = 0; index < 2; index++) {
          const response = await device(caller, { method: "POST", body });
          assert.equal(response.status, 201);
          object(response.body, ["device_id"], "registered device");
          assert.ok(response.body.device_id === identity.deviceId, "registration must retain the claimant device ID");
          noStore(response); noSecretEcho(response);
        }
      }
      flatError(await device(primary, { method: "POST", body: {} }), 400, "bad_request");
      const own = { team_id: fixture.primary.teamId, device_pubkey: fixture.primary.devicePubkey, label: fixture.primary.label };
      flatError(await device(primary, { method: "POST", body: { ...own, team_id: fixture.foreign.teamId } }), 403, "forbidden");
      flatError(await device(primary, { method: "POST", body: { ...own, device_pubkey: fixture.foreign.devicePubkey } }), 409, "device_key_mismatch");
      const a = await device(unknown, { method: "POST", body: {} });
      const b = await device(revoked, { method: "POST", body: {} });
      flatError(a, 401, "unauthenticated"); flatError(b, 401, "unauthenticated");
      assert.ok(a.raw === b.raw, "unknown and revoked control credentials must be indistinguishable");
    });

    it("distinguishes malformed requests from invalid epoch material without retaining it", async () => {
      const candidate = await material(1, null);
      validateChain([candidate.snapshot]);
      const post = body => data(primary, "/keys/epochs", fixture.primary.teamId, { method: "POST", body });
      for (const body of [{}, { ...candidate, epoch: "1" }, { ...candidate, extra: true }]) {
        error(await post(body), 400, "bad_request", fixture.primary.teamId);
      }
      for (const [body, code] of [
        [{ ...candidate, epoch: 0, snapshot: { ...candidate.snapshot, epoch_revision: "-1" } }, "epoch_invalid"],
        [{ ...candidate, key_id: "INVALID" }, "key_id_invalid"],
        [{ ...candidate, recipient: "not-an-age-recipient" }, "recipient_invalid"],
        [{ ...candidate, identity: fixture.foreign.deviceIdentity }, "identity_mismatch"],
        [{ ...candidate, snapshot: { ...candidate.snapshot, epoch_revision: "99" } }, "snapshot_mismatch"],
        [await material(2, candidate), "previous_epoch_missing"],
      ]) error(await post(body), 422, code, fixture.primary.teamId);
      error(await data(primary, "/keys/bundle", fixture.primary.teamId), 409, "no_team_key", fixture.primary.teamId);
    });

    it("registers one concurrent winner and returns a sealed complete retained chain", async () => {
      error(await data(primary, "/keys/bundle", fixture.primary.teamId), 409, "no_team_key", fixture.primary.teamId);
      const candidates = await Promise.all([material(1, null), material(1, null)]);
      assert.notEqual(candidates[0].key_id, candidates[1].key_id, "fixture epoch candidates must use distinct keys");
      for (const candidate of candidates) validateChain([candidate.snapshot]);
      const results = await Promise.all(candidates.map(body => data(primary, "/keys/epochs", fixture.primary.teamId, { method: "POST", body })));
      assert.equal(results.filter(response => response.status === 201).length, 1, "exactly one concurrent registration wins");
      assert.equal(results.filter(response => response.status === 200).length, 1, "the concurrent loser receives the existing public key");
      const winnerIndex = results.findIndex(response => response.status === 201);
      const winner = candidates[winnerIndex];
      epochResponse(results[winnerIndex], 201, 1, winner);
      epochResponse(results[1 - winnerIndex], 200, 1, winner);
      for (const candidate of candidates) epochResponse(await data(primary, "/keys/epochs", fixture.primary.teamId, { method: "POST", body: candidate }), 200, 1, winner);
      await bundle([winner]);
      const second = await material(2, winner);
      validateChain([winner.snapshot, second.snapshot]);
      error(await data(primary, "/keys/epochs", fixture.primary.teamId, { method: "POST", body: { ...second, key_id: winner.key_id } }), 422, "key_id_conflict", fixture.primary.teamId);
      epochResponse(await data(primary, "/keys/epochs", fixture.primary.teamId, { method: "POST", body: second }), 201, 2, second);
      epochResponse(await data(primary, "/keys/epochs", fixture.primary.teamId, { method: "POST", body: second }), 200, 2, second);
      await bundle([winner, second]);
    });

    it("keeps unknown/revoked secrets and foreign/nonexistent teams indistinguishable", async () => {
      const absentTeam = "018f3f7e-ffff-7fff-8fff-ffffffffffff";
      for (const [path, options] of [["/keys/bundle", {}], ["/keys/epochs", { method: "POST", body: {} }]]) {
        const a = await data(unknown, path, fixture.primary.teamId, options);
        const b = await data(revoked, path, fixture.primary.teamId, options);
        error(a, 401, "unauthenticated", fixture.primary.teamId); error(b, 401, "unauthenticated", fixture.primary.teamId);
        assert.ok(a.raw === b.raw, "unknown and revoked key credentials must be indistinguishable");
        const existing = await data(primary, path, fixture.foreign.teamId, options);
        const absent = await data(primary, path, absentTeam, options);
        error(existing, 404, ["not_found", "team-not-found"], fixture.foreign.teamId);
        error(absent, 404, ["not_found", "team-not-found"], absentTeam);
        assert.ok(existing.raw === absent.raw, "foreign and nonexistent key teams must be indistinguishable");
      }
    });

    it("requires a registered recipient even for a live authorized capability", async () => {
      const candidate = await material(1, null);
      error(await data(unregistered, "/keys/bundle", fixture.primary.teamId), 403, "forbidden", fixture.primary.teamId);
      error(await data(unregistered, "/keys/epochs", fixture.primary.teamId, { method: "POST", body: candidate }), 403, "forbidden", fixture.primary.teamId);
    });
  });
}
