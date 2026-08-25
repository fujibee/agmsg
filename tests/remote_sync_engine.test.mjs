import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readdirSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, readdir, rename, rm, stat, symlink, unlink,
  utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { readNativeAgeIdentity } from "../scripts/internal/sync-cipher.mjs";
import {
  ageSnapshotDigest,
  activateKeyRotations,
  authorityFileFault,
  authorityFileRemedy,
  shellQuote,
  describeChildExit,
  canonicalJson,
  consistentReadStateContext,
  configure,
  cycle,
  discardInputDirectory,
  driver,
  STORAGE_BUSY_EXIT,
  storageDriverExitGraceMs,
  exportAgeHandoff,
  exportAgeSnapshot,
  isRetryable,
  initialAgeSnapshot,
  isRefusal,
  collectInstallBaseline,
  installChangedAgainst,
  runLoop,
  loadConfig,
  nextLocalAgeSnapshot,
  plaintextWriteEligible,
  pullBootstrap,
  parseStrictJsonl,
  readStateCycle,
  rosterSequencesFor,
  readStateUpdateBatches,
  reprocessCycle,
  request,
  resyncCycle,
  retainAgeCheckpoint,
  rosterDriver,
  selectWriteProfile,
  setEndpoint,
  stage2ReadStateSupported,
  stage1ResyncSupported,
  validateAckMapping,
  validateAgeConfiguration,
  validateConfiguredAgeIdentities,
  validateCapabilities,
  validateErrorBinding,
  errorCode,
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
  // Each refusal names the condition that actually failed. This test used to
  // accept one sentence about permissions for all three, which is how a
  // Windows operator -- where the permission test does not run at all -- was
  // sent to look at modes for a symlink and for an oversized file (#781).
  await withConnectedCredential(async (root) => {
    await writeConnectedTeam(root);
    const path = join(root, "teams", "demo", "config.json");
    if (process.platform !== "win32") {
      await chmod(path, 0o666);
      await assert.rejects(loadConfig("demo"), /must not be writable by group or others/u);
      await unlink(path);
      const target = join(root, "binding-target.json");
      await writeConnectedTeam(root);
      await rename(path, target);
      await symlink(target, path);
      await assert.rejects(loadConfig("demo"), (error) =>
        // NEGATIVE CONTROL, and the whole point: a symlink must not be
        // reported as a permission problem. The old message did exactly that.
        /must not be a symbolic link/u.test(error.message) &&
        !/writable|group or others/u.test(error.message));
      await unlink(path);
      await rename(target, path);
    }
    await writeFile(path, "x".repeat(2 * 1024 * 1024 + 1), { mode: 0o644 });
    await assert.rejects(loadConfig("demo"), (error) =>
      /must not be larger than \d+ bytes/u.test(error.message) &&
      !/writable|symbolic link/u.test(error.message));
  });
});

test("a file fault names the condition that failed, and permissions last", () => {
  // Directly, because the ordering is the fix: the mode test is consulted only
  // after the others, so no message above it can be about permissions -- which
  // is what makes the win32 case (where it is never consulted) safe.
  const stats = (over = {}) => ({
    isSymbolicLink: () => false, isFile: () => true, size: 10, mode: 0o600, ...over,
  });
  assert.equal(authorityFileFault(stats(), { maxBytes: 100, privateFile: true }), null);
  assert.match(
    authorityFileFault(stats({ isSymbolicLink: () => true }), { maxBytes: 100 }),
    /symbolic link/u);
  assert.match(
    authorityFileFault(stats({ isFile: () => false }), { maxBytes: 100 }), /regular file/u);
  assert.match(
    authorityFileFault(stats({ size: 101 }), { maxBytes: 100 }), /larger than 100 bytes/u);
  // A symlink that is ALSO group-writable reports the symlink: the caller can
  // only act on one, and the one it can act on is the one that is true on
  // every platform.
  assert.match(
    authorityFileFault(stats({ isSymbolicLink: () => true, mode: 0o666 }), { maxBytes: 100 }),
    /symbolic link/u);
  if (process.platform !== "win32") {
    assert.match(
      authorityFileFault(stats({ mode: 0o666 }), { maxBytes: 100, privateFile: true }),
      /readable or writable by group or others/u);
    assert.match(
      authorityFileFault(stats({ mode: 0o666 }), { maxBytes: 100 }),
      /must not be writable by group or others/u);

    // The mode it HAS. #804: a machine that joined on an older version carries
    // a 0664 config, upgrading does not rewrite it, and the operator was told
    // which bits are forbidden without being told which ones are set.
    assert.match(
      authorityFileFault(stats({ mode: 0o664 }), { maxBytes: 100 }), /\(it is 0664\)/u);
    assert.match(
      authorityFileFault(stats({ mode: 0o666 }), { maxBytes: 100, privateFile: true }),
      /\(it is 0666\)/u);
    // Four digits, so it can be compared with `stat` output without arithmetic
    // -- and so a setuid bit shows up rather than being masked away.
    assert.match(
      authorityFileFault(stats({ mode: 0o4664 }), { maxBytes: 100 }), /\(it is 4664\)/u);
  }
});

test("the permission fault carries the command that clears it, and nothing else does", () => {
  const stats = (over = {}) => ({
    isSymbolicLink: () => false, isFile: () => true, size: 10, mode: 0o600, ...over,
  });
  if (process.platform === "win32") return;

  // The two faults a mode change fixes, and the two different remedies. `go-w`
  // for the binding and `go-rwx` for the credential: the checks differ, so the
  // commands do.
  assert.equal(authorityFileRemedy(stats({ mode: 0o664 }), {}), "chmod go-w");
  assert.equal(
    authorityFileRemedy(stats({ mode: 0o640 }), { privateFile: true }), "chmod go-rwx");

  // Nothing to type. Offering `chmod` for these would send someone to do the
  // wrong thing confidently, which is worse than saying less.
  assert.equal(authorityFileRemedy(stats({ isSymbolicLink: () => true, mode: 0o666 }), {}), null);
  assert.equal(authorityFileRemedy(stats({ isFile: () => false, mode: 0o666 }), {}), null);
  // Already correct: no fault, so no remedy.
  assert.equal(authorityFileRemedy(stats({ mode: 0o644 }), {}), null);
  assert.equal(authorityFileRemedy(stats({ mode: 0o600 }), { privateFile: true }), null);

  // The pair must agree. A remedy offered where there is no fault, or withheld
  // where there is one, is the drift this function pair exists to prevent --
  // the same drift #781 fixed between the sentence and the condition.
  for (const mode of [0o600, 0o640, 0o644, 0o660, 0o664, 0o666, 0o700, 0o777]) {
    for (const privateFile of [false, true]) {
      const fault = authorityFileFault(stats({ mode }), { maxBytes: 100, privateFile });
      const remedy = authorityFileRemedy(stats({ mode }), { privateFile });
      assert.equal(
        remedy !== null, fault !== null,
        `mode 0${mode.toString(8)} privateFile=${privateFile}: fault=${fault} remedy=${remedy}`);
    }
  }
});

test("the remedy we print is a command that runs, on a path that fights back", async () => {
  if (process.platform === "win32") return;

  // THE PRODUCTION ENTRY, not the pieces beside it. An earlier version of this
  // test built the command itself out of `authorityFileRemedy` and
  // `shellQuote` -- which proves those two work and says nothing about whether
  // the sentence production emits uses either. Deleting the `shellQuote` call
  // from both throw sites left it green. This drives `loadConfig`, takes the
  // message it actually throws, and cuts the command out of that.
  //
  // A team name may contain a space and a single quote -- lib/validate.sh
  // rejects only empty, `.`, `..`, `/`, `\\`, a leading `-`, and control
  // characters -- and the store sits under $HOME, which is outside our control
  // entirely.
  const root = await mkdtemp(join(tmpdir(), "agmsg-remedy-"));
  const previousConnection = process.env.AGMSG_SYNC_CONNECTION_DIR;
  const previousSkill = process.env.SKILL_DIR;
  try {
    const team = "a b's team";
    const dir = join(root, "teams", team);
    await mkdir(dir, { recursive: true });
    const target = join(dir, "config.json");
    const bystander = join(root, "bystander");
    await writeFile(target, JSON.stringify({ local_team: team }));
    await writeFile(bystander, "{}\n");
    await chmod(target, 0o664);
    await chmod(bystander, 0o664);

    process.env.AGMSG_SYNC_CONNECTION_DIR = root;
    delete process.env.SKILL_DIR;

    // The premise: production refuses this file, and says so with a command.
    // Without asserting it, a message that stopped offering one would leave the
    // rest of this test skipping quietly.
    let message = null;
    await assert.rejects(() => loadConfig(team), (error) => {
      message = error.message;
      return true;
    });
    assert.match(message, /must not be writable by group or others \(it is 0664\)/u);
    assert.ok(message.includes(" — fix it with: "), `no remedy offered: ${message}`);

    const command = message.split(" — fix it with: ")[1];
    const ran = spawnSync("sh", ["-c", command], { encoding: "utf8" });
    assert.equal(ran.status, 0, `printed command failed: ${command}\n${ran.stderr}`);

    const after = await stat(target);
    // It changed, into a mode the engine accepts, stated the way it states it.
    assert.notEqual(after.mode & 0o7777, 0o664);
    assert.equal(after.mode & 0o022, 0);
    assert.equal(authorityFileFault(after, { maxBytes: 100, privateFile: false }), null);
    // And only it. Unquoted, the command would have split at the space and been
    // about a different file, or about several.
    assert.equal((await stat(bystander)).mode & 0o7777, 0o664);
  } finally {
    if (previousConnection === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = previousConnection;
    if (previousSkill === undefined) delete process.env.SKILL_DIR;
    else process.env.SKILL_DIR = previousSkill;
    await rm(root, { recursive: true, force: true });
  }
});

test("shellQuote survives what the validator lets through", () => {
  if (process.platform === "win32") return;

  // Round-trip through a real shell rather than comparing to an expected
  // string: the question is what the pasting shell does with it, and an
  // expected-string assertion would only re-state the implementation.
  for (const value of [
    "/plain/path",
    "/with a space/config.json",
    "/with'a'quote/config.json",
    "/both it's here/config.json",
    "/$(touch pwned)/config.json",
    "/back\\slash/config.json",
  ]) {
    const out = spawnSync("sh", ["-c", `printf %s ${shellQuote(value)}`], { encoding: "utf8" });
    assert.equal(out.status, 0, `shell rejected ${shellQuote(value)}`);
    assert.equal(out.stdout, value, `did not round-trip: ${value}`);
  }
});

test("a driver failure names the binding, or says why it cannot be named", async () => {
  // THE PRODUCTION ENTRY, not the helper beside it: `driver()` resolves the
  // binding path itself, so this drives the same call a sync makes.
  //
  // Two cases, and the second is the one that was silent. `teamConfigPath`
  // throws without a connection root, and a caller that has none still has to
  // run -- so the run continues either way, and the difference is what the
  // failure message can say. Returning `undefined` and dropping the reason is
  // what #802 collects; reverting to it turns the second half of this red.
  const root = await mkdtemp(join(tmpdir(), "agmsg-binding-"));
  const previousDriver = process.env.AGMSG_SYNC_DRIVER;
  const previousConnection = process.env.AGMSG_SYNC_CONNECTION_DIR;
  const previousSkill = process.env.SKILL_DIR;
  try {
    const script = join(root, "driver.sh");
    // Exits non-zero with NOTHING on stderr, so the fallback diagnostic -- the
    // one that names the binding -- is the sentence under test.
    await writeFile(script, "#!/usr/bin/env bash\ncat > /dev/null\nexit 9\n", { mode: 0o755 });
    process.env.AGMSG_SYNC_DRIVER = script;
    const config = {
      local_team: "t", server_instance_id: "018f3f7e-0000-7000-8000-000000000001",
      remote_team_id: "018f3f7e-0000-7000-8000-000000000002", protocol_version: 1,
    };

    process.env.AGMSG_SYNC_CONNECTION_DIR = root;
    delete process.env.SKILL_DIR;
    await assert.rejects(() => driver("prepare", config, []), (error) =>
      error.message.includes(join(root, "teams", "t", "config.json")) &&
      /failed for team 't'/u.test(error.message));

    // No connection root: the path cannot be resolved. The run still reaches
    // the driver and still reports its exit -- and now says WHY there is no
    // path instead of quietly leaving the sentence short.
    delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    delete process.env.SKILL_DIR;
    await assert.rejects(() => driver("prepare", config, []), (error) =>
      /failed for team 't' \(exit 9\)/u.test(error.message) &&
      /its path could not be resolved: sync connection root is unavailable/u.test(error.message));
  } finally {
    if (previousDriver === undefined) delete process.env.AGMSG_SYNC_DRIVER;
    else process.env.AGMSG_SYNC_DRIVER = previousDriver;
    if (previousConnection === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = previousConnection;
    if (previousSkill === undefined) delete process.env.SKILL_DIR;
    else process.env.SKILL_DIR = previousSkill;
    if (!root.startsWith(tmpdir())) throw new Error("unsafe test root");
    await rm(root, { recursive: true, force: true });
  }
});

test("an unreadable age identity says which condition failed, and keeps the parser's own reason", async () => {
  // The real entry point, not a helper beside it. Reverting the change in
  // sync-cipher.mjs turns each of the first three red; the fourth is here to
  // pin what must NOT change -- the parser's own reason already survived the
  // catch on the base, and a fix that started routing it through the generic
  // sentence would be a regression this file would otherwise not notice.
  const root = await mkdtemp(join(tmpdir(), "agmsg-identity-"));
  try {
    const missing = join(root, "absent.key");
    assert.throws(() => readNativeAgeIdentity(missing), (error) =>
      /was not found/u.test(error.message) &&
      error.message.includes(missing) &&
      !/securely readable/u.test(error.message));

    const directory = join(root, "a-directory");
    await mkdir(directory);
    assert.throws(() => readNativeAgeIdentity(directory), (error) =>
      /must be a regular file/u.test(error.message) &&
      error.message.includes(directory) &&
      !/securely readable|group or others/u.test(error.message));

    const malformedPath = join(root, "malformed.key");
    await writeFile(malformedPath, "not an age key\nnor is this\n", { mode: 0o600 });
    assert.throws(() => readNativeAgeIdentity(malformedPath), (error) =>
      // The parser's own CipherStateError, unchanged: state "malformed", and
      // NOT the privacy sentence. This already held before this change.
      error.state === "malformed" && !/securely readable/u.test(error.message));

    if (process.platform !== "win32") {
      const loose = join(root, "loose.key");
      await writeFile(loose, "x\n", { mode: 0o666 });
      assert.throws(() => readNativeAgeIdentity(loose), (error) =>
        /readable or writable by group or others/u.test(error.message) &&
        error.message.includes(loose) &&
        !/regular file|was not found/u.test(error.message));
    }
  } finally {
    if (!root.startsWith(tmpdir())) throw new Error("unsafe test root");
    await rm(root, { recursive: true, force: true });
  }
});

test("the rename script says which condition failed, and names the file", async () => {
  // Driven as the script, because that is how it runs. A helper extracted for
  // the test would leave the file's own entry point unbound -- which is what
  // this test exists to stop.
  const root = await mkdtemp(join(tmpdir(), "agmsg-rename-"));
  try {
    const directory = join(root, "remote-sync");
    await mkdir(directory, { recursive: true });
    const source = join(directory, "old.json");
    const script = fileURLToPath(
      new URL("../scripts/internal/rename-sync-config.mjs", import.meta.url));
    const run = () => spawnSync(process.execPath, [script, root, "old", "new"], {
      encoding: "utf8",
    });

    await writeFile(join(root, "elsewhere.json"), "{}\n", { mode: 0o600 });
    await symlink(join(root, "elsewhere.json"), source);
    let result = run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must not be a symbolic link/u);
    assert.ok(result.stderr.includes(source), "the message names the file");
    assert.doesNotMatch(result.stderr, /group or others/u);
    await unlink(source);

    await mkdir(source);
    result = run();
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must be a regular file/u);
    assert.ok(result.stderr.includes(source), "the message names the file");
    assert.doesNotMatch(result.stderr, /symbolic link|group or others/u);
    await rm(source, { recursive: true });

    if (process.platform !== "win32") {
      await writeFile(source, "{}\n", { mode: 0o666 });
      result = run();
      assert.notEqual(result.status, 0);
      assert.match(result.stderr, /must not be readable or writable by group or others/u);
      assert.ok(result.stderr.includes(source), "the message names the file");
      assert.doesNotMatch(result.stderr, /symbolic link|must be a regular file/u);
    }
  } finally {
    if (!root.startsWith(tmpdir())) throw new Error("unsafe test root");
    await rm(root, { recursive: true, force: true });
  }
});

test("a child's ending is named by field, and an out-of-range code is decomposed", () => {
  assert.equal(describeChildExit(7, null), "exit 7");
  assert.equal(describeChildExit(0, "SIGTERM"), "signal SIGTERM");
  assert.equal(describeChildExit(null, null), "no exit status");
  // The reported case: 3840 arrived through `code` with no signal. Both
  // components are shown and NEITHER is asserted as the reading -- under the
  // POSIX encoding this is an exit status of 15, while the report that raised
  // it described a signal, and no one reproducing it has that platform.
  const decomposed = describeChildExit(3840, null);
  assert.match(decomposed, /exit 3840/u);
  assert.match(decomposed, /exit 15/u);
  assert.match(decomposed, /signal 0/u);
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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

test("roster sequences: the journal's roster_synced records for this binding, and nothing on a missing or torn journal (#968)", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-968-journal-"));
  try {
    const rosterFile = join(root, "teams", "demo", "config.json");
    await mkdir(dirname(rosterFile), { recursive: true });
    // No journal yet: no evidence, no sequences.
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile }), []);
    const other = "018f3f7e-0000-7000-8000-00000000ffff";
    await writeFile(join(root, "teams", "demo", "roster.jsonl"), [
      JSON.stringify({ type: "member_joined", id: "m1", name: "alice" }),
      JSON.stringify({ type: "roster_synced", mutation_id: "m1", server_seq: "2", wire_id: "w1",
        server_instance_id: config.server_instance_id, remote_team_id: config.remote_team_id }),
      JSON.stringify({ type: "roster_synced", mutation_id: "m0", server_seq: "1", wire_id: "w0",
        server_instance_id: config.server_instance_id, remote_team_id: config.remote_team_id }),
      // another binding's record is not this binding's evidence
      JSON.stringify({ type: "roster_synced", mutation_id: "mx", server_seq: "7", wire_id: "wx",
        server_instance_id: other, remote_team_id: config.remote_team_id }),
      // duplicate of seq 2 collapses
      JSON.stringify({ type: "roster_synced", mutation_id: "m1b", server_seq: "2", wire_id: "w1b",
        server_instance_id: config.server_instance_id, remote_team_id: config.remote_team_id }),
    ].join("\n"));
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile }), ["1", "2"]);
    // A torn journal (a line that is not JSON) yields nothing: a frontier is
    // never advanced on evidence that could not be read whole. And it is
    // NAMED, with the line, because a pinned frontier is also what #968
    // looked like -- a silent fallback would be indistinguishable from the bug.
    const events = [];
    const eventCall = async (name, fields) => { events.push({ name, ...fields }); };
    await writeFile(join(root, "teams", "demo", "roster.jsonl"),
      '{"type":"roster_synced","mutation_id":"m1","server_seq":"2","wire_id":"w1",' +
      `"server_instance_id":"${config.server_instance_id}","remote_team_id":"${config.remote_team_id}"}\n{"type":"roster_syn`);
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile, eventCall }), []);
    assert.equal(events.length, 1);
    assert.equal(events[0].name, "read-state.roster-journal-unreadable");
    assert.equal(events[0].line, 2);
    assert.match(events[0].path, /roster\.jsonl$/u);
    // A non-canonical sequence ("007") is corrupt evidence: the whole list is
    // withheld and the line named, not the one record skipped -- a journal
    // with one bad record is not a journal to take sequences from.
    events.length = 0;
    await writeFile(join(root, "teams", "demo", "roster.jsonl"), [
      JSON.stringify({ type: "roster_synced", mutation_id: "m0", server_seq: "1", wire_id: "w0",
        server_instance_id: config.server_instance_id, remote_team_id: config.remote_team_id }),
      JSON.stringify({ type: "roster_synced", mutation_id: "my", server_seq: "007", wire_id: "wy",
        server_instance_id: config.server_instance_id, remote_team_id: config.remote_team_id }),
    ].join("\n"));
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile, eventCall }), []);
    assert.equal(events.length, 1);
    assert.equal(events[0].line, 2);
    // A sequence outside the domain is corrupt evidence, treated the same way
    // (review finding: shape alone let 2^63..10^19-1 through).
    events.length = 0;
    await writeFile(join(root, "teams", "demo", "roster.jsonl"),
      JSON.stringify({ type: "roster_synced", mutation_id: "m1", server_seq: "9223372036854775808", wire_id: "w1",
        server_instance_id: config.server_instance_id, remote_team_id: config.remote_team_id }));
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile, eventCall }), []);
    assert.equal(events.length, 1);
    assert.equal(events[0].line, 1);
    assert.match(events[0].reason, /not a canonical sequence/u);
    // MAX itself is a legal sequence.
    events.length = 0;
    await writeFile(join(root, "teams", "demo", "roster.jsonl"),
      JSON.stringify({ type: "roster_synced", mutation_id: "m1", server_seq: "9223372036854775807", wire_id: "w1",
        server_instance_id: config.server_instance_id, remote_team_id: config.remote_team_id }));
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile, eventCall }), ["9223372036854775807"]);
    assert.equal(events.length, 0);
    // No journal at all is not an anomaly (no roster before the first pull): quiet.
    await rm(join(root, "teams", "demo", "roster.jsonl"));
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile, eventCall }), []);
    assert.equal(events.length, 0);
    // An unreadable journal (a directory in its place) IS named.
    await mkdir(join(root, "teams", "demo", "roster.jsonl"));
    assert.deepEqual(await rosterSequencesFor(config, { rosterFile, eventCall }), []);
    assert.equal(events.length, 1);
    assert.equal(events[0].reason, "EISDIR");
  } finally {
    await rm(root, { recursive: true });
  }
});

test("Stage-2 read-prepare carries the roster sequences into the context (#968)", async () => {
  const events = [];
  const harness = readStateHarness(threeMembers, ["masa-claude"], events);
  let contextSeen = null;
  const innerDriver = harness.driverCall;
  await readStateCycle(config, 100, {
    ...harness,
    driverCall: async (operation, cfg, input) => {
      if (operation === "read-prepare") contextSeen = input[0];
      return innerDriver(operation, cfg, input);
    },
    rosterSequencesCall: async () => ["1", "2"],
  });
  assert.ok(contextSeen, "read-prepare was called");
  assert.equal(contextSeen.type, "sync_read_context");
  assert.deepEqual(contextSeen.roster_seqs, ["1", "2"]);
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

// A freshly pulled machine says `0 member(s)` and cannot say it is waiting.
//
// The roster arrives as `member_joined` events in the message stream, so a
// machine that pulled before any connected engine pushed them has an empty
// roster and no way to know one is outstanding. Meanwhile this same loop logs
// `read-state.applied ... "member_count":3` every few seconds -- read cursors
// for three members, not a roster of three -- which is what sent both the
// reporter and the first person to trace it the wrong way (#743).
const readStateHarness = (members, localAgents, events) => {
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, min_available_seq: "0", current_seq: "0",
    next_sequence_boundary: "1", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1], write_allowed_ciphers: ["none"] }],
  };
  return {
    driverCall: async (operation) => {
      if (operation === "capabilities") return [{ type: "sync_driver_capabilities",
        capabilities: ["stage1-sync", "stage2-read-state"] }];
      if (operation === "read-prepare") return members.map((member) => ({
        type: "sync_read_frontier", member_id: member.member_id, server_seq: "0" }));
      if (operation === "read-apply") {
        // The line that misleads, reproduced verbatim: the storage driver is
        // reporting read state FOR three members, and says so with a field
        // named exactly like a roster count.
        return [{ type: "sync_read_apply_result", min_available_seq: "0",
          member_count: members.length }];
      }
      throw new Error(`unexpected driver operation ${operation}`);
    },
    requestCall: async (_config, path) => {
      if (path === "/v1/capabilities") return capabilities;
      if (path === "/v1/members") return { protocol_version: 1,
        server_instance_id: config.server_instance_id, team_id: config.remote_team_id,
        min_available_seq: "0", members_revision: "0",
        members: members.map((member) => ({ ...member, registrations: [] })) };
      return { protocol_version: 1, server_instance_id: config.server_instance_id,
        team_id: config.remote_team_id, min_available_seq: "0", current_seq: "0",
        items: members.map((member) => ({ kind: "frontier",
          member_id: member.member_id, server_seq: "0" })),
        next_page_after: null, has_more: false };
    },
    eventCall: async (name, value) => { events.push([name, value]); },
    localAgentsCall: async () => localAgents,
  };
};

const threeMembers = [
  { member_id: "018f3f7e-0000-7000-8000-000000000010", name: "masa-claude" },
  { member_id: "018f3f7e-0000-7000-8000-000000000020", name: "masa-codex" },
  { member_id: "018f3f7e-0000-7000-8000-000000000030", name: "masa-grok" },
];

test("read-state names the members the local roster has not materialised", async () => {
  const events = [];
  await readStateCycle(config, 100, readStateHarness(threeMembers, [], events));
  const incomplete = events.filter(([name]) => name === "roster.incomplete");
  assert.equal(incomplete.length, 1);
  // The names, not just a count: an agent about to choose its own name needs to
  // know which are taken, which is the whole reason this step exists.
  assert.deepEqual(incomplete[0][1], {
    server_members: 3, local_members: 0,
    missing: ["masa-claude", "masa-codex", "masa-grok"],
  });
  // And it sits beside the line that reads like the roster already arrived.
  assert.ok(events.some(([name, value]) =>
    name === "read-state.applied" && value.result.member_count === 3));
});

test("read-state reports a partial roster, not only an empty one", async () => {
  const events = [];
  await readStateCycle(config, 100,
    readStateHarness(threeMembers, ["masa-claude", "masa-grok"], events));
  const incomplete = events.filter(([name]) => name === "roster.incomplete");
  assert.equal(incomplete.length, 1);
  assert.deepEqual(incomplete[0][1],
    { server_members: 3, local_members: 2, missing: ["masa-codex"] });
});

test("read-state stays quiet once the roster has caught up", async () => {
  const events = [];
  await readStateCycle(config, 100, readStateHarness(threeMembers,
    threeMembers.map((member) => member.name), events));
  // A converged machine must not log a standing complaint every few seconds --
  // a warning that never clears is one people learn to scroll past.
  assert.deepEqual(events.filter(([name]) => name === "roster.incomplete"), []);
  // A local-only name is this machine's own, not a gap in the other direction.
  const extra = [];
  await readStateCycle(config, 100, readStateHarness(threeMembers,
    [...threeMembers.map((member) => member.name), "masa-mini"], extra));
  assert.deepEqual(extra.filter(([name]) => name === "roster.incomplete"), []);
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

test("an error that carries no binding is reported as itself, not as a mismatch", () => {
  // The allowlist was {400,401,426}, so everything else went through
  // validateBinding — which compares body.team_id, `undefined` in an ordinary
  // error body. Every 403, 404, 409 and 500 therefore arrived as "server/team
  // binding mismatch": the one message meaning "you are talking to the wrong
  // team" stood in for forbidden, missing, conflicting, and crashed alike.
  //
  // Whether a body carries a binding is the real question, so that is what is
  // asked. Statuses listed explicitly rather than looped from a range: each one
  // is a diagnosis a caller acts on differently.
  for (const status of [403, 404, 409, 500]) {
    assert.doesNotThrow(
      () => validateErrorBinding(config, status, { error: { code: "some-server-error" } }),
      `status ${status} must not be reported as a binding mismatch`,
    );
  }
  // A PARTIAL binding is still a binding claim, and the partial one is what
  // matters: a body with only protocol_version reached validateBinding under the
  // allowlist and was refused for the missing pair. Triggering on two of the
  // three fields would have let it through — the inversion loosening a path
  // instead of tightening it. The value being the correct 1 is the sharp case:
  // it is right, and the rest is still missing.
  for (const status of [403, 500]) {
    assert.throws(() => validateErrorBinding(config, status, {
      protocol_version: 1, error: { code: "partial-binding" },
    }), /binding mismatch/u, `status ${status} with only protocol_version must be refused`);
  }
  // But protocol_version is not itself an identity claim — every well-formed
  // reply carries one, including an ordinary 401. Treating it as one everywhere
  // would turn "your credential was rejected" back into "binding mismatch",
  // which is the bug this whole change exists to remove.
  assert.doesNotThrow(() => validateErrorBinding(config, 401, {
    protocol_version: 1, error: { code: "unauthenticated" },
  }));
  // Presence is the trigger, so a mismatched binding on a status the old
  // allowlist skipped is now caught rather than waved through.
  assert.throws(() => validateErrorBinding(config, 400, {
    protocol_version: 1,
    server_instance_id: "018f3f7e-0000-7000-8000-000000000099",
    team_id: config.remote_team_id,
    error: { code: "bad-request" },
  }), /binding mismatch/u);
});

test("a masked 500 becomes retryable again", () => {
  // Not a side effect — the point. While validateBinding swallowed it, the
  // caller never built the Error that carries `status`, and isRetryable saw
  // `undefined`: a 500 was treated as permanent even though it is in the
  // retryable set. Passing the body through restores that.
  assert.doesNotThrow(() =>
    validateErrorBinding(config, 500, { error: { code: "internal" } }));
  const escalated = Object.assign(new Error("HTTP 500 internal"), { status: 500 });
  assert.equal(isRetryable(escalated), true);
  // And the mismatch itself stays permanent: retrying a wrong-team binding
  // would just repeat it.
  assert.equal(isRetryable(new Error("server/team binding mismatch")), false);
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

test("send collapses an out-of-shape server error code in the message, keeping code and body raw", async () => {
  // The message reaches raw sinks (the daemon logfile via main()'s stderr
  // write, the operator's terminal on foreground subcommands), so it may only
  // carry a code in the protocol's own shape (#729, same boundary as
  // publicGet's #726/#728). error.code / error.body feed the JSON-escaped
  // event lines and keep the server's actual value -- collapsing those too
  // would blind the push.oversized/cycle.error diagnostics.
  const previousFetch = globalThis.fetch;
  try {
    await withConnectedCredential(async () => {
      // Control bytes plus the exact substring remote.sh's unlock readiness
      // probe greps for -- the raw-stderr injection this boundary exists to stop.
      const evil = 'boom\u001b[2J\n"event":"capabilities"';
      globalThis.fetch = async () => new Response(JSON.stringify({ error: { code: evil } }), {
        status: 400, headers: { "Agmsg-Protocol-Version": "1" },
      });
      await assert.rejects(request({ ...config, server_url: "https://sync.example" }, "/v1/messages"),
        (error) => error.message === "HTTP 400 unknown-error" &&
          error.code === evil && error.body?.error?.code === evil);
      // A code in the protocol's own shape passes through untouched.
      globalThis.fetch = async () => new Response(JSON.stringify({ error: { code: "not-found" } }), {
        status: 404, headers: { "Agmsg-Protocol-Version": "1" },
      });
      await assert.rejects(request({ ...config, server_url: "https://sync.example" }, "/v1/messages"),
        (error) => error.message === "HTTP 404 not-found" && error.code === "not-found");
      // The hosted edge's snake_case bridge code: collapsed in the raw-sink
      // message, preserved on error.code for the event readers (the split the
      // push.oversized detail test pins from the other side).
      globalThis.fetch = async () => new Response(JSON.stringify({ error: "payload_too_large" }), {
        status: 413, headers: { "Agmsg-Protocol-Version": "1" },
      });
      await assert.rejects(request({ ...config, server_url: "https://sync.example" }, "/v1/messages"),
        (error) => error.message === "HTTP 413 unknown-error" && error.code === "payload_too_large");
    });
  } finally {
    globalThis.fetch = previousFetch;
  }
});

test("set-endpoint aligns the stored sync config's server_url with the moved binding (#718)", async () => {
  // remote.sh moves the binding's endpoint only after the new address proved
  // it is the same server instance. This subcommand then aligns the OTHER
  // place that pins the address -- the stored sync config, whose server_url
  // loadConfig requires to match the binding -- re-verifying the identity
  // end to end against the new address before anything is written.
  const root = await mkdtemp(join(tmpdir(), "agmsg-set-endpoint-"));
  const saved = { connection: process.env.AGMSG_SYNC_CONNECTION_DIR,
    storage: process.env.AGMSG_SYNC_STORAGE_DIR };
  const previousFetch = globalThis.fetch;
  const storedPath = join(root, "store", "remote-sync", "demo.json");
  try {
    process.env.AGMSG_SYNC_CONNECTION_DIR = root;
    process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "store");
    const teamDir = join(root, "teams", "demo");
    await mkdir(teamDir, { recursive: true });
    await writeFile(join(teamDir, "config.json"), `${JSON.stringify({ name: "demo",
      remote_binding: { endpoint: "https://moved.example",
        server_instance_id: config.server_instance_id,
        remote_team_id: config.remote_team_id, protocol_version: 1,
        capabilities: { write_allowed_ciphers: ["none"] },
        cipher_profile: "none", connected_at: "2026-07-29T00:00:00Z",
        disconnected_at: null } })}\n`);
    const stored = { format_version: 1, local_team: "demo",
      server_url: "http://127.0.0.1:8787",
      server_instance_id: config.server_instance_id,
      remote_team_id: config.remote_team_id, protocol_version: 1,
      cipher_profile: "none",
      local_security_history: [{ local_security_revision: "0",
        effective_from_seq: "1", minimum_security_mode: "plaintext-allowed" }] };
    await mkdir(join(root, "store", "remote-sync"), { recursive: true });
    await writeFile(storedPath, JSON.stringify(stored));
    const capabilities = { protocol_version: 1,
      server_instance_id: config.server_instance_id,
      team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
      current_seq: "0", next_sequence_boundary: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
      max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
        effective_from_seq: "1", accepted_envelope_versions: [1],
        write_allowed_ciphers: ["none"] }] };
    let fetchedUrl = null;
    globalThis.fetch = async (url) => {
      fetchedUrl = String(url);
      return new Response(JSON.stringify(capabilities), { status: 200,
        headers: { "Agmsg-Protocol-Version": "1" } });
    };
    await setEndpoint({ team: "demo" });
    // The identity was re-proved against the NEW address, then written.
    assert.match(fetchedUrl, /^https:\/\/moved\.example\//u);
    const rewritten = JSON.parse(await readFile(storedPath, "utf8"));
    assert.equal(rewritten.server_url, "https://moved.example");
    assert.equal(rewritten.server_instance_id, config.server_instance_id);

    // A stored config that is not this binding's connection: refused, and the
    // file keeps its old address -- no unverified path to the write.
    await writeFile(storedPath, JSON.stringify({ ...stored,
      server_instance_id: "018f3f7e-9999-7000-8000-00000000000f" }));
    await assert.rejects(setEndpoint({ team: "demo" }), /does not belong/u);
    assert.equal(JSON.parse(await readFile(storedPath, "utf8")).server_url,
      "http://127.0.0.1:8787");

    // No stored config at all (plain teams): a recorded no-op that must not
    // materialise one.
    await rm(storedPath);
    await setEndpoint({ team: "demo" });
    await assert.rejects(readFile(storedPath, "utf8"), /ENOENT/u);
  } finally {
    globalThis.fetch = previousFetch;
    if (saved.connection === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = saved.connection;
    if (saved.storage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
    else process.env.AGMSG_SYNC_STORAGE_DIR = saved.storage;
    await rm(root, { recursive: true });
  }
});

test("set-endpoint cannot land a stale alignment over a newer move (#739 interleave)", async () => {
  // The review's interleave: A verifies a move to X and stalls in the
  // capabilities request; B moves the binding on to Y (revision advanced) and
  // completes its own alignment; A resumes. A's write must refuse -- the
  // binding it verified is no longer the binding -- and B's completed pair
  // must survive. The guard is the lock-held re-read of endpoint+revision.
  const root = await mkdtemp(join(tmpdir(), "agmsg-set-endpoint-race-"));
  const saved = { connection: process.env.AGMSG_SYNC_CONNECTION_DIR,
    storage: process.env.AGMSG_SYNC_STORAGE_DIR };
  const previousFetch = globalThis.fetch;
  const storedPath = join(root, "store", "remote-sync", "demo.json");
  const teamCfgPath = join(root, "teams", "demo", "config.json");
  const bindingFor = (endpoint, revision) => ({ name: "demo", remote_binding: {
    endpoint, server_instance_id: config.server_instance_id,
    remote_team_id: config.remote_team_id, protocol_version: 1,
    capabilities: { write_allowed_ciphers: ["none"] }, cipher_profile: "none",
    connected_at: "2026-07-29T00:00:00Z", disconnected_at: null,
    binding_revision: revision } });
  try {
    process.env.AGMSG_SYNC_CONNECTION_DIR = root;
    process.env.AGMSG_SYNC_STORAGE_DIR = join(root, "store");
    await mkdir(join(root, "teams", "demo"), { recursive: true });
    await mkdir(join(root, "store", "remote-sync"), { recursive: true });
    await writeFile(teamCfgPath, `${JSON.stringify(bindingFor("https://x.example", 2))}\n`);
    const stored = { format_version: 1, local_team: "demo",
      server_url: "https://o.example",
      server_instance_id: config.server_instance_id,
      remote_team_id: config.remote_team_id, protocol_version: 1,
      cipher_profile: "none",
      local_security_history: [{ local_security_revision: "0",
        effective_from_seq: "1", minimum_security_mode: "plaintext-allowed" }] };
    await writeFile(storedPath, JSON.stringify(stored));
    const capabilities = { protocol_version: 1,
      server_instance_id: config.server_instance_id,
      team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
      current_seq: "0", next_sequence_boundary: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
      max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
        effective_from_seq: "1", accepted_envelope_versions: [1],
        write_allowed_ciphers: ["none"] }] };
    const respond = () => new Response(JSON.stringify(capabilities), { status: 200,
      headers: { "Agmsg-Protocol-Version": "1" } });
    let releaseFetch = null;
    globalThis.fetch = () => new Promise((resolveFetch) => {
      releaseFetch = () => resolveFetch(respond());
    });
    const stale = setEndpoint({ team: "demo" }); // A: verifying the move to X
    const staleOutcome = stale.catch((error) => error);
    while (releaseFetch === null) await new Promise((r) => setTimeout(r, 5));
    // B: moves the binding on to Y and completes its own alignment.
    await writeFile(teamCfgPath, `${JSON.stringify(bindingFor("https://y.example", 3))}\n`);
    await writeFile(storedPath, JSON.stringify({ ...stored, server_url: "https://y.example" }));
    releaseFetch();
    const outcome = await staleOutcome;
    assert.match(String(outcome?.message), /moved while this alignment was verifying/u);
    // B's completed pair survived A's stale write attempt.
    assert.equal(JSON.parse(await readFile(storedPath, "utf8")).server_url, "https://y.example");
    // And the lock was released on the refusal path: a fresh run against the
    // current binding completes (stored already matches -> recorded no-op).
    globalThis.fetch = async () => respond();
    await setEndpoint({ team: "demo" });
  } finally {
    globalThis.fetch = previousFetch;
    if (saved.connection === undefined) delete process.env.AGMSG_SYNC_CONNECTION_DIR;
    else process.env.AGMSG_SYNC_CONNECTION_DIR = saved.connection;
    if (saved.storage === undefined) delete process.env.AGMSG_SYNC_STORAGE_DIR;
    else process.env.AGMSG_SYNC_STORAGE_DIR = saved.storage;
    await rm(root, { recursive: true });
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

test("the roster driver that stops reading its input is left to release its own lock",
  { timeout: 30_000 }, async (t) => {
  // This was a test about EPIPE. The parent wrote the input down a pipe, a
  // driver that had stopped reading took the write's error, and the call
  // answered by SIGKILLing that driver -- which is the one thing it must not do.
  // roster-sync-driver.sh takes the team's registry lock as its first act and
  // holds it for the whole call, and its only release routes are traps. SIGKILL
  // runs none of them, so the fast failure was bought by leaving `.config.lock`
  // behind with no owner, and every later run for that team then waits on a
  // directory nobody is going to remove.
  //
  // So the fixture now takes a lock the way the driver does -- a directory,
  // released from an EXIT trap -- and stops reading its input while still
  // holding it. It keeps the background descendant that holds the inherited
  // pipes, which is what a real driver starting a helper leaves and the reason
  // 'close' never arrives, but it ends itself rather than sleeping past the
  // test: nothing here may pass by waiting, and nothing may hang.
  //
  // The payload is past any platform's pipe buffer (64 KiB on Linux, less on
  // macOS): under the old code the write could not complete unread, which is
  // what made it fail there.
  //
  // Measured against the previous implementation this test fails -- the driver
  // is killed about 20ms in and the trap never runs. What it costs is the fast
  // failure: the call now waits for the driver to end instead of ending it.
  // That trade is deliberate, and bounding a driver that HANGS is separate work
  // that is not done here.
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-lock-"));
  const lockFor = (pidFile) => `${pidFile}.lock`;
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
sleep 300 &
echo $! > ${JSON.stringify(helperFile)}
mkdir ${JSON.stringify(lockFor(pidFile))} || exit 1
trap 'rmdir ${JSON.stringify(lockFor(pidFile))} 2>/dev/null' EXIT
exec 0<&-
sleep 2
exit 7
`;
  const wide = "x".repeat(4096);
  const input = Array.from({ length: 512 }, (_, index) => ({ type: "probe", index, wide }));
  // The ROSTER driver only. It is the one that holds the lock, and it is the
  // only one handed a staged file; the storage driver keeps its pipe and is
  // covered by the test below, with the expectations it always had.
  const { started, gone } = await withDriverEnvironment(t, root, script,
    (mock, config) => [
      () => rosterDriver("apply", config, input),
    ]);

  for (const [index, { promise, childPid }] of started.entries()) {
    // The call still fails, but through the ordinary route -- the driver's own
    // exit status -- rather than through a write whose reader went away. Both
    // halves are asserted: a rejection carrying the stdin-write marker would
    // mean the pipe write came back, and that marker is set in exactly one
    // place, so it cannot be satisfied by accident.
    await assert.rejects(() => promise,
      (error) => error.driverFailurePhase === undefined &&
        /exit/iu.test(String(error.message)));
    // No poll and no grace period. The call settles only after the driver has
    // exited, so by this line it is already gone.
    assert.ok(gone(childPid), "the failed driver was left running");
    // The property this test exists for.
    assert.ok(!existsSync(lockFor(join(root, `child-${index}.pid`))),
      "the driver was killed before its trap could release the lock");
  }
});

test("the storage driver that stops reading its input fails through its exit code, not the broken write",
  { timeout: 30_000 }, async (t) => {
  // The storage driver keeps its pipe: after evaluatePull() its input is
  // decrypted message content, on E2EE teams as much as plain ones, and a pipe
  // is what keeps that off disk. So a large page can lose its reader when the
  // driver exits before the whole page is written -- a busy `apply` waits out
  // its timeout and exits 11 while the parent is still writing -- and the write
  // comes back EPIPE (macOS: ENOTCONN or EPIPE, the errno set is not closed).
  //
  // That EPIPE is a symptom of the exit, not a verdict on the call. Concluding
  // "stdin-write failed" on it, ahead of the exit, is what masked a retryable
  // busy 11 as an unrecoverable error and ended #910's reprocess. So the call
  // must report the CHILD'S EXIT CODE: here a plain non-zero (7), asserted to
  // arrive as `driverExitCode` with no `driverFailurePhase` verdict in front of
  // it -- which is exactly what lets `driver` see an 11 and retry it. The busy
  // 11 -> retry path itself is covered by "driver() waits out a busy store".
  //
  // The trade this makes explicit: a driver that stops reading AND never exits
  // is no longer failed at once -- the call waits for its exit, the same trade
  // the roster (staged) path already makes above. Bounding a driver that hangs
  // without exiting is separate work, not done here; this driver exits.
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-epipe-"));
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
sleep 300 &
echo $! > ${JSON.stringify(helperFile)}
exec 0<&-
exit 7
`;
  const wide = "x".repeat(4096);
  const input = Array.from({ length: 512 }, (_, index) => ({ type: "probe", index, wide }));
  const { started, gone } = await withDriverEnvironment(t, root, script,
    (mock, config) => [
      () => driver("prepare", config, input, ["1"]),
    ]);

  for (const { promise, childPid } of started) {
    // The exit code won, and the EPIPE marker did not get in front of it. Both
    // are asserted: a rejection still carrying `stdin-write` would mean the old
    // premature verdict came back, and that marker is set in exactly one place,
    // so it cannot be satisfied by accident.
    await assert.rejects(() => promise,
      (error) => error.driverFailurePhase === undefined &&
        error.driverExitCode === 7 && /exit 7/u.test(String(error.message)));
    // The call settles only after the driver has exited, so by this line it is
    // already gone -- and it was NOT killed to get there.
    assert.ok(gone(childPid), "the failed driver was left running");
  }
});

test("a clean exit after a broken write is not a truncated success", { timeout: 30_000 }, async (t) => {
  // The order-independent half of the fix. A driver that reads a little of a
  // large page and then exits 0 leaves the parent's write without a reader --
  // EPIPE -- while the child's status is a success. The call must NOT report
  // that as a synced page: the child never received the rest. Whichever of
  // 'exit' (code 0) and the stdin error is seen first, the write error is what
  // settles it. Without the close-handler's fail-closed check this rejects only
  // when the exit is seen after the error, and passes as an empty success when
  // the clean exit is seen first -- so this pins the case that used to slip.
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-trunc-"));
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
sleep 300 &
echo $! > ${JSON.stringify(helperFile)}
head -c 50 >/dev/null
exit 0
`;
  const wide = "x".repeat(4096);
  const input = Array.from({ length: 512 }, (_, index) => ({ type: "probe", index, wide }));
  const { started } = await withDriverEnvironment(t, root, script,
    (mock, config) => [
      () => driver("prepare", config, input, ["1"]),
    ]);
  for (const { promise } of started) {
    await assert.rejects(() => promise,
      (error) => error.driverFailurePhase === "stdin-write");
  }
});

test("the storage driver exit grace is bounded above so a huge busy timeout cannot overflow the timer", () => {
  // setTimeout clamps a delay past its 32-bit millisecond limit to 1 ms, which
  // would kill a busy child almost at once -- so a safe integer past that limit
  // must not pass through. The env carries the storage busy timeout; the grace
  // is it plus slack, or the default when it is unusable.
  const TIMER_MAX = 2 ** 31 - 1;
  assert.equal(storageDriverExitGraceMs(undefined), 10000);           // default 5 s + slack
  // Empty means the same 5 s default the child reads from ${...:-5000}, NOT
  // Number("") === 0 -- otherwise the grace would equal the child's busy timeout
  // and the kill would race a busy exit 11.
  assert.equal(storageDriverExitGraceMs(""), 10000);
  assert.equal(storageDriverExitGraceMs("500"), 5500);                // the test value used below
  assert.equal(storageDriverExitGraceMs("5000"), 10000);              // default busy timeout
  for (const unusable of ["oops", "-1", "1.5", "9007199254740991", String(TIMER_MAX)]) {
    const grace = storageDriverExitGraceMs(unusable);
    assert.equal(grace, 10000, `${unusable} did not fall back to the default`);
    assert.ok(grace < TIMER_MAX, "grace must stay under the timer limit");
  }
  // The largest accepted busy timeout (one hour) is still well under the limit.
  assert.equal(storageDriverExitGraceMs("3600000"), 3605000);
  assert.ok(storageDriverExitGraceMs("3600000") < TIMER_MAX);
  assert.equal(storageDriverExitGraceMs("3600001"), 10000);           // over the cap -> default
});

test("the storage driver that stops reading AND never exits is still bounded and killed",
  { timeout: 30_000 }, async (t) => {
  // The other side of deferring to the exit code: a driver that loses the write
  // AND does not exit must not hang the call forever. The pipe path keeps its
  // SIGKILL bound for exactly this -- a timer past the busy timeout gives a real
  // (busy) child every chance to exit on its own, and only a child that takes
  // neither route is killed. Its failure carries the stdin-write marker, since
  // that is the only thing this child ever told us.
  //
  // AGMSG_BUSY_TIMEOUT is set low so the grace (timeout + slack) is a few
  // seconds, not the default ten: this is the one child the timer is allowed to
  // wait for, and there is no reason to make the suite wait the whole default.
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-hang-"));
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
sleep 300 &
echo $! > ${JSON.stringify(helperFile)}
exec 0<&-
exec sleep 300
`;
  const wide = "x".repeat(4096);
  const input = Array.from({ length: 512 }, (_, index) => ({ type: "probe", index, wide }));
  const previousBusy = process.env.AGMSG_BUSY_TIMEOUT;
  process.env.AGMSG_BUSY_TIMEOUT = "500";
  t.after(() => {
    if (previousBusy === undefined) delete process.env.AGMSG_BUSY_TIMEOUT;
    else process.env.AGMSG_BUSY_TIMEOUT = previousBusy;
  });
  const { started, gone } = await withDriverEnvironment(t, root, script,
    (mock, config) => [
      () => driver("prepare", config, input, ["1"]),
    ]);

  for (const { promise, childPid } of started) {
    // The bound fired: the marker is the child's only signal, and the driver was
    // killed rather than waited for without end.
    await assert.rejects(() => promise,
      (error) => error.driverFailurePhase === "stdin-write");
    assert.ok(gone(childPid), "the hung driver was left running past the bound");
  }
});

test("a driver is handed its whole input, from the start of it",
  { timeout: 30_000 }, async (t) => {
  // The input is staged in a file and that file's descriptor is handed over as
  // the child's stdin. Two ways that goes silently wrong, and neither one
  // announces itself -- the driver reads a short input or an empty one and
  // reports a perfectly successful sync of nothing:
  //
  //   - the descriptor the write used is passed on, and it sits at EOF
  //   - the file is still being written when the child starts reading
  //
  // So the driver counts what it actually received and the count is asserted
  // against what was sent. A payload well past any pipe buffer, because a small
  // one is delivered correctly by almost any mistake.
  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-input-"));
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
echo $$ > ${JSON.stringify(helperFile)}
lines=$(wc -l)
printf '{"lines":%d}\\n' "$lines"
`;
  const wide = "x".repeat(4096);
  const RECORDS = 512;
  const input = Array.from({ length: RECORDS },
    (_, index) => ({ type: "probe", index, wide }));
  const { started } = await withDriverEnvironment(t, root, script,
    (mock, config) => [
      () => driver("prepare", config, input, ["1"]),
      () => rosterDriver("apply", config, input),
    ]);

  for (const { promise } of started) {
    const result = await promise;
    assert.equal(result[0]?.lines, RECORDS,
      "the driver did not receive every record that was sent");
  }
});

test("a staged input leaves nothing behind, whether the call succeeds or fails",
  { timeout: 30_000 }, async (t) => {
  // What is staged is message content, so the temp directory is not a tidiness
  // matter. Two routes have to be checked and neither is the interesting one:
  // it is the DULL paths that leak, because the failure path is the one people
  // write cleanup for.
  //
  // Counted by name in the system temp directory rather than by watching the
  // implementation, so a future change of mechanism is still measured. The
  // baseline is taken first: this is a shared directory and something else may
  // already have left one, and asserting zero would be asserting about the
  // machine rather than about this call.
  const residue = async () => (await readdir(tmpdir()))
    .filter((entry) => entry.startsWith("agmsg-driver-input-")).length;
  const before = await residue();

  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-residue-"));
  const input = Array.from({ length: 8 }, (_, index) => ({ type: "probe", index }));

  const ok = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
echo $$ > ${JSON.stringify(helperFile)}
cat > /dev/null
printf '{"ok":true}\\n'
`;
  // Repeated, and counted on descriptors as well as directories, because the
  // ORDINARY path is the one that matters most here: this runs every sync
  // cycle for the life of the engine. On this platform the file is already
  // unlinked by settle time, so a settle that forgot to release would leave no
  // directory at all and leak one descriptor per cycle -- invisible to a
  // directory count, and fatal over a long run.
  const descriptors = () => {
    try { return readdirSync("/dev/fd").length; } catch { return null; }
  };
  // Sequential, and driven directly rather than through the pid fixture. That
  // fixture waits for every driver to record a pid before it returns, and 24
  // bash processes at once is a lot to ask of a Windows runner -- a timeout
  // there would fail this test for the runner's speed rather than for a leak,
  // which is the wrong thing for it to be sensitive to.
  const okDriver = join(root, "ok-driver.sh");
  await writeFile(okDriver,
    "#!/usr/bin/env bash\ncat > /dev/null\nprintf '{\"ok\":true}\\n'\n",
    { mode: 0o700 });
  const previousRosterDriver = process.env.AGMSG_SYNC_ROSTER_DRIVER;
  process.env.AGMSG_SYNC_ROSTER_DRIVER = okDriver;
  t.after(() => {
    if (previousRosterDriver === undefined) delete process.env.AGMSG_SYNC_ROSTER_DRIVER;
    else process.env.AGMSG_SYNC_ROSTER_DRIVER = previousRosterDriver;
  });
  const config = {
    local_team: "residue", server_instance_id: "018f0000-0000-7000-8000-000000000001",
    remote_team_id: "018f0000-0000-7000-8000-000000000002", protocol_version: 1,
  };
  const openBefore = descriptors();
  for (let attempt = 0; attempt < 24; attempt += 1) {
    await rosterDriver("apply", config, input);
  }
  assert.equal(await residue(), before, "a successful call left its input behind");
  if (openBefore !== null) {
    // A bound, not equality: this process has descriptors of its own. Twenty-
    // four is not a margin.
    assert.ok(descriptors() < openBefore + 12,
      `successful calls leaked descriptors: ${openBefore} -> ${descriptors()}`);
  }

  const bad = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-residue-"));
  const fails = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
echo $$ > ${JSON.stringify(helperFile)}
echo "refused" >&2
exit 9
`;
  const { started: broken } = await withDriverEnvironment(t, bad, fails,
    (mock, config) => [() => rosterDriver("apply", config, input)]);
  for (const { promise } of broken) await assert.rejects(() => promise);
  assert.equal(await residue(), before, "a failed call left its input behind");

  // The third route, and the one nothing else here reaches: the spawn itself
  // fails. It is staged by then -- the input is written before the spawn, on
  // purpose -- so this is the window where the descriptor and, on Windows, a
  // named file of message content have no owner at all. A synchronous spawn
  // failure never reaches 'error', so the settle path that cleans up after
  // every other route is not on this one.
  //
  // Forced through the arguments rather than through the environment: a NUL in
  // an argument is rejected by spawn() before it does anything, which is a
  // synchronous throw and not an ENOENT the runner would answer later.
  // Called directly, without the driver fixture: nothing is started, so there
  // is no pid for that helper to wait on, and the driver script is never read
  // because the spawn does not get that far.
  // On this platform the directory count cannot see this route at all, and
  // saying so is the point: the name is taken away at handover, so what a
  // spawn failure strands here is the DESCRIPTOR, not a directory. Windows,
  // where the file cannot be unlinked while open, is the other way round --
  // there the directory assertion above is the one that catches it, which is
  // why this test runs in the focused Windows leg too.
  //
  // So the descriptor is counted, and the route is run enough times that one
  // leaked per call is unmistakable rather than lost in noise.
  const spawnOpenBefore = descriptors();
  for (let attempt = 0; attempt < 24; attempt += 1) {
    await assert.rejects(() => rosterDriver("apply", {
      local_team: "team\u0000name",
      server_instance_id: "018f0000-0000-7000-8000-000000000001",
      remote_team_id: "018f0000-0000-7000-8000-000000000002",
      protocol_version: 1,
    }, input));
  }
  assert.equal(await residue(), before, "a failed spawn left its input behind");
  if (spawnOpenBefore !== null) {
    // Not exact equality: this process is doing other things, and a count that
    // has to be identical would fail on something unrelated. Twenty-four leaked
    // descriptors is not a margin, it is the defect.
    assert.ok(descriptors() < spawnOpenBefore + 12,
      `a failed spawn leaked its descriptor: ${spawnOpenBefore} -> ${descriptors()}`);
  }
});

test("the staged input has no name for as long as the driver is reading it",
  { timeout: 30_000 }, async (t) => {
  // The claim this binds is the security one, and until now nothing tested it:
  // the file is unlinked as soon as its read-only descriptor is open, so for
  // the whole life of the call there is a file being read that nothing can
  // open by name -- which is what makes "a parent that dies leaves no message
  // content behind" true rather than hopeful.
  //
  // Every other test here looks AFTER the call, and by then the settle path has
  // cleaned up whether the handover unlinked or not. So this one looks WHILE
  // the driver is alive and still reading, which is the only window where the
  // two differ.
  //
  // POSIX only, and not skipped quietly on Windows for a bad reason: there a
  // file cannot be unlinked while open, so the directory is SUPPOSED to survive
  // until settle, and the residue test is what covers it.
  if (process.platform === "win32") {
    t.skip("Windows cannot unlink an open file; settle-time removal covers it there");
    return;
  }
  const residue = async () => (await readdir(tmpdir()))
    .filter((entry) => entry.startsWith("agmsg-driver-input-")).length;
  const before = await residue();

  const root = await mkdtemp(join(tmpdir(), "agmsg-sync-driver-unnamed-"));
  // Writes its pid, then stays alive without having read its input yet -- the
  // fixture helper returns once that pid is on disk, so the check below lands
  // inside the call rather than after it.
  const script = (pidFile, helperFile) => `#!/usr/bin/env bash
echo $$ > ${JSON.stringify(pidFile)}
echo $$ > ${JSON.stringify(helperFile)}
sleep 2
cat > /dev/null
printf '{"ok":true}\\n'
`;
  const input = Array.from({ length: 2000 }, (_, index) => ({ type: "probe", index }));
  const { started } = await withDriverEnvironment(t, root, script,
    (mock, config) => [() => rosterDriver("apply", config, input)]);

  assert.equal(await residue(), before,
    "the staged input still had a name while the driver was reading it");
  for (const { promise } of started) await promise;
  assert.equal(await residue(), before, "and none after it settled");
});

test("a cleanup that cannot remove the staged input says so, and does not fail the call",
  { timeout: 30_000 }, async (t) => {
  // The staged file is message content. When its removal fails there are two
  // wrong answers and this takes neither: failing the call would trade a sync
  // that completed for a cleanup detail the caller cannot act on, and staying
  // silent would leave that content on disk with nobody told.
  //
  // Driven directly rather than through a driver call, because the state it
  // needs -- a directory that refuses removal -- cannot be arranged from
  // outside `runDriver` without reaching into the timing of its own staging,
  // and a test that depends on that timing breaks on the next refactor for
  // reasons unrelated to what it checks.
  if (process.platform === "win32") {
    t.skip("chmod is the mechanism here and Windows does not honour it that way");
    return;
  }
  if (process.getuid?.() === 0) {
    t.skip("root ignores the permissions this arranges, so the failure never happens");
    return;
  }
  const parent = await mkdtemp(join(tmpdir(), "agmsg-sync-stuck-"));
  // Registered against the parent the moment it exists, before anything below
  // can throw. Hooking cleanup up only once the fixture is fully built means
  // the half-built cases -- the ones a failure actually produces -- are the
  // ones that leak.
  t.after(async () => {
    // The chmod is best effort on purpose: it runs before the directory below
    // necessarily exists, and its only job is to make the removal possible.
    await chmod(join(parent, "refuses-removal"), 0o700).catch(() => {});
    // The removal is NOT. `force: true` already treats a path that is not there
    // as success, so a catch here could only ever hide a real failure -- and
    // what it would hide is this fixture's content staying on disk while the
    // test reports green, which is the exact shape this test is about.
    await rm(parent, { recursive: true, force: true });
  });
  // NOT named `agmsg-driver-input-*`. That prefix is what the residue test
  // counts, and a fixture standing in the middle of another test's instrument
  // is a fixture that can fail it -- or, worse, hide a real leak inside its own
  // noise. What is under test here is the helper, which takes any path.
  const directory = join(parent, "refuses-removal");
  await mkdir(directory);
  const staged = join(directory, "input.jsonl");
  await writeFile(staged, "{\"a\":1}\n");
  // Not writable, so the file inside it cannot be unlinked and the recursive
  // removal has to fail.
  await chmod(directory, 0o500);
  // Everything comes back afterwards -- see the hook above, registered before
  // this could throw. This test's whole subject is content left on disk when a
  // removal fails; leaving that content on disk would be an odd way to make
  // the point, and the run after this one inherits it.

  const warnings = [];
  const collect = (warning) => warnings.push(warning);
  process.on("warning", collect);
  try {
    // Must not throw. That is half the contract, and it is asserted by this
    // call standing here: a throw propagates out of the finally and fails the
    // test before it can reach the assertion below.
    discardInputDirectory(directory, "the driver call ended");
    // emitWarning is delivered on the next tick.
    await new Promise((resolve) => setImmediate(resolve));
  } finally {
    // In a finally, not on the straight line. A regression that makes the
    // helper throw would otherwise leave this listener attached for the rest
    // of the file -- so the first failure would be followed by a second,
    // unrelated one, in whichever test happens to warn next.
    process.off("warning", collect);
  }

  // The directory itself, because that is the one thing an operator needs in
  // order to go and remove it. A warning that says "cleanup failed" and not
  // where is a warning that cannot be acted on.
  assert.ok(warnings.some((warning) => warning.message.includes(directory)),
    `no warning named the directory left behind: ${warnings.map((w) => w.message)}`);
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
      // The number is labelled and the team is named: `failed (7)` did not say
      // which field 7 came from, nor which team it was about (#782).
      /failed for team 't' \(exit 7\)/u.test(error.message) &&
      /giving up/u.test(error.message));
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
        // The health reply has to name the team, or configure refuses here and
        // the credential check below is never reached — this test would then
        // pass on the wrong rejection.
        return new Response(JSON.stringify({ status: "ok", database: "ok",
          server_instance_id: config.server_instance_id,
          team_id: config.remote_team_id }), {
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
        // team_id too: configure now reads it back and refuses a server that
        // names a different team, so a stub that omits it is a server which
        // does not answer per-team.
        { status: "ok", database: "ok", server_instance_id: config.server_instance_id,
          team_id: config.remote_team_id } :
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

test("health treats a 503 error page as weather, not a protocol mismatch (#814)", async () => {
  // A gateway that is down answers 502/503/504 with its own body and none of
  // our headers, so the version check fails for a reason that has nothing to do
  // with versions. `request()` already drew this line; `health()` did not — and
  // `health()` is what the engine's loop calls every cycle, so a 90-second
  // outage ended both engines on a live two-machine setup, permanently and
  // silently. The remote recovered; they did not.
  const previousFetch = globalThis.fetch;
  await withConnectedCredential(async (root) => {
    await writeConnectedTeam(root, { capabilities: { write_allowed_ciphers: ["none"] } });
    globalThis.fetch = async () =>
      new Response("<html>503 Service Unavailable</html>",
        { status: 503, headers: { "Content-Type": "text/html" } });
    try {
      await assert.rejects(
        configure({ team: "demo", server: "https://sync.example",
          "team-id": config.remote_team_id, "minimum-security": "plaintext-allowed" }),
        (error) => {
          // Retryable is the whole point: the loop keeps the engine alive and
          // the machine comes back on its own when the remote does.
          assert.equal(error.retryable, true, "a 503 error page must be retryable");
          assert.equal(error.status, 503);
          return true;
        });
    } finally {
      globalThis.fetch = previousFetch;
    }
  });
});

test("health still refuses a 200 that names a different protocol version (#814)", async () => {
  // The other half, and the reason the fix is a narrowed guard rather than
  // "retry everything": a successful response whose header says another version
  // IS a real mismatch. Making the first case retryable must not make this one
  // retryable too — one condition covering both cases is what the defect was.
  const previousFetch = globalThis.fetch;
  await withConnectedCredential(async (root) => {
    await writeConnectedTeam(root, { capabilities: { write_allowed_ciphers: ["none"] } });
    globalThis.fetch = async () =>
      new Response(JSON.stringify({ status: "ok", database: "ok",
        server_instance_id: config.server_instance_id,
        team_id: config.remote_team_id }),
        { status: 200, headers: { "Agmsg-Protocol-Version": "999" } });
    try {
      await assert.rejects(
        configure({ team: "demo", server: "https://sync.example",
          "team-id": config.remote_team_id, "minimum-security": "plaintext-allowed" }),
        (error) => {
          assert.notEqual(error.retryable, true,
            "a 200 with a different protocol version must NOT be retryable");
          return /protocol version mismatch/u.test(error.message);
        });
    } finally {
      globalThis.fetch = previousFetch;
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

test("runLoop: an install update stands the engine down before any cycle, naming the update and the restart (#963)", async () => {
  const events = [];
  let cycles = 0;
  // Resolves -- a stand-down is a deliberate return, not a thrown failure.
  await runLoop(config, {}, {
    collectInstallBaselineCall: async () => new Map([["/skill/scripts/a.sh", 111]]),
    installChangedCall: async () => "/skill/scripts/drivers/storage/sqlite-sync.sh",
    cycleCall: async () => { cycles += 1; return {}; },
    sleepCall: async () => {},
    eventCall: async (name, fields) => { events.push({ name, ...fields }); },
  });
  // Detected at the loop boundary: no driver was ever spawned.
  assert.equal(cycles, 0);
  assert.equal(events.length, 1);
  assert.equal(events[0].name, "stand-down");
  assert.equal(events[0].reason, "install-updated");
  assert.equal(events[0].changed_path, "/skill/scripts/drivers/storage/sqlite-sync.sh");
  // The message names the update, not a parse error, and the restart names the team.
  assert.match(events[0].message, /installation was updated/u);
  assert.equal(events[0].restart, "remote.sh sync start demo");
});

test("runLoop: a failure to OBSERVE the install is not evidence -- the engine keeps running (#963)", async () => {
  let cycles = 0;
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => new Map(),
    installChangedCall: async () => { throw new Error("EACCES: scripts unreadable"); },
    cycleCall: async () => {
      cycles += 1;
      if (cycles >= 2) { const stop = new Error("stop"); stop.retryable = false; throw stop; }
      return {};
    },
    sleepCall: async () => {},
    isRetryableCall: () => false,
    eventCall: async () => {},
  }), /stop/);
  // The check threw on every iteration and the loop cycled anyway.
  assert.equal(cycles, 2);
});

test("runLoop: an incomplete baseline disarms the detector entirely -- the check never runs (#963)", async () => {
  let cycles = 0;
  let checks = 0;
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => null, // one unreadable entry at start
    installChangedCall: async () => { checks += 1; return "/would-be-proof"; },
    cycleCall: async () => {
      cycles += 1;
      const stop = new Error("stop"); stop.retryable = false; throw stop;
    },
    sleepCall: async () => {},
    isRetryableCall: () => false,
    eventCall: async () => {},
  }), /stop/);
  // Partially armed detectors recreate the false positive; disarmed means today's behavior.
  assert.equal(checks, 0);
  assert.equal(cycles, 1);
});

test("install baseline: a pre-existing FUTURE mtime is what the tree looked like, not an update (#963)", async () => {
  // The first review counterexample against comparing mtimes to the
  // engine's start clock: a file that already carried a future mtime at
  // start (clock skew, an archive with preserved timestamps) must not
  // stand every fresh engine down. Against the baseline it is unchanged.
  const root = await mkdtemp(join(tmpdir(), "agmsg-963-"));
  try {
    await mkdir(join(root, "internal"), { recursive: true });
    const future = new Date(Date.now() + 3600_000);
    await writeFile(join(root, "internal", "from-the-future.sh"), "echo hi\n");
    await utimes(join(root, "internal", "from-the-future.sh"), future, future);
    const baseline = await collectInstallBaseline(root);
    assert.ok(baseline instanceof Map);
    assert.equal(await installChangedAgainst(root, baseline), null);
  } finally {
    await rm(root, { recursive: true });
  }
});

test("install baseline: an mtime change with UNCHANGED content is a touch, not an update (#963)", async () => {
  // The second review counterexample: mtime change does not prove content
  // change, and a false stand-down is a stopped sync engine. A touch, a
  // metadata-only correction, a same-content re-copy must all keep the
  // engine running; only different bytes are proof.
  const root = await mkdtemp(join(tmpdir(), "agmsg-963t-"));
  try {
    await mkdir(join(root, "internal"), { recursive: true });
    const file = join(root, "internal", "driver.sh");
    await writeFile(file, "echo stable\n");
    const baseline = await collectInstallBaseline(root);
    // touch: same bytes, new mtime
    const later = new Date(Date.now() + 60_000);
    await utimes(file, later, later);
    assert.equal(await installChangedAgainst(root, baseline), null);
    // The benign touch is remembered: the next sweep takes the cheap path
    // and does not re-read the file.
    let reads = 0;
    const countingRead = async (path) => { reads += 1; return readFile(path); };
    assert.equal(await installChangedAgainst(root, baseline, { readFileCall: countingRead }), null);
    assert.equal(reads, 0);
    // A rewrite with DIFFERENT bytes (and a new mtime) is proof.
    const evenLater = new Date(Date.now() + 120_000);
    await writeFile(file, "echo rewritten\n");
    await utimes(file, evenLater, evenLater);
    assert.equal(await installChangedAgainst(root, baseline), file);
  } finally {
    await rm(root, { recursive: true });
  }
});

test("install baseline: a file appearing after start is proof; missing roots observe nothing (#963)", async () => {
  const root = await mkdtemp(join(tmpdir(), "agmsg-963b-"));
  try {
    await mkdir(join(root, "internal"), { recursive: true });
    await writeFile(join(root, "internal", "old.sh"), "echo old\n");
    const baseline = await collectInstallBaseline(root);
    assert.equal(await installChangedAgainst(root, baseline), null);
    await writeFile(join(root, "internal", "added-by-update.sh"), "echo new\n");
    assert.equal(await installChangedAgainst(root, baseline),
      join(root, "internal", "added-by-update.sh"));
    // A root that cannot be read at baseline time disables the detector (null)...
    assert.equal(await collectInstallBaseline(join(root, "no-such-dir")), null);
    // ...and one that cannot be read at check time yields no evidence.
    assert.equal(await installChangedAgainst(join(root, "no-such-dir"), baseline), null);
    // A file whose bytes cannot be re-read after an mtime change proves nothing.
    await unlink(join(root, "internal", "added-by-update.sh")); // clear the standing proof first
    const target = join(root, "internal", "old.sh");
    const later = new Date(Date.now() + 60_000);
    await utimes(target, later, later);
    const failingRead = async () => { throw new Error("EACCES"); };
    assert.equal(await installChangedAgainst(root, baseline, { readFileCall: failingRead }), null);
  } finally {
    await rm(root, { recursive: true });
  }
});

test("runLoop: push saturation drives catch-up (no wait), a drained cycle returns to the steady interval", async () => {
  const sleeps = [];
  const limitsSeen = [];
  const saturationScript = [true, true, false]; // two catch-up cycles, then drained
  let i = 0;
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
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
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
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
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
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

// The failing cycle has to be diagnosable from the log alone.
//
// `fetch` rejects with a bare `TypeError: fetch failed` whose own `code` is
// undefined, so reading one property off the thrown error logged
// `{"message":"fetch failed","code":null}` once a second, forever, for a TLS
// trust failure Node had already named. The operator who hit that had to
// reproduce the request by hand, with curl and with a raw Node client, to find
// out which one was refusing the certificate (#744).
const cycleErrorFor = async (error) => {
  const logged = [];
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
    cycleCall: async () => { throw error; },
    sleepCall: async () => {},
    isRetryableCall: () => false, // one iteration, then out
    eventCall: async (name, payload) => { if (name === "cycle.error") logged.push(payload); },
  }));
  assert.equal(logged.length, 1);
  return logged[0];
};

// `status` could say `engine running` forever while every cycle failed. The
// engine knows the difference; it had nowhere to put it (#756).
const cycleRecordRun = async (script) => {
  const recorded = [];
  let i = 0;
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
    cycleCall: async () => {
      const step = script[i++];
      if (step === undefined) { const stop = new Error("stop"); stop.retryable = false; throw stop; }
      if (step === "fail") { const net = new Error("net"); net.retryable = true; throw net; }
      return {};
    },
    sleepCall: async () => {},
    isRetryableCall: (error) => error.retryable === true,
    eventCall: async () => {},
    nowCall: () => `T${recorded.length + 1}`,
    recordCycleCall: async (team, at) => { recorded.push([team, at]); },
  }), /stop/);
  return recorded;
};

test("runLoop: a completed cycle is recorded, a failed one is not", async () => {
  // The whole value of the record is that it cannot be written by an attempt.
  assert.deepEqual(await cycleRecordRun(["fail", "fail"]), []);
  assert.deepEqual(await cycleRecordRun(["ok"]), [[config.local_team, "T1"]]);
  // And a failure after a success does not retract the success -- "it worked
  // once and then stopped" is a different state from "it never worked", and
  // `status` needs to be able to tell them apart.
  assert.deepEqual(await cycleRecordRun(["ok", "fail"]), [[config.local_team, "T1"]]);
});

test("runLoop: bookkeeping that throws does not take down a working cycle", async () => {
  // Best-effort by design: an unwritable run directory must not stop syncing,
  // which is the part that is working. Under-reporting is the safe direction --
  // `status` says "nothing recorded" when something happened, rather than
  // claiming a success that did not.
  let cycles = 0;
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
    cycleCall: async () => {
      cycles += 1;
      if (cycles > 2) { const stop = new Error("stop"); stop.retryable = false; throw stop; }
      return {};
    },
    sleepCall: async () => {},
    isRetryableCall: (error) => error.retryable === true,
    eventCall: async () => {},
    recordCycleCall: async () => { throw new Error("run directory is unwritable"); },
  }), /stop/);
  assert.equal(cycles, 3, "a failing record must not stop the loop from cycling");
});

test("runLoop: cycle.error reports the code from the cause, not the wrapper's own empty one", async () => {
  const wrapper = new TypeError("fetch failed");
  wrapper.cause = Object.assign(new Error("self-signed certificate"),
    { code: "DEPTH_ZERO_SELF_SIGNED_CERT" });
  assert.deepEqual(await cycleErrorFor(wrapper), {
    message: "fetch failed",
    code: "DEPTH_ZERO_SELF_SIGNED_CERT",
    cause: "self-signed certificate",
  });
});

test("runLoop: cycle.error walks past an intermediate wrapper that carries no code", async () => {
  // A proxied or agent-wrapped request nests further than one level, which is
  // why the chain is walked rather than read at a fixed depth.
  const inner = Object.assign(new Error("unable to verify the first certificate"),
    { code: "UNABLE_TO_VERIFY_LEAF_SIGNATURE" });
  const middle = new Error("socket error");
  middle.cause = inner;
  const wrapper = new TypeError("fetch failed");
  wrapper.cause = middle;
  const payload = await cycleErrorFor(wrapper);
  assert.equal(payload.code, "UNABLE_TO_VERIFY_LEAF_SIGNATURE");
  assert.equal(payload.cause, "unable to verify the first certificate");
});

test("runLoop: cycle.error keeps an error's own code rather than a deeper one", async () => {
  // The outermost code is the one the engine's own error taxonomy sets, so a
  // cause underneath must not silently replace what the caller declared.
  const error = Object.assign(new Error("read-state limit exceeded"),
    { code: "read-state-limit-exceeded" });
  error.cause = Object.assign(new Error("inner"), { code: "ECONNRESET" });
  const payload = await cycleErrorFor(error);
  assert.equal(payload.code, "read-state-limit-exceeded");
});

test("runLoop: cycle.error survives a cyclic cause chain and invents nothing without one", async () => {
  const a = new Error("a");
  const b = new Error("b");
  a.cause = b; b.cause = a; // a cause chain is not guaranteed to be a tree
  const cyclic = await cycleErrorFor(a);
  assert.equal(cyclic.message, "a");
  // No cause at all must stay reportable, and must not grow a `cause` key that
  // would read as a diagnosis nobody made.
  assert.deepEqual(await cycleErrorFor(new Error("plain")), { message: "plain", code: null });
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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
    healthCall: async () => ({ server_instance_id: config.server_instance_id, team_id: config.remote_team_id }),
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

test("the roster driver is handed a resolved file path, from the connection root", async () => {
  // Only `remote.sh pull` ever set AGMSG_SYNC_LOCAL_ROSTER_FILE, so every other
  // caller left the driver to guess — and its guess was the skill directory. A
  // second machine keeps its teams under its own connection directory, so an
  // existing roster looked missing.
  //
  // The engine derives the path now and passes the file, at the one place both
  // drivers go through. This drives a stand-in driver that reports what it was
  // given, so what is measured is the value that crosses the process boundary,
  // not a re-derivation of the same expression.
  const root = await mkdtemp(join(tmpdir(), "agmsg-roster-env-"));
  const connection = join(root, "connection");
  const skill = join(root, "skill");
  await mkdir(join(connection, "teams", "demo"), { recursive: true });
  await mkdir(skill, { recursive: true });
  const script = join(root, "driver.sh");
  // The `cat` is load-bearing, not tidiness: without it this test fails on a
  // loaded CI runner with `write EPIPE` and nothing to do with what it asserts.
  // `rosterDriver` writes the driver's stdin and then ends it; a stub that only
  // prints has already exited by then, so the `end()` lands on a closed pipe and
  // `runDriver` reports a driver failure -- correctly, since a real driver reads
  // its input. Locally the parent always wins the race and it passes. It blocked
  // three unrelated landings before the mechanism was named (#755).
  await writeFile(script, `#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"seen","roster":"%s","connection_dir":"%s","trust_dir":"%s"}\\n' \\
  "\${AGMSG_SYNC_LOCAL_ROSTER_FILE:-}" "\${AGMSG_SYNC_CONNECTION_DIR:-}" "\${AGMSG_SYNC_TRUST_DIR:-}"
`, { mode: 0o700 });

  const previous = {
    driver: process.env.AGMSG_SYNC_ROSTER_DRIVER,
    connection: process.env.AGMSG_SYNC_CONNECTION_DIR,
    skill: process.env.SKILL_DIR,
    roster: process.env.AGMSG_SYNC_LOCAL_ROSTER_FILE,
    trust: process.env.AGMSG_SYNC_TRUST_DIR,
  };
  process.env.AGMSG_SYNC_ROSTER_DRIVER = script;
  process.env.AGMSG_SYNC_CONNECTION_DIR = connection;
  process.env.SKILL_DIR = skill;
  delete process.env.AGMSG_SYNC_LOCAL_ROSTER_FILE;
  process.env.AGMSG_SYNC_TRUST_DIR = "/durable/trust";
  try {
    const [seen] = await rosterDriver("prepare", config, []);
    assert.equal(seen.roster, join(connection, "teams", "demo", "config.json"));
    assert.notEqual(seen.roster, join(skill, "teams", "demo", "config.json"));
    // The directories stay stripped: the driver is given the one file it needs
    // and is not put back in the business of deriving locations.
    assert.equal(seen.connection_dir, "");
    assert.equal(seen.trust_dir, "");
  } finally {
    for (const [key, value] of [
      ["AGMSG_SYNC_ROSTER_DRIVER", previous.driver],
      ["AGMSG_SYNC_CONNECTION_DIR", previous.connection],
      ["SKILL_DIR", previous.skill],
      ["AGMSG_SYNC_LOCAL_ROSTER_FILE", previous.roster],
      ["AGMSG_SYNC_TRUST_DIR", previous.trust],
    ]) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(root, { recursive: true, force: true });
  }
});

test("only the roster file may be set after the strip — nothing else can be re-added", async () => {
  // The strip is the boundary, and it has to be one. An earlier version took a
  // general "extra environment" object applied after the deletes, which let any
  // caller put TOKEN, TRUST_DIR or an age identity back; the rule that they
  // never cross lived in a comment instead of in the function. runDriver now
  // accepts one named path and nothing else, so this asserts the shape of the
  // parameter rather than the good behaviour of today's only caller.
  const source = await readFile(new URL("../scripts/internal/remote-sync.mjs", import.meta.url), "utf8");
  const signature = /function runDriver\(\{([^}]*)\}\)/u.exec(source);
  assert.ok(signature, "runDriver's destructured parameters could not be read");
  const parameters = signature[1].split(",").map((name) => name.trim().split(/[:=]/u)[0].trim());
  // No general environment/env/extraEnv escape hatch — the reviewable property.
  for (const forbidden of ["environment", "env", "extraEnv", "envOverrides"]) {
    assert.ok(!parameters.includes(forbidden),
      `runDriver takes "${forbidden}", which re-opens the secret boundary`);
  }
  assert.ok(parameters.includes("rosterFile"), "the one permitted value is missing");
  // And exactly one assignment into the child environment after the deletes.
  const afterStrip = source.slice(source.indexOf("function runDriver"), source.indexOf("const child = spawn"));
  const assignments = afterStrip.match(/childEnvironment\.[A-Z_]+\s*=/gu) ?? [];
  assert.deepEqual(assignments, ["childEnvironment.AGMSG_SYNC_LOCAL_ROSTER_FILE ="]);
});

test("a secret handed in as the roster file cannot reach the driver as a secret", async () => {
  // The complement of the shape check: drive the real path and confirm the only
  // thing that lands is the roster variable.
  //
  // Note what this test can and cannot do. With a general environment parameter
  // it would still pass, because the only caller passes just the roster path —
  // which is exactly why the shape check above exists as well. Behaviour proves
  // today's callers behave; the parameter list proves a future one cannot.
  const root = await mkdtemp(join(tmpdir(), "agmsg-roster-allowlist-"));
  const script = join(root, "driver.sh");
  // Same race as the stub above, same reason for the `cat`. This one has not
  // been seen to fail, which is not a reason to leave it: it is the same shape,
  // and the one next door failed three times before anyone looked.
  await writeFile(script, `#!/usr/bin/env bash
cat >/dev/null
printf '{"type":"seen","token":"%s","trust":"%s","conn":"%s","identity":"%s","roster":"%s"}\\n' \\
  "\${AGMSG_SYNC_TOKEN:-}" "\${AGMSG_SYNC_TRUST_DIR:-}" "\${AGMSG_SYNC_CONNECTION_DIR:-}" \\
  "\${AGMSG_AGE_IDENTITY:-}" "\${AGMSG_SYNC_LOCAL_ROSTER_FILE:-}"
`, { mode: 0o700 });
  const previous = {
    driver: process.env.AGMSG_SYNC_ROSTER_DRIVER,
    token: process.env.AGMSG_SYNC_TOKEN,
    trust: process.env.AGMSG_SYNC_TRUST_DIR,
    connection: process.env.AGMSG_SYNC_CONNECTION_DIR,
    identity: process.env.AGMSG_AGE_IDENTITY,
    roster: process.env.AGMSG_SYNC_LOCAL_ROSTER_FILE,
  };
  process.env.AGMSG_SYNC_ROSTER_DRIVER = script;
  process.env.AGMSG_SYNC_TOKEN = "must-not-cross";
  process.env.AGMSG_SYNC_TRUST_DIR = "/durable/trust";
  process.env.AGMSG_SYNC_CONNECTION_DIR = root;
  process.env.AGMSG_AGE_IDENTITY = "AGE-SECRET-KEY-1FIXTURE";
  delete process.env.AGMSG_SYNC_LOCAL_ROSTER_FILE;
  try {
    const [seen] = await rosterDriver("prepare", config, []);
    assert.equal(seen.token, "");
    assert.equal(seen.trust, "");
    assert.equal(seen.conn, "");
    assert.equal(seen.identity, "");
    assert.equal(seen.roster, join(root, "teams", config.local_team, "config.json"));
  } finally {
    for (const [key, value] of [
      ["AGMSG_SYNC_ROSTER_DRIVER", previous.driver],
      ["AGMSG_SYNC_TOKEN", previous.token],
      ["AGMSG_SYNC_TRUST_DIR", previous.trust],
      ["AGMSG_SYNC_CONNECTION_DIR", previous.connection],
      ["AGMSG_AGE_IDENTITY", previous.identity],
      ["AGMSG_SYNC_LOCAL_ROSTER_FILE", previous.roster],
    ]) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(root, { recursive: true, force: true });
  }
});

// --- push batching: bytes, and the 413 split ------------------------------

// A candidate whose wire size is dominated by `bytes` of blob.
function bulkyCandidate(index, bytes) {
  return {
    type: "sync_push_candidate",
    local_position: String(index + 1),
    local_id: `m${index}`,
    id: `550e8400-e29b-41d4-a716-${String(index + 1).padStart(12, "0")}`,
    envelope: { v: 1, cipher: "none", key_id: null, blob: "A".repeat(bytes) },
  };
}

function pushHarness(candidates, onPost) {
  const capabilities = {
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: "0", next_sequence_boundary: "1", accepted_envelope_versions: [1],
    write_allowed_ciphers: ["none"], policy_revision: "0", effective_from_seq: "1",
    max_blob_bytes: "1048576", policy_history: [{ policy_revision: "0",
      effective_from_seq: "1", accepted_envelope_versions: [1],
      write_allowed_ciphers: ["none"] }],
  };
  return {
    healthCall: async () => ({ server_instance_id: config.server_instance_id,
      team_id: config.remote_team_id }),
    requestCall: async (_config, path, options) => {
      if (path === "/v1/capabilities") return capabilities;
      if (path === "/v1/messages") return onPost(JSON.parse(options.body).messages);
      if (path.startsWith("/v1/messages?after=")) {
        return { messages: [], next_after: "0", has_more: false };
      }
      throw new Error(`unexpected request ${path}`);
    },
    driverCall: async (operation) => {
      if (operation === "prepare") {
        return [{ type: "sync_state",
          driver_generation: "018f3f7e-0000-7000-8000-000000000099",
          transport_cursor: "0" }, ...candidates];
      }
      if (operation === "reconcile") return [{ type: "sync_reconcile_result", count: 1 }];
      if (operation === "apply") return [{ type: "sync_apply_result", transport_cursor: "0" }];
      throw new Error(`unexpected storage operation ${operation}`);
    },
    logApplyCall: async () => {},
    eventCall: async () => {},
    readStateCycleCall: async () => {},
  };
}

// Sequences come from a counter that keeps advancing across POSTs, the way a
// real server assigns them. Restarting at 1 per response would make the
// concatenated acks non-monotonic, and validateAckMapping rejects that — a
// property of the stub, not of the split, but one that hides the real behaviour
// if it is wrong.
function ackAllFrom(counter) {
  return (messages) => ({
    protocol_version: 1, server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
    current_seq: String(counter.value + messages.length), policy_revision: "0",
    acks: messages.map((message) => ({ id: message.id,
      server_seq: String(++counter.value), disposition: "stored" })),
  });
}

test("push.posted marks the end of the POST, before the acks are written", async () => {
  // push.ack and push.reconciled are both emitted after recordAcks, so a
  // reader of the log saw the POST and the reconcile as one span between
  // push.prepared and push.ack (#913). push.posted is the boundary: it carries
  // the ack count, and it arrives after the last POST answered and before the
  // reconcile driver is asked to write anything.
  const candidates = Array.from({ length: 3 }, (_unused, index) =>
    bulkyCandidate(index, 100));
  const ack = ackAllFrom({ value: 0 });
  const sequence = [];
  const harness = pushHarness(candidates, (messages) => {
    sequence.push(`POST ${messages.length}`);
    return ack(messages);
  });
  await cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    ...harness,
    eventCall: async (name, payload) => {
      if (name.startsWith("push.")) sequence.push(`${name} ${payload?.count ?? payload?.acks?.length ?? ""}`.trim());
    },
    driverCall: async (operation, driverConfig, input) => {
      if (operation === "reconcile") {
        sequence.push(`reconcile ${input.length}`);
        return [{ type: "sync_reconcile_result", count: input.length }];
      }
      return harness.driverCall(operation, driverConfig, input);
    },
  });
  assert.deepEqual(sequence, [
    "push.prepared 3",
    "POST 3",
    "push.posted 3",
    "reconcile 3",
    "push.ack 3",
    "push.reconciled",
  ]);
});

test("push.posted cannot cost the durable write: an unwritable log still reconciles", async () => {
  // The event sits between the acks and recordAcks. Emitted bare, a log
  // failure there would throw before the write and the acks would be lost to
  // this cycle; the next one would resend what the server already holds. So
  // it goes through note(): the write happens, and the failure is the log's.
  const candidates = Array.from({ length: 2 }, (_unused, index) =>
    bulkyCandidate(index, 100));
  const ack = ackAllFrom({ value: 0 });
  const reconciled = [];
  const harness = pushHarness(candidates, (messages) => ack(messages));
  await cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    ...harness,
    eventCall: async (name) => {
      if (name === "push.posted") throw new Error("event log is unwritable");
    },
    driverCall: async (operation, driverConfig, input) => {
      if (operation === "reconcile") {
        reconciled.push(...input.map((record) => record.id));
        return [{ type: "sync_reconcile_result", count: input.length }];
      }
      return harness.driverCall(operation, driverConfig, input);
    },
  });
  assert.deepEqual(reconciled, candidates.map((candidate) => candidate.id));
});

test("push splits a page by BYTES, not by message count", async () => {
  // The count limit was 1000, so a thousand small messages and a thousand large
  // ones were the same batch and only the second kind was ever refused. Twelve
  // messages of 64 KiB is far under any count limit and far over the byte one.
  const candidates = Array.from({ length: 12 }, (_unused, index) =>
    bulkyCandidate(index, 64 * 1024));
  const posts = [];
  const ack = ackAllFrom({ value: 0 });
  await cycle(config, { pushLimit: 100, pullLimit: 1000 },
    pushHarness(candidates, (messages) => { posts.push(messages.length); return ack(messages); }));
  assert.ok(posts.length > 1, `expected more than one POST, got ${posts.length}`);
  assert.equal(posts.reduce((sum, n) => sum + n, 0), 12); // every message sent exactly once
});

test("push halves on 413 and every message still lands, in order", async () => {
  // The server refuses anything above four at a time. The client does not know
  // that number and must not need to: it halves until the server accepts.
  const candidates = Array.from({ length: 8 }, (_unused, index) => bulkyCandidate(index, 64));
  const accepted = [];
  const ack = ackAllFrom({ value: 0 });
  let refusals = 0;
  await cycle(config, { pushLimit: 100, pullLimit: 1000 },
    pushHarness(candidates, (messages) => {
      if (messages.length > 4) {
        refusals += 1;
        const error = new Error("HTTP 413 request-too-large");
        error.status = 413;
        error.body = { protocol_version: 1, server_instance_id: config.server_instance_id,
          team_id: config.remote_team_id, error: { code: "request-too-large" } };
        throw error;
      }
      accepted.push(...messages.map((m) => m.id));
      return ack(messages);
    }));
  assert.ok(refusals > 0, "the server never refused, so no split was exercised");
  assert.deepEqual(accepted, candidates.map((c) => c.id)); // all of them, in send order
});

test("a POST that fails after earlier ones succeeded still records their acks", async () => {
  // Several POSTs cannot be atomic the way one was: when a later one dies, the
  // rows the earlier ones stored are committed and their acks are in hand.
  // Dropping them leaves the client with no record of messages the server holds
  // — the exact state the split has to keep from happening. Both the failure and
  // the prefix have to reach the caller.
  const candidates = Array.from({ length: 8 }, (_unused, index) =>
    bulkyCandidate(index, 256 * 1024));
  const committed = [];
  const reconciled = [];
  const events = [];
  let posts = 0;
  const ack = ackAllFrom({ value: 0 });
  const harness = pushHarness(candidates, (messages) => {
    posts += 1;
    if (posts === 2) {
      const error = new Error("HTTP 409 conflict");
      error.status = 409;
      throw error;
    }
    committed.push(...messages.map((message) => message.id));
    return ack(messages);
  });
  const dependencies = {
    ...harness,
    eventCall: async (name, payload) => { events.push([name, payload]); },
    driverCall: async (operation, driverConfig, input) => {
      if (operation === "reconcile") {
        reconciled.push(...input.map((record) => record.id));
        return [{ type: "sync_reconcile_result", count: input.length }];
      }
      return harness.driverCall(operation, driverConfig, input);
    },
  };
  await assert.rejects(cycle(config, { pushLimit: 100, pullLimit: 1000 }, dependencies),
    (error) => error.status === 409);
  assert.ok(posts > 1, `expected the page to split, got ${posts} POST(s)`);
  assert.ok(committed.length > 0, "the first POST stored nothing, so nothing was at risk");
  // What the server kept is exactly what the client wrote down — no more (it
  // must not claim rows the failed POST never stored) and no less.
  assert.deepEqual(reconciled, committed);
  assert.deepEqual(events.filter(([name]) => name === "push.partial")
    .map(([, payload]) => payload), [{ acked: committed.length, of: candidates.length }]);
});

test("a half that fails after its sibling succeeded still records the sibling's acks", async () => {
  // The same loss, one level down: the 413 halving is recursive, so a failure in
  // the second half discards the first half's acks unless every layer carries
  // them. Small messages, so the byte budget makes one group and the only split
  // is the recursive one — this reaches code the batch-level test does not.
  const candidates = Array.from({ length: 4 }, (_unused, index) => bulkyCandidate(index, 64));
  const committed = [];
  const reconciled = [];
  let refused = false;
  const ack = ackAllFrom({ value: 0 });
  const harness = pushHarness(candidates, (messages) => {
    if (messages.length > 2) { // refuse the whole group once, forcing the halving
      refused = true;
      const error = new Error("HTTP 413 request-too-large");
      error.status = 413;
      error.body = { protocol_version: 1, server_instance_id: config.server_instance_id,
        team_id: config.remote_team_id, error: { code: "request-too-large" } };
      throw error;
    }
    if (committed.length > 0) { // the second half, after the first one stored
      const error = new Error("HTTP 503 unavailable");
      error.status = 503;
      throw error;
    }
    committed.push(...messages.map((message) => message.id));
    return ack(messages);
  });
  await assert.rejects(cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    ...harness,
    driverCall: async (operation, driverConfig, input) => {
      if (operation === "reconcile") {
        reconciled.push(...input.map((record) => record.id));
        return [{ type: "sync_reconcile_result", count: input.length }];
      }
      return harness.driverCall(operation, driverConfig, input);
    },
  }), (error) => error.status === 503);
  assert.ok(refused, "the server never refused, so the recursive halving never ran");
  assert.deepEqual(reconciled, committed);
  assert.equal(committed.length, 2);
});

test("an event sink that fails costs neither the prefix nor the transport error", async () => {
  // The recovery must not depend on the reporting. An event log that cannot be
  // written is a reason to say so, never a reason to skip the durable write the
  // acks exist for, or to surface itself as the cycle's error in place of the
  // transport failure that caused it.
  const candidates = Array.from({ length: 8 }, (_unused, index) =>
    bulkyCandidate(index, 256 * 1024));
  const committed = [];
  const reconciled = [];
  let posts = 0;
  const ack = ackAllFrom({ value: 0 });
  const harness = pushHarness(candidates, (messages) => {
    posts += 1;
    if (posts === 2) {
      const error = new Error("HTTP 409 conflict");
      error.status = 409;
      throw error;
    }
    committed.push(...messages.map((message) => message.id));
    return ack(messages);
  });
  const attempted = [];
  const failed = await cycle(config, { pushLimit: 100, pullLimit: 1000 }, {
    ...harness,
    // Every event reachable once the push has failed throws — the two this
    // change added, and the two that report the reconcile. None of them may sit
    // between the acks and the durable write.
    eventCall: async (name) => {
      if (["push.partial", "push.partial-unrecorded", "push.ack", "push.reconciled"]
        .includes(name)) {
        attempted.push(name);
        throw new Error("event log is unwritable");
      }
    },
    driverCall: async (operation, driverConfig, input) => {
      if (operation === "reconcile") {
        reconciled.push(...input.map((record) => record.id));
        return [{ type: "sync_reconcile_result", count: input.length }];
      }
      return harness.driverCall(operation, driverConfig, input);
    },
  }).then(() => null, (error) => error);
  assert.ok(failed, "the cycle resolved, so the transport failure was swallowed");
  assert.equal(failed.status, 409);
  assert.match(failed.message, /409 conflict/u);
  assert.ok(committed.length > 0, "the first POST stored nothing, so nothing was at risk");
  assert.deepEqual(reconciled, committed);
  // The write succeeded and only the log failed. Saying "unrecorded" here would
  // send the next reader to resend a prefix that is already durable, so the
  // classification is the assertion — a log failure is not a write failure.
  assert.ok(!attempted.includes("push.partial-unrecorded"),
    "a durable prefix was reported as unrecorded");
  assert.equal(failed.cause, undefined, "an event failure took the cause slot");
  // Reporting was still attempted, in order, after the write.
  assert.deepEqual(attempted, ["push.partial", "push.ack", "push.reconciled"]);
});

test("push stops at one message rather than splitting forever, and names it", async () => {
  // A single message the server refuses is a permanent dead end: no batching
  // this client can do will get it across, and every later cycle retries it.
  // The failure has to say which message and how big, or an operator sees a sync
  // that stops progressing and nothing that points at the cause.
  const candidates = [bulkyCandidate(0, 4096)];
  const events = [];
  let attempts = 0;
  const harness = pushHarness(candidates, () => {
    attempts += 1;
    const error = new Error("HTTP 413 request-too-large");
    error.status = 413;
    // The HOSTED shape on purpose: a bare string, which is what the edge sends.
    // If this event read body.error.code directly it would report detail:null
    // for exactly the deployment the bridge was added for.
    error.body = { protocol_version: 1, server_instance_id: config.server_instance_id,
      team_id: config.remote_team_id, error: "payload_too_large" };
    throw error;
  });
  harness.eventCall = async (name, payload) => { events.push([name, payload]); };
  await assert.rejects(
    cycle(config, { pushLimit: 100, pullLimit: 1000 }, harness),
    (error) => {
      assert.match(error.message, /cannot be pushed by splitting/u);
      // The message a human reads has to carry the local coordinate too.
      assert.ok(error.message.includes(candidates[0].local_id),
        `error must name local_id, got: ${error.message}`);
      assert.equal(error.local_id, candidates[0].local_id);
      assert.equal(error.local_position, candidates[0].local_position);
      assert.equal(error.wire_id, candidates[0].id);
      return true;
    });
  assert.equal(attempts, 1, "a single message must not be split again");
  const oversized = events.find(([name]) => name === "push.oversized");
  assert.ok(oversized, "no push.oversized event was emitted");
  // local_id is the coordinate in THIS machine's store — the row an operator can
  // look at or delete. The wire id is a reservation this push minted and points
  // at nothing locally, so reporting only that would say "sync is stuck" without
  // saying on what. The fixture keeps them different on purpose.
  assert.notEqual(candidates[0].local_id, candidates[0].id);
  assert.equal(oversized[1].local_id, candidates[0].local_id);
  assert.equal(oversized[1].local_position, candidates[0].local_position);
  assert.equal(oversized[1].sync_axis, "messages");
  assert.equal(oversized[1].wire_id, candidates[0].id); // still there, for correlation
  assert.ok(oversized[1].bytes > 4096, "the reported size must be the real wire size");
  assert.equal(oversized[1].detail, "payload_too_large");
});

test("an overlapping resend acks every message SENT, duplicates included", async () => {
  // The property the split rests on. A retry after a partial success resends
  // messages the server already has; validateAckMapping compares ack count with
  // candidate count, so a server that acked only the newly stored ones would
  // fail the whole push with "incomplete ack mapping". Nothing else in the suite
  // sends an overlapping batch, so this would break silently.
  const candidates = Array.from({ length: 4 }, (_unused, index) => bulkyCandidate(index, 64));
  const alreadyStored = new Set([candidates[0].id, candidates[1].id]);
  let seen = null;
  await cycle(config, { pushLimit: 100, pullLimit: 1000 },
    pushHarness(candidates, (messages) => {
      seen = messages.map((message) => ({ id: message.id,
        disposition: alreadyStored.has(message.id) ? "duplicate" : "stored" }));
      return { protocol_version: 1, server_instance_id: config.server_instance_id,
        team_id: config.remote_team_id, team_name: "demo", min_available_seq: "0",
        current_seq: "4", policy_revision: "0",
        acks: seen.map((ack, index) => ({ ...ack, server_seq: String(index + 1) })) };
    }));
  assert.equal(seen.length, 4);
  assert.equal(seen.filter((ack) => ack.disposition === "duplicate").length, 2);
});

test("an error code is read from the protocol shape, and from the edge's for now", () => {
  // The nested form is the protocol. The bare string is a bridge to what the
  // hosted edge sends today, and this test says so on purpose: when the edge
  // emits the nested shape, the string case here and the branch it covers both
  // go away together.
  assert.equal(errorCode({ error: { code: "request-too-large" } }), "request-too-large");
  assert.equal(errorCode({ error: "payload_too_large" }), "payload_too_large"); // bridge
  // Neither shape present, or present but empty: say so rather than inventing one.
  assert.equal(errorCode({ error: {} }), "unknown-error");
  assert.equal(errorCode({ error: "" }), "unknown-error");
  assert.equal(errorCode({}), "unknown-error");
  assert.equal(errorCode(undefined), "unknown-error");
});

// ── a refusal the caller can act on (#773) ──────────────────────────────────
//
// The engine used to leave the loop on one: not retryable, so it threw, main()
// rejected, and the process exited. `status` then said "engine stopped — run:
// remote.sh sync start", which invites the one action that cannot work.

test("isRefusal: a 4xx the retry policy does not cover, by class and not by number", () => {
  // The status in use today is deliberately not named in the engine, so it is
  // not named here either — what is asserted is the CLASS. A server may refuse
  // for reasons this protocol never enumerates.
  for (const status of [400, 401, 402, 403, 409, 422, 451]) {
    assert.equal(isRefusal({ status }), true, `${status} should be a refusal`);
  }
  // Retryable 4xx stay retryable: isRetryable is asked first.
  for (const status of [408, 429]) {
    assert.equal(isRefusal({ status }), false, `${status} is retryable, not refused`);
  }
  // 5xx is a transport failure, not a decision.
  for (const status of [500, 502, 503, 504]) {
    assert.equal(isRefusal({ status }), false, `${status} is transport, not refused`);
  }
  // An error carrying no status at all — a socket failure — is neither.
  assert.equal(isRefusal(new Error("fetch failed")), false);
  assert.equal(isRefusal({ retryable: true, status: 402 }), false);
});

test("runLoop: a refusal is recorded and does NOT leave the loop", async () => {
  const recorded = [];
  const sleeps = [];
  let i = 0;
  // An endpoint the host can actually be read from: the recorded host is the
  // one fact here that says WHERE the operator of that server would be
  // reached, and a fixture without one would let the assertion pass on null.
  const refusedConfig = { ...config, endpoint: "https://sync.example.test" };
  await assert.rejects(() => runLoop(refusedConfig, {}, {
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
    cycleCall: async () => {
      i += 1;
      if (i <= 2) { const refused = new Error("HTTP 402 payment_required"); refused.status = 402; refused.code = "payment_required"; throw refused; }
      // Only a DIFFERENT, non-retryable error ends the loop — which is how
      // this test can end at all. If a refusal exited, i would never reach 3.
      const stop = new Error("stop"); stop.retryable = false; throw stop;
    },
    isRetryableCall: (error) => error.retryable === true,
    isRefusalCall: (error) => typeof error.status === "number" && error.status >= 400 && error.status < 500,
    recordRefusalCall: async (team, fact) => { recorded.push({ team, ...fact }); },
    clearRefusalCall: async () => {},
    nowCall: () => "2026-08-14T00:00:00Z",
    sleepCall: async (ms) => { sleeps.push(ms); },
    eventCall: async () => {},
  }), /stop/);

  // It came back for a second cycle after the first refusal, and a third.
  assert.equal(i, 3);
  // Both refusals were written down, verbatim, with the host from the config.
  assert.equal(recorded.length, 2);
  assert.equal(recorded[0].status, 402);
  assert.equal(recorded[0].code, "payment_required");
  assert.equal(recorded[0].at, "2026-08-14T00:00:00Z");
  assert.equal(recorded[0].endpoint_host, "sync.example.test");
  // Backed off to the longest interval rather than hammering, and the failure
  // count was not advanced — a refusal is not evidence the transport is
  // degrading, so it must not shorten anything else's backoff.
  assert.deepEqual(sleeps, [60000, 60000]);
});

test("runLoop: a successful cycle clears a refusal that is no longer true", async () => {
  // A record that outlives its truth is worse than no record: `status` would
  // keep reporting a decision the server has since reversed.
  const cleared = [];
  let i = 0;
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
    cycleCall: async () => {
      i += 1;
      if (i === 1) { const refused = new Error("refused"); refused.status = 402; throw refused; }
      if (i === 2) return { pushSaturated: false };
      const stop = new Error("stop"); stop.retryable = false; throw stop;
    },
    isRetryableCall: (error) => error.retryable === true,
    isRefusalCall: (error) => typeof error.status === "number" && error.status >= 400 && error.status < 500,
    recordRefusalCall: async () => {},
    clearRefusalCall: async (team) => { cleared.push(team); },
    recordCycleCall: async () => {},
    nowCall: () => "2026-08-14T00:00:00Z",
    sleepCall: async () => {},
    eventCall: async () => {},
  }), /stop/);
  assert.deepEqual(cleared, [config.local_team]);
});

test("runLoop: a non-retryable error that is NOT a refusal still ends the loop", async () => {
  // The negative control. Staying up for everything would turn a malformed
  // config into an engine that spins forever saying nothing useful — exiting
  // is right for that, and the refusal case is the exception, not the rule.
  await assert.rejects(() => runLoop(config, {}, {
    collectInstallBaselineCall: async () => null, // not under test; skip the real scripts walk
    cycleCall: async () => { const bad = new Error("config is unreadable"); throw bad; },
    isRetryableCall: () => false,
    isRefusalCall: () => false,
    sleepCall: async () => {},
    eventCall: async () => {},
  }), /config is unreadable/);
});

test("pull bootstrap reports progress on stderr and leaves stdout as the result channel", async () => {
  const teamId = "018f3f7e-0000-7000-8000-000000000001";
  const serverId = "018f3f7e-0000-7000-8000-000000000002";
  // Both streams are captured, not just the one under test. `cmd_pull` reads
  // this process's stdout as the result -- result="$(... pull-bootstrap ...)"
  // then greps it for pull_bootstrap_result -- so a progress line landing there
  // is the regression this case exists to catch, and it is invisible unless
  // stdout is measured too.
  const out = [];
  const err = [];
  const realOut = process.stdout.write.bind(process.stdout);
  const realErr = process.stderr.write.bind(process.stderr);
  process.stdout.write = (chunk) => { out.push(String(chunk)); return true; };
  process.stderr.write = (chunk) => { err.push(String(chunk)); return true; };
  try {
    await pullBootstrap({
      team: "clone", "team-id": teamId,
      // The shape a hosted endpoint really has: the path IS the capability.
      endpoint: "https://user:pa55word@sync.example.test:8443/t/agsy_SECRETCAP123?q=1#f",
    }, {
      publicSnapshotCall: async () => ({
        server_instance_id: serverId, team_id: teamId, team_name: "source",
        min_available_seq: "0",
      }),
      requestPublicCall: async () => ({
        messages: [{ id: "01", seq: "1", envelope: { v: 1, cipher: "plain", blob: "x" } }],
        next_after: "1", has_more: false,
      }),
      evaluateCall: async () => ({
        status: "importable", policy_revision: "0", local_security_revision: "0",
      }),
      driverCall: async () => [{ type: "sync_apply_result", transport_cursor: "1", corrupt_count: 0 }],
      rosterDriverCall: async () => [],
      eventCall: async () => {},
    });
  } finally {
    process.stdout.write = realOut;
    process.stderr.write = realErr;
  }

  // stdout: exactly the result, still parseable as one JSON line.
  // Judged by CONTENT, not by a raw line count. Under `node --test` the test
  // runner itself transports its results over this same stdout, and its
  // serialized test:complete frame for the PREVIOUS test can flush into the
  // patched window on a slow machine -- observed on CI as a 2!==1 count with
  // the second "line" being the runner's frame, which no real consumer of
  // pullBootstrap ever sees (in production this code does not run under the
  // test runner). What this case actually protects: exactly one result line
  // lands on stdout, and no progress line does.
  const stdoutText = out.join("");
  const resultLines = stdoutText.split("\n").filter((line) =>
    line.startsWith('{"type":"pull_bootstrap_result"'));
  assert.equal(resultLines.length, 1, `stdout carried: ${JSON.stringify(out)}`);
  assert.equal(JSON.parse(resultLines[0]).type, "pull_bootstrap_result");
  assert.ok(!stdoutText.includes("agmsg: ["), "a progress line leaked onto stdout");

  // stderr: the operator can see it start, and can see it move. Both halves are
  // named, because when this stops moving the line it stopped on says whether
  // to look at the network or at the driver's child process.
  const stderrText = err.join("");
  assert.match(stderrText, /agmsg: \[\d+s\] pulling clone from sync\.example\.test:8443 /);
  // WHAT MUST NOT BE THERE, named one piece at a time. This is the line a person
  // pastes into an issue when a pull is taking too long, so the capability in
  // the path, the credential before the host, and the query and fragment beside
  // them all have to be absent -- and asserting the host is present does not say
  // that any of them are gone.
  for (const secret of ["agsy_SECRETCAP123", "pa55word", "/t/", "q=1", "#f"]) {
    assert.ok(!stderrText.includes(secret), `stderr must not carry ${secret}`);
  }
  assert.ok(!out.join("").includes("agsy_SECRETCAP123"), "stdout must not carry it either");
  assert.match(stderrText, /agmsg: \[\d+s\] fetching messages after /);
  assert.match(stderrText, /agmsg: \[\d+s\] applying 1 messages/);
});

test("pull bootstrap prints a server cursor only when it is a canonical sequence", async () => {
  // WHERE A MALFORMED CURSOR ACTUALLY COMES FROM. The first cursor is not ours:
  // it is `teamSnapshot.min_available_seq`, and `publicSnapshot` checks only the
  // team id and the server instance id -- the sequence is never validated, so a
  // server's value reaches the first progress line exactly as it was sent.
  //
  // The second page cannot be the case this pins, even though it looks like the
  // better one. A malformed `next_after` would have to survive the driver first,
  // and the real sqlite driver refuses a non-numeric `sync_pull_cursor`
  // (sqlite-sync.sh:891-897, `return 13`) before the loop comes round again. A
  // fixture built there is testing a path only a stubbed driver allows.
  //
  // The line matters because it is the one people paste when a pull is slow: an
  // escape sequence in a pasted log is a terminal doing what the server's
  // operator told it.
  const ESC = String.fromCharCode(27);
  const evil = `${ESC}[2Jwiped`;
  const teamId = "018f3f7e-0000-7000-8000-000000000001";

  const run = async (minAvailableSeq) => {
    const err = [];
    const realErr = process.stderr.write.bind(process.stderr);
    const realOut = process.stdout.write.bind(process.stdout);
    process.stderr.write = (chunk) => { err.push(String(chunk)); return true; };
    process.stdout.write = () => true;
    try {
      await pullBootstrap({
        team: "clone", "team-id": teamId, endpoint: "https://sync.example.test/t/agsy_X",
      }, {
        publicSnapshotCall: async () => ({
          server_instance_id: "018f3f7e-0000-7000-8000-000000000002",
          team_id: teamId, team_name: "source", min_available_seq: minAvailableSeq,
        }),
        requestPublicCall: async () => ({ messages: [], next_after: "9", has_more: false }),
        evaluateCall: async () => ({ status: "importable" }),
        driverCall: async () => [{ type: "sync_apply_result", transport_cursor: "9", corrupt_count: 0 }],
        rosterDriverCall: async () => [],
        eventCall: async () => {},
      });
    } finally {
      process.stderr.write = realErr;
      process.stdout.write = realOut;
    }
    return err.join("");
  };

  const bad = await run(evil);
  assert.match(bad, /fetching messages after an unreadable cursor /);
  assert.ok(!bad.includes(ESC), "no escape byte reaches stderr");
  assert.ok(!bad.includes("wiped"), "and nothing that rode with it");

  // The control on the replacement: a sequence prints as itself. Without this a
  // guard that had decayed into printing the placeholder for everything would
  // satisfy every assertion above -- redacting and erasing are not the same act.
  const good = await run("41");
  assert.match(good, /fetching messages after 41 /);
  assert.ok(!good.includes("an unreadable cursor"), "a real sequence is not replaced");
});

test("driver() waits out a busy store and retries; anything else is asked once", async (t) => {
  // #910: the storage adapter exits STORAGE_BUSY_EXIT when another writer held
  // the store past the busy timeout. That is a fact about the moment, so the
  // call is repeated with a growing wait, within a budget; every other non-zero
  // exit is a decision and is not asked again.
  const root = await mkdtemp(join(tmpdir(), "agmsg-busy-"));
  const previousDriver = process.env.AGMSG_SYNC_DRIVER;
  t.after(async () => {
    if (previousDriver === undefined) delete process.env.AGMSG_SYNC_DRIVER;
    else process.env.AGMSG_SYNC_DRIVER = previousDriver;
    if (!root.startsWith(tmpdir())) throw new Error("unsafe test root");
    await rm(root, { recursive: true, force: true });
  });
  const config = {
    local_team: "t", server_instance_id: "018f3f7e-0000-7000-8000-000000000001",
    remote_team_id: "018f3f7e-0000-7000-8000-000000000002", protocol_version: 1,
  };
  const counter = join(root, "calls");
  // A driver that is busy for its first `busyFor` calls and answers after that.
  const useDriver = async (name, busyFor, exitWith = STORAGE_BUSY_EXIT) => {
    const script = join(root, name);
    await writeFile(script, [
      "#!/usr/bin/env bash",
      "cat > /dev/null",
      `n=$(( $(cat ${shellQuote(counter)} 2>/dev/null || echo 0) + 1 ))`,
      `printf %s "$n" > ${shellQuote(counter)}`,
      `if [ "$n" -le ${busyFor} ]; then`,
      "  echo 'agmsg: sqlite-sync: prepare: the store is busy -- another writer held it' >&2",
      `  exit ${exitWith}`,
      "fi",
      "printf '%s\\n' '{\"type\":\"sync_state\",\"transport_cursor\":\"0\"}'",
      "",
    ].join("\n"), { mode: 0o755 });
    await writeFile(counter, "0");
    process.env.AGMSG_SYNC_DRIVER = script;
  };
  const waits = [];
  const events = [];
  const dependencies = {
    sleepCall: async (ms) => { waits.push(ms); },
    eventCall: async (name, fields) => { events.push({ name, ...fields }); },
  };

  // Busy twice, then answered: two waits, doubling, and the answer comes back.
  await useDriver("busy-twice.sh", 2);
  const result = await driver("prepare", config, [], [], dependencies);
  assert.deepEqual(result, [{ type: "sync_state", transport_cursor: "0" }]);
  assert.equal(await readFile(counter, "utf8"), "3");
  assert.deepEqual(waits, [1000, 2000]);
  assert.deepEqual(events.map((e) => [e.name, e.operation, e.attempt, e.wait_ms, e.waited_ms]),
    [["driver.busy", "prepare", 1, 1000, 0], ["driver.busy", "prepare", 2, 2000, 1000]]);

  // Busy past the budget: the driver's own sentence comes back, marked
  // retryable and named, with how long this waited. The budget is a constant
  // (5 min) and the sleep is injected, so the whole ladder runs in no time:
  // 1+2+4+8+16 s, then 30 s steps, and the 14th attempt would need 301 s.
  await useDriver("busy-always.sh", 1000);
  waits.length = 0;
  await assert.rejects(() => driver("prepare", config, [], [], dependencies), (error) =>
    error.code === "storage-busy" && isRetryable(error) &&
    error.driverExitCode === STORAGE_BUSY_EXIT &&
    /storage sync prepare failed for team 't' \(exit 11\): agmsg: sqlite-sync: prepare: the store is busy/u.test(error.message) &&
    /waited 271 s for the store to come free \(the 300 s budget\) and it did not/u.test(error.message));
  assert.deepEqual(waits, [1000, 2000, 4000, 8000, 16000, ...Array(8).fill(30000)]);
  assert.equal(await readFile(counter, "utf8"), "14");
  assert.equal(waits.reduce((sum, ms) => sum + ms, 0), 271000);

  // A failed check (13) is a decision: asked once, not retried, not retryable.
  await useDriver("refuses.sh", 1000, 13);
  waits.length = 0;
  await assert.rejects(() => driver("prepare", config, [], [], dependencies), (error) =>
    error.driverExitCode === 13 && !isRetryable(error) && error.code === undefined);
  assert.equal(await readFile(counter, "utf8"), "1");
  assert.deepEqual(waits, []);
});
