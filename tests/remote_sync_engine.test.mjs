import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, readdir, rename, rm, stat, symlink, unlink,
  writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { readNativeAgeIdentity } from "../scripts/internal/sync-cipher.mjs";
import {
  ageSnapshotDigest,
  activateKeyRotations,
  canonicalJson,
  consistentReadStateContext,
  configure,
  cycle,
  driver,
  exportAgeHandoff,
  exportAgeSnapshot,
  isRetryable,
  initialAgeSnapshot,
  runLoop,
  loadConfig,
  nextLocalAgeSnapshot,
  plaintextWriteEligible,
  pullBootstrap,
  parseStrictJsonl,
  readStateCycle,
  readStateUpdateBatches,
  reprocessCycle,
  request,
  resyncCycle,
  retainAgeCheckpoint,
  rosterDriver,
  selectWriteProfile,
  stage2ReadStateSupported,
  stage1ResyncSupported,
  validateAckMapping,
  validateAgeConfiguration,
  validateConfiguredAgeIdentities,
  validateCapabilities,
  validateErrorBinding,
  validateMembers,
  validateReadStatePage,
  validateResyncResult,
  validateResyncStatus,
  verifyAgeSnapshot,
  verifyAgeHandoff,
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

const credentialId = "018f3f7e-0000-7000-8000-000000000020";

test("a rotator provisions its confirmed snapshot at the server boundary", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-local-key-rotation-"));
  const saved = {
    connection: process.env.AGMSG_SYNC_CONNECTION_DIR,
    storage: process.env.AGMSG_SYNC_STORAGE_DIR,
    trust: process.env.AGMSG_SYNC_TRUST_DIR,
  };
  const oldKeyId = "epoch-old";
  const newKeyId = "epoch-new";
  const recipient = "age1ykvctct4aklx4f4mnjd8rmzqs7p2le9ufg4faydljsk5mvcy0pls27mu64";
  const identity = "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ";
  const initial = {
    profile: "age-v1",
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    epoch_revision: "0",
    writer_generation: "0",
    authorized_writers: [oldKeyId],
    previous_snapshot_sha256: null,
    history: [{ epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
      key_id: oldKeyId, recipients: [recipient] }],
  };
  const rotation = {
    id: "018f3f7e-0000-7000-8000-000000000025",
    epoch: "1",
    key_id: newKeyId,
    fingerprint: createHash("sha256").update(recipient).digest("hex"),
    server_seq: "8",
  };
  const localEpoch = { key_id: newKeyId, epoch_revision: 1, writer_generation: 1,
    recipient, previous_snapshot_sha256: ageSnapshotDigest(initial),
    created_at: "2026-07-30T00:00:00Z" };
  const teamConfig = { name: "demo", remote_key: { current: localEpoch,
    epochs: [{ key_id: oldKeyId, epoch_revision: 0, writer_generation: 0,
      recipient, previous_snapshot_sha256: null, created_at: "2026-07-29T00:00:00Z" },
    localEpoch] } };
  const rotationConfig = {
    ...config,
    server_url: "https://sync.example.test",
    cipher_profile: "age-v1",
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: "e2ee-required" }],
    age_v1: {
      epoch_snapshots: [initial],
      checkpoint: { epoch_revision: "0", writer_generation: "0",
        snapshot_sha256: ageSnapshotDigest(initial), confirmed_at: "2026-07-29T00:00:00Z" },
      identity_files: { [oldKeyId]: join(root, "run", "remote-credentials", "demo",
        "keys", `${oldKeyId}.key`) },
      age_version: "v1.3.1",
    },
  };
  try {
    process.env.AGMSG_SYNC_CONNECTION_DIR = root;
    process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "store");
    process.env.AGMSG_SYNC_TRUST_DIR = join(root, "trust");
    const teamDir = join(root, "teams", "demo");
    const keyDir = join(root, "run", "remote-credentials", "demo", "keys");
    await mkdir(teamDir, { recursive: true });
    await mkdir(keyDir, { recursive: true });
    await writeFile(join(teamDir, "config.json"), `${JSON.stringify({ ...teamConfig,
      remote_binding: { endpoint: "https://sync.example.test",
        server_instance_id: config.server_instance_id,
        remote_team_id: config.remote_team_id, protocol_version: 1,
        capabilities: { write_allowed_ciphers: ["none", "age-v1"] },
        cipher_profile: "age-v1", connected_at: "2026-07-29T00:00:00Z",
        disconnected_at: null },
    })}\n`);
    await writeFile(join(teamDir, "roster.jsonl"), [
      JSON.stringify({ type: "key_rotated", ...rotation,
        at: "2026-07-30T00:00:00.000000Z", server_seq: undefined }),
      JSON.stringify({ type: "roster_synced", mutation_id: rotation.id,
        server_seq: rotation.server_seq,
        wire_id: "550e8400-e29b-41d4-a716-446655440006",
        server_instance_id: config.server_instance_id,
        remote_team_id: config.remote_team_id }), "",
    ].join("\n"));
    await writeFile(join(keyDir, `${oldKeyId}.key`), `${identity}\n`, { mode: 0o600 });
    await writeFile(join(keyDir, `${newKeyId}.key`), `${identity}\n`, { mode: 0o600 });
    const snapshot = nextLocalAgeSnapshot(rotationConfig, teamConfig, rotation);
    assert.equal(snapshot.epoch_revision, "1");
    assert.equal(snapshot.writer_generation, "1");
    assert.equal(snapshot.previous_snapshot_sha256, ageSnapshotDigest(initial));
    assert.equal(snapshot.history.at(-1).effective_from_seq, "9");
    const laterEpoch = { ...localEpoch, key_id: "epoch-later", epoch_revision: 2,
      writer_generation: 2 };
    const replayed = nextLocalAgeSnapshot(rotationConfig, { ...teamConfig, remote_key: {
      current: laterEpoch, epochs: [...teamConfig.remote_key.epochs, laterEpoch],
    } }, rotation);
    assert.equal(replayed.history.at(-1).key_id, newKeyId);
    await activateKeyRotations(rotationConfig);
    assert.equal(rotationConfig.age_v1_runtime_history.at(-1).key_id, newKeyId);
    const stored = JSON.parse(await readFile(join(root, "store", "remote-sync", "demo.json"), "utf8"));
    assert.equal(stored.age_v1.epoch_snapshots.length, 2);
    assert.equal(stored.age_v1.epoch_snapshots.at(-1).epoch_revision, "1");
    assert.equal(stored.age_v1.checkpoint.snapshot_sha256, ageSnapshotDigest(snapshot));
    const exportedPath = join(root, "exported-age-snapshot.json");
    await exportAgeSnapshot({ team: "demo", out: exportedPath });
    const exported = JSON.parse(await readFile(exportedPath, "utf8"));
    assert.equal(exported.epoch_revision, "1");
    assert.equal(exported.history.length, 2);
    const handoffPath = join(root, "age-handoff.json");
    await exportAgeHandoff({ team: "demo", out: handoffPath });
    const handoff = JSON.parse(await readFile(handoffPath, "utf8"));
    assert.equal(handoff.snapshots.length, 2);
    assert.deepEqual(handoff.identities.map((entry) => entry.key_id), [oldKeyId, newKeyId]);
    assert.equal((await stat(handoffPath)).mode & 0o077, 0);
    const extracted = await verifyAgeHandoff({ team: "demo", bundle: handoffPath,
      "out-dir": join(root, "handoff-extracted") });
    assert.equal(extracted.snapshot_sha256, ageSnapshotDigest(snapshot));
    assert.equal(extracted.snapshot_paths.length, 2);
    assert.equal(extracted.identities.length, 2);
    const confirmedStored = structuredClone(stored);
    const rolledBack = structuredClone(confirmedStored);
    rolledBack.age_v1.epoch_snapshots = [initial];
    rolledBack.age_v1.checkpoint = { ...rolledBack.age_v1.checkpoint,
      epoch_revision: "0", writer_generation: "0", snapshot_sha256: ageSnapshotDigest(initial) };
    await writeFile(join(root, "store", "remote-sync", "demo.json"), JSON.stringify(rolledBack));
    await assert.rejects(exportAgeSnapshot({ team: "demo", out: join(root, "rollback.json") }),
      /rollback/u);
    const conflictingStored = structuredClone(confirmedStored);
    const conflicting = { ...snapshot, authorized_writers: ["conflicting-writer"] };
    conflictingStored.age_v1.epoch_snapshots[1] = conflicting;
    conflictingStored.age_v1.checkpoint.snapshot_sha256 = ageSnapshotDigest(conflicting);
    await writeFile(join(root, "store", "remote-sync", "demo.json"),
      JSON.stringify(conflictingStored));
    await assert.rejects(exportAgeSnapshot({ team: "demo", out: join(root, "conflict.json") }),
      /same-revision conflict/u);
    const advancedStored = structuredClone(confirmedStored);
    const unconfirmed = { ...snapshot, epoch_revision: "2", writer_generation: "2",
      previous_snapshot_sha256: ageSnapshotDigest(snapshot),
      history: [...snapshot.history, { ...snapshot.history.at(-1), epoch_revision: "2",
        effective_from_seq: "10", key_id: "epoch-unconfirmed" }] };
    advancedStored.age_v1.epoch_snapshots.push(unconfirmed);
    advancedStored.age_v1.checkpoint = { ...advancedStored.age_v1.checkpoint, epoch_revision: "2",
      writer_generation: "2", snapshot_sha256: ageSnapshotDigest(unconfirmed) };
    await writeFile(join(root, "store", "remote-sync", "demo.json"), JSON.stringify(advancedStored));
    await assert.rejects(exportAgeSnapshot({ team: "demo", out: join(root, "unsafe.json") }),
      /retained age checkpoint/u);
    assert.match(await readFile(join(root, "trust",
      `age-v1-${config.server_instance_id}-${config.remote_team_id}-v1.json`), "utf8"),
    new RegExp(ageSnapshotDigest(snapshot), "u"));
  } finally {
    if (saved.connection === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = saved.connection;
    if (saved.storage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
    else process.env.AGMSG_SYNC_STORAGE_DIR = saved.storage;
    if (saved.trust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
    else process.env.AGMSG_SYNC_TRUST_DIR = saved.trust;
    await rm(root, { recursive: true });
  }
});

test("a synced rotation halts until an out-of-band identity matches its fingerprint", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-key-rotation-"));
  const previous = process.env.AGMSG_SYNC_CONNECTION_DIR;
  process.env.AGMSG_SYNC_CONNECTION_DIR = root;
  const epoch = "1";
  const keyId = "epoch-20260729010000-abcd";
  const mutationId = "018f3f7e-0000-7000-8000-000000000025";
  const recipient = "age1ykvctct4aklx4f4mnjd8rmzqs7p2le9ufg4faydljsk5mvcy0pls27mu64";
  const identity = "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ";
  const fingerprint = createHash("sha256").update(recipient).digest("hex");
  const rotationConfig = {
    ...config,
    cipher_profile: "age-v1",
    age_v1: {
      epoch_snapshot: { history: [{
        epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
        key_id: "epoch-0", recipients: [recipient],
      }] },
      identity_files: {},
    },
  };
  try {
    await mkdir(join(root, "teams", "demo"), { recursive: true });
    await writeFile(join(root, "teams", "demo", "roster.jsonl"), [
      JSON.stringify({ type: "key_rotated", id: mutationId, epoch, key_id: keyId, fingerprint,
        at: "2026-07-29T01:00:00.000000Z" }),
      JSON.stringify({ type: "roster_synced", mutation_id: mutationId, server_seq: "8",
        wire_id: "550e8400-e29b-41d4-a716-446655440006",
        server_instance_id: config.server_instance_id,
        remote_team_id: config.remote_team_id }),
      "",
    ].join("\n"));
    await assert.rejects(activateKeyRotations(rotationConfig),
      /import its authority-confirmed epoch snapshot/u);
    rotationConfig.age_v1.epoch_snapshots = [
      rotationConfig.age_v1.epoch_snapshot,
      { history: [
        ...rotationConfig.age_v1.epoch_snapshot.history,
        { epoch_revision: epoch, effective_from_seq: "9", cipher: "age-v1",
          key_id: keyId, recipients: [recipient] },
      ] },
    ];
    await assert.rejects(activateKeyRotations(rotationConfig), /import that key out of band/u);
    const keyDir = join(root, "run", "remote-credentials", "demo", "keys");
    await mkdir(keyDir, { recursive: true });
    await writeFile(join(keyDir, `${keyId}.key`), `${identity}\n`, { mode: 0o600 });
    await activateKeyRotations(rotationConfig);
    assert.equal(rotationConfig.age_v1_runtime_history[0].epoch_revision, epoch);
    assert.equal(rotationConfig.age_v1_runtime_history[0].key_id, keyId);
    assert.equal(rotationConfig.age_v1_runtime_history[0].effective_from_seq, "9");
    assert.deepEqual(rotationConfig.age_v1_runtime_history[0].recipients, [recipient]);
  } finally {
    if (previous === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = previous;
    await rm(root, { recursive: true });
  }
});

test("rotation cutover accepts MAX_SEQUENCE minus one and rejects the final sequence", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-key-rotation-boundary-"));
  const previous = process.env.AGMSG_SYNC_CONNECTION_DIR;
  process.env.AGMSG_SYNC_CONNECTION_DIR = root;
  const mutationId = "018f3f7e-0000-7000-8000-000000000028";
  const keyId = "epoch-boundary";
  const recipient = "age1ykvctct4aklx4f4mnjd8rmzqs7p2le9ufg4faydljsk5mvcy0pls27mu64";
  const identity = "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ";
  const fingerprint = createHash("sha256").update(recipient).digest("hex");
  const rotationConfig = (serverSeq) => ({
    ...config,
    cipher_profile: "age-v1",
    age_v1: {
      epoch_snapshots: [{ history: [{
        epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
        key_id: "epoch-0", recipients: [recipient],
      }] }, { history: [
        { epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
          key_id: "epoch-0", recipients: [recipient] },
        { epoch_revision: "1", effective_from_seq: (BigInt(serverSeq) + 1n).toString(),
          cipher: "age-v1", key_id: keyId, recipients: [recipient] },
      ] }],
      identity_files: {},
    },
  });
  try {
    const teamDir = join(root, "teams", "demo");
    const keyDir = join(root, "run", "remote-credentials", "demo", "keys");
    await mkdir(teamDir, { recursive: true });
    await mkdir(keyDir, { recursive: true });
    await writeFile(join(keyDir, `${keyId}.key`), `${identity}\n`, { mode: 0o600 });
    const writeRotation = async (serverSeq) => writeFile(join(teamDir, "roster.jsonl"), [
      JSON.stringify({ type: "key_rotated", id: mutationId, epoch: "1",
        key_id: keyId, fingerprint, at: "2026-07-29T01:00:00.000000Z" }),
      JSON.stringify({ type: "roster_synced", mutation_id: mutationId, server_seq: serverSeq,
        wire_id: "550e8400-e29b-41d4-a716-446655440009",
        server_instance_id: config.server_instance_id,
        remote_team_id: config.remote_team_id }),
      "",
    ].join("\n"));

    await writeRotation("9223372036854775806");
    const accepted = rotationConfig("9223372036854775806");
    await activateKeyRotations(accepted);
    assert.equal(accepted.age_v1_runtime_history[0].effective_from_seq,
      "9223372036854775807");

    await writeRotation("9223372036854775807");
    await assert.rejects(activateKeyRotations(rotationConfig("9223372036854775807")),
      /final server sequence/u);
  } finally {
    if (previous === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = previous;
    await rm(root, { recursive: true });
  }
});

test("concurrent rotations adopt the first server sequence and the loser must import it", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-key-rotation-race-"));
  const previous = process.env.AGMSG_SYNC_CONNECTION_DIR;
  process.env.AGMSG_SYNC_CONNECTION_DIR = root;
  const winner = {
    id: "018f3f7e-0000-7000-8000-000000000026",
    keyId: "epoch-winner",
    recipient: "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
    identity: "AGE-SECRET-KEY-1WWJJYKYVUUQNL8ZX7Y6NYRTEW79LHTF0H28EYC0CFYN5A7WECDHQMT4S0V",
    serverSeq: "8",
  };
  const loser = {
    id: "018f3f7e-0000-7000-8000-000000000027",
    keyId: "epoch-loser",
    recipient: "age1ykvctct4aklx4f4mnjd8rmzqs7p2le9ufg4faydljsk5mvcy0pls27mu64",
    identity: "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ",
    serverSeq: "9",
  };
  const rotationConfig = () => ({
    ...config,
    cipher_profile: "age-v1",
    age_v1: {
      epoch_snapshots: [{ history: [{
        epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
        key_id: "epoch-0", recipients: [winner.recipient],
      }] }, { history: [
        { epoch_revision: "0", effective_from_seq: "1", cipher: "age-v1",
          key_id: "epoch-0", recipients: [winner.recipient] },
        { epoch_revision: "1", effective_from_seq: "9", cipher: "age-v1",
          key_id: winner.keyId, recipients: [winner.recipient] },
      ] }],
      identity_files: {},
    },
  });
  try {
    const teamDir = join(root, "teams", "demo");
    const keyDir = join(root, "run", "remote-credentials", "demo", "keys");
    await mkdir(teamDir, { recursive: true });
    await mkdir(keyDir, { recursive: true });
    const rotationRecord = (value) => JSON.stringify({
      type: "key_rotated", id: value.id, epoch: "1", key_id: value.keyId,
      fingerprint: createHash("sha256").update(value.recipient).digest("hex"),
      at: "2026-07-29T01:00:00.000000Z",
    });
    const syncedRecord = (value) => JSON.stringify({
      type: "roster_synced", mutation_id: value.id, server_seq: value.serverSeq,
      wire_id: value.serverSeq === "8" ?
        "550e8400-e29b-41d4-a716-446655440007" :
        "550e8400-e29b-41d4-a716-446655440008",
      server_instance_id: config.server_instance_id,
      remote_team_id: config.remote_team_id,
    });
    await writeFile(join(teamDir, "roster.jsonl"), [
      rotationRecord(loser),
      rotationRecord(winner),
      syncedRecord(loser),
      syncedRecord(winner),
      "",
    ].join("\n"));

    await writeFile(join(keyDir, `${winner.keyId}.key`), `${winner.identity}\n`, { mode: 0o600 });
    const winnerConfig = rotationConfig();
    await activateKeyRotations(winnerConfig);
    assert.equal(winnerConfig.age_v1_runtime_history.length, 1);
    assert.equal(winnerConfig.age_v1_runtime_history[0].key_id, winner.keyId);
    assert.equal(winnerConfig.age_v1_runtime_history[0].effective_from_seq, "9");

    await unlink(join(keyDir, `${winner.keyId}.key`));
    await writeFile(join(keyDir, `${loser.keyId}.key`), `${loser.identity}\n`, { mode: 0o600 });
    await assert.rejects(activateKeyRotations(rotationConfig()),
      /selected epoch 1 with key_id=epoch-winner/u);
  } finally {
    if (previous === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = previous;
    await rm(root, { recursive: true });
  }
});

async function withConnectedCredential(callback) {
  const root = await mkdtemp(join(tmpdir(), "agmsg-connected-credential-"));
  const previous = process.env.AGMSG_SYNC_CONNECTION_DIR;
  process.env.AGMSG_SYNC_CONNECTION_DIR = root;
  try {
    return await callback(root);
  } finally {
    if (previous === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = previous;
    await rm(root, { recursive: true });
  }
}

async function writeConnectedTeam(root, overrides = {}) {
  await mkdir(join(root, "teams", "demo"), { recursive: true });
  const remoteBinding = {
    endpoint: "https://sync.example",
    server_instance_id: config.server_instance_id,
    remote_team_id: config.remote_team_id,
    remote_team_name: "demo",
    protocol_version: 1,
    capabilities: { write_allowed_ciphers: ["none", "age-v1"] },
    connected_at: "2026-07-23T00:00:00Z",
    disconnected_at: null,
    ...overrides,
  };
  await writeFile(join(root, "teams", "demo", "config.json"),
    `${JSON.stringify({ name: "demo", agents: {}, remote_binding: remoteBinding }, null, 2)}\n`);
}

test("connected binding is a bounded non-writable nofollow authority", async () => {
  await withConnectedCredential(async (root) => {
    await writeConnectedTeam(root);
    const path = join(root, "teams", "demo", "config.json");
    if (process.platform !== "win32") {
      await chmod(path, 0o666);
      await assert.rejects(loadConfig("demo"), /non-writable regular file/u);
      await unlink(path);
      const target = join(root, "binding-target.json");
      await writeConnectedTeam(root);
      await rename(path, target);
      await symlink(target, path);
      await assert.rejects(loadConfig("demo"), /non-writable regular file/u);
      await unlink(path);
      await rename(target, path);
    }
    await writeFile(path, "x".repeat(2 * 1024 * 1024 + 1), { mode: 0o644 });
    await assert.rejects(loadConfig("demo"), /non-writable regular file|byte limit/u);
  });
});

test("an age-selected binding never synthesizes a plaintext config", async () => {
  await withConnectedCredential(async (root) => {
    const previousStorage = process.env.AGMSG_SYNC_STORAGE_DIR;
    process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "db");
    await writeConnectedTeam(root, { cipher_profile: "age-v1" });
    try {
      await assert.rejects(loadConfig("demo"),
        /selected age-v1.*authenticated sync configuration is missing/u);
      await mkdir(join(root, "db", "remote-sync"), { recursive: true });
      await writeFile(join(root, "db", "remote-sync", "demo.json"),
        `${JSON.stringify({
          format_version: 1,
          local_team: "demo",
          server_url: "https://sync.example",
          server_instance_id: config.server_instance_id,
          remote_team_id: config.remote_team_id,
          protocol_version: 1,
          cipher_profile: "none",
          local_security_history: [{
            local_security_revision: "0",
            effective_from_seq: "1",
            minimum_security_mode: "plaintext-allowed",
          }],
        })}\n`,
        { mode: 0o600 });
      await assert.rejects(loadConfig("demo"),
        /sync configuration cipher does not match.*binding/u);
    } finally {
      if (previousStorage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
      else process.env.AGMSG_SYNC_STORAGE_DIR = previousStorage;
    }
  });
});

test("unlock snapshot verification is canonical and bound to the pulled team", async () => {
  await withConnectedCredential(async (root) => {
    await writeConnectedTeam(root, { cipher_profile: "age-v1" });
    const snapshot = {
      profile: "age-v1",
      server_instance_id: config.server_instance_id,
      team_id: config.remote_team_id,
      epoch_revision: "0",
      writer_generation: "0",
      authorized_writers: ["epoch-initial"],
      previous_snapshot_sha256: null,
      history: [{
        epoch_revision: "0",
        effective_from_seq: "1",
        cipher: "age-v1",
        key_id: "epoch-initial",
        recipients: ["age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp"],
      }],
    };
    const path = join(root, "snapshot.json");
    await writeFile(path, canonicalJson(snapshot), { mode: 0o600 });
    const result = await verifyAgeSnapshot({
      team: "demo",
      // CLI option parsing represents repeatable options as arrays even when
      // exactly one value was supplied.
      "age-snapshot": [path],
    });
    assert.equal(result.snapshot_sha256, ageSnapshotDigest(snapshot));
    assert.equal(result.key_id, "epoch-initial");
    assert.equal(result.recipient, snapshot.history[0].recipients[0]);
    await writeFile(path, `${JSON.stringify(snapshot, null, 2)}\n`, { mode: 0o600 });
    await assert.rejects(verifyAgeSnapshot({
      team: "demo",
      "age-snapshot": [path],
    }), /RFC 8785 JCS/u);
    await writeFile(path, canonicalJson(snapshot), { mode: 0o600 });
    const next = { ...snapshot, epoch_revision: "1", writer_generation: "1",
      previous_snapshot_sha256: ageSnapshotDigest(snapshot),
      history: [...snapshot.history, { ...snapshot.history[0], epoch_revision: "1",
        effective_from_seq: "3", key_id: "epoch-next" }] };
    const nextPath = join(root, "snapshot-next.json");
    await writeFile(nextPath, canonicalJson(next), { mode: 0o600 });
    const rotated = await verifyAgeSnapshot({ team: "demo",
      "age-snapshot": [path, nextPath] });
    assert.equal(rotated.epoch_revision, "1");
    assert.equal(rotated.snapshot_sha256, ageSnapshotDigest(next));
    await assert.rejects(verifyAgeSnapshot({ team: "demo",
      "age-snapshot": [nextPath, path] }), /missing revision/u);
  });
});

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

test("explicit reprocess walks past a permanent first keyset page", async () => {
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: "2", next_sequence_boundary: "3", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"] }],
  };
  const ids = ["550e8400-e29b-41d4-a716-446655440001",
    "550e8400-e29b-41d4-a716-446655440002"];
  const applied = [];
  const driverCall = async (operation, _config, input, extra) => {
    if (operation === "apply") {
      const messages = input.filter((record) => record.type === "sync_pull_message");
      applied.push(...messages.map((record) => record.id));
      return [
        { type: "sync_apply_result", transport_cursor: "2", corrupt_count: 0 },
        ...messages.map((record) => ({
          type: "sync_apply_outcome",
          id: record.id,
          server_seq: record.server_seq,
          status: "authentication_failed",
        })),
      ];
    }
    assert.equal(operation, "reprocess");
    const pageIndex = extra.length === 1 ? 0 : 1;
    if (pageIndex === 1) assert.equal(extra[1], `1:${ids[0]}`);
    const seq = String(pageIndex + 1);
    return [
      { type: "sync_state", driver_generation: "018f3f7e-0000-7000-8000-000000000099",
        transport_cursor: "2" },
      { type: "sync_reprocess_candidate", server_seq: seq, id: ids[pageIndex],
        server_received_at: "2026-07-22T11:00:00.000000Z",
        envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
        prior_status: "authentication_failed" },
      { type: "sync_reprocess_page", next_after: pageIndex === 0 ? `1:${ids[0]}` : null,
        has_more: pageIndex === 0 },
    ];
  };
  const result = await reprocessCycle(config, 1, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async () => capabilities,
    driverCall,
    evaluateCall: async () => ({ status: "authentication_failed", reason: "still blocked",
      policy_revision: "0", local_security_revision: "0" }),
    eventCall: async () => {},
    logApplyCall: async () => {},
  });
  assert.deepEqual(applied, ids);
  assert.equal(result.imported_count, 0);
  assert.equal(result.blocking_remaining, true);
});

test("reprocess completion counts imported outcomes and requires empty blocking quarantine", async () => {
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: "1", next_sequence_boundary: "2", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"] }],
  };
  const id = "550e8400-e29b-41d4-a716-446655440001";
  let imported = false;
  const result = await reprocessCycle(config, 100, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async () => capabilities,
    driverCall: async (operation, _config, input) => {
      if (operation === "apply") {
        imported = true;
        return [
          { type: "sync_apply_result", transport_cursor: "1", corrupt_count: 0 },
          { type: "sync_apply_outcome", id, server_seq: "1", status: "imported" },
        ];
      }
      assert.equal(operation, "reprocess");
      return [
        { type: "sync_state", driver_generation: "generation-1", transport_cursor: "1" },
        ...(!imported ? [{
          type: "sync_reprocess_candidate", server_seq: "1", id,
          server_received_at: "2026-07-22T11:00:00.000000Z",
          envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
          prior_status: "authentication_failed",
        }] : []),
        { type: "sync_reprocess_page", next_after: null, has_more: false },
      ];
    },
    evaluateCall: async () => ({ status: "importable", projection: {
      body: "recovered", created_at: "2026-07-22T11:00:00.000000Z",
      from_agent: "alice", to_agent: "bob",
    }, policy_revision: "0", local_security_revision: "0" }),
    eventCall: async () => {},
    logApplyCall: async () => {},
  });
  assert.equal(result.count, 1);
  assert.equal(result.imported_count, 1);
  assert.equal(result.blocking_remaining, false);
});

test("reprocess routes recovered roster mutations away from message storage", async () => {
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: "2", next_sequence_boundary: "3", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["age-v1"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["age-v1"] }],
  };
  const rosterId = "80dc98aa-a3a1-4a75-becb-9397347875b0";
  const messageId = "900f3ee4-eca6-44a1-a288-4e9c72b941ac";
  let rosterApplied = false;
  let messageApplied = false;
  const result = await reprocessCycle(config, 100, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async () => capabilities,
    driverCall: async (operation, _config, input) => {
      if (operation === "apply") {
        assert.deepEqual(input.map((record) => record.id).filter(Boolean), [rosterId, messageId]);
        assert.deepEqual(input.at(-1), { type: "sync_pull_cursor", next_after: "2" });
        messageApplied = true;
        return [
          { type: "sync_apply_result", transport_cursor: "2", corrupt_count: 0 },
          { type: "sync_apply_outcome", id: rosterId, server_seq: "1", status: "imported" },
          { type: "sync_apply_outcome", id: messageId, server_seq: "2", status: "imported" },
        ];
      }
      assert.equal(operation, "reprocess");
      return [
        { type: "sync_state", driver_generation: "generation-1", transport_cursor: "2" },
        ...(!rosterApplied || !messageApplied ? [{
          type: "sync_reprocess_candidate", server_seq: "1", id: rosterId,
          server_received_at: "2026-07-30T20:33:33.000000Z",
          envelope: { v: 1, cipher: "age-v1", key_id: "epoch-initial", blob: "roster" },
          prior_status: "unsupported_cipher",
        }, {
          type: "sync_reprocess_candidate", server_seq: "2", id: messageId,
          server_received_at: "2026-07-30T20:33:43.000000Z",
          envelope: { v: 1, cipher: "age-v1", key_id: "epoch-initial", blob: "message" },
          prior_status: "unsupported_cipher",
        }] : []),
        { type: "sync_reprocess_page", next_after: null, has_more: false },
      ];
    },
    rosterDriverCall: async (operation, _config, input) => {
      assert.equal(operation, "apply");
      assert.deepEqual(input.map((record) => record.id).filter(Boolean), [rosterId]);
      assert.deepEqual(input.at(-1), { type: "sync_pull_cursor", next_after: "2" });
      rosterApplied = true;
      return [{ type: "roster_sync_apply_outcome", id: rosterId,
        server_seq: "1", status: "imported" }];
    },
    evaluateCall: async (_config, _capabilities, message) => message.id === rosterId ? ({
      status: "importable", projection: {
        kind: "member_joined",
        mutation_id: "019fb4bb-7948-7520-8c16-ab64753e2012",
        member_id: "019fb4bb-7948-7ce9-8e4f-61229dc726cf",
        name: "dana", occurred_at: "2026-07-30T20:33:33.000000Z",
      }, policy_revision: "0", local_security_revision: "0",
    }) : ({
      status: "importable", projection: {
        body: "first sealed message", created_at: "2026-07-30T20:33:43.000000Z",
        from_agent: "dana", to_agent: "dana",
      }, policy_revision: "0", local_security_revision: "0",
    }),
    eventCall: async () => {},
    logApplyCall: async () => {},
  });
  assert.equal(result.count, 2);
  assert.equal(result.imported_count, 2);
  assert.equal(result.blocking_remaining, false);
});

test("reprocess preserves server order across roster mutations and rotations", async () => {
  const capabilities = {
    ...capsFor(["age-v1"]), current_seq: "6", next_sequence_boundary: "7",
  };
  const ids = Array.from({ length: 6 }, (_, index) =>
    `550e8400-e29b-41d4-a716-44665544000${index + 1}`);
  let completed = false;
  let activeEpoch = 0;
  const rosterOrder = [];
  const result = await reprocessCycle(config, 100, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async () => capabilities,
    driverCall: async (operation, _config, input) => {
      if (operation === "apply") {
        assert.deepEqual(input.filter((record) => record.id).map((record) => record.server_seq),
          ["1", "2", "3", "4", "5", "6"]);
        completed = true;
        return [{ type: "sync_apply_result", transport_cursor: "6", corrupt_count: 0 },
          ...ids.map((id, index) => ({ type: "sync_apply_outcome", id,
            server_seq: String(index + 1), status: "imported" }))];
      }
      assert.equal(operation, "reprocess");
      return [
        { type: "sync_state", driver_generation: "generation-ordered", transport_cursor: "6" },
        ...(!completed ? ids.map((id, index) => ({ type: "sync_reprocess_candidate",
          server_seq: String(index + 1), id,
          server_received_at: "2026-07-30T20:33:33.000000Z",
          envelope: { v: 1, cipher: "age-v1", key_id: "epoch-initial", blob: id },
          prior_status: "pending_key" })) : []),
        { type: "sync_reprocess_page", next_after: null, has_more: false },
      ];
    },
    rosterDriverCall: async (operation, _config, input) => {
      assert.equal(operation, "apply");
      rosterOrder.push(...input.filter((record) => record.id).map((record) => record.server_seq));
      return [];
    },
    activateKeyRotationsCall: async () => { activeEpoch += 1; },
    evaluateCall: async (_config, _capabilities, message) => {
      const seq = Number(message.server_seq);
      if (seq === 2 || seq === 5) return { status: "importable", projection: {
        kind: "key_rotated", mutation_id: `018f3f7e-0000-7000-8000-00000000002${seq}`,
        epoch: String(seq === 2 ? 1 : 2), key_id: `epoch-${seq}`,
        fingerprint: "a".repeat(64), occurred_at: "2026-07-30T20:33:33.000000Z",
      }, policy_revision: "0", local_security_revision: "0" };
      if (seq === 4) {
        assert.equal(activeEpoch, 1);
        return { status: "importable", projection: { body: "after rotation",
          created_at: "2026-07-30T20:33:33.000000Z", from_agent: "a", to_agent: "b" },
        policy_revision: "0", local_security_revision: "0" };
      }
      return { status: "importable", projection: { kind: "member_joined",
        mutation_id: `018f3f7e-0000-7000-8000-00000000001${seq}`,
        member_id: `018f3f7e-0000-7000-8000-00000000003${seq}`,
        name: `member-${seq}`, occurred_at: "2026-07-30T20:33:33.000000Z" },
      policy_revision: "0", local_security_revision: "0" };
    },
    eventCall: async () => {}, logApplyCall: async () => {},
  });
  assert.deepEqual(rosterOrder, ["1", "2", "3", "5", "6"]);
  assert.equal(activeEpoch, 2);
  assert.equal(result.imported_count, 6);
});

test("reprocess does not advance storage when an ordered roster flush fails", async () => {
  const ids = ["550e8400-e29b-41d4-a716-446655440001",
    "550e8400-e29b-41d4-a716-446655440002"];
  let storageApplied = false;
  let activated = false;
  await assert.rejects(reprocessCycle(config, 100, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async () => ({ ...capsFor(["age-v1"]), current_seq: "2",
      next_sequence_boundary: "3" }),
    driverCall: async (operation) => {
      if (operation === "apply") { storageApplied = true; return []; }
      return [{ type: "sync_state", driver_generation: "generation-fail", transport_cursor: "2" },
        ...ids.map((id, index) => ({ type: "sync_reprocess_candidate",
          server_seq: String(index + 1), id,
          server_received_at: "2026-07-30T20:33:33.000000Z",
          envelope: { v: 1, cipher: "age-v1", key_id: "epoch-initial", blob: id },
          prior_status: "pending_key" })),
        { type: "sync_reprocess_page", next_after: null, has_more: false }];
    },
    rosterDriverCall: async () => { throw new Error("roster append failed"); },
    activateKeyRotationsCall: async () => { activated = true; },
    evaluateCall: async (_config, _capabilities, message) => ({ status: "importable",
      projection: message.server_seq === "1" ? { kind: "member_joined",
        mutation_id: "018f3f7e-0000-7000-8000-000000000011",
        member_id: "018f3f7e-0000-7000-8000-000000000031", name: "member-1",
        occurred_at: "2026-07-30T20:33:33.000000Z" } : { kind: "key_rotated",
        mutation_id: "018f3f7e-0000-7000-8000-000000000022", epoch: "1",
        key_id: "epoch-1", fingerprint: "a".repeat(64),
        occurred_at: "2026-07-30T20:33:33.000000Z" },
      policy_revision: "0", local_security_revision: "0" }),
    eventCall: async () => {}, logApplyCall: async () => {},
  }), /roster append failed/u);
  assert.equal(storageApplied, false);
  assert.equal(activated, false);
});

test("explicit reprocess rejects an unbounded walk through duplicate server sequences", async () => {
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: "2", next_sequence_boundary: "3", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"] }],
  };
  const ids = ["550e8400-e29b-41d4-a716-446655440001",
    "550e8400-e29b-41d4-a716-446655440002"];
  let pageIndex = 0;
  await assert.rejects(() => reprocessCycle(config, 1, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async () => capabilities,
    driverCall: async (operation) => {
      if (operation === "apply") {
        return [{ type: "sync_apply_result", transport_cursor: "2", corrupt_count: 0 }];
      }
      const id = ids[pageIndex];
      pageIndex += 1;
      return [
        { type: "sync_state", driver_generation: "018f3f7e-0000-7000-8000-000000000099",
          transport_cursor: "2" },
        { type: "sync_reprocess_candidate", server_seq: "1", id,
          server_received_at: "2026-07-22T11:00:00.000000Z",
          envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
          prior_status: "authentication_failed" },
        { type: "sync_reprocess_page", next_after: pageIndex === 1 ? `1:${id}` : null,
          has_more: pageIndex === 1 },
      ];
    },
    evaluateCall: async () => ({ status: "authentication_failed", reason: "still blocked",
      policy_revision: "0", local_security_revision: "0" }),
    eventCall: async () => {}, logApplyCall: async () => {},
  }), /one server sequence to multiple wire ids/u);
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

test("resync framing rejects duplicate keys and inconsistent audits", () => {
  assert.throws(() => parseStrictJsonl(
    '{"type":"sync_resync_status","type":"sync_resync_status"}\n'), /duplicate key/u);
  assert.throws(() => parseStrictJsonl(
    '{"type":"sync_resync_status","audit":{"gap_end":"5","gap_end":"6"}}\n'),
  /duplicate key/u);
  const generation = "018f3f7e-0000-7000-8000-000000000099";
  const status = { type: "sync_resync_status", driver_generation: generation,
    transport_cursor: "5", audit: { expected_transport_cursor: "0", accepted_floor: "5",
      gap_start: "1", gap_end: "5", reason: "retention-gap-accepted" } };
  assert.deepEqual(validateResyncStatus([status], "5"), status);
  assert.throws(() => validateResyncStatus([{ ...status,
    audit: { ...status.audit, gap_start: "2" } }], "5"), /inconsistent/u);
  assert.throws(() => validateResyncStatus([{ ...status, extra: true }], "5"), /shape/u);
  const result = { type: "sync_resync_result", driver_generation: generation,
    expected_transport_cursor: "0", transport_cursor: "5", accepted_floor: "5",
    gap_start: "1", gap_end: "5", reason: "retention-gap-accepted" };
  assert.deepEqual(validateResyncResult([result], status, "5"), result);
});

test("resync requires an authenticated 410 before atomically accepting a gap", async () => {
  const generation = "018f3f7e-0000-7000-8000-000000000099";
  const operations = [];
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "5",
    current_seq: "7", next_sequence_boundary: "8", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1], write_allowed_ciphers: ["none"] }],
  };
  const result = await resyncCycle(config, "5", {
    driverCall: async (operation, _config, input, extra) => {
      operations.push(operation);
      if (operation === "capabilities") return [{ type: "sync_driver_capabilities",
        capabilities: ["stage1-sync", "stage1-resync"] }];
      if (operation === "resync-status") {
        assert.deepEqual(extra, ["5"]);
        return [{ type: "sync_resync_status", driver_generation: generation,
          transport_cursor: "0", audit: null }];
      }
      assert.equal(operation, "resync");
      assert.deepEqual(input, [{ type: "sync_resync", expected_transport_cursor: "0",
        min_available_seq: "5", current_seq: "7", reason: "retention-gap-accepted" }]);
      return [{ type: "sync_resync_result", driver_generation: generation,
        expected_transport_cursor: "0", transport_cursor: "5", accepted_floor: "5",
        gap_start: "1", gap_end: "5", reason: "retention-gap-accepted" }];
    },
    requestCall: async (_config, path) => {
      if (path === "/v1/capabilities") return capabilities;
      const error = new Error("retained");
      error.status = 410; error.code = "resync-required";
      error.body = { protocol_version: 1, server_instance_id: config.server_instance_id,
        team_id: config.remote_team_id, min_available_seq: "5",
        error: { code: "resync-required", details: { after: "0", min_available_seq: "5" } } };
      throw error;
    },
    eventCall: async () => {},
  });
  assert.equal(result.transport_cursor, "5");
  assert.deepEqual(operations, ["capabilities", "resync-status", "resync"]);
});

test("resync output-loss retry returns the immutable audit without replaying 410", async () => {
  const generation = "018f3f7e-0000-7000-8000-000000000099";
  let messageRequest = false;
  const result = await resyncCycle(config, "5", {
    driverCall: async (operation) => {
      if (operation === "capabilities") return [{ type: "sync_driver_capabilities",
        capabilities: ["stage1-sync", "stage1-resync"] }];
      assert.equal(operation, "resync-status");
      return [{ type: "sync_resync_status", driver_generation: generation,
        transport_cursor: "5", audit: { expected_transport_cursor: "0", accepted_floor: "5",
          gap_start: "1", gap_end: "5", reason: "retention-gap-accepted" } }];
    },
    requestCall: async (_config, path) => {
      if (path !== "/v1/capabilities") messageRequest = true;
      return { protocol_version: 1, server_instance_id: config.server_instance_id,
        team_id: config.remote_team_id, team_name: "demo", min_available_seq: "5",
        current_seq: "7", next_sequence_boundary: "8", accepted_envelope_versions: [1],
        write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
        max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
          effective_from_seq: "1", accepted_envelope_versions: [1], write_allowed_ciphers: ["none"] }] };
    },
    eventCall: async () => {},
  });
  assert.equal(messageRequest, false);
  assert.deepEqual(result, { type: "sync_resync_result", driver_generation: generation,
    expected_transport_cursor: "0", transport_cursor: "5", accepted_floor: "5",
    gap_start: "1", gap_end: "5", reason: "retention-gap-accepted" });
});

test("resync remains optional for Stage-1 drivers", () => {
  assert.equal(stage1ResyncSupported([{ type: "sync_driver_capabilities",
    capabilities: ["stage1-sync"] }]), false);
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
  try {
    await withConnectedCredential(async () => {
      for (const status of [502, 503, 504]) {
        globalThis.fetch = async () => new Response("temporary proxy failure", { status });
        await assert.rejects(request({ ...config, credential_id: credentialId,
          server_url: "https://sync.example" }, "/v1/messages"),
        (error) => error.status === status && error.retryable === true);
      }
    });
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test("request callers cannot override the binding headers, and it sends no Authorization", async () => {
  const previousFetch = globalThis.fetch;
  let captured;
  try {
    await withConnectedCredential(async () => {
      globalThis.fetch = async (_url, init) => {
        captured = init.headers;
        return new Response(JSON.stringify({ protocol_version: 1,
          server_instance_id: config.server_instance_id, team_id: config.remote_team_id }), {
          status: 200, headers: { "Agmsg-Protocol-Version": "1" },
        });
      };
      await request({ ...config, server_url: "https://sync.example" },
        "/v1/messages", { headers: {
          "Agmsg-Team-ID": "018f3f7e-9999-7000-8000-000000000009",
          "Agmsg-Protocol-Version": "99",
        } });
      assert.equal(captured["Agmsg-Team-ID"], config.remote_team_id);
      assert.equal(captured["Agmsg-Protocol-Version"], "1");
      // No per-request credential on the remote-sync data plane anymore.
      assert.equal(captured.Authorization, undefined);
    });
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test("request distinguishes config errors from response transport loss", async () => {
  const previousFetch = globalThis.fetch;
  let fetchCalled = false;
  try {
    await withConnectedCredential(async () => {
      globalThis.fetch = async () => { fetchCalled = true; throw new Error("unexpected fetch"); };
      await assert.rejects(request({ ...config, credential_id: credentialId,
        server_url: "not a URL" }, "/v1/messages"),
      (error) => error.retryable !== true);
      assert.equal(fetchCalled, false);

      globalThis.fetch = async () => ({
        ok: true, status: 200,
        headers: { get: () => "1" },
        text: async () => { throw new Error("body stream reset"); },
      });
      await assert.rejects(request({ ...config, credential_id: credentialId,
        server_url: "https://sync.example" }, "/v1/messages"),
      (error) => error.retryable === true);
    });
  } finally {
    globalThis.fetch = previousFetch;
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

// Shared by the two driver-lifecycle tests below. Both need the same awkward
// shape: start the call, get hold of the fixture's pids *before* asserting
// anything, and make sure those pids are reaped no matter where the test stops.
//
// Registering cleanup first is not tidiness. The mutation that proves these
// tests -- making the engine wait for 'close' -- makes the call hang, so the
// test ends on its timeout with the assertions never reached. Anything recorded
// after an assertion is therefore recorded exactly never, in the one run that
// needs it most, and 300-second sleeps outlive the runner. (Observed, not
// predicted: an earlier version of this file left six of them behind.)
async function driverLifecycleFixture(t, { script, calls, root }) {
  const reap = [];
  // t.after rather than try/finally: it still runs when the test is aborted on
  // its timeout, which is precisely the failing case that leaves processes.
  t.after(() => {
    for (const pid of reap) {
      try { process.kill(pid, "SIGKILL"); } catch { /* already gone */ }
    }
  });

  const gone = (pid) => {
    try {
      process.kill(pid, 0);
      return false;
    } catch (error) {
      return error.code === "ESRCH";
    }
  };
  const awaitPid = async (file) => {
    // Bounded: the fixture writes both pids before it can block or exit, so a
    // file that never appears is a broken fixture, not slowness to wait out.
    for (let attempt = 0; attempt < 200; attempt += 1) {
      try {
        const pid = Number((await readFile(file, "utf8")).trim());
        if (Number.isInteger(pid) && pid > 0) return pid;
      } catch { /* not written yet */ }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error(`fixture never recorded a pid in ${file}`);
  };

  const started = [];
  for (const [index, call] of calls.entries()) {
    // Each call gets its own pid files, so the second driver's pids cannot be
    // read as the first's -- both fixtures write as soon as they start.
    const pidFile = join(root, `child-${index}.pid`);
    const helperFile = join(root, `helper-${index}.pid`);
    await writeFile(join(root, `driver-${index}.sh`),
      script(pidFile, helperFile), { mode: 0o700 });
    const promise = call(join(root, `driver-${index}.sh`));
    // Held so the rejection is not unhandled while the pids are collected.
    promise.catch(() => {});
    // Each pid joins the reap list the moment it is known, rather than both
    // after both are read: a fixture that manages to start a process but not to
    // record the second file would otherwise leave the first one unreaped, and
    // the reap list is the one thing here that must not depend on the fixture
    // being correct.
    const childPid = await awaitPid(pidFile);
    reap.push(childPid);
    reap.push(await awaitPid(helperFile));
    started.push({ promise, childPid });
  }
  return { started, gone };
}

test("a driver that stops reading its input fails the call and is not left running",
  { timeout: 30_000 }, async (t) => {
  // The write loses its reader and takes EPIPE, which arrives on the stdin
  // stream rather than on the child -- and an unhandled stream 'error' is
  // thrown, not returned. So the failure escaped the promise and killed the
  // process, surfacing as an uncaughtException inside whichever unrelated test
  // was running when it fired, which is how it read as a flake.
  //
  // Rejecting is only half of it: a rejected call that leaves the driver running
  // trades "the process dies" for "the process cannot exit". So the fixture
  // records its pid, and leaves a background descendant holding the inherited
  // pipes -- what a real driver that starts a helper does, and the thing that
  // keeps 'close' from ever arriving -- then replaces itself with a sleep longer
  // than this test may run, so nothing here can pass by waiting.
  //
  // The payload is past any platform's pipe buffer (64 KiB on Linux, less on
  // macOS), so the write cannot complete unread.
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-epipe-"));
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
sleep 300 &
echo $! > ${JSON.stringify(helperFile)}
exec 0<&-
exec sleep 300
`;
  const wide = "x".repeat(4096);
  const input = Array.from({ length: 512 }, (_, index) => ({ type: "probe", index, wide }));
  const { started, gone } = await withDriverEnvironment(t, root, script,
    (mock, config) => [
      () => driver("prepare", config, input, ["1"]),
      () => rosterDriver("apply", config, input),
    ]);

  for (const { promise, childPid } of started) {
    // On the marker the stdin handler sets, not on the errno. This asserted
    // EPIPE first and so passed or failed by platform -- macOS answers ENOTCONN
    // or EPIPE from the same event -- and enumerating the codes seen so far only
    // moves the problem to whichever spelling appears next. The set of errnos is
    // not closed; the set of places that set this marker is.
    //
    // It stays load-bearing for the same reason it is stable: only that handler
    // sets it, so a rejection arriving from 'close' cannot satisfy this, and
    // removing the handler fails the test.
    await assert.rejects(() => promise,
      (error) => error.driverFailurePhase === "stdin-write");
    // No poll and no grace period. The call settles only after the driver has
    // exited, so by this line it is already gone.
    assert.ok(gone(childPid), "the failed driver was left running");
  }
});

test("a driver that fails after starting a helper fails the call, and says how",
  { timeout: 30_000 }, async (t) => {
  // The ordinary failure: the driver reads its input, so there is no stream
  // error anywhere, and then exits non-zero. It has a background helper holding
  // the inherited pipes, so 'close' never arrives -- an engine that settled
  // non-zero exits there would hang on the most common failure it has, and the
  // stream-error fix alone would not have touched this path.
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-exit-"));
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
sleep 300 &
echo $! > ${JSON.stringify(helperFile)}
echo "driver is giving up" >&2
cat > /dev/null
exit 7
`;
  const input = [{ type: "probe" }];
  const { started, gone } = await withDriverEnvironment(t, root, script,
    (mock, config) => [
      () => driver("prepare", config, input, ["1"]),
      () => rosterDriver("apply", config, input),
    ]);

  for (const { promise, childPid } of started) {
    // The exit code has to survive: it is the whole diagnostic. So does the
    // stderr collected before the child went away.
    await assert.rejects(() => promise, (error) =>
      /failed \(7\)/u.test(error.message) && /giving up/u.test(error.message));
    assert.ok(gone(childPid), "the failed driver was left running");
  }
});

// Sets AGMSG_SYNC_DRIVER / AGMSG_SYNC_ROSTER_DRIVER per call, restores them
// whatever happens, and hands back the started calls with their pids collected.
async function withDriverEnvironment(t, root, script, buildCalls) {
  const config = {
    local_team: "t", server_instance_id: "018f3f7e-0000-7000-8000-000000000001",
    remote_team_id: "018f3f7e-0000-7000-8000-000000000002", protocol_version: 1,
  };
  const previousDriver = process.env.AGMSG_SYNC_DRIVER;
  const previousRoster = process.env.AGMSG_SYNC_ROSTER_DRIVER;
  t.after(async () => {
    if (previousDriver === undefined) delete process.env.AGMSG_SYNC_DRIVER;
    else process.env.AGMSG_SYNC_DRIVER = previousDriver;
    if (previousRoster === undefined) delete process.env.AGMSG_SYNC_ROSTER_DRIVER;
    else process.env.AGMSG_SYNC_ROSTER_DRIVER = previousRoster;
    if (!root.startsWith(tmpdir())) throw new Error("unsafe test root");
    await rm(root, { recursive: true, force: true });
  });

  const built = buildCalls(null, config);
  // Each call reads the driver path from the environment when it runs, so the
  // path is set immediately before that call and never shared between them.
  const calls = built.map((call) => (mockPath) => {
    process.env.AGMSG_SYNC_DRIVER = mockPath;
    process.env.AGMSG_SYNC_ROSTER_DRIVER = mockPath;
    return call();
  });
  return driverLifecycleFixture(t, { script, calls, root });
}

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

test("age-v1 configuration verifies the complete epoch snapshot hash chain", () => {
  assert.throws(() => ageSnapshotDigest({ bad: "\ud800" }), /lone surrogate/u);
  assert.throws(() => ageSnapshotDigest({ ["\udc00"]: "bad-key" }), /lone surrogate/u);
  const initialAgeSnapshot = {
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
    epoch_snapshot: initialAgeSnapshot,
    checkpoint: { epoch_revision: "0", writer_generation: "0",
      snapshot_sha256: ageSnapshotDigest(initialAgeSnapshot),
      confirmed_at: "2026-07-21T00:00:00.000Z" },
    identity_files: {}, age_version: "v1.3.1",
  } };
  assert.doesNotThrow(() => validateAgeConfiguration(ageConfig));
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1, checkpoint: { ...ageConfig.age_v1.checkpoint,
      snapshot_sha256: "0".repeat(64) },
  } }), /checkpoint/u);
  assert.throws(() => validateAgeConfiguration({ ...ageConfig, age_v1: {
    ...ageConfig.age_v1,
    epoch_snapshot: { ...initialAgeSnapshot, previous_snapshot_sha256: "1".repeat(64) },
  } }), /hash chain/u);
  const rotatedAgeSnapshot = { ...initialAgeSnapshot, epoch_revision: "1",
    writer_generation: "1", previous_snapshot_sha256: ageSnapshotDigest(initialAgeSnapshot),
    history: [...initialAgeSnapshot.history, { ...initialAgeSnapshot.history[0], epoch_revision: "1",
      effective_from_seq: "2", key_id: "epoch-2" }] };
  const chainedAgeConfig = { ...ageConfig, age_v1: {
    ...ageConfig.age_v1,
    epoch_snapshots: [initialAgeSnapshot, rotatedAgeSnapshot],
    epoch_snapshot: undefined,
    checkpoint: { ...ageConfig.age_v1.checkpoint, epoch_revision: "1",
      writer_generation: "1",
      snapshot_sha256: ageSnapshotDigest(rotatedAgeSnapshot) },
  } };
  assert.doesNotThrow(() => validateAgeConfiguration(chainedAgeConfig));

  const tamperedInitial = { ...initialAgeSnapshot, authorized_writers: ["writer-b"] };
  assert.throws(() => validateAgeConfiguration({ ...chainedAgeConfig, age_v1: {
    ...chainedAgeConfig.age_v1,
    epoch_snapshots: [tamperedInitial, rotatedAgeSnapshot],
  } }), /hash chain/u);

  const reusedKeyId = {
    ...rotatedAgeSnapshot,
    history: [...initialAgeSnapshot.history, {
      ...rotatedAgeSnapshot.history.at(-1),
      key_id: initialAgeSnapshot.history[0].key_id,
      recipients: ["age1ykvctct4aklx4f4mnjd8rmzqs7p2le9ufg4faydljsk5mvcy0pls27mu64"],
    }],
  };
  assert.throws(() => validateAgeConfiguration({ ...chainedAgeConfig, age_v1: {
    ...chainedAgeConfig.age_v1,
    epoch_snapshots: [initialAgeSnapshot, reusedKeyId],
    checkpoint: { ...chainedAgeConfig.age_v1.checkpoint,
      snapshot_sha256: ageSnapshotDigest(reusedKeyId) },
  } }), /conflicting recipient manifests/u);

  const revisionTwo = { ...rotatedAgeSnapshot, epoch_revision: "2", writer_generation: "2",
    previous_snapshot_sha256: ageSnapshotDigest(rotatedAgeSnapshot),
    history: [...rotatedAgeSnapshot.history, {
      ...rotatedAgeSnapshot.history.at(-1), epoch_revision: "2",
      effective_from_seq: "3", key_id: "epoch-3" }] };
  assert.throws(() => validateAgeConfiguration({ ...chainedAgeConfig, age_v1: {
    ...chainedAgeConfig.age_v1, epoch_snapshots: [initialAgeSnapshot, revisionTwo],
    checkpoint: { ...chainedAgeConfig.age_v1.checkpoint, epoch_revision: "2",
      writer_generation: "2", snapshot_sha256: ageSnapshotDigest(revisionTwo) },
  } }), /missing revision/u);
});

test("initial age snapshot uses the key id as its sole writer and stable JCS", () => {
  const keyId = "epoch-initial";
  const recipient = "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp";
  const epoch = {
    key_id: keyId,
    epoch_revision: 0,
    writer_generation: 0,
    recipient,
    previous_snapshot_sha256: null,
    created_at: "2026-07-30T00:00:00Z",
  };
  const teamConfig = {
    name: "demo",
    agents: {},
    remote_key: { current: epoch, epochs: [epoch] },
    remote_binding: {
      endpoint: "https://sync.example.test",
      server_instance_id: config.server_instance_id,
      remote_team_id: config.remote_team_id,
      remote_team_name: "demo",
      protocol_version: 1,
      capabilities: { write_allowed_ciphers: ["none", "age-v1"] },
      connected_at: "2026-07-30T00:00:00Z",
      disconnected_at: null,
    },
  };
  const first = initialAgeSnapshot(teamConfig);
  const second = initialAgeSnapshot(JSON.parse(JSON.stringify(teamConfig)));
  assert.deepEqual(first.authorized_writers, [keyId]);
  assert.equal(canonicalJson(first), canonicalJson(second));
  assert.equal(ageSnapshotDigest(first), ageSnapshotDigest(second));
  assert.match(ageSnapshotDigest(first), /^[0-9a-f]{64}$/u);
  assert.doesNotThrow(() => validateAgeConfiguration({
    ...config,
    cipher_profile: "age-v1",
    local_security_history: [{
      local_security_revision: "0",
      effective_from_seq: "1",
      minimum_security_mode: "e2ee-required",
    }],
    age_v1: {
      epoch_snapshot: first,
      checkpoint: {
        epoch_revision: "0",
        writer_generation: "0",
        snapshot_sha256: ageSnapshotDigest(first),
        confirmed_at: "2026-07-30T00:00:00Z",
      },
      identity_files: {},
      age_version: "v1.3.1",
    },
  }));
});

test("retained age checkpoint survives sync config reset and rejects same-revision conflict", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-age-trust-"));
  const previousTrust = process.env.AGMSG_SYNC_TRUST_DIR;
  const previousStorage = process.env.AGMSG_SYNC_STORAGE_DIR;
  process.env.AGMSG_SYNC_TRUST_DIR = join(root, "trust");
  process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "resettable-store");
  const initialAgeSnapshot = {
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
    await assert.rejects(
      retainAgeCheckpoint(makeConfig(initialAgeSnapshot), undefined), /operator-live/u);
    const retained = await retainAgeCheckpoint(
      makeConfig(initialAgeSnapshot), "operator-live");
    assert.equal(retained.snapshot_sha256, ageSnapshotDigest(initialAgeSnapshot));
    const resettableConfig = join(process.env.AGMSG_SYNC_STORAGE_DIR, "remote-sync", "demo.json");
    await mkdir(join(process.env.AGMSG_SYNC_STORAGE_DIR, "remote-sync"), { recursive: true });
    await writeFile(resettableConfig, "{}\n");
    await unlink(resettableConfig);
    const conflicting = { ...initialAgeSnapshot, authorized_writers: ["writer-b"] };
    await assert.rejects(retainAgeCheckpoint(makeConfig(conflicting), "operator-live"),
      /same-revision conflict/u);
    const rotatedAgeSnapshot = {
      ...initialAgeSnapshot,
      epoch_revision: "1",
      writer_generation: "1",
      previous_snapshot_sha256: ageSnapshotDigest(initialAgeSnapshot),
      history: [...initialAgeSnapshot.history, {
        ...initialAgeSnapshot.history[0], epoch_revision: "1",
        effective_from_seq: "2", key_id: "epoch-2",
      }],
    };
    const advanced = { ...config, cipher_profile: "age-v1", age_v1: {
      epoch_snapshots: [initialAgeSnapshot, rotatedAgeSnapshot],
      checkpoint: { epoch_revision: "1", writer_generation: "1",
        snapshot_sha256: ageSnapshotDigest(rotatedAgeSnapshot),
        confirmed_at: "2026-07-22T00:00:00.000Z" },
      identity_files: {}, age_version: "v1.3.1",
    } };
    const retainedAdvanced = await retainAgeCheckpoint(advanced, "operator-live");
    assert.equal(retainedAdvanced.epoch_revision, "1");
    await assert.rejects(retainAgeCheckpoint(makeConfig(initialAgeSnapshot), "operator-live"),
      /rollback/u);
  } finally {
    if (previousTrust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
    else process.env.AGMSG_SYNC_TRUST_DIR = previousTrust;
    if (previousStorage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
    else process.env.AGMSG_SYNC_STORAGE_DIR = previousStorage;
    await rm(root, { recursive: true });
  }
});

test("age configure authenticates the connected credential before retaining trust", async () => {
  const previousFetch = globalThis.fetch;
  await withConnectedCredential(async (root) => {
    await writeConnectedTeam(root, { capabilities: { write_allowed_ciphers: ["age-v1"] } });
    const ageSnapshot = {
      authorized_writers: ["writer-a"],
      epoch_revision: "0",
      history: [{ cipher: "age-v1", effective_from_seq: "1", epoch_revision: "0",
        key_id: "epoch-1", recipients: [
          "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp",
        ] }],
      previous_snapshot_sha256: null,
      profile: "age-v1",
      server_instance_id: config.server_instance_id,
      team_id: config.remote_team_id,
      writer_generation: "0",
    };
    const ageSnapshotPath = join(root, "epoch-snapshot.json");
    await writeFile(ageSnapshotPath, JSON.stringify(ageSnapshot));
    const fakeAge = join(root, "age");
    await writeFile(fakeAge, "#!/bin/sh\necho v1.3.1\n", { mode: 0o700 });
    const saved = {
      storage: process.env.AGMSG_SYNC_STORAGE_DIR,
      trust: process.env.AGMSG_SYNC_TRUST_DIR,
      age: process.env.AGMSG_AGE_BIN,
    };
    process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "store");
    process.env.AGMSG_SYNC_TRUST_DIR = join(root, "trust");
    process.env.AGMSG_AGE_BIN = fakeAge;
    let calls = 0;
    globalThis.fetch = async () => {
      calls += 1;
      if (calls === 1) {
        return new Response(JSON.stringify({ status: "ok", database: "ok",
          server_instance_id: config.server_instance_id }), {
          status: 200, headers: { "Agmsg-Protocol-Version": "1" },
        });
      }
      return new Response(JSON.stringify({ protocol_version: 1,
        error: { code: "unauthenticated" } }), {
        status: 401, headers: { "Agmsg-Protocol-Version": "1" },
      });
    };
    try {
      await assert.rejects(configure({ team: "demo", server: "https://sync.example",
        "team-id": config.remote_team_id, "minimum-security": "e2ee-required",
        cipher: "age-v1", "age-snapshot": ageSnapshotPath,
        "age-checkpoint": `0:${ageSnapshotDigest(ageSnapshot)}`,
        "age-confirmation": "operator-live" }), /unauthenticated/u);
      assert.equal(calls, 2);
      await assert.rejects(readdir(process.env.AGMSG_SYNC_TRUST_DIR),
        (error) => error.code === "ENOENT");
    } finally {
      globalThis.fetch = previousFetch;
      if (saved.storage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
      else process.env.AGMSG_SYNC_STORAGE_DIR = saved.storage;
      if (saved.trust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
      else process.env.AGMSG_SYNC_TRUST_DIR = saved.trust;
      if (saved.age === undefined) delete process.env.AGMSG_AGE_BIN;
      else process.env.AGMSG_AGE_BIN = saved.age;
    }
  });
});

test("age configure extends a stored chain and activates its announced epoch", async () => {
  const previousFetch = globalThis.fetch;
  await withConnectedCredential(async (root) => {
    await writeConnectedTeam(root, { capabilities: { write_allowed_ciphers: ["age-v1"] } });
    const identityDir = join(root, "run", "remote-credentials", "demo", "keys");
    const identity1 = join(identityDir, "epoch-1.key");
    await mkdir(identityDir, { recursive: true });
    await writeFile(identity1,
      "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ\n",
      { mode: 0o600 });
    const recipient1 = readNativeAgeIdentity(identity1).recipient;
    const recipient0 = recipient1;
    const ageSnapshot0 = {
      authorized_writers: ["writer-a"],
      epoch_revision: "0",
      history: [{ cipher: "age-v1", effective_from_seq: "1", epoch_revision: "0",
        key_id: "epoch-0", recipients: [recipient0] }],
      previous_snapshot_sha256: null,
      profile: "age-v1",
      server_instance_id: config.server_instance_id,
      team_id: config.remote_team_id,
      writer_generation: "0",
    };
    const ageSnapshot1 = {
      ...ageSnapshot0,
      epoch_revision: "1",
      history: [...ageSnapshot0.history, {
        cipher: "age-v1", effective_from_seq: "2", epoch_revision: "1",
        key_id: "epoch-1", recipients: [recipient1],
      }],
      previous_snapshot_sha256: ageSnapshotDigest(ageSnapshot0),
      writer_generation: "1",
    };
    const ageSnapshot0Path = join(root, "epoch-snapshot-0.json");
    const ageSnapshot1Path = join(root, "epoch-snapshot-1.json");
    await writeFile(ageSnapshot0Path, JSON.stringify(ageSnapshot0));
    await writeFile(ageSnapshot1Path, JSON.stringify(ageSnapshot1));
    const fakeAge = join(root, "age");
    await writeFile(fakeAge, "#!/bin/sh\necho v1.3.1\n", { mode: 0o700 });
    const saved = {
      storage: process.env.AGMSG_SYNC_STORAGE_DIR,
      trust: process.env.AGMSG_SYNC_TRUST_DIR,
      age: process.env.AGMSG_AGE_BIN,
    };
    process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "store");
    process.env.AGMSG_SYNC_TRUST_DIR = join(root, "trust");
    process.env.AGMSG_AGE_BIN = fakeAge;
    globalThis.fetch = async (url) => {
      const body = String(url).endsWith("/v1/health") ?
        { status: "ok", database: "ok", server_instance_id: config.server_instance_id } :
        capsFor(["age-v1"]);
      return new Response(JSON.stringify(body), {
        status: 200, headers: { "Agmsg-Protocol-Version": "1" },
      });
    };
    try {
      await configure({ team: "demo", server: "https://sync.example",
        "team-id": config.remote_team_id, "minimum-security": "e2ee-required",
        cipher: "age-v1", "age-snapshot": [ageSnapshot0Path],
        "age-checkpoint": `0:${ageSnapshotDigest(ageSnapshot0)}`,
        "age-confirmation": "operator-live", "age-identity": [`epoch-0=${identity1}`] });
      const mutationId = "018f3f7e-0000-7000-8000-000000000025";
      await writeFile(join(root, "teams", "demo", "roster.jsonl"), [
        JSON.stringify({ type: "key_rotated", id: mutationId, epoch: "1",
          key_id: "epoch-1", fingerprint: createHash("sha256").update(recipient1).digest("hex"),
          at: "2026-07-30T00:00:00.000000Z" }),
        JSON.stringify({ type: "roster_synced", mutation_id: mutationId, server_seq: "1",
          wire_id: "550e8400-e29b-41d4-a716-446655440006",
          server_instance_id: config.server_instance_id,
          remote_team_id: config.remote_team_id }), "",
      ].join("\n"));
      await configure({ team: "demo", server: "https://sync.example",
        "team-id": config.remote_team_id, "minimum-security": "e2ee-required",
        cipher: "age-v1", "age-snapshot": [ageSnapshot0Path, ageSnapshot1Path],
        "age-checkpoint": `1:${ageSnapshotDigest(ageSnapshot1)}`,
        "age-confirmation": "operator-live", "age-identity": [`epoch-1=${identity1}`] });
      const stored = JSON.parse(await readFile(
        join(process.env.AGMSG_SYNC_STORAGE_DIR, "remote-sync", "demo.json"), "utf8"));
      assert.equal(stored.age_v1.epoch_snapshots.length, 2);
      assert.equal(stored.age_v1.identity_files["epoch-0"], identity1);
      assert.equal(stored.age_v1.identity_files["epoch-1"], identity1);
      const loaded = await loadConfig("demo");
      assert.equal(loaded.age_v1_runtime_history.length, 1);
      assert.equal(loaded.age_v1_runtime_history[0].key_id, "epoch-1");
      const afterFirstSequence = {
        ...capsFor(["age-v1"]), current_seq: "1", next_sequence_boundary: "2",
      };
      assert.equal(selectWriteProfile(loaded, afterFirstSequence).key_id, "epoch-1");
    } finally {
      globalThis.fetch = previousFetch;
      if (saved.storage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
      else process.env.AGMSG_SYNC_STORAGE_DIR = saved.storage;
      if (saved.trust === undefined) delete process.env.AGMSG_SYNC_TRUST_DIR;
      else process.env.AGMSG_SYNC_TRUST_DIR = saved.trust;
      if (saved.age === undefined) delete process.env.AGMSG_AGE_BIN;
      else process.env.AGMSG_AGE_BIN = saved.age;
    }
  });
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

// ---- adaptive sync catch-up (adaptive-sync-catchup design) ----

test("runLoop: push saturation drives catch-up (no wait), a drained cycle returns to the steady interval", async () => {
  const sleeps = [];
  const limitsSeen = [];
  const saturationScript = [true, true, false]; // two catch-up cycles, then drained
  let i = 0;
  await assert.rejects(() => runLoop(config, {}, {
    cycleCall: async (_config, limits) => {
      limitsSeen.push(limits);
      if (i >= saturationScript.length) { const stop = new Error("stop"); stop.retryable = false; throw stop; }
      return { pushSaturated: saturationScript[i++] };
    },
    sleepCall: async (ms) => { sleeps.push(ms); },
    isRetryableCall: (error) => error.retryable === true,
    eventCall: async () => {},
  }), /stop/);
  // Only the drained (non-saturated) cycle waits, and it waits the 5s steady interval.
  assert.deepEqual(sleeps, [5000]);
  // First cycle starts steady (100); saturation lifts push to 1000; a drained cycle drops back to 100.
  assert.equal(limitsSeen[0].pushLimit, 100);
  assert.equal(limitsSeen[1].pushLimit, 1000);
  assert.equal(limitsSeen[2].pushLimit, 1000);
  assert.equal(limitsSeen[3].pushLimit, 100);
  // Pull is always large regardless of cadence.
  assert.ok(limitsSeen.every((limits) => limits.pullLimit === 1000));
});

test("runLoop: a retryable failure always backs off exponentially, even after entering catch-up (no hot loop)", async () => {
  const sleeps = [];
  let i = 0;
  await assert.rejects(() => runLoop(config, {}, {
    cycleCall: async () => {
      i += 1;
      if (i === 1) return { pushSaturated: true }; // enter catch-up (would otherwise skip the wait)
      if (i <= 3) { const net = new Error("net"); net.retryable = true; throw net; } // two retryable failures
      const stop = new Error("stop"); stop.retryable = false; throw stop;
    },
    sleepCall: async (ms) => { sleeps.push(ms); },
    isRetryableCall: (error) => error.retryable === true,
    eventCall: async () => {},
  }), /stop/);
  // Cycle 1 saturated -> no wait; then two failures back off 1s, 2s despite catch-up being engaged.
  assert.deepEqual(sleeps, [1000, 2000]);
});

test("runLoop: an explicit --limit caps both push and pull page sizes, even in catch-up", async () => {
  const limitsSeen = [];
  await assert.rejects(() => runLoop(config, { limit: 50 }, {
    cycleCall: async (_config, limits) => {
      limitsSeen.push(limits);
      if (limitsSeen.length === 1) return { pushSaturated: true }; // would jump to 1000 without a ceiling
      const stop = new Error("stop"); stop.retryable = false; throw stop;
    },
    sleepCall: async () => {},
    isRetryableCall: (error) => error.retryable === true,
    eventCall: async () => {},
  }), /stop/);
  for (const limits of limitsSeen) {
    assert.equal(limits.pushLimit, 50);
    assert.equal(limits.pullLimit, 50);
  }
});

test("cycle: a large pull page (backlog present) is requested and accepted at pullLimit — trap 1 regression", async () => {
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: "500", next_sequence_boundary: "501", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"] }],
  };
  // 500 contiguous messages — larger than the steady 100 page. If the pull
  // validation still read a 100-sized limit, this would throw "pull page is
  // invalid"; a normal (no-backlog) test never receives a page this big.
  const messages = Array.from({ length: 500 }, (_unused, index) => ({
    id: `550e8400-e29b-41d4-a716-${String(index + 1).padStart(12, "0")}`,
    server_seq: String(index + 1),
    envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
  }));
  let pullPath = null;
  const result = await cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async (_config, path) => {
      if (path === "/v1/capabilities") return capabilities;
      if (path.startsWith("/v1/messages?after=")) { pullPath = path; return { messages, next_after: "500", has_more: false }; }
      throw new Error(`unexpected request ${path}`);
    },
    driverCall: async (operation) => {
      if (operation === "prepare") {
        return [{ type: "sync_state", driver_generation: "018f3f7e-0000-7000-8000-000000000099", transport_cursor: "0" }];
      }
      if (operation === "apply") return [{ type: "sync_apply_result", transport_cursor: "500", corrupt_count: 0 }];
      throw new Error(`unexpected driver op ${operation}`);
    },
    evaluateCall: async () => ({ status: "imported", policy_revision: "0", local_security_revision: "0" }),
    logApplyCall: async () => {},
    eventCall: async () => {},
    readStateCycleCall: async () => {},
  });
  // The request used the large pull limit, and the 500-message page was accepted (no throw).
  assert.match(pullPath, /limit=1000/);
  // No push candidates were prepared, so push is not saturated.
  assert.equal(result.pushSaturated, false);
});

test("cycle routes roster payloads through the existing message transport", async () => {
  let posted = false;
  let advanced = false;
  const wireId = "550e8400-e29b-41d4-a716-446655440001";
  const mutationId = "018f3f7e-0000-7000-8000-000000000020";
  const projection = {
    kind: "member_joined",
    mutation_id: mutationId,
    member_id: "018f3f7e-0000-7000-8000-000000000010",
    name: "alice",
    occurred_at: "2026-07-28T23:00:00.000000Z",
  };
  const capability = () => ({
    ...capsFor(["none"]),
    current_seq: advanced ? "1" : "0",
    next_sequence_boundary: advanced ? "2" : "1",
  });
  const rosterOperations = [];
  await cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async (_config, path, init) => {
      if (path === "/v1/capabilities") return capability();
      if (path === "/v1/messages" && init?.method === "POST") {
        const body = JSON.parse(init.body);
        assert.deepEqual(body.messages, [{
          id: wireId,
          envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
        }]);
        posted = true;
        advanced = true;
        return { acks: [{ id: wireId, server_seq: "1", disposition: "stored" }] };
      }
      if (path.startsWith("/v1/messages?after=")) {
        return {
          messages: [{
            server_seq: "1",
            id: wireId,
            server_received_at: "2026-07-28T23:00:01.000000Z",
            envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
          }],
          next_after: "1",
          has_more: false,
        };
      }
      throw new Error(`unexpected request ${path}`);
    },
    driverCall: async (operation, _config, input) => {
      if (operation === "prepare") return [{
        type: "sync_state",
        driver_generation: "018f3f7e-0000-7000-8000-000000000099",
        transport_cursor: "0",
      }];
      if (operation === "apply") {
        assert.deepEqual(input, [{ type: "sync_pull_cursor", next_after: "1" }]);
        return [{ type: "sync_apply_result", transport_cursor: "1", corrupt_count: 0 }];
      }
      throw new Error(`unexpected storage operation ${operation}`);
    },
    rosterDriverCall: async (operation, _config, input) => {
      rosterOperations.push(operation);
      if (operation === "prepare") return [{
        type: "roster_sync_push_candidate",
        local_position: mutationId,
        local_id: mutationId,
        id: wireId,
        envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
      }];
      if (operation === "reconcile") {
        assert.equal(input[0].local_position, mutationId);
        return [{ type: "roster_sync_reconcile_result", count: 1 }];
      }
      if (operation === "apply") {
        assert.equal(input[0].projection.kind, "member_joined");
        assert.deepEqual(input.at(-1), { type: "sync_pull_cursor", next_after: "1" });
        return [{ type: "roster_sync_apply_outcome", status: "reconciled" }];
      }
      throw new Error(`unexpected roster operation ${operation}`);
    },
    evaluateCall: async () => ({ status: "importable", projection }),
    logApplyCall: async () => {},
    eventCall: async () => {},
    readStateCycleCall: async () => {},
  });
  assert.equal(posted, true);
  assert.deepEqual(rosterOperations, ["prepare", "reconcile", "apply"]);
});

test("pull bootstrap dispatches a real mixed roster and message page", async () => {
  const teamId = "018f3f7e-0000-7000-8000-000000000001";
  const serverId = "018f3f7e-0000-7000-8000-000000000002";
  const roster = Array.from({ length: 7 }, (_, index) => ({
    server_seq: String(index + 1),
    id: `10000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    server_received_at: "2026-07-29T05:00:00.000000Z",
    envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
    projection: {
      kind: "member_joined",
      mutation_id: `018f3f7e-0000-7000-8000-${String(index + 10).padStart(12, "0")}`,
      member_id: `018f3f7e-0000-7000-8000-${String(index + 20).padStart(12, "0")}`,
      name: `member-${index + 1}`,
      occurred_at: "2026-07-29T05:00:00.000000Z",
    },
  }));
  const messages = Array.from({ length: 73 }, (_, index) => ({
    server_seq: String(index + 8),
    id: `20000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`,
    server_received_at: "2026-07-29T05:00:00.000000Z",
    envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
    projection: {
      body: `message-${index + 1}`,
      created_at: "2026-07-29T05:00:00.000000Z",
      from_agent: "member-1",
      to_agent: "member-2",
    },
  }));
  messages[0].envelope = {
    v: 1, cipher: "age-v1", key_id: "epoch-0", blob: "encrypted",
  };
  const storageInputs = [];
  const rosterInputs = [];
  const result = await pullBootstrap({
    team: "clone", "team-id": teamId, endpoint: "http://127.0.0.1:8787",
  }, {
    publicSnapshotCall: async () => ({
      server_instance_id: serverId, team_id: teamId, team_name: "source",
      min_available_seq: "0",
    }),
    requestPublicCall: async () => ({
      messages: [...roster, ...messages].map(({ projection: _projection, ...message }) => message),
      next_after: "80", has_more: false,
    }),
    evaluateCall: async (_config, _teamSnapshot, message) => ({
      status: "importable",
      projection: [...roster, ...messages].find((entry) => entry.id === message.id).projection,
      policy_revision: "0", local_security_revision: "0",
    }),
    driverCall: async (operation, _config, input) => {
      assert.equal(operation, "apply");
      storageInputs.push(input);
      return [{ type: "sync_apply_result", transport_cursor: "80", corrupt_count: 0 }];
    },
    rosterDriverCall: async (operation, _config, input) => {
      assert.equal(operation, "apply");
      rosterInputs.push(input);
      return [{ type: "roster_sync_apply_outcome", status: "imported" }];
    },
    eventCall: async () => {},
  });
  assert.equal(rosterInputs.length, 1);
  assert.equal(rosterInputs[0].filter((record) => record.type === "sync_pull_message").length, 7);
  assert.deepEqual(rosterInputs[0].at(-1), { type: "sync_pull_cursor", next_after: "80" });
  assert.equal(storageInputs.length, 1);
  assert.equal(storageInputs[0].filter((record) => record.type === "sync_pull_message").length, 73);
  assert.deepEqual(storageInputs[0].at(-1), { type: "sync_pull_cursor", next_after: "80" });
  assert.equal(result.age_v1_envelopes, 1);
});

test("pull bootstrap rejects unsupported projection kinds before either cursor advances", async () => {
  const teamId = "018f3f7e-0000-7000-8000-000000000001";
  const serverId = "018f3f7e-0000-7000-8000-000000000002";
  let storageApplied = false;
  let rosterApplied = false;
  await assert.rejects(pullBootstrap({
    team: "clone", "team-id": teamId, endpoint: "http://127.0.0.1:8787",
  }, {
    publicSnapshotCall: async () => ({
      server_instance_id: serverId, team_id: teamId, team_name: "source",
      min_available_seq: "0",
    }),
    requestPublicCall: async () => ({
      messages: [{
        server_seq: "1", id: "10000000-0000-4000-8000-000000000001",
        server_received_at: "2026-07-29T05:00:00.000000Z",
        envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
      }],
      next_after: "1", has_more: false,
    }),
    evaluateCall: async () => ({
      status: "importable",
      projection: {
        kind: "key_rotated",
        mutation_id: "018f3f7e-0000-7000-8000-000000000010",
        epoch: "1", key_id: "epoch-1", fingerprint: "a".repeat(64),
        occurred_at: "2026-07-29T05:00:00.000000Z",
      },
      policy_revision: "0", local_security_revision: "0",
    }),
    driverCall: async () => { storageApplied = true; },
    rosterDriverCall: async () => { rosterApplied = true; },
    eventCall: async () => {},
  }), /cannot apply this projection kind/u);
  assert.equal(storageApplied, false);
  assert.equal(rosterApplied, false);
});

test("cycle pushes a key rotation alone and waits for ordered pull before activation", async () => {
  const rotationWire = "550e8400-e29b-41d4-a716-446655440003";
  const messageWire = "550e8400-e29b-41d4-a716-446655440004";
  const projection = {
    kind: "key_rotated",
    mutation_id: "018f3f7e-0000-7000-8000-000000000023",
    epoch: "1",
    key_id: "epoch-20260729010000-abcd",
    fingerprint: "c".repeat(64),
    occurred_at: "2026-07-29T01:00:00.000000Z",
  };
  let activated = 0;
  await cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async (_config, path, init) => {
      if (path === "/v1/capabilities") return capsFor(["none"]);
      if (path === "/v1/messages" && init?.method === "POST") {
        assert.deepEqual(JSON.parse(init.body).messages.map((item) => item.id), [rotationWire]);
        return { acks: [{ id: rotationWire, server_seq: "1", disposition: "stored" }] };
      }
      if (path.startsWith("/v1/messages?after=")) {
        return { messages: [], next_after: "0", has_more: false };
      }
      throw new Error(`unexpected request ${path}`);
    },
    driverCall: async (operation) => {
      if (operation === "prepare") return [{
        type: "sync_state",
        driver_generation: "018f3f7e-0000-7000-8000-000000000099",
        transport_cursor: "0",
      }, {
        type: "sync_push_candidate", local_position: "1", local_id: "message",
        id: messageWire, envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
      }];
      if (operation === "apply") return [{ type: "sync_apply_result", transport_cursor: "0" }];
      throw new Error(`unexpected storage operation ${operation}`);
    },
    rosterDriverCall: async (operation) => {
      if (operation === "prepare") return [{
        type: "roster_sync_push_candidate",
        local_position: projection.mutation_id,
        local_id: projection.mutation_id,
        id: rotationWire,
        envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
        projection,
      }];
      if (operation === "reconcile") return [{ type: "roster_sync_reconcile_result", count: 1 }];
      throw new Error(`unexpected roster operation ${operation}`);
    },
    activateKeyRotationsCall: async () => { activated += 1; },
    logApplyCall: async () => {},
    eventCall: async () => {},
    readStateCycleCall: async () => {},
  });
  assert.equal(activated, 0);
});

test("cycle records a pulled key rotation before halting for a missing replacement key", async () => {
  const projection = {
    kind: "key_rotated",
    mutation_id: "018f3f7e-0000-7000-8000-000000000024",
    epoch: "1",
    key_id: "epoch-20260729010000-bcde",
    fingerprint: "d".repeat(64),
    occurred_at: "2026-07-29T01:00:00.000000Z",
  };
  let recorded = false;
  let storageApplied = false;
  await assert.rejects(cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async (_config, path) => {
      if (path === "/v1/capabilities") return {
        ...capsFor(["none"]), current_seq: "1", next_sequence_boundary: "2",
      };
      if (path.startsWith("/v1/messages?after=")) return {
        messages: [{
          server_seq: "1", id: "550e8400-e29b-41d4-a716-446655440005",
          server_received_at: "2026-07-29T01:00:01.000000Z",
          envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" },
        }],
        next_after: "1", has_more: false,
      };
      throw new Error(`unexpected request ${path}`);
    },
    driverCall: async (operation) => {
      if (operation === "prepare") return [{
        type: "sync_state",
        driver_generation: "018f3f7e-0000-7000-8000-000000000099",
        transport_cursor: "0",
      }];
      if (operation === "apply") storageApplied = true;
      return [];
    },
    rosterDriverCall: async (operation, _config, input) => {
      if (operation === "prepare") return [{ type: "roster_sync_state", transport_cursor: "0" }];
      if (operation === "apply") {
        assert.equal(input[0].projection.kind, "key_rotated");
        recorded = true;
        return [];
      }
      return [];
    },
    evaluateCall: async () => ({ status: "importable", projection }),
    activateKeyRotationsCall: async () => {
      throw new Error("replacement epoch is missing; import that key out of band");
    },
    eventCall: async () => {},
    readStateCycleCall: async () => {},
  }), /import that key out of band/u);
  assert.equal(recorded, true);
  assert.equal(storageApplied, false);
});

// ---- pushSaturated is computed by cycle itself (B2 test gate) ----
// These exercise cycle's own `writeProfile.eligible && candidates.length ===
// pushLimit`; the runLoop tests above hand-write pushSaturated, so without
// these a broken signal in cycle would leave every adaptive test green.

function capsFor(writeCiphers) {
  return {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: "0", next_sequence_boundary: "1", accepted_envelope_versions: [1],
    write_allowed_ciphers: writeCiphers, policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1], write_allowed_ciphers: writeCiphers }],
  };
}
function pushCandidateRecord(n) {
  return { type: "sync_push_candidate", local_position: String(n),
    id: `550e8400-e29b-41d4-a716-${String(n).padStart(12, "0")}`,
    envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" } };
}
async function runCycleWithPush({ writeCiphers, candidateCount, pushLimit }) {
  const capabilities = capsFor(writeCiphers);
  const prepared = [
    { type: "sync_state", driver_generation: "018f3f7e-0000-7000-8000-000000000099", transport_cursor: "0" },
    ...Array.from({ length: candidateCount }, (_unused, index) => pushCandidateRecord(index + 1)),
  ];
  let posted = false;
  let reconcileCalled = false;
  const result = await cycle(config, { pushLimit, pullLimit: 1000 }, {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async (_config, path, init) => {
      if (path === "/v1/capabilities") return capabilities;
      if (path === "/v1/messages" && init?.method === "POST") {
        posted = true;
        const body = JSON.parse(init.body);
        return { acks: body.messages.map((message, index) => ({ id: message.id, server_seq: String(index + 1), disposition: "stored" })) };
      }
      if (path.startsWith("/v1/messages?after=")) return { messages: [], next_after: "0", has_more: false };
      throw new Error(`unexpected request ${path}`);
    },
    driverCall: async (operation) => {
      if (operation === "prepare") return prepared;
      if (operation === "reconcile") { reconcileCalled = true; return [{ type: "sync_reconcile_result" }]; }
      if (operation === "apply") return [{ type: "sync_apply_result", transport_cursor: "0", corrupt_count: 0 }];
      throw new Error(`unexpected driver op ${operation}`);
    },
    evaluateCall: async () => ({ status: "imported" }),
    logApplyCall: async () => {},
    eventCall: async () => {},
    readStateCycleCall: async () => {},
  });
  return { result, posted, reconcileCalled };
}

test("cycle: pushSaturated is true only for an eligible, full push page (B2 wiring)", async () => {
  const full = await runCycleWithPush({ writeCiphers: ["none"], candidateCount: 2, pushLimit: 2 });
  assert.equal(full.result.pushSaturated, true);
  assert.equal(full.posted, true);
});

test("cycle: pushSaturated is false for an eligible short push page (B2 wiring)", async () => {
  const short = await runCycleWithPush({ writeCiphers: ["none"], candidateCount: 1, pushLimit: 2 });
  assert.equal(short.result.pushSaturated, false);
});

test("cycle: pushSaturated is false when the write profile is ineligible, even with a full-shaped page (B2 wiring)", async () => {
  // ["age-v1"] with no "none" makes the plaintext profile ineligible.
  const blocked = await runCycleWithPush({ writeCiphers: ["age-v1"], candidateCount: 2, pushLimit: 2 });
  assert.equal(blocked.result.pushSaturated, false);
  assert.equal(blocked.posted, false); // ineligible profile never POSTs
  assert.equal(blocked.reconcileCalled, false);
});

test("cycle: a batch that fails after prepare re-sends the same candidates and converges on duplicate acks (B3, design-mandated)", async () => {
  const capabilities = capsFor(["none"]);
  const candidateIds = ["550e8400-e29b-41d4-a716-000000000001", "550e8400-e29b-41d4-a716-000000000002"];
  let reconciled = false;
  let postAttempts = 0;
  let reconcileAcks = null;
  const postedIdsPerAttempt = [];
  const deps = {
    healthCall: async () => ({ server_instance_id: config.server_instance_id }),
    requestCall: async (_config, path, init) => {
      if (path === "/v1/capabilities") return capabilities;
      if (path === "/v1/messages" && init?.method === "POST") {
        postAttempts += 1;
        const body = JSON.parse(init.body);
        postedIdsPerAttempt.push(body.messages.map((message) => message.id));
        if (postAttempts === 1) { const error = new Error("network"); error.retryable = true; throw error; }
        return { acks: body.messages.map((message, index) => ({ id: message.id, server_seq: String(index + 1), disposition: "duplicate" })) };
      }
      if (path.startsWith("/v1/messages?after=")) return { messages: [], next_after: "0", has_more: false };
      throw new Error(`unexpected request ${path}`);
    },
    driverCall: async (operation, _config, input) => {
      if (operation === "prepare") {
        // The same candidates are offered until they are reconciled; a failed
        // POST leaves reconcile unrun, so the next cycle re-prepares them.
        return [{ type: "sync_state", driver_generation: "018f3f7e-0000-7000-8000-000000000099", transport_cursor: "0" },
          ...(reconciled ? [] : candidateIds.map((id, index) => ({ type: "sync_push_candidate",
            local_position: String(index + 1), id, envelope: { v: 1, cipher: "none", key_id: null, blob: "e30=" } })))];
      }
      if (operation === "reconcile") { reconciled = true; reconcileAcks = input; return [{ type: "sync_reconcile_result" }]; }
      if (operation === "apply") return [{ type: "sync_apply_result", transport_cursor: "0", corrupt_count: 0 }];
      throw new Error(`unexpected driver op ${operation}`);
    },
    evaluateCall: async () => ({ status: "imported" }),
    logApplyCall: async () => {},
    eventCall: async () => {},
    readStateCycleCall: async () => {},
  };
  // Cycle 1: POST fails after prepare -> cycle throws, reconcile is NOT run.
  await assert.rejects(() => cycle(config, { pushLimit: 100, pullLimit: 1000 }, deps), /network/);
  assert.equal(reconciled, false);
  // Cycle 2: the same candidates are re-prepared, the POST succeeds with
  // duplicate acks, and reconcile receives exactly those ids in order.
  await cycle(config, { pushLimit: 100, pullLimit: 1000 }, deps);
  assert.equal(postAttempts, 2);
  // Both attempts posted the SAME range of candidate ids (the "same range" the
  // design mandates), and reconcile received exactly those ids as duplicates.
  assert.deepEqual(postedIdsPerAttempt, [candidateIds, candidateIds]);
  assert.deepEqual(reconcileAcks.map((ack) => ack.id), candidateIds);
  assert.ok(reconcileAcks.every((ack) => ack.disposition === "duplicate"));
});
