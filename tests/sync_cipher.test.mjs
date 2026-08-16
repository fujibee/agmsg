import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { evaluatePull } from "../scripts/internal/remote-sync.mjs";
import { nativeAgeIdentity, openEnvelope, sealEnvelope,
  validateAgeHeader } from "../scripts/internal/sync-cipher.mjs";

const manifest = JSON.parse(await readFile(
  new URL("../docs/spec/vectors/age-v1-vectors.json", import.meta.url), "utf8"));
const rustGrease = JSON.parse(await readFile(
  new URL("../docs/spec/vectors/age-v1-rust-grease.json", import.meta.url), "utf8"));
const byName = new Map(manifest.vectors.map((vector) => [vector.name, vector]));

function resolveEnvelope(vector) {
  const source = vector.envelope_from ? byName.get(vector.envelope_from) : vector;
  return { ...source.envelope, ...(vector.envelope_override || {}) };
}

function capabilities(config, cipher) {
  return {
    protocol_version: 1,
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    min_available_seq: "0",
    current_seq: "1",
    next_sequence_boundary: "2",
    accepted_envelope_versions: [1],
    write_allowed_ciphers: [cipher],
    policy_revision: "0",
    effective_from_seq: "1",
    max_blob_bytes: "1048576",
    policy_history: [{ policy_revision: "0", effective_from_seq: "1",
      accepted_envelope_versions: [1], write_allowed_ciphers: [cipher] }],
  };
}

test("age-v1 shared vectors preserve every pinned quarantine state", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-contract-"));
  try {
    const identityPaths = {};
    for (const [name, recipientSet] of Object.entries(manifest.recipient_sets)) {
      const path = join(scratch, `${name}.identity`);
      await writeFile(path, `${recipientSet.identity}\n`, { mode: 0o600 });
      identityPaths[name] = path;
    }
    for (const vector of manifest.vectors) {
      const envelope = resolveEnvelope(vector);
      const trustedKeyId = vector.trusted_epoch_key_id || manifest.binding.key_id;
      const config = {
        local_team: "demo",
        server_instance_id: "018f3f7e-0000-7000-8000-000000000000",
        remote_team_id: vector.binding_override?.team_id || manifest.binding.team_id,
        protocol_version: vector.binding_override?.protocol_version || manifest.binding.protocol_version,
        cipher_profile: "age-v1",
        local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
          minimum_security_mode: "e2ee-required" }],
        age_v1: {
          epoch_snapshot: { history: [{ epoch_revision: "0", effective_from_seq: "1",
            cipher: "age-v1", key_id: trustedKeyId,
            recipients: [manifest.recipient_sets.team_a.recipient] }] },
          identity_files: { [trustedKeyId]: identityPaths[vector.identity] },
        },
      };
      const message = {
        server_seq: "1",
        id: vector.binding_override?.wire_id || manifest.binding.wire_id,
        server_received_at: "2026-07-20T06:30:01.000000Z",
        envelope,
      };
      const result = await evaluatePull(config, capabilities(config, envelope.cipher), message);
      assert.equal(result.status, vector.expected_state, vector.name);
      if (result.status === "importable") assert.deepEqual(result.projection, manifest.canonical_message);
      else assert.equal(result.projection, undefined, vector.name);
    }
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("none and age-v1 profiles share one seal/open registry", async () => {
  const base = {
    type: "sync_seal",
    envelope_v: 1,
    max_blob_bytes: 1_048_576,
    wire_id: manifest.binding.wire_id,
    team_id: manifest.binding.team_id,
    protocol_version: 1,
    projection: manifest.canonical_message,
  };
  const none = sealEnvelope({ ...base, cipher: "none", key_id: null, recipients: [] });
  assert.deepEqual(await openEnvelope({ envelope: none, max_blob_bytes: 1_048_576 }), manifest.canonical_message);

  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-roundtrip-"));
  try {
    const identity = join(scratch, "identity");
    await writeFile(identity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
    const age = sealEnvelope({ ...base, cipher: "age-v1", key_id: manifest.binding.key_id,
      recipients: [manifest.recipient_sets.team_a.recipient] });
    assert.deepEqual(await openEnvelope({ envelope: age, protocol_version: 1,
      team_id: base.team_id, wire_id: base.wire_id, identity_file: identity,
      expected_recipients: [manifest.recipient_sets.team_a.recipient],
      max_blob_bytes: 1_048_576 }), manifest.canonical_message);
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("legacy messages remain discriminator-free while roster mutations use kind", async () => {
  const base = {
    type: "sync_seal",
    envelope_v: 1,
    cipher: "none",
    key_id: null,
    recipients: [],
    max_blob_bytes: 1_048_576,
    wire_id: manifest.binding.wire_id,
    team_id: manifest.binding.team_id,
    protocol_version: 1,
  };
  const legacy = sealEnvelope({ ...base, projection: manifest.canonical_message });
  const legacyPlaintext = Buffer.from(legacy.blob, "base64").toString("utf8");
  assert.equal(legacyPlaintext, JSON.stringify(manifest.canonical_message));
  assert.equal(JSON.parse(legacyPlaintext).kind, undefined);

  const roster = {
    kind: "member_renamed",
    mutation_id: "018f3f7e-0000-7000-8000-000000000010",
    member_id: "018f3f7e-0000-7000-8000-000000000011",
    from: "alice",
    to: "carol",
    occurred_at: "2026-07-28T23:00:00.000000Z",
  };
  const rosterEnvelope = sealEnvelope({
    ...base,
    wire_id: "550e8400-e29b-41d4-a716-446655440001",
    projection: roster,
  });
  assert.deepEqual(await openEnvelope({
    envelope: rosterEnvelope,
    max_blob_bytes: 1_048_576,
  }), roster);

  const rotation = {
    kind: "key_rotated",
    mutation_id: "018f3f7e-0000-7000-8000-000000000012",
    epoch: "1",
    key_id: "epoch-20260729010000-abcd",
    fingerprint: "a".repeat(64),
    occurred_at: "2026-07-29T01:00:00.000000Z",
  };
  const rotationEnvelope = sealEnvelope({
    ...base,
    wire_id: "550e8400-e29b-41d4-a716-446655440002",
    projection: rotation,
  });
  assert.deepEqual(await openEnvelope({
    envelope: rotationEnvelope,
    max_blob_bytes: 1_048_576,
  }), rotation);
  assert.equal(Buffer.from(rotationEnvelope.blob, "base64").toString("utf8").includes("age1"), false);
});

test("a late concurrent rotation may use the preceding key but ordinary data may not", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-rotation-race-"));
  const oldIdentity = join(scratch, "old.identity");
  const newIdentity = join(scratch, "new.identity");
  await writeFile(oldIdentity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
  await writeFile(newIdentity, `${manifest.recipient_sets.team_b.identity}\n`, { mode: 0o600 });
  const oldKeyId = "epoch-old";
  const newKeyId = "epoch-winner";
  const rotation = {
    kind: "key_rotated",
    mutation_id: "018f3f7e-0000-7000-8000-000000000013",
    epoch: "1",
    key_id: "epoch-loser",
    fingerprint: "b".repeat(64),
    occurred_at: "2026-07-29T01:00:00.000000Z",
  };
  const wireId = "550e8400-e29b-41d4-a716-446655440003";
  const rotationEnvelope = sealEnvelope({
    type: "sync_seal",
    envelope_v: 1,
    max_blob_bytes: 1_048_576,
    wire_id: wireId,
    team_id: manifest.binding.team_id,
    protocol_version: 1,
    cipher: "age-v1",
    key_id: oldKeyId,
    recipients: [manifest.recipient_sets.team_a.recipient],
    projection: rotation,
  });
  const raceConfig = {
    local_team: "demo",
    server_instance_id: "018f3f7e-0000-7000-8000-000000000000",
    remote_team_id: manifest.binding.team_id,
    protocol_version: 1,
    cipher_profile: "age-v1",
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: "e2ee-required" }],
    age_v1: {
      epoch_snapshot: { history: [{
        epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
        key_id: oldKeyId, recipients: [manifest.recipient_sets.team_a.recipient],
      }] },
      identity_files: { [oldKeyId]: oldIdentity, [newKeyId]: newIdentity },
    },
    age_v1_runtime_history: [{
      epoch_revision: "1", effective_from_seq: "2", cipher: "age-v1",
      key_id: newKeyId, recipients: [manifest.recipient_sets.team_b.recipient],
    }],
  };
  try {
    const accepted = await evaluatePull(raceConfig, capabilities(raceConfig, "age-v1"), {
      server_seq: "2",
      id: wireId,
      server_received_at: "2026-07-29T01:00:01.000000Z",
      envelope: rotationEnvelope,
    });
    assert.equal(accepted.status, "importable");
    assert.deepEqual(accepted.projection, rotation);

    raceConfig.age_v1.identity_files["epoch-current"] = newIdentity;
    raceConfig.age_v1_runtime_history.push({
      epoch_revision: "2", effective_from_seq: "3", cipher: "age-v1",
      key_id: "epoch-current", recipients: [manifest.recipient_sets.team_b.recipient],
    });
    const stale = await evaluatePull(raceConfig, capabilities(raceConfig, "age-v1"), {
      server_seq: "3",
      id: wireId,
      server_received_at: "2026-07-29T01:00:02.000000Z",
      envelope: rotationEnvelope,
    });
    assert.equal(stale.status, "policy_violation");

    const messageId = "550e8400-e29b-41d4-a716-446655440004";
    const oldKeyMessage = sealEnvelope({
      type: "sync_seal",
      envelope_v: 1,
      max_blob_bytes: 1_048_576,
      wire_id: messageId,
      team_id: manifest.binding.team_id,
      protocol_version: 1,
      cipher: "age-v1",
      key_id: oldKeyId,
      recipients: [manifest.recipient_sets.team_a.recipient],
      projection: manifest.canonical_message,
    });
    const rejected = await evaluatePull(raceConfig, capabilities(raceConfig, "age-v1"), {
      server_seq: "2",
      id: messageId,
      server_received_at: "2026-07-29T01:00:01.000000Z",
      envelope: oldKeyMessage,
    });
    assert.equal(rejected.status, "policy_violation");
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("age-v1 accepts only native X25519 identity files", () => {
  const teamA = nativeAgeIdentity(Buffer.from(`${manifest.recipient_sets.team_a.identity}\n`));
  assert.equal(teamA.recipient, manifest.recipient_sets.team_a.recipient);
  assert.throws(() => nativeAgeIdentity(Buffer.from("AGE-PLUGIN-EXAMPLE-1COMMAND\n")),
    /native X25519/u);
  assert.throws(() => nativeAgeIdentity(Buffer.from("-----BEGIN AGE ENCRYPTED FILE-----\nfixture\n")),
    /native (?:X25519|key)/u);
});

test("age-v1 recipient stanza count must match the effective manifest", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-stanzas-"));
  try {
    const identity = join(scratch, "identity");
    await writeFile(identity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
    const base = { type: "sync_seal", envelope_v: 1, cipher: "age-v1", key_id: "epoch-1",
      max_blob_bytes: 1_048_576, wire_id: manifest.binding.wire_id,
      team_id: manifest.binding.team_id, protocol_version: 1,
      projection: manifest.canonical_message };
    const one = sealEnvelope({ ...base, recipients: [manifest.recipient_sets.team_a.recipient] });
    const two = sealEnvelope({ ...base, recipients: [manifest.recipient_sets.team_a.recipient,
      manifest.recipient_sets.team_b.recipient] });
    await assert.rejects(openEnvelope({ envelope: one, protocol_version: 1,
      team_id: base.team_id, wire_id: base.wire_id, identity_file: identity,
      expected_recipients: [manifest.recipient_sets.team_a.recipient,
        manifest.recipient_sets.team_b.recipient], max_blob_bytes: 1_048_576 }),
    (error) => error.state === "authentication_failed");
    await assert.rejects(openEnvelope({ envelope: two, protocol_version: 1,
      team_id: base.team_id, wire_id: base.wire_id, identity_file: identity,
      expected_recipients: [manifest.recipient_sets.team_a.recipient], max_blob_bytes: 1_048_576 }),
    (error) => error.state === "authentication_failed");
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("age-v1 ignores bounded GREASE stanzas without weakening X25519 count", () => {
  const header = (...lines) => Buffer.concat([
    Buffer.from(`${lines.join("\n")}\n`, "ascii"), Buffer.from([0xde, 0xad, 0xbe, 0xef]),
  ]);
  const x25519 = [
    "-> X25519 UHwSYuqz0nETnk0k8pTzWX5dUSwX32+mdzrgiooZ5FM",
    "fHRC1X2S0nMkexfGaMYo7k1WeRjMXouDB6VI1ERX1ho",
  ];
  const grease = ["-> test-grease ext", "ZmFrZS13cmFwcGVkLWZpbGUta2V5"];
  const footer = "--- 1D+zVTAq2TisMsHnBKk0agnk0N0xNzkdHc07l8O8we0";
  assert.deepEqual(validateAgeHeader(header("age-encryption.org/v1", ...grease,
    ...x25519, footer)), { totalStanzaCount: 2, x25519StanzaCount: 1 });
  assert.throws(() => validateAgeHeader(header("age-encryption.org/v1", ...grease, footer)),
    /footer/u);
  const excessive = Array.from({ length: 513 }, () => [
    "-> x-grease", "",
  ]).flat();
  assert.throws(() => validateAgeHeader(header("age-encryption.org/v1", ...x25519,
    ...excessive, footer)), /total stanza limit/u);
  assert.throws(() => validateAgeHeader(header("age-encryption.org/v1", ...x25519,
    `-> x-grease ${"a".repeat(4090)}`, "", footer)), /incomplete/u);
  const largeHeader = Array.from({ length: 400 }, () => [
    "-> abcdefgh-grease abcdefgh abcdefgh abcdefgh abcdefgh",
    "A".repeat(64), "A".repeat(64), "A".repeat(6),
  ]).flat();
  assert.throws(() => validateAgeHeader(header("age-encryption.org/v1", ...x25519,
    ...largeHeader, footer)), /size limit/u);
});

test("age-v1 opens the Rust age 0.12.1 GREASE interoperability fixture", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-rust-grease-"));
  try {
    const identity = join(scratch, "identity");
    await writeFile(identity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
    assert.deepEqual(validateAgeHeader(Buffer.from(rustGrease.envelope.blob, "base64")), {
      totalStanzaCount: rustGrease.total_stanza_count,
      x25519StanzaCount: rustGrease.x25519_stanza_count,
    });
    assert.deepEqual(await openEnvelope({ envelope: rustGrease.envelope,
      protocol_version: 1, team_id: manifest.binding.team_id,
      wire_id: manifest.binding.wire_id, identity_file: identity,
      expected_recipients: [manifest.recipient_sets.team_a.recipient],
      max_blob_bytes: 1_048_576 }), manifest.canonical_message);
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("age-v1 rejects active non-X25519 stanzas before spawning the decryptor", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-active-stanza-"));
  const originalAgeBin = process.env.AGMSG_AGE_BIN;
  const originalMarker = process.env.AGMSG_AGE_SPAWN_MARKER;
  try {
    const identity = join(scratch, "identity");
    const fakeAge = join(scratch, "fake-age");
    const marker = join(scratch, "spawned");
    await writeFile(identity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
    await writeFile(fakeAge, "#!/bin/sh\nprintf invoked > \"$AGMSG_AGE_SPAWN_MARKER\"\nexit 99\n",
      { mode: 0o700 });
    process.env.AGMSG_AGE_BIN = fakeAge;
    process.env.AGMSG_AGE_SPAWN_MARKER = marker;
    const active = ["scrypt salt 10", "ssh-rsa key", "ssh-ed25519 key",
      "plugin-example data", "plugin-x-grease data", "future-recipient data"];
    for (const stanza of active) {
      const bytes = Buffer.concat([Buffer.from([
        "age-encryption.org/v1",
        "-> X25519 UHwSYuqz0nETnk0k8pTzWX5dUSwX32+mdzrgiooZ5FM",
        "fHRC1X2S0nMkexfGaMYo7k1WeRjMXouDB6VI1ERX1ho",
        `-> ${stanza}`,
        "YQ",
        "--- 1D+zVTAq2TisMsHnBKk0agnk0N0xNzkdHc07l8O8we0",
        "",
      ].join("\n"), "ascii"), Buffer.from([0xde, 0xad, 0xbe, 0xef])]);
      await assert.rejects(openEnvelope({
        envelope: { ...rustGrease.envelope, blob: bytes.toString("base64") },
        protocol_version: 1, team_id: manifest.binding.team_id,
        wire_id: manifest.binding.wire_id, identity_file: identity,
        expected_recipients: [manifest.recipient_sets.team_a.recipient],
        max_blob_bytes: 1_048_576,
      }), (error) => error.state === "malformed");
      await assert.rejects(readFile(marker), (error) => error.code === "ENOENT");
    }
  } finally {
    if (originalAgeBin === undefined) delete process.env.AGMSG_AGE_BIN;
    else process.env.AGMSG_AGE_BIN = originalAgeBin;
    if (originalMarker === undefined) delete process.env.AGMSG_AGE_SPAWN_MARKER;
    else process.env.AGMSG_AGE_SPAWN_MARKER = originalMarker;
    await rm(scratch, { recursive: true });
  }
});

test("age-v1 rejects noncanonical GREASE base64 before spawning the decryptor", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-grease-base64-"));
  const originalAgeBin = process.env.AGMSG_AGE_BIN;
  const originalMarker = process.env.AGMSG_AGE_SPAWN_MARKER;
  try {
    const identity = join(scratch, "identity");
    const fakeAge = join(scratch, "fake-age");
    const marker = join(scratch, "spawned");
    await writeFile(identity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
    await writeFile(fakeAge, "#!/bin/sh\nprintf invoked > \"$AGMSG_AGE_SPAWN_MARKER\"\nexit 99\n",
      { mode: 0o700 });
    process.env.AGMSG_AGE_BIN = fakeAge;
    process.env.AGMSG_AGE_SPAWN_MARKER = marker;
    for (const body of ["AB", "AAB"]) {
      const bytes = Buffer.concat([Buffer.from([
        "age-encryption.org/v1",
        "-> x-grease",
        body,
        "-> X25519 UHwSYuqz0nETnk0k8pTzWX5dUSwX32+mdzrgiooZ5FM",
        "fHRC1X2S0nMkexfGaMYo7k1WeRjMXouDB6VI1ERX1ho",
        "--- 1D+zVTAq2TisMsHnBKk0agnk0N0xNzkdHc07l8O8we0",
        "",
      ].join("\n"), "ascii"), Buffer.from([0xde, 0xad, 0xbe, 0xef])]);
      await assert.rejects(openEnvelope({
        envelope: { ...rustGrease.envelope, blob: bytes.toString("base64") },
        protocol_version: 1, team_id: manifest.binding.team_id,
        wire_id: manifest.binding.wire_id, identity_file: identity,
        expected_recipients: [manifest.recipient_sets.team_a.recipient],
        max_blob_bytes: 1_048_576,
      }), (error) => error.state === "malformed" && /canonical base64/u.test(error.message));
      await assert.rejects(readFile(marker), (error) => error.code === "ENOENT");
    }
  } finally {
    if (originalAgeBin === undefined) delete process.env.AGMSG_AGE_BIN;
    else process.env.AGMSG_AGE_BIN = originalAgeBin;
    if (originalMarker === undefined) delete process.env.AGMSG_AGE_SPAWN_MARKER;
    else process.env.AGMSG_AGE_SPAWN_MARKER = originalMarker;
    await rm(scratch, { recursive: true });
  }
});

test("age-v1 rejects trailing bytes and concatenated age files", async () => {
  const scratch = await mkdtemp(join(tmpdir(), "agmsg-age-v1-trailing-"));
  try {
    const identity = join(scratch, "identity");
    await writeFile(identity, `${manifest.recipient_sets.team_a.identity}\n`, { mode: 0o600 });
    const source = byName.get("valid").envelope;
    const ageFile = Buffer.from(source.blob, "base64");
    for (const bytes of [Buffer.concat([ageFile, Buffer.from([0])]), Buffer.concat([ageFile, ageFile])]) {
      await assert.rejects(openEnvelope({ envelope: { ...source, blob: bytes.toString("base64") },
        protocol_version: 1, team_id: manifest.binding.team_id, wire_id: manifest.binding.wire_id,
        identity_file: identity, expected_recipients: [manifest.recipient_sets.team_a.recipient],
        max_blob_bytes: 1_048_576 }), (error) => error.state === "authentication_failed");
    }
  } finally {
    await rm(scratch, { recursive: true });
  }
});

test("canonical plaintext rejects lone surrogates and impossible timestamps", async () => {
  const base = { type: "sync_seal", envelope_v: 1, cipher: "none", key_id: null,
    recipients: [], max_blob_bytes: 1_048_576, wire_id: manifest.binding.wire_id,
    team_id: manifest.binding.team_id, protocol_version: 1,
    projection: manifest.canonical_message };
  assert.throws(() => sealEnvelope({ ...base,
    projection: { ...base.projection, body: "\ud800" } }), /lone surrogate/u);
  assert.throws(() => sealEnvelope({ ...base,
    projection: { ...base.projection, created_at: "2026-99-99T99:99:99.999999Z" } }), /projection/u);
  const invalid = Buffer.from(JSON.stringify({ ...base.projection, body: "\udc00" })).toString("base64");
  await assert.rejects(openEnvelope({ envelope: { v: 1, cipher: "none", key_id: null, blob: invalid },
    max_blob_bytes: 1_048_576 }), (error) => error.state === "malformed");
  assert.doesNotThrow(() => sealEnvelope({ ...base,
    projection: { ...base.projection, created_at: "2028-02-29T23:59:59.999999Z",
      from_agent: "😀".repeat(65) } }));
  assert.throws(() => sealEnvelope({ ...base,
    projection: { ...base.projection, from_agent: "😀".repeat(129) } }), /from_agent/u);
});
