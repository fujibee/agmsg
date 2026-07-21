import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  ageSnapshotDigest,
  consistentReadStateContext,
  driver,
  isRetryable,
  plaintextWriteEligible,
  readStateCycle,
  readStateUpdateBatches,
  request,
  retainAgeCheckpoint,
  selectWriteProfile,
  stage2ReadStateSupported,
  validateAckMapping,
  validateAgeConfiguration,
  validateConfiguredAgeIdentities,
  validateCapabilities,
  validateErrorBinding,
  validateMembers,
  validateReadStatePage,
} from "../scripts/internal/remote-sync.mjs";

const config = {
  local_team: "demo",
  server_instance_id: "018f3f7e-0000-7000-8000-000000000000",
  remote_team_id: "018f3f7e-0000-7000-8000-000000000001",
  protocol_version: 1,
  local_security_history: [{
    local_security_revision: "0", effective_from_seq: "1",
    minimum_security_mode: "plaintext-allowed",
  }],
};

const candidates = [
  { local_position: "1", id: "550e8400-e29b-41d4-a716-446655440001" },
  { local_position: "2", id: "550e8400-e29b-41d4-a716-446655440002" },
];

test("ack mapping rejects reversed and duplicate server sequences", () => {
  assert.throws(() => validateAckMapping(candidates, [
    { id: candidates[0].id, server_seq: "2", disposition: "stored" },
    { id: candidates[1].id, server_seq: "1", disposition: "stored" },
  ]), /strictly increasing/u);
  assert.throws(() => validateAckMapping(candidates, [
    { id: candidates[0].id, server_seq: "1", disposition: "stored" },
    { id: candidates[1].id, server_seq: "1", disposition: "stored" },
  ]), /strictly increasing/u);
  assert.throws(() => validateAckMapping(candidates, [
    { id: candidates[0].id, server_seq: "1", disposition: "stored", extra: true },
    { id: candidates[1].id, server_seq: "2", disposition: "stored" },
  ]), /shape/u);
});

test("Stage-2 roster, update batches, and response pages are canonical", () => {
  const members = [{ member_id: "018f3f7e-0000-7000-8000-000000000010", name: "worker-1" }];
  assert.deepEqual(validateMembers(config, {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "0", members_revision: "1",
    members: [{ ...members[0], registrations: [] }],
  }), members);
  const exact = Array.from({ length: 1001 }, (_, index) =>
    `550e8400-e29b-41d4-a716-${String(index).padStart(12, "0")}`);
  const batches = readStateUpdateBatches(members, [
    { type: "sync_read_frontier", member_id: members[0].member_id, server_seq: "7" },
    ...exact.map((wire_id) => ({ type: "sync_read_exact", member_id: members[0].member_id, wire_id })),
  ]);
  assert.equal(batches.length, 2);
  assert.equal(batches[0][0].exact_wire_ids.length, 1000);
  assert.equal(batches[1][0].exact_wire_ids.length, 1);

  assert.doesNotThrow(() => validateReadStatePage(config, {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "4", current_seq: "9",
    items: [{ kind: "frontier", member_id: members[0].member_id, server_seq: "7" }],
    next_page_after: { member_id: members[0].member_id, kind: "frontier" }, has_more: true,
  }, 1));
  assert.throws(() => validateReadStatePage(config, {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "4", current_seq: "9",
    items: [{ kind: "frontier", member_id: members[0].member_id, server_seq: "3" }],
    next_page_after: null, has_more: false,
  }, 1), /item is invalid/u);
  const after = { member_id: members[0].member_id, kind: "frontier" };
  assert.throws(() => validateReadStatePage(config, {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "4", current_seq: "9",
    items: [{ kind: "frontier", member_id: members[0].member_id, server_seq: "7" }],
    next_page_after: { member_id: members[0].member_id, kind: "frontier" }, has_more: true,
  }, 1, after), /page order/u);
  assert.throws(() => validateReadStatePage(config, {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "4", current_seq: "9",
    items: [], next_page_after: null, has_more: true,
  }, 1), /response is invalid/u);
});

test("Stage-2 capability is optional and blocked members emit no mutation", () => {
  assert.equal(stage2ReadStateSupported([{
    type: "sync_driver_capabilities", capabilities: ["stage1-sync"],
  }]), false);
  assert.equal(stage2ReadStateSupported([{
    type: "sync_driver_capabilities", capabilities: ["stage1-sync", "stage2-read-state"],
  }]), true);
  const member = { member_id: "018f3f7e-0000-7000-8000-000000000010", name: "worker-1" };
  assert.deepEqual(readStateUpdateBatches([member], [{
    type: "sync_read_blocked", member_id: member.member_id,
    reason: "read-state-limit-exceeded",
  }]), [[]]);
});

test("Stage-1-only driver skips the optional Stage-2 network path", async () => {
  const events = [];
  await readStateCycle(config, 100, {
    driverCall: async (operation) => {
      assert.equal(operation, "capabilities");
      return [{ type: "sync_driver_capabilities", capabilities: ["stage1-sync"] }];
    },
    requestCall: async () => { throw new Error("Stage-2 request must be skipped"); },
    eventCall: async (name, value) => { events.push([name, value]); },
  });
  assert.deepEqual(events, [["read-state.skipped", {
    reason: "driver-capability-not-advertised",
  }]]);
});

test("Stage-2 isolates a limit offender and continues read-only synchronization", async () => {
  const members = [
    { member_id: "018f3f7e-0000-7000-8000-000000000010", name: "causal-a" },
    { member_id: "018f3f7e-0000-7000-8000-000000000020", name: "worker-b" },
    { member_id: "018f3f7e-0000-7000-8000-000000000030", name: "reported-c" },
  ];
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "0", current_seq: "0",
    next_sequence_boundary: "1", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1], write_allowed_ciphers: ["none"] }],
  };
  const roster = { protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "0", members_revision: "0",
    members: members.map((member) => ({ ...member, registrations: [] })) };
  const operations = [];
  let postCount = 0;
  await readStateCycle(config, 100, {
    driverCall: async (operation, _config, input) => {
      operations.push(operation);
      if (operation === "capabilities") return [{
        type: "sync_driver_capabilities", capabilities: ["stage1-sync", "stage2-read-state"],
      }];
      if (operation === "read-prepare") return [
        { type: "sync_read_frontier", member_id: members[0].member_id, server_seq: "0" },
        ...Array.from({ length: 5001 }, (_, index) => ({ type: "sync_read_exact",
          member_id: members[0].member_id,
          wire_id: `550e8400-e29b-4000-8000-${String(index).padStart(12, "0")}` })),
        ...members.slice(1).map((member) => ({ type: "sync_read_frontier",
          member_id: member.member_id, server_seq: "0" })),
      ];
      if (operation === "read-block") {
        assert.equal(input[0].member_id, members[0].member_id);
        return [{ type: "sync_read_blocked", member_id: members[0].member_id,
          reason: "read-state-limit-exceeded" }];
      }
      if (operation === "read-apply") return [{ type: "sync_read_applied", member_count: 2 }];
      throw new Error(`unexpected driver operation ${operation}`);
    },
    requestCall: async (_config, path, init) => {
      if (path === "/v1/capabilities") return capabilities;
      if (path === "/v1/members") return roster;
      assert.equal(path, "/v1/read-state/sync");
      postCount += 1;
      const updates = JSON.parse(init.body).updates;
      if (postCount <= 4) {
        assert.deepEqual(updates.map((update) => update.member_id), [members[0].member_id]);
      }
      if (postCount === 5) {
        assert.deepEqual(updates.map((update) => update.member_id), [members[0].member_id]);
        const error = new Error("limit");
        error.code = "read-state-limit-exceeded";
        error.body = { error: { details: { member_id: members[2].member_id } } };
        throw error;
      }
      if (postCount > 5) {
        assert.equal(updates.some((update) => update.member_id === members[0].member_id), false);
      }
      return { protocol_version: 1, server_instance_id: config.server_instance_id,
        team_id: config.remote_team_id, min_available_seq: "0", current_seq: "0",
        items: members.map((member) => ({ kind: "frontier",
          member_id: member.member_id, server_seq: "0" })),
        next_page_after: null, has_more: false };
    },
    eventCall: async () => {},
    localAgentsCall: async () => members.map((member) => member.name),
  });
  assert.equal(postCount, 7);
  assert.ok(operations.includes("read-block"));
  assert.ok(operations.includes("read-apply"));
});

test("read-state context refetches a concurrent retention floor", async () => {
  const capabilities10 = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "10", current_seq: "20",
    next_sequence_boundary: "21", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1], write_allowed_ciphers: ["none"] }],
  };
  const capabilities20 = { ...capabilities10, min_available_seq: "20" };
  const roster = (floor) => ({ protocol_version: 1,
    server_instance_id: config.server_instance_id, team_id: config.remote_team_id,
    min_available_seq: floor, members_revision: "0", members: [] });
  const replies = [roster("20"), capabilities20, roster("20")];
  const result = await consistentReadStateContext(config, capabilities10, async () => replies.shift());
  assert.equal(result.capabilities.min_available_seq, "20");
});

test("resolved protocol errors enforce the immutable binding", () => {
  for (const status of [403, 410]) {
    assert.throws(() => validateErrorBinding(config, status, {
      protocol_version: 1,
      server_instance_id: "018f3f7e-0000-7000-8000-000000000099",
      team_id: config.remote_team_id,
      error: { code: status === 410 ? "resync-required" : "cipher-policy-violation" },
    }), /binding mismatch/u);
  }
  assert.doesNotThrow(() => validateErrorBinding(config, 401, {
    protocol_version: 1, error: { code: "unauthenticated" },
  }));
});

test("run retry classification excludes permanent HTTP and validation failures", () => {
  assert.equal(isRetryable({ retryable: true }), true);
  for (const status of [408, 429, 500, 502, 503, 504]) assert.equal(isRetryable({ status }), true);
  for (const status of [400, 401, 403, 404, 409, 410, 422, 426]) assert.equal(isRetryable({ status }), false);
  assert.equal(isRetryable(new Error("binding mismatch")), false);
});

test("headerless non-JSON intermediary failures remain retryable", async () => {
  const previousFetch = globalThis.fetch;
  const previousToken = process.env.AGMSG_SYNC_TOKEN;
  process.env.AGMSG_SYNC_TOKEN = "fixture-token";
  try {
    for (const status of [502, 503, 504]) {
      globalThis.fetch = async () => new Response("temporary proxy failure", { status });
      await assert.rejects(request({ ...config, server_url: "https://sync.example" }, "/v1/messages"),
        (error) => error.status === status && error.retryable === true);
    }
  } finally {
    globalThis.fetch = previousFetch;
    if (previousToken === undefined) delete process.env.AGMSG_SYNC_TOKEN;
    else process.env.AGMSG_SYNC_TOKEN = previousToken;
  }
});

test("request distinguishes config errors from response transport loss", async () => {
  const previousFetch = globalThis.fetch;
  const previousToken = process.env.AGMSG_SYNC_TOKEN;
  process.env.AGMSG_SYNC_TOKEN = "fixture-token";
  let fetchCalled = false;
  try {
    globalThis.fetch = async () => { fetchCalled = true; throw new Error("unexpected fetch"); };
    await assert.rejects(request({ ...config, server_url: "not a URL" }, "/v1/messages"),
      (error) => error.retryable !== true);
    assert.equal(fetchCalled, false);

    globalThis.fetch = async () => ({
      ok: true, status: 200,
      headers: { get: () => "1" },
      text: async () => { throw new Error("body stream reset"); },
    });
    await assert.rejects(request({ ...config, server_url: "https://sync.example" }, "/v1/messages"),
      (error) => error.retryable === true);
  } finally {
    globalThis.fetch = previousFetch;
    if (previousToken === undefined) delete process.env.AGMSG_SYNC_TOKEN;
    else process.env.AGMSG_SYNC_TOKEN = previousToken;
  }
});

test("write-ineligible capabilities still validate for pull", () => {
  const base = {
    protocol_version: 1,
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    min_available_seq: "0",
    current_seq: "4",
    next_sequence_boundary: "5",
    accepted_envelope_versions: [1],
    write_allowed_ciphers: ["future-aead"],
    policy_revision: "1",
    effective_from_seq: "1",
    max_blob_bytes: "1048576",
    policy_history: [{
      policy_revision: "1", effective_from_seq: "1",
      accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"],
    }],
  };
  assert.equal(plaintextWriteEligible(config, base), false);
  assert.equal(plaintextWriteEligible(config, {
    ...base,
    current_seq: "9223372036854775807",
    next_sequence_boundary: null,
  }), false);
});

test("capability policy history must be canonical and match current policy", () => {
  const base = {
    protocol_version: 1,
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    min_available_seq: "0", current_seq: "4", next_sequence_boundary: "5",
    accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"],
    policy_revision: "2", effective_from_seq: "3", max_blob_bytes: "1048576",
    policy_history: [
      { policy_revision: "0", effective_from_seq: "1",
        accepted_envelope_versions: [1], write_allowed_ciphers: ["none"] },
      { policy_revision: "2", effective_from_seq: "3",
        accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"] },
    ],
  };
  assert.doesNotThrow(() => validateCapabilities(config, base));
  assert.throws(() => validateCapabilities(config, {
    ...base, write_allowed_ciphers: ["none"],
  }), /does not match/u);
  assert.throws(() => validateCapabilities(config, {
    ...base,
    policy_history: [...base.policy_history,
      { policy_revision: "3", effective_from_seq: "3",
        accepted_envelope_versions: [1], write_allowed_ciphers: ["future-aead"] }],
    policy_revision: "3",
  }), /canonical ascending/u);
  assert.throws(() => validateCapabilities(config, {
    ...base,
    policy_history: [base.policy_history[1], base.policy_history[0]],
  }), /canonical ascending|begin at sequence 1/u);
});

test("storage driver subprocess cannot observe HTTP or age identity secrets", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-env-"));
  const mock = join(root, "driver.sh");
  await writeFile(mock, `#!/usr/bin/env bash
[ -z "\${AGMSG_SYNC_TOKEN:-}" ] || exit 99
[ -z "\${AGMSG_SYNC_TRUST_DIR:-}" ] || exit 95
[ -z "\${AGMSG_AGE_IDENTITY:-}" ] || exit 98
[ -z "\${AGMSG_AGE_IDENTITY_FILE:-}" ] || exit 97
[ -z "\${AGMSG_SYNC_AGE_IDENTITY_EPOCH_1:-}" ] || exit 96
printf '{"type":"mock-ok"}\\n'
`, { mode: 0o700 });
  const previousDriver = process.env.AGMSG_SYNC_DRIVER;
  const previousToken = process.env.AGMSG_SYNC_TOKEN;
  const previousIdentity = process.env.AGMSG_AGE_IDENTITY;
  const previousIdentityFile = process.env.AGMSG_AGE_IDENTITY_FILE;
  const previousSyncIdentity = process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1;
  const previousTrust = process.env.AGMSG_SYNC_TRUST_DIR;
  process.env.AGMSG_SYNC_DRIVER = mock;
  process.env.AGMSG_SYNC_TOKEN = "must-not-cross-driver-boundary";
  process.env.AGMSG_AGE_IDENTITY = "AGE-SECRET-KEY-1FIXTURE";
  process.env.AGMSG_AGE_IDENTITY_FILE = "/secret/identity";
  process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1 = "/secret/identity";
  process.env.AGMSG_SYNC_TRUST_DIR = "/durable/trust";
  try {
    assert.deepEqual(await driver("prepare", config, [], ["1"]), [{ type: "mock-ok" }]);
  } finally {
    if (previousDriver === undefined) delete process.env.AGMSG_SYNC_DRIVER;
    else process.env.AGMSG_SYNC_DRIVER = previousDriver;
    if (previousToken === undefined) delete process.env.AGMSG_SYNC_TOKEN;
    else process.env.AGMSG_SYNC_TOKEN = previousToken;
    if (previousIdentity === undefined) delete process.env.AGMSG_AGE_IDENTITY;
    else process.env.AGMSG_AGE_IDENTITY = previousIdentity;
    if (previousIdentityFile === undefined) delete process.env.AGMSG_AGE_IDENTITY_FILE;
    else process.env.AGMSG_AGE_IDENTITY_FILE = previousIdentityFile;
    if (previousSyncIdentity === undefined) delete process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1;
    else process.env.AGMSG_SYNC_AGE_IDENTITY_EPOCH_1 = previousSyncIdentity;
    if (previousTrust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
    else process.env.AGMSG_SYNC_TRUST_DIR = previousTrust;
    if (!root.startsWith(join(tmpdir(), "agmsg-sync-driver-env-"))) throw new Error("unsafe test root");
    await rm(root, { recursive: true });
  }
});

test("age-v1 write selection exposes only public epoch material", () => {
  const recipients = ["age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp"];
  const ageConfig = {
    ...config,
    cipher_profile: "age-v1",
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: "e2ee-required" }],
    age_v1: { epoch_snapshot: { history: [{ epoch_revision: "0", effective_from_seq: "1",
      cipher: "age-v1", key_id: "epoch-1", recipients }] },
    identity_files: { "epoch-1": "/secret/identity" } },
  };
  const policy = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "0", current_seq: "4",
    next_sequence_boundary: "5", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["age-v1"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["age-v1"] }],
  };
  const selected = selectWriteProfile(ageConfig, policy);
  assert.deepEqual(selected, { eligible: true, profile: "age-v1", key_id: "epoch-1", recipients });
  assert.equal(JSON.stringify(selected).includes("identity"), false);
});

test("age-v1 configuration binds its checkpoint and initial history", () => {
  assert.throws(() => ageSnapshotDigest({ bad: "\ud800" }), /lone surrogate/u);
  assert.throws(() => ageSnapshotDigest({ ["\udc00"]: "bad-key" }), /lone surrogate/u);
  const snapshot = {
    profile: "age-v1",
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    epoch_revision: "0",
    writer_generation: "0",
    authorized_writers: ["writer-a"],
    previous_snapshot_sha256: null,
    history: [{ epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
      key_id: "epoch-1", recipients: [
        "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
      ] }],
  };
  const ageConfig = { ...config, cipher_profile: "age-v1", age_v1: {
    epoch_snapshot: snapshot,
    checkpoint: { epoch_revision: "0", writer_generation: "0",
      snapshot_sha256: ageSnapshotDigest(snapshot), confirmed_at: "2026-07-21T00:00:00.000Z" },
    identity_files: {}, age_version: "v1.3.1",
  } };
  assert.doesNotThrow(() => validateAgeConfiguration(ageConfig));
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1, checkpoint: { ...ageConfig.age_v1.checkpoint,
      snapshot_sha256: "0".repeat(64) },
  } }), /checkpoint/u);
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1, epoch_snapshot: { ...snapshot, previous_snapshot_sha256: "1".repeat(64) },
  } }), /previous digest/u);
  const rotated = { ...snapshot, epoch_revision: "1", previous_snapshot_sha256: "1".repeat(64),
    history: [...snapshot.history, { ...snapshot.history[0], epoch_revision: "1",
      effective_from_seq: "2", key_id: "epoch-2" }] };
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1,
    epoch_snapshot: rotated,
    checkpoint: { ...ageConfig.age_v1.checkpoint, epoch_revision: "1",
      snapshot_sha256: ageSnapshotDigest(rotated) },
  } }), /only an initial revision-0/u);
});

test("retained age checkpoint survives sync config reset and rejects same-revision conflict", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-age-trust-"));
  const previousTrust = process.env.AGMSG_SYNC_TRUST_DIR;
  const previousStorage = process.env.AGMSG_SYNC_STORAGE_DIR;
  process.env.AGMSG_SYNC_TRUST_DIR = join(root, "trust");
  process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "resettable-store");
  const snapshot = {
    profile: "age-v1", server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, epoch_revision: "0", writer_generation: "0",
    authorized_writers: ["writer-a"], previous_snapshot_sha256: null,
    history: [{ epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
      key_id: "epoch-1", recipients: [
        "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
      ] }],
  };
  const makeConfig = (value) => ({ ...config, cipher_profile: "age-v1", age_v1: {
    epoch_snapshot: value,
    checkpoint: { epoch_revision: "0", writer_generation: "0",
      snapshot_sha256: ageSnapshotDigest(value), confirmed_at: "2026-07-21T00:00:00.000Z" },
    identity_files: {}, age_version: "v1.3.1",
  } });
  try {
    await assert.rejects(retainAgeCheckpoint(makeConfig(snapshot), undefined), /operator-live/u);
    const retained = await retainAgeCheckpoint(makeConfig(snapshot), "operator-live");
    assert.equal(retained.snapshot_sha256, ageSnapshotDigest(snapshot));
    const resettableConfig = join(process.env.AGMSG_SYNC_STORAGE_DIR, "remote-sync", "demo.json");
    await mkdir(join(process.env.AGMSG_SYNC_STORAGE_DIR, "remote-sync"), { recursive: true });
    await writeFile(resettableConfig, "{}\n");
    await unlink(resettableConfig);
    const conflicting = { ...snapshot, authorized_writers: ["writer-b"] };
    await assert.rejects(retainAgeCheckpoint(makeConfig(conflicting), "operator-live"),
      /same-revision conflict/u);
  } finally {
    if (previousTrust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
    else process.env.AGMSG_SYNC_TRUST_DIR = previousTrust;
    if (previousStorage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
    else process.env.AGMSG_SYNC_STORAGE_DIR = previousStorage;
    await rm(root, { recursive: true });
  }
});

test("configured native identity must belong to its epoch recipient manifest", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-age-identity-"));
  const identity = join(root, "identity");
  await writeFile(identity,
    "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ\n",
    { mode: 0o600 });
  const ageConfig = { ...config, age_v1: {
    identity_files: { "epoch-1": identity },
    epoch_snapshot: { history: [{ key_id: "epoch-1", recipients: [
      "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
    ] }] },
  } };
  try {
    assert.throws(() => validateConfiguredAgeIdentities(ageConfig), /does not match/u);
  } finally {
    await rm(root, { recursive: true });
  }
});
