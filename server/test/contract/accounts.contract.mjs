// HTTP-only accounts contract. The same assertions run against either server;
// fixture creation and approval are injected, never selected by host name.
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { after, describe, it } from "node:test";

const CLIENT = "agmsg-cli";
const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SECRET = /^agsy_[0-9a-f]{8}_[A-Za-z0-9_-]{43}$/;
const USER_CODE = /^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;
const CODE_KEYS = ["device_code", "user_code", "verification_uri", "verification_uri_complete", "expires_in", "interval"];
const DEVICE_KEYS = ["id", "devicePubkey", "label", "createdAt", "thisMachine"];

function keys(value, expected, label, optional = []) {
  assert.ok(value && typeof value === "object" && !Array.isArray(value), `${label}: expected an object`);
  assert.ok(expected.every(key => Object.hasOwn(value, key)) && Object.keys(value).every(key => expected.includes(key) || optional.includes(key)), `${label}: response keys differ`);
}
function text(value, label) {
  assert.ok(typeof value === "string" && value.length > 0, `${label}: expected a nonempty string`);
}
function parsedUrl(value, label) {
  try { return new URL(value); }
  catch { throw new Error(`${label}: invalid URL`); }
}
function flatError(response, status, code) {
  assert.equal(response.status, status, "control-plane error status");
  keys(response.body, ["error"], "control-plane error");
  assert.ok(response.body.error === code, "control-plane error code differs");
}
function dataError(response, status, code) {
  assert.equal(response.status, status, "data-plane error status");
  keys(response.body, ["error"], "data-plane error", ["protocol_version", "server_instance_id", "team_id"]);
  keys(response.body.error, ["code"], "data-plane error code", ["message", "details"]);
  if (Object.hasOwn(response.body, "protocol_version")) assert.equal(response.body.protocol_version, 1);
  for (const name of ["server_instance_id", "team_id"]) {
    if (Object.hasOwn(response.body, name)) text(response.body[name], `error ${name}`);
  }
  if (Object.hasOwn(response.body.error, "message")) assert.equal(typeof response.body.error.message, "string");
  if (Object.hasOwn(response.body.error, "details")) {
    const details = response.body.error.details;
    assert.ok(details && typeof details === "object" && !Array.isArray(details), "error details must be an object");
  }
  assert.ok((Array.isArray(code) ? code : [code]).includes(response.body.error.code), "data-plane error code differs");
}
function noStore(response, pragma = false) {
  assert.ok(response.headers.get("cache-control")?.split(/\s*,\s*/).includes("no-store"), "response must be no-store");
  if (pragma) assert.equal(response.headers.get("pragma"), "no-cache");
}
function capability(url) {
  const parsed = parsedUrl(url, "capability");
  const match = /\/t\/([^/]+)$/.exec(parsed.pathname);
  assert.ok(match && SECRET.test(match[1]), "capability URL has the wrong path/secret format");
  assert.ok(!parsed.search && !parsed.hash && !parsed.username && !parsed.password, "capability URL must not carry extra credentials or query data");
  return { url: parsed.href.replace(/\/$/, ""), secret: match[1] };
}

export function defineAccountsContract({ baseUrl, fixture, requestTimeoutMs = 5000 }) {
  const base = parsedUrl(baseUrl, "control origin");
  assert.ok(["http:", "https:"].includes(base.protocol), "base URL must use HTTP(S)");
  assert.ok(!base.username && !base.password && !base.search && !base.hash, "base URL must not contain credentials, query, or fragment");
  const origin = base.href.replace(/\/$/, "");
  for (const name of ["primary", "foreign", "revoked"]) {
    const value = fixture[name];
    assert.ok(value && typeof value === "object", `fixture.${name} is required`);
    capability(value.capabilityUrl);
    text(value.teamId, `fixture.${name}.teamId`);
    text(value.deviceId, `fixture.${name}.deviceId`);
    if (name !== "revoked") {
      if (value.devicePubkey !== null) text(value.devicePubkey, `fixture.${name}.devicePubkey`);
      text(value.label, `fixture.${name}.label`);
    }
  }
  assert.notEqual(fixture.primary.teamId, fixture.foreign.teamId, "fixtures must contain two separately owned teams");
  text(fixture.primary.teamName, "fixture.primary.teamName");
  assert.equal(typeof fixture.approveGrant, "function", "fixture.approveGrant is required");
  assert.equal(typeof fixture.dispose, "function", "fixture.dispose is required");
  assert.ok(fixture.expectedLimits && typeof fixture.expectedLimits === "object" && !Array.isArray(fixture.expectedLimits), "fixture.expectedLimits is required (empty for unlimited)");
  const primary = capability(fixture.primary.capabilityUrl);
  const foreign = capability(fixture.foreign.capabilityUrl);
  const revoked = capability(fixture.revoked.capabilityUrl);
  const unknown = `agsy_${randomBytes(4).toString("hex")}_${randomBytes(32).toString("base64url")}`;
  const unknownUrl = primary.url.replace(/\/t\/[^/]+$/, `/t/${unknown}`);
  const knownSecrets = [primary.secret, foreign.secret, revoked.secret, unknown];

  // Labels and failures deliberately omit URLs, request bodies, cookies, and
  // response bodies: those can carry live test credentials even on failure.
  async function request(root, path, { method = "GET", headers = {}, body } = {}) {
    let response, raw;
    try {
      response = await fetch(`${root}${path}`, {
        method,
        headers: { ...(body === undefined ? {} : { "content-type": "application/json" }), ...headers },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(requestTimeoutMs),
        redirect: "error",
      });
      raw = await response.text();
    } catch {
      throw new Error(`${method} contract request failed or timed out`);
    }
    let parsed;
    try { parsed = JSON.parse(raw); }
    catch { throw new Error(`${method} contract response is not JSON`); }
    return { status: response.status, headers: response.headers, body: parsed, raw };
  }
  const control = (path, options) => request(origin, path, options);
  const data = (url, path, teamId, options = {}) => request(url, `/v1${path}`, {
    ...options,
    headers: { "agmsg-protocol-version": "1", "agmsg-team-id": teamId, ...options.headers },
  });
  const bearer = secret => ({ authorization: `Bearer ${secret}` });
  function noSecretEcho(response) {
    assert.ok(knownSecrets.every(secret => !response.raw.includes(secret)), "error response reflected a capability secret");
  }
  async function issue(machineName) {
    const response = await control("/v1/device/code", { method: "POST", body: { client_id: CLIENT, machine_name: machineName } });
    assert.equal(response.status, 200);
    keys(response.body, CODE_KEYS, "device code");
    assert.ok(/^[A-Za-z0-9_-]{43}$/.test(response.body.device_code), "device code must be 32-byte base64url");
    assert.ok(USER_CODE.test(response.body.user_code), "user code must use the displayed Crockford form");
    assert.equal(response.body.expires_in, 900);
    assert.equal(response.body.interval, 5);
    const verification = parsedUrl(response.body.verification_uri, "verification URI");
    const complete = parsedUrl(response.body.verification_uri_complete, "complete verification URI");
    assert.ok(complete.origin === verification.origin && complete.pathname === verification.pathname, "verification URIs must identify the same page");
    assert.ok(complete.searchParams.get("user_code") === response.body.user_code, "verification URL must carry this user code");
    noStore(response, true);
    return response.body;
  }

  describe("accounts and capability HTTP contract", { concurrency: false }, () => {
    after(async () => { await fixture.dispose(); });

    it("advertises device approval on unauthenticated origin health", async () => {
      const response = await control("/v1/health");
      assert.equal(response.status, 200);
      assert.ok(Array.isArray(response.body.features), "origin health must expose features");
      assert.ok(response.body.features.every(name => typeof name === "string"), "feature names must be strings");
      assert.ok(response.body.features.includes("device-approval"), "origin must advertise device approval");
    });

    it("rejects malformed device-code bodies and unknown clients with the current control-plane errors", async () => {
      for (const body of [
        {}, { client_id: CLIENT }, { client_id: CLIENT, machine_name: " padded " },
        { client_id: CLIENT, machine_name: "line\nbreak" },
        { client_id: CLIENT, machine_name: "test", scope: "join" },
        { client_id: CLIENT, machine_name: "test", unknown: true },
      ]) flatError(await control("/v1/device/code", { method: "POST", body }), 400, "bad_request");
      flatError(await control("/v1/device/code", { method: "POST", body: { client_id: "unregistered-contract-client", machine_name: "test" } }), 400, "invalid_client");
    });

    it("issues a grant and reports pending, slow_down, and opaque unknown/wrong-client token answers", async () => {
      const pending = await issue(`contract-pending-${randomBytes(8).toString("hex")}`);
      const payload = { device_code: pending.device_code, client_id: CLIENT };
      const first = await control("/v1/device/token", { method: "POST", body: payload });
      flatError(first, 400, "authorization_pending");
      noStore(first, true);
      const fast = await control("/v1/device/token", { method: "POST", body: payload });
      assert.equal(fast.status, 400);
      keys(fast.body, ["error", "interval"], "slow_down");
      assert.ok(fast.body.error === "slow_down", "rapid polling must report slow_down");
      assert.equal(fast.body.interval, 10);
      noStore(fast, true);
      flatError(await control("/v1/device/token", { method: "POST", body: {} }), 400, "bad_request");
      flatError(await control("/v1/device/token", { method: "POST", body: { ...payload, extra: true } }), 400, "bad_request");
      flatError(await control("/v1/device/token", { method: "POST", body: { ...payload, client_id: "wrong-client" } }), 400, "expired_token");
      flatError(await control("/v1/device/token", { method: "POST", body: { ...payload, device_code: "unknown-contract-device-code" } }), 400, "expired_token");
    });

    it("reports an owner-denied grant without minting a credential", async () => {
      const grant = await issue(`contract-denied-${randomBytes(8).toString("hex")}`);
      await fixture.approveGrant({ userCode: grant.user_code, decision: "deny", teamId: fixture.primary.teamId });
      const response = await control("/v1/device/token", { method: "POST", body: { device_code: grant.device_code, client_id: CLIENT } });
      flatError(response, 400, "access_denied");
      noStore(response, true);
    });

    it("activates an approved provisional URL idempotently and never returns its token twice", async () => {
      const machineName = `contract-approved-${randomBytes(8).toString("hex")}`;
      const grant = await issue(machineName);
      await fixture.approveGrant({ userCode: grant.user_code, decision: "approve", teamId: fixture.primary.teamId });
      const tokenBody = { device_code: grant.device_code, client_id: CLIENT };
      const response = await control("/v1/device/token", { method: "POST", body: tokenBody });
      assert.equal(response.status, 200);
      keys(response.body, ["capability_url", "machine_name", "scope", "org"], "approved token", ["team_id", "team_name"]);
      const hasTeam = Object.hasOwn(response.body, "team_id");
      assert.equal(hasTeam, Object.hasOwn(response.body, "team_name"), "token team fields must be present together");
      if (hasTeam) {
        assert.ok(typeof response.body.team_id === "string" && UUID_V7.test(response.body.team_id), "token team id must be UUIDv7");
        text(response.body.team_name, "token team name");
        assert.ok(response.body.team_id === fixture.primary.teamId && response.body.team_name === fixture.primary.teamName, "token team must match the approved fixture team");
      }
      assert.ok(response.body.machine_name === machineName, "token must retain the requested machine label");
      assert.ok(response.body.scope === "login", "token scope must remain login");
      text(response.body.org, "token org");
      const approved = capability(response.body.capability_url);
      knownSecrets.push(approved.secret);
      noStore(response, true);
      dataError(await data(approved.url, "/capabilities", fixture.primary.teamId), 401, "unauthenticated");
      for (let n = 0; n < 2; n++) {
        const activated = await control("/v1/device/activate", { method: "POST", headers: bearer(approved.secret) });
        assert.equal(activated.status, 200);
        keys(activated.body, ["activated", "machine_name"], "activation");
        assert.ok(activated.body.activated === true && activated.body.machine_name === machineName, "activation must identify this machine");
        noStore(activated, true);
      }
      flatError(await control("/v1/device/token", { method: "POST", body: tokenBody }), 400, "expired_token");
      assert.equal((await data(approved.url, "/capabilities", fixture.primary.teamId)).status, 200);
    });

    it("distinguishes missing, unknown, and revoked activation credentials", async () => {
      flatError(await control("/v1/device/activate", { method: "POST" }), 401, "unauthenticated");
      flatError(await control("/v1/device/activate", { method: "POST", headers: bearer(unknown) }), 401, "not_found");
      flatError(await control("/v1/device/activate", { method: "POST", headers: bearer(revoked.secret) }), 410, "revoked");
    });

    it("lists registered device wire rows, marks the caller, and excludes revoked or foreign devices", async () => {
      for (const [identity, credential] of [[fixture.primary, primary], [fixture.foreign, foreign]]) {
        const response = await control("/v1/devices", { headers: bearer(credential.secret) });
        assert.equal(response.status, 200);
        keys(response.body, ["devices"], "device listing");
        assert.ok(Array.isArray(response.body.devices), "devices must be an array");
        for (const row of response.body.devices) {
          keys(row, DEVICE_KEYS, "device row", ["type", "lastFetchAt"]);
          text(row.id, "device id");
          if (row.devicePubkey !== null) text(row.devicePubkey, "device public key");
          text(row.label, "device label");
          assert.ok(Number.isFinite(Date.parse(row.createdAt)), "device creation time must be an ISO timestamp");
          assert.equal(typeof row.thisMachine, "boolean");
          if (Object.hasOwn(row, "type")) assert.ok(row.type === null || typeof row.type === "string", "device type must be a string or null");
          if (Object.hasOwn(row, "lastFetchAt")) assert.ok(row.lastFetchAt === null || (typeof row.lastFetchAt === "string" && Number.isFinite(Date.parse(row.lastFetchAt))), "last fetch must be a timestamp or null");
        }
        const own = response.body.devices.find(row => row.id === identity.deviceId);
        assert.ok(own?.thisMachine === true && own.devicePubkey === identity.devicePubkey && own.label === identity.label, "listing must identify the registered caller");
        assert.equal(response.body.devices.filter(row => row.thisMachine).length, 1, "only the caller may be thisMachine");
        const forbidden = [fixture.revoked.deviceId, identity === fixture.primary ? fixture.foreign.deviceId : fixture.primary.deviceId];
        assert.ok(response.body.devices.every(row => !forbidden.includes(row.id)), "listing disclosed a revoked or foreign device");
        noStore(response);
      }
    });

    it("registers the claimant idempotently with 201 and preserves key/team refusal shapes", { skip: "lands with key routes" }, async () => {
      const body = { team_id: fixture.primary.teamId, device_pubkey: fixture.primary.devicePubkey, label: fixture.primary.label };
      for (let n = 0; n < 2; n++) {
        const response = await control("/v1/devices", { method: "POST", headers: bearer(primary.secret), body });
        assert.equal(response.status, 201);
        keys(response.body, ["device_id"], "device bootstrap");
        assert.ok(response.body.device_id === fixture.primary.deviceId, "idempotent registration must return the existing device");
      }
      flatError(await control("/v1/devices", { method: "POST", headers: bearer(primary.secret), body: {} }), 400, "bad_request");
      flatError(await control("/v1/devices", { method: "POST", headers: bearer(primary.secret), body: { ...body, team_id: fixture.foreign.teamId } }), 403, "forbidden");
      flatError(await control("/v1/devices", { method: "POST", headers: bearer(primary.secret), body: { ...body, device_pubkey: fixture.foreign.devicePubkey } }), 409, "device_key_mismatch");
    });

    it("denies unknown and revoked control credentials with identical unauthenticated answers", async () => {
      flatError(await control("/v1/devices"), 401, "unauthenticated");
      const a = await control("/v1/devices", { headers: bearer(unknown) });
      const b = await control("/v1/devices", { headers: bearer(revoked.secret) });
      flatError(a, 401, "unauthenticated"); flatError(b, 401, "unauthenticated");
      assert.ok(a.raw === b.raw, "unknown and revoked credentials must be indistinguishable");
      noSecretEcho(a); noSecretEcho(b); noStore(a); noStore(b);
    });

    it("denies unknown and revoked control credentials on device registration", { skip: "lands with key routes" }, async () => {
      const a = await control("/v1/devices", { method: "POST", body: {}, headers: bearer(unknown) });
      const b = await control("/v1/devices", { method: "POST", body: {}, headers: bearer(revoked.secret) });
      flatError(a, 401, "unauthenticated"); flatError(b, 401, "unauthenticated");
      assert.ok(a.raw === b.raw, "unknown and revoked credentials must be indistinguishable");
      noSecretEcho(a); noSecretEcho(b); noStore(a); noStore(b);
    });

    it("uses capability paths without a bearer header and denies a different team's reads and writes", async () => {
      const own = await data(primary.url, "/members", fixture.primary.teamId);
      assert.equal(own.status, 200);
      assert.equal(own.headers.get("agmsg-protocol-version"), "1");
      const nonexistentTeam = "018f3f7e-ffff-7fff-8fff-ffffffffffff";
      for (const [foreignPath, absentPath, options] of [
        ["/members", "/members", {}],
        [`/teams/${fixture.foreign.teamId}`, `/teams/${nonexistentTeam}`, {}],
        ["/messages", "/messages", { method: "POST", body: { messages: [] } }],
      ]) {
        const existing = await data(primary.url, foreignPath, fixture.foreign.teamId, options);
        const absent = await data(primary.url, absentPath, nonexistentTeam, options);
        dataError(existing, 404, ["not_found", "team-not-found"]);
        dataError(absent, 404, ["not_found", "team-not-found"]);
        assert.ok(existing.raw === absent.raw, "foreign and nonexistent teams must be indistinguishable");
        noSecretEcho(existing); noSecretEcho(absent);
      }
      // Check the path binding independently of the team header binding.
      const foreignPath = await data(primary.url, `/teams/${fixture.foreign.teamId}`, fixture.primary.teamId);
      const absentPath = await data(primary.url, `/teams/${nonexistentTeam}`, fixture.primary.teamId);
      dataError(foreignPath, 404, ["not_found", "team-not-found"]);
      dataError(absentPath, 404, ["not_found", "team-not-found"]);
      assert.ok(foreignPath.raw === absentPath.raw, "path binding must not disclose another team");
    });

    it("denies unknown and revoked device secrets identically on the data plane", async () => {
      for (const [path, options] of [["/members", {}], ["/messages", { method: "POST", body: { messages: [] } }]]) {
        const a = await data(unknownUrl, path, fixture.primary.teamId, options);
        const b = await data(revoked.url, path, fixture.primary.teamId, options);
        dataError(a, 401, "unauthenticated"); dataError(b, 401, "unauthenticated");
        assert.ok(a.raw === b.raw, "unknown and revoked secrets must be indistinguishable");
        noSecretEcho(a); noSecretEcho(b);
      }
    });

    it("advertises post-connect features in team-scoped capabilities", async () => {
      const response = await data(primary.url, "/capabilities", fixture.primary.teamId);
      assert.equal(response.status, 200);
      assert.equal(response.body.protocol_version, 1);
      assert.ok(response.body.team_id === fixture.primary.teamId, "capability binding must name the requested team");
      text(response.body.server_instance_id, "server instance id");
      assert.ok(Array.isArray(response.body.features) && response.body.features.every(name => typeof name === "string"), "capabilities must expose string feature names");
      for (const feature of ["devices", "roster-snapshot", "limits"]) assert.ok(response.body.features.includes(feature), `missing feature: ${feature}`);
      keys(response.body.limits, Object.keys(fixture.expectedLimits), "finite configured limits");
      for (const [name, value] of Object.entries(response.body.limits)) {
        assert.ok(["devices", "teams", "live_messages"].includes(name), "unexpected configured limit name");
        assert.ok(typeof value === "string" && /^(0|[1-9][0-9]*)$/.test(value), "limit values must be decimal strings");
        assert.ok(value === fixture.expectedLimits[name], "configured limit value differs from the fixture");
      }
      // Additional feature names are compatible. Retention's live_messages
      // value describes eviction, not a new limit-reached refusal.
    });
  });
}
