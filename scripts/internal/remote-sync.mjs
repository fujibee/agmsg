#!/usr/bin/env node
import { createHash } from "node:crypto";
import { constants } from "node:fs";
import { spawn } from "node:child_process";
import { appendFile, lstat, mkdir, open, readFile, rename, stat, writeFile } from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { ageExecutableVersion, CipherStateError, openEnvelope,
  readNativeAgeIdentity } from "./sync-cipher.mjs";
import { parseStrictJson, parseStrictJsonl } from "./strict-jsonl.mjs";
export { parseStrictJson, parseStrictJsonl } from "./strict-jsonl.mjs";

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const SEQUENCE = /^(0|[1-9][0-9]*)$/;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/;
const PROTOCOL = "1";
const MAX_SEQUENCE = 9_223_372_036_854_775_807n;
const CREDENTIAL_ID = /^[A-Za-z0-9._-]{1,128}$/u;

function usage() {
  return `usage:
  remote-sync.sh configure --team NAME --server URL --team-id UUID --minimum-security e2ee-required \\
    --cipher age-v1 --age-snapshot FILE --age-checkpoint REVISION:SHA256 \\
    --age-confirmation operator-live \\
    [--age-identity KEY_ID=FILE ...]
  remote-sync.sh once --team NAME [--limit N]
  remote-sync.sh run --team NAME [--limit N] [--interval SECONDS]
  remote-sync.sh reprocess --team NAME [--limit N]
  remote-sync.sh resync --team NAME --accept-floor SEQUENCE
  remote-sync.sh unblock-read --team NAME --member-id UUID

Run remote.sh connect first. The engine reads that team's private credential
file directly; credentials are never accepted through argv or environment.`;
}

function options(args) {
  const result = { _: [] };
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (!value.startsWith("--")) { result._.push(value); continue; }
    const next = args[index + 1];
    if (next === undefined || next.startsWith("--")) throw new Error(`missing value for ${value}`);
    const key = value.slice(2);
    if (key === "age-identity") {
      if (!Array.isArray(result[key])) result[key] = [];
      result[key].push(next);
    } else {
      result[key] = next;
    }
    index += 1;
  }
  return result;
}

function requireName(value, label) {
  if (typeof value !== "string" || [...value].length < 1 || [...value].length > 128 ||
      value.startsWith("-") || value === "." || value === ".." ||
      /[./\\"\[\]\u0000-\u001f\u007f]/u.test(value) || value !== value.normalize("NFC")) {
    throw new Error(`${label} is invalid`);
  }
  return value;
}

function sequence(value, label) {
  if (typeof value !== "string" || !SEQUENCE.test(value) || BigInt(value) > MAX_SEQUENCE) {
    throw new Error(`${label} is not a canonical sequence`);
  }
  return value;
}

function configPath(team) {
  const root = process.env.AGMSG_SYNC_STORAGE_DIR;
  if (!root) throw new Error("AGMSG_SYNC_STORAGE_DIR is not set");
  return join(root, "remote-sync", `${encodeURIComponent(team)}.json`);
}

function teamConfigPath(team) {
  const connectionRoot = process.env.AGMSG_SYNC_CONNECTION_DIR ?? process.env.SKILL_DIR;
  if (!connectionRoot) throw new Error("sync connection root is unavailable");
  return join(connectionRoot, "teams", team, "config.json");
}

function credentialPath(team) {
  const connectionRoot = process.env.AGMSG_SYNC_CONNECTION_DIR ?? process.env.SKILL_DIR;
  if (!connectionRoot) throw new Error("sync connection root is unavailable");
  return join(connectionRoot, "run", "remote-credentials", `${team}.json`);
}

function connectedBinding(value, team) {
  const binding = value?.remote_binding;
  if (value?.name !== team || !binding || typeof binding !== "object" ||
      typeof binding.endpoint !== "string" || binding.endpoint.length < 1 ||
      !CREDENTIAL_ID.test(binding.credential_id ?? "") ||
      !UUID_V7.test(binding.server_instance_id ?? "") ||
      !UUID_V7.test(binding.remote_team_id ?? "") || binding.protocol_version !== 1 ||
      typeof binding.connected_at !== "string" || Number.isNaN(Date.parse(binding.connected_at)) ||
      binding.disconnected_at !== null || !binding.capabilities ||
      !Array.isArray(binding.capabilities.write_allowed_ciphers) ||
      binding.capabilities.write_allowed_ciphers.some((cipher) => typeof cipher !== "string")) {
    throw new Error("connected team binding is invalid or disconnected");
  }
  const connectedEndpoint = new URL(binding.endpoint);
  if (connectedEndpoint.protocol !== "https:" &&
      (connectedEndpoint.protocol !== "http:" ||
       !["127.0.0.1", "localhost", "[::1]"].includes(connectedEndpoint.hostname))) {
    throw new Error("connected team endpoint must use HTTPS or exact loopback HTTP");
  }
  endpoint(binding.endpoint, "/v1/health");
  return binding;
}

async function readConnectedBinding(team) {
  const bytes = await readFile(teamConfigPath(team));
  const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  return connectedBinding(parseStrictJson(source), team);
}

export async function readConnectedCredential(config) {
  const path = credentialPath(config.local_team);
  const before = await lstat(path);
  if (!before.isFile() || before.isSymbolicLink() ||
      (process.platform !== "win32" && (before.mode & 0o077) !== 0)) {
    throw new Error("remote credential must be a private regular file");
  }
  const handle = await open(path, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  try {
    const metadata = await handle.stat();
    if (!metadata.isFile() || metadata.dev !== before.dev || metadata.ino !== before.ino ||
        (process.platform !== "win32" && (metadata.mode & 0o077) !== 0)) {
      throw new Error("remote credential changed while it was being opened");
    }
    const source = new TextDecoder("utf-8", { fatal: true }).decode(await handle.readFile());
    const records = parseStrictJsonl(source);
    const value = records[0];
    if (records.length !== 1 || !value || typeof value !== "object" || Array.isArray(value) ||
        Object.keys(value).sort().join(",") !== "credential,credential_id" ||
        typeof value.credential !== "string" || value.credential.length < 1 ||
        /[\u0000-\u001f\u007f]/u.test(value.credential) ||
        !CREDENTIAL_ID.test(value.credential_id) ||
        (config.credential_id && value.credential_id !== config.credential_id)) {
      throw new Error("remote credential file is invalid or does not match the binding");
    }
    return value.credential;
  } finally {
    await handle.close();
  }
}

function ageTrustPath(config) {
  const root = process.env.AGMSG_SYNC_TRUST_DIR;
  if (!root) throw new Error("AGMSG_SYNC_TRUST_DIR is required for age-v1 and must survive sync-state reset");
  const resolvedRoot = resolve(root);
  const storageRoot = resolve(process.env.AGMSG_SYNC_STORAGE_DIR ?? "");
  if (resolvedRoot === storageRoot || resolvedRoot.startsWith(`${storageRoot}${sep}`)) {
    throw new Error("AGMSG_SYNC_TRUST_DIR must be outside the resettable sync storage directory");
  }
  return join(resolvedRoot,
    `age-v1-${config.server_instance_id}-${config.remote_team_id}-v${config.protocol_version}.json`);
}

async function writeConfig(path, value) {
  const directory = dirname(path);
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const temporary = join(directory, `.${basename(path)}.${process.pid}.tmp`);
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600, flag: "wx" });
  await rename(temporary, path);
}

async function readStoredSyncConfig(team) {
  const bytes = await readFile(configPath(team));
  return parseStrictJson(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
}

export async function loadConfig(team) {
  const binding = await readConnectedBinding(team);
  let value;
  try {
    value = await readStoredSyncConfig(team);
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    if (!binding.capabilities.write_allowed_ciphers.includes("none")) {
      throw new Error("connected team requires an authenticated age-v1 sync configuration");
    }
    value = {
      format_version: 1,
      local_team: team,
      server_url: binding.endpoint,
      server_instance_id: binding.server_instance_id,
      remote_team_id: binding.remote_team_id,
      protocol_version: binding.protocol_version,
      cipher_profile: "none",
      local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
        minimum_security_mode: "plaintext-allowed" }],
    };
  }
  if (value.server_url !== binding.endpoint ||
      value.server_instance_id !== binding.server_instance_id ||
      value.remote_team_id !== binding.remote_team_id ||
      value.protocol_version !== binding.protocol_version) {
    throw new Error("sync configuration does not match the connected team binding");
  }
  value.credential_id = binding.credential_id;
  if (value.local_team !== team || value.protocol_version !== 1 ||
      !UUID_V7.test(value.server_instance_id) || !UUID_V7.test(value.remote_team_id)) {
    throw new Error("sync config binding is invalid");
  }
  value.cipher_profile ??= "none";
  validateLocalSecurityHistory(value.local_security_history);
  if (value.cipher_profile === "age-v1") {
    validateAgeConfiguration(value);
    await validateRetainedAgeCheckpoint(value);
  }
  else if (value.cipher_profile !== "none") throw new Error("sync cipher profile is unsupported");
  await readConnectedCredential(value);
  return value;
}

async function localAgentRoster(team) {
  const supplied = process.env.AGMSG_SYNC_LOCAL_ROSTER_FILE;
  const skillRoot = process.env.SKILL_DIR;
  const path = supplied || (skillRoot ? join(skillRoot, "teams", team, "config.json") : "");
  if (!path) throw new Error("local team roster path is unavailable");
  const value = JSON.parse(await readFile(path, "utf8"));
  if (!value?.agents || typeof value.agents !== "object" || Array.isArray(value.agents)) {
    throw new Error("local team roster is invalid");
  }
  const names = Object.keys(value.agents).map((name) => requireName(name, "local agent name")).sort();
  if (names.length > 1000 || new Set(names).size !== names.length) {
    throw new Error("local team roster is invalid");
  }
  return names;
}

function requireUnicodeScalars(value, label) {
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (index + 1 >= value.length || next < 0xdc00 || next > 0xdfff) {
        throw new Error(`${label} contains a lone surrogate`);
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      throw new Error(`${label} contains a lone surrogate`);
    }
  }
}

function canonicalJson(value) {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "string") {
    requireUnicodeScalars(value, "snapshot string");
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("snapshot contains a non-finite number");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    return `{${Object.keys(value).sort().map((key) => {
      requireUnicodeScalars(key, "snapshot key");
      return `${JSON.stringify(key)}:${canonicalJson(value[key])}`;
    }).join(",")}}`;
  }
  throw new Error("snapshot contains a non-JSON value");
}

export function ageSnapshotDigest(value) {
  return createHash("sha256").update(canonicalJson(value), "utf8").digest("hex");
}

function validateLocalSecurityHistory(history) {
  if (!Array.isArray(history) || history.length < 1 || history.length > 4096) {
    throw new Error("local security history is invalid");
  }
  let priorRevision = -1n;
  let priorBoundary = 0n;
  for (const entry of history) {
    const revision = BigInt(sequence(entry.local_security_revision, "local security revision"));
    const boundary = BigInt(sequence(entry.effective_from_seq, "local security boundary"));
    if (revision <= priorRevision || boundary <= priorBoundary ||
        !["plaintext-allowed", "e2ee-required"].includes(entry.minimum_security_mode)) {
      throw new Error("local security history is not canonical");
    }
    priorRevision = revision;
    priorBoundary = boundary;
  }
  if (history[0].effective_from_seq !== "1") throw new Error("local security history must begin at 1");
}

export function validateAgeConfiguration(config) {
  const age = config.age_v1;
  const snapshot = age?.epoch_snapshot;
  const checkpoint = age?.checkpoint;
  if (!age || !snapshot || !checkpoint || snapshot.profile !== "age-v1" ||
      snapshot.server_instance_id !== config.server_instance_id || snapshot.team_id !== config.remote_team_id ||
      !Array.isArray(snapshot.authorized_writers) || snapshot.authorized_writers.length < 1 ||
      new Set(snapshot.authorized_writers).size !== snapshot.authorized_writers.length ||
      snapshot.authorized_writers.some((writer) => typeof writer !== "string" || writer.length < 1) ||
      !Array.isArray(snapshot.history) || snapshot.history.length < 1 || snapshot.history.length > 4096 ||
      !age.identity_files || typeof age.identity_files !== "object" || Array.isArray(age.identity_files) ||
      Object.entries(age.identity_files).some(([keyId, path]) =>
        !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(keyId) || typeof path !== "string" || path.length < 1) ||
      typeof age.age_version !== "string" || age.age_version.length < 1) {
    throw new Error("age-v1 configuration is invalid");
  }
  const snapshotRevision = sequence(snapshot.epoch_revision, "epoch_revision");
  sequence(snapshot.writer_generation, "writer_generation");
  if (snapshotRevision !== "0") {
    throw new Error("age-v1 dogfood currently accepts only an initial revision-0 epoch snapshot");
  }
  if ((snapshotRevision === "0" && snapshot.previous_snapshot_sha256 !== null) ||
      (snapshotRevision !== "0" && (typeof snapshot.previous_snapshot_sha256 !== "string" ||
        !/^[0-9a-f]{64}$/u.test(snapshot.previous_snapshot_sha256)))) {
    throw new Error("epoch snapshot previous digest is invalid");
  }
  let priorRevision = -1n;
  let priorBoundary = 0n;
  for (const entry of snapshot.history) {
    const revision = BigInt(sequence(entry.epoch_revision, "epoch history revision"));
    const boundary = BigInt(sequence(entry.effective_from_seq, "epoch history boundary"));
    if (revision <= priorRevision || boundary <= priorBoundary || entry.cipher !== "age-v1" ||
        typeof entry.key_id !== "string" || !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(entry.key_id) ||
        !Array.isArray(entry.recipients) || entry.recipients.length < 1 || entry.recipients.length > 256 ||
        new Set(entry.recipients).size !== entry.recipients.length ||
        entry.recipients.some((recipient) => typeof recipient !== "string" || !/^age1[0-9a-z]{58}$/u.test(recipient))) {
      throw new Error("age epoch history is not canonical");
    }
    priorRevision = revision;
    priorBoundary = boundary;
  }
  if (snapshot.history[0].effective_from_seq !== "1" ||
      snapshot.history.at(-1).epoch_revision !== snapshot.epoch_revision) {
    throw new Error("age epoch history does not cover the snapshot revision");
  }
  const digest = ageSnapshotDigest(snapshot);
  if (checkpoint.epoch_revision !== snapshot.epoch_revision || checkpoint.snapshot_sha256 !== digest ||
      checkpoint.writer_generation !== snapshot.writer_generation ||
      typeof checkpoint.confirmed_at !== "string" || Number.isNaN(Date.parse(checkpoint.confirmed_at))) {
    throw new Error("age epoch checkpoint does not match the snapshot");
  }
  return digest;
}

export function validateConfiguredAgeIdentities(config) {
  for (const [keyId, path] of Object.entries(config.age_v1.identity_files)) {
    const identity = readNativeAgeIdentity(path);
    const matchingEpochs = config.age_v1.epoch_snapshot.history.filter((entry) => entry.key_id === keyId);
    if (matchingEpochs.length < 1 || matchingEpochs.some((entry) => !entry.recipients.includes(identity.recipient))) {
      throw new Error(`age identity for ${keyId} does not match its recipient manifest`);
    }
  }
}

function checkpointRecord(config, confirmation) {
  return {
    format_version: 1,
    profile: "age-v1",
    server_instance_id: config.server_instance_id,
    team_id: config.remote_team_id,
    protocol_version: config.protocol_version,
    epoch_revision: config.age_v1.checkpoint.epoch_revision,
    snapshot_sha256: config.age_v1.checkpoint.snapshot_sha256,
    writer_generation: config.age_v1.checkpoint.writer_generation,
    confirmation: { method: confirmation, confirmed_at: config.age_v1.checkpoint.confirmed_at },
  };
}

function compareRetainedCheckpoint(config, retained) {
  const proposed = checkpointRecord(config, retained.confirmation?.method);
  if (retained.format_version !== 1 || retained.profile !== "age-v1" ||
      retained.server_instance_id !== proposed.server_instance_id || retained.team_id !== proposed.team_id ||
      retained.protocol_version !== proposed.protocol_version || retained.confirmation?.method !== "operator-live") {
    throw new Error("retained age checkpoint is invalid");
  }
  const retainedRevision = BigInt(sequence(retained.epoch_revision, "retained epoch revision"));
  const proposedRevision = BigInt(sequence(proposed.epoch_revision, "proposed epoch revision"));
  const retainedGeneration = BigInt(sequence(retained.writer_generation, "retained writer generation"));
  const proposedGeneration = BigInt(sequence(proposed.writer_generation, "proposed writer generation"));
  if (proposedRevision < retainedRevision || proposedGeneration < retainedGeneration ||
      (proposedRevision === retainedRevision && retained.snapshot_sha256 !== proposed.snapshot_sha256)) {
    throw new Error("age checkpoint rollback or same-revision conflict detected");
  }
  if (proposedRevision !== retainedRevision || proposedGeneration !== retainedGeneration) {
    throw new Error("age checkpoint advancement requires the fenced rotation workflow");
  }
  return retained;
}

async function readRetainedCheckpointFile(path) {
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink() ||
      (process.platform !== "win32" && (metadata.mode & 0o077) !== 0)) {
    throw new Error("retained age checkpoint must be a private regular file");
  }
  return JSON.parse(await readFile(path, "utf8"));
}

export async function retainAgeCheckpoint(config, confirmation) {
  const path = ageTrustPath(config);
  try {
    return compareRetainedCheckpoint(config, await readRetainedCheckpointFile(path));
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
  if (confirmation !== "operator-live") {
    throw new Error("initial age checkpoint requires --age-confirmation operator-live");
  }
  const retained = checkpointRecord(config, confirmation);
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const directoryMetadata = await lstat(dirname(path));
  if (!directoryMetadata.isDirectory() ||
      (process.platform !== "win32" && (directoryMetadata.mode & 0o077) !== 0)) {
    throw new Error("AGMSG_SYNC_TRUST_DIR must be a private directory");
  }
  try {
    const handle = await open(path, "wx", 0o600);
    try {
      await handle.writeFile(`${JSON.stringify(retained)}\n`, "utf8");
      await handle.sync();
    } finally {
      await handle.close();
    }
    if (process.platform !== "win32") {
      const directoryHandle = await open(dirname(path), "r");
      try {
        await directoryHandle.sync();
      } finally {
        await directoryHandle.close();
      }
    }
    return retained;
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    return compareRetainedCheckpoint(config, await readRetainedCheckpointFile(path));
  }
}

export async function validateRetainedAgeCheckpoint(config) {
  const retained = await readRetainedCheckpointFile(ageTrustPath(config));
  compareRetainedCheckpoint(config, retained);
  if (retained.confirmation.confirmed_at !== config.age_v1.checkpoint.confirmed_at) {
    throw new Error("sync config does not match the retained age checkpoint confirmation");
  }
}

function endpoint(base, path) {
  const root = new URL(base);
  if (root.username || root.password || root.search || root.hash) {
    throw new Error("server URL must not contain credentials, query, or fragment");
  }
  const prefix = root.pathname.replace(/\/$/, "");
  const separator = path.indexOf("?");
  const pathname = separator === -1 ? path : path.slice(0, separator);
  const query = separator === -1 ? "" : path.slice(separator + 1);
  root.pathname = `${prefix}${pathname}`;
  root.search = query;
  return root;
}

export async function request(config, path, init = {}) {
  const token = await readConnectedCredential(config);
  const headers = {
    "Agmsg-Protocol-Version": PROTOCOL,
    "Agmsg-Team-ID": config.remote_team_id,
    Authorization: `Bearer ${token}`,
    ...init.headers,
  };
  const url = endpoint(config.server_url, path);
  let response;
  try {
    response = await fetch(url, {
      ...init, headers, redirect: "error", signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    error.retryable = true;
    throw error;
  }
  const protocol = response.headers.get("agmsg-protocol-version");
  let text;
  try { text = await response.text(); } catch (error) {
    error.retryable = true;
    throw error;
  }
  let body;
  try { body = JSON.parse(text); } catch {
    if (!response.ok && [502, 503, 504].includes(response.status)) {
      const error = new Error(`HTTP ${response.status} intermediary failure`);
      error.status = response.status; error.retryable = true;
      throw error;
    }
    throw new Error(`HTTP ${response.status} returned invalid JSON`);
  }
  if (protocol !== PROTOCOL) {
    if (!response.ok && [502, 503, 504].includes(response.status)) {
      const error = new Error(`HTTP ${response.status} intermediary failure`);
      error.status = response.status; error.retryable = true;
      throw error;
    }
    throw new Error("response protocol version mismatch");
  }
  if (!response.ok) {
    validateErrorBinding(config, response.status, body);
    const code = body?.error?.code ?? "unknown-error";
    const error = new Error(`HTTP ${response.status} ${code}`);
    error.status = response.status; error.code = code; error.body = body;
    throw error;
  }
  validateBinding(config, body);
  return body;
}

export function validateErrorBinding(config, status, body) {
  const preResolution = status === 400 || status === 401 || status === 426;
  const carriesBinding = body?.server_instance_id !== undefined || body?.team_id !== undefined;
  if (!preResolution || carriesBinding) validateBinding(config, body);
}

async function health(serverUrl) {
  let response;
  try {
    response = await fetch(endpoint(serverUrl, "/v1/health"), {
      redirect: "error", signal: AbortSignal.timeout(15_000),
    });
  } catch (error) {
    error.retryable = true;
    throw error;
  }
  if (response.headers.get("agmsg-protocol-version") !== PROTOCOL) {
    throw new Error("health protocol version mismatch");
  }
  const body = await response.json();
  if (!response.ok || body.status !== "ok" || body.database !== "ok" || !UUID_V7.test(body.server_instance_id)) {
    const error = new Error("server health is unavailable or unbound");
    error.status = response.status;
    error.retryable = response.status === 503;
    throw error;
  }
  return body;
}

function validateBinding(config, body) {
  if (body?.protocol_version !== 1 || body?.server_instance_id !== config.server_instance_id ||
      body?.team_id !== config.remote_team_id) {
    throw new Error("server/team binding mismatch");
  }
}

export function validateMembers(config, value) {
  validateBinding(config, value);
  sequence(value.min_available_seq, "members min_available_seq");
  sequence(value.members_revision, "members_revision");
  if (!Array.isArray(value.members) || value.members.length > 1000) {
    throw new Error("members response is invalid");
  }
  const ids = new Set();
  const names = new Set();
  const registrationIds = new Set();
  let previous = "";
  for (const member of value.members) {
    if (!member || !UUID_V7.test(member.member_id) ||
        requireName(member.name, "member name") !== member.name ||
        !Array.isArray(member.registrations) || ids.has(member.member_id) ||
        names.has(member.name) || (previous && member.member_id <= previous)) {
      throw new Error("members response is not canonical");
    }
    let priorRegistration = "";
    for (const registration of member.registrations) {
      if (Object.keys(registration).sort().join(",") !==
          "installation_id,registration_id,type" ||
          !UUID_V7.test(registration.registration_id) ||
          !UUID_V7.test(registration.installation_id) ||
          typeof registration.type !== "string" ||
          !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(registration.type) ||
          registrationIds.has(registration.registration_id) ||
          (priorRegistration && registration.registration_id <= priorRegistration)) {
        throw new Error("member registrations are not canonical");
      }
      registrationIds.add(registration.registration_id);
      priorRegistration = registration.registration_id;
    }
    ids.add(member.member_id); names.add(member.name); previous = member.member_id;
  }
  return value.members.map(({ member_id, name }) => ({ member_id, name }));
}

export async function driver(operation, config, input, extra = []) {
  const script = process.env.AGMSG_SYNC_DRIVER;
  if (!script) throw new Error("AGMSG_SYNC_DRIVER is not set");
  const args = [script, operation, config.local_team, config.server_instance_id,
    config.remote_team_id, String(config.protocol_version), ...extra];
  return new Promise((resolve, reject) => {
    const childEnvironment = { ...process.env };
    delete childEnvironment.AGMSG_SYNC_TOKEN;
    delete childEnvironment.AGMSG_SYNC_CONNECTION_DIR;
    delete childEnvironment.AGMSG_SYNC_TRUST_DIR;
    for (const key of Object.keys(childEnvironment)) {
      if (/^(?:AGMSG_AGE_IDENTITY|AGMSG_SYNC_AGE_IDENTITY)/u.test(key)) {
        delete childEnvironment[key];
      }
    }
    const child = spawn("bash", args, { stdio: ["pipe", "pipe", "pipe"], env: childEnvironment });
    let stdout = ""; let stderr = "";
    child.stdout.setEncoding("utf8"); child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(["resync-status", "resync"].includes(operation) ?
        parseStrictJsonl(stdout) : parseJsonl(stdout));
      else reject(new Error(`storage sync ${operation} failed (${code}): ${stderr.trim()}`));
    });
    child.stdin.end(input.map((record) => `${JSON.stringify(record)}\n`).join(""));
  });
}

function parseJsonl(value) {
  return value.split(/\r?\n/u).filter(Boolean).map((line) => JSON.parse(line));
}

async function event(name, fields = {}) {
  const record = { at: new Date().toISOString(), event: name, ...fields };
  const line = `${JSON.stringify(record)}\n`;
  process.stdout.write(line);
  if (process.env.AGMSG_SYNC_LOG_FILE) {
    await appendFile(process.env.AGMSG_SYNC_LOG_FILE, line, { encoding: "utf8", mode: 0o600 });
  }
}

async function logApplyOutcomes(config, records, applied) {
  for (const outcome of applied.filter((record) => record.type === "sync_apply_outcome")) {
    const source = records.find((record) => record.type === "sync_pull_message" && record.id === outcome.id);
    await event(outcome.status === "imported" ? "pull.import" :
      outcome.status === "reconciled" ? "pull.reconciled" : "pull.quarantined", {
      id: outcome.id, server_seq: outcome.server_seq, status: outcome.status,
      ...(outcome.status === "imported" && source?.projection &&
        (config.cipher_profile === "none" || process.env.AGMSG_SYNC_LOG_PLAINTEXT === "1") ? {
        from_agent: source.projection.from_agent, to_agent: source.projection.to_agent,
        body: source.projection.body,
      } : {}),
    });
  }
}

function currentPolicy(capabilities, serverSeq) {
  const target = BigInt(serverSeq);
  const candidates = capabilities.policy_history.filter((entry) =>
    BigInt(sequence(entry.effective_from_seq, "policy effective_from_seq")) <= target);
  if (candidates.length === 0) throw new Error("policy history has no effective entry");
  return candidates.reduce((best, entry) => BigInt(entry.policy_revision) > BigInt(best.policy_revision) ? entry : best);
}

function currentLocalPolicy(config, serverSeq) {
  const target = BigInt(serverSeq);
  const candidates = config.local_security_history.filter((entry) => BigInt(entry.effective_from_seq) <= target);
  if (candidates.length === 0) throw new Error("local security history has no effective entry");
  return candidates.reduce((best, entry) => BigInt(entry.local_security_revision) > BigInt(best.local_security_revision) ? entry : best);
}

function currentAgeEpoch(config, serverSeq) {
  const history = config.age_v1?.epoch_snapshot?.history;
  if (!Array.isArray(history) || history.length < 1) return null;
  const target = BigInt(sequence(serverSeq, "age epoch server_seq"));
  const candidates = history.filter((entry) =>
    BigInt(sequence(entry.effective_from_seq, "age epoch effective_from_seq")) <= target);
  if (candidates.length === 0) return null;
  return candidates.reduce((best, entry) =>
    BigInt(entry.epoch_revision) > BigInt(best.epoch_revision) ? entry : best);
}

export async function evaluatePull(config, capabilities, message) {
  sequence(message.server_seq, "message server_seq");
  if (!UUID_V4.test(message.id) || !TIMESTAMP.test(message.server_received_at) || typeof message.envelope !== "object") {
    return { status: "malformed", reason: "invalid message metadata" };
  }
  const serverPolicy = currentPolicy(capabilities, message.server_seq);
  const localPolicy = currentLocalPolicy(config, message.server_seq);
  if (!serverPolicy.accepted_envelope_versions.includes(message.envelope.v) ||
      !serverPolicy.write_allowed_ciphers.includes(message.envelope.cipher) ||
      (localPolicy.minimum_security_mode === "e2ee-required" && message.envelope.cipher === "none")) {
    return { status: "policy_violation", reason: "envelope violates effective policy",
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
  if (message.envelope.v !== 1 || !["none", "age-v1"].includes(message.envelope.cipher)) {
    return { status: "unsupported_cipher", reason: "cipher profile is not implemented",
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
  let identityFile;
  if (message.envelope.cipher === "age-v1") {
    if (config.cipher_profile !== "age-v1" || !config.age_v1) {
      return { status: "unsupported_cipher", reason: "age-v1 is not configured",
        policy_revision: serverPolicy.policy_revision,
        local_security_revision: localPolicy.local_security_revision };
    }
    const epoch = currentAgeEpoch(config, message.server_seq);
    if (!epoch || message.envelope.key_id !== epoch.key_id) {
      return { status: "policy_violation", reason: "envelope key_id violates effective epoch",
        policy_revision: serverPolicy.policy_revision,
        local_security_revision: localPolicy.local_security_revision };
    }
    identityFile = config.age_v1.identity_files?.[epoch.key_id];
  }
  try {
    const projection = await openEnvelope({ envelope: message.envelope,
      protocol_version: config.protocol_version, team_id: config.remote_team_id,
      wire_id: message.id, identity_file: identityFile,
      expected_recipients: message.envelope.cipher === "age-v1" ?
        currentAgeEpoch(config, message.server_seq).recipients : undefined,
      max_blob_bytes: 1_048_576 });
    return { status: "importable", projection,
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  } catch (error) {
    const status = error instanceof CipherStateError ? error.state : "malformed";
    return { status, reason: error.message,
      policy_revision: serverPolicy.policy_revision,
      local_security_revision: localPolicy.local_security_revision };
  }
}

export function validateCapabilities(config, value) {
  validateBinding(config, value);
  sequence(value.current_seq, "current_seq"); sequence(value.min_available_seq, "min_available_seq");
  if (!Array.isArray(value.policy_history) || value.policy_history.length < 1 || value.policy_history.length > 4096 ||
      !Array.isArray(value.accepted_envelope_versions) || !Array.isArray(value.write_allowed_ciphers)) {
    throw new Error("capabilities response is invalid");
  }
  const current = BigInt(value.current_seq);
  const floor = BigInt(value.min_available_seq);
  if (floor > current) throw new Error("min_available_seq exceeds current_seq");
  const currentRevision = BigInt(sequence(value.policy_revision, "policy_revision"));
  const currentBoundary = BigInt(sequence(value.effective_from_seq, "effective_from_seq"));
  sequence(value.max_blob_bytes, "max_blob_bytes");
  if (BigInt(value.max_blob_bytes) < 1n || BigInt(value.max_blob_bytes) > 1_048_576n) {
    throw new Error("max_blob_bytes is outside the protocol limit");
  }
  validatePolicySet(value.accepted_envelope_versions, value.write_allowed_ciphers, "current policy");
  let previousRevision = -1n;
  let previousBoundary = 0n;
  for (const entry of value.policy_history) {
    const revision = BigInt(sequence(entry.policy_revision, "policy history revision"));
    const boundary = BigInt(sequence(entry.effective_from_seq, "policy history boundary"));
    validatePolicySet(entry.accepted_envelope_versions, entry.write_allowed_ciphers, "policy history");
    if (revision <= previousRevision || boundary <= previousBoundary) {
      throw new Error("policy history is not canonical ascending history");
    }
    previousRevision = revision; previousBoundary = boundary;
  }
  if (BigInt(value.policy_history[0].effective_from_seq) !== 1n) {
    throw new Error("policy history must begin at sequence 1");
  }
  const final = value.policy_history.at(-1);
  if (BigInt(final.policy_revision) !== currentRevision ||
      BigInt(final.effective_from_seq) !== currentBoundary ||
      !sameArray(final.accepted_envelope_versions, value.accepted_envelope_versions) ||
      !sameArray(final.write_allowed_ciphers, value.write_allowed_ciphers)) {
    throw new Error("current policy does not match final policy history entry");
  }
  if (value.next_sequence_boundary === null) {
    if (current !== MAX_SEQUENCE) throw new Error("next_sequence_boundary is unexpectedly null");
  } else {
    const next = BigInt(sequence(value.next_sequence_boundary, "next_sequence_boundary"));
    if (current === MAX_SEQUENCE || next !== current + 1n) {
      throw new Error("next_sequence_boundary does not follow current_seq");
    }
    if (previousBoundary > next) throw new Error("policy history starts beyond the next sequence boundary");
  }
}

function validatePolicySet(versions, ciphers, label) {
  if (!Array.isArray(versions) || versions.length < 1 ||
      versions.some((version) => !Number.isInteger(version) || version < 0 || version > 0xffff_ffff) ||
      new Set(versions).size !== versions.length || !Array.isArray(ciphers) ||
      ciphers.some((cipher) => typeof cipher !== "string" || !/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(cipher)) ||
      new Set(ciphers).size !== ciphers.length) {
    throw new Error(`${label} capability set is invalid`);
  }
}

function sameArray(left, right) {
  return left.length === right.length && left.every((value, index) => value === right[index]);
}

export function plaintextWriteEligible(config, value) {
  validateCapabilities(config, value);
  const boundary = value.next_sequence_boundary;
  return boundary !== null && value.accepted_envelope_versions.includes(1) &&
    value.write_allowed_ciphers.includes("none") &&
    currentLocalPolicy(config, boundary).minimum_security_mode === "plaintext-allowed";
}

export function selectWriteProfile(config, value) {
  validateCapabilities(config, value);
  const boundary = value.next_sequence_boundary;
  const profile = config.cipher_profile ?? "none";
  if (boundary === null) return { eligible: false, reason: "sequence-exhausted", profile };
  if (!value.accepted_envelope_versions.includes(1) || !value.write_allowed_ciphers.includes(profile)) {
    return { eligible: false, reason: `${profile}-write-not-allowed`, profile };
  }
  const localPolicy = currentLocalPolicy(config, boundary);
  if (profile === "none") {
    return localPolicy.minimum_security_mode === "plaintext-allowed" ?
      { eligible: true, profile, key_id: null, recipients: [] } :
      { eligible: false, reason: "local-e2ee-required", profile };
  }
  if (profile === "age-v1") {
    const epoch = currentAgeEpoch(config, boundary);
    if (!epoch || !Array.isArray(epoch.recipients)) {
      return { eligible: false, reason: "age-epoch-unavailable", profile };
    }
    return { eligible: true, profile, key_id: epoch.key_id, recipients: epoch.recipients };
  }
  return { eligible: false, reason: "cipher-profile-unsupported", profile };
}

export function isRetryable(error) {
  if (error?.retryable === true) return true;
  return [408, 429, 500, 502, 503, 504].includes(error?.status);
}

export function validateAckMapping(candidates, acks) {
  if (!Array.isArray(acks) || acks.length !== candidates.length) {
    throw new Error("incomplete ack mapping");
  }
  const seenIds = new Set();
  const seenSequences = new Set();
  let previous = -1n;
  return acks.map((ack, index) => {
    const candidate = candidates[index];
    const fields = Object.keys(ack).sort().join(",");
    if (fields !== "disposition,id,server_seq" || ack.id !== candidate.id ||
        !["stored", "duplicate"].includes(ack.disposition)) {
      throw new Error("ack shape/order/id mismatch");
    }
    sequence(ack.server_seq, "ack server_seq");
    const current = BigInt(ack.server_seq);
    if (seenIds.has(ack.id) || seenSequences.has(ack.server_seq) || current <= previous) {
      throw new Error("ack sequence mapping is not strictly increasing and unique");
    }
    seenIds.add(ack.id); seenSequences.add(ack.server_seq); previous = current;
    return { type: "sync_push_ack", local_position: candidate.local_position, id: ack.id,
      server_seq: ack.server_seq, disposition: ack.disposition };
  });
}

export function readStateUpdateBatches(members, records) {
  const memberIds = new Set(members.map((member) => member.member_id));
  const frontiers = new Map();
  const exact = new Map(members.map((member) => [member.member_id, []]));
  const blocked = new Map();
  for (const record of records) {
    if (!memberIds.has(record.member_id)) throw new Error("driver emitted an unknown read member");
    if (record.type === "sync_read_frontier") {
      if (frontiers.has(record.member_id)) throw new Error("driver emitted duplicate read frontier");
      frontiers.set(record.member_id, sequence(record.server_seq, "prepared read frontier"));
    } else if (record.type === "sync_read_exact") {
      if (!UUID_V4.test(record.wire_id)) throw new Error("driver emitted an invalid exact wire ID");
      exact.get(record.member_id).push(record.wire_id);
    } else if (record.type === "sync_read_blocked") {
      if (blocked.has(record.member_id) ||
          !["member-name-mismatch", "read-state-limit-exceeded"].includes(record.reason)) {
        throw new Error("driver emitted an invalid blocked read member");
      }
      blocked.set(record.member_id, record.reason);
    } else {
      throw new Error("driver emitted an unknown read-state record");
    }
  }
  const entries = [];
  for (const member of members) {
    if (blocked.has(member.member_id)) {
      if (frontiers.has(member.member_id) || exact.get(member.member_id).length > 0) {
        throw new Error("driver emitted updates for a blocked read member");
      }
      continue;
    }
    const serverSeq = frontiers.get(member.member_id);
    if (serverSeq === undefined) throw new Error("driver omitted a member read frontier");
    const wires = exact.get(member.member_id);
    if (new Set(wires).size !== wires.length) throw new Error("driver emitted duplicate exact reads");
    if (wires.length === 0) {
      entries.push({ member_id: member.member_id, server_seq: serverSeq, exact_wire_ids: [] });
    } else {
      for (let offset = 0; offset < wires.length; offset += 1000) {
        entries.push({ member_id: member.member_id, server_seq: serverSeq,
          exact_wire_ids: wires.slice(offset, offset + 1000) });
      }
    }
  }
  const batches = [];
  let batch = []; let exactCount = 0; let batchMembers = new Set();
  for (const entry of entries) {
    if (batch.length >= 1000 || exactCount + entry.exact_wire_ids.length > 1000 ||
        batchMembers.has(entry.member_id)) {
      batches.push(batch); batch = []; exactCount = 0; batchMembers = new Set();
    }
    batch.push(entry); exactCount += entry.exact_wire_ids.length; batchMembers.add(entry.member_id);
  }
  if (batch.length > 0) batches.push(batch);
  return batches.length > 0 ? batches : [[]];
}

export function stage2ReadStateSupported(records) {
  if (!Array.isArray(records) || records.length !== 1 ||
      records[0]?.type !== "sync_driver_capabilities" ||
      !Array.isArray(records[0].capabilities) ||
      records[0].capabilities.some((value) => typeof value !== "string")) {
    throw new Error("driver capability response is invalid");
  }
  return records[0].capabilities.includes("stage2-read-state");
}

export function stage1ResyncSupported(records) {
  if (!Array.isArray(records) || records.length !== 1 ||
      records[0]?.type !== "sync_driver_capabilities" ||
      !Array.isArray(records[0].capabilities) ||
      records[0].capabilities.some((value) => typeof value !== "string") ||
      new Set(records[0].capabilities).size !== records[0].capabilities.length) {
    throw new Error("driver capability response is invalid");
  }
  return records[0].capabilities.includes("stage1-resync");
}

function strictKeys(value, expected, label) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== [...expected].sort().join(",")) {
    throw new Error(`${label} shape is invalid`);
  }
}

function validDriverGeneration(value) {
  return typeof value === "string" && Buffer.byteLength(value, "utf8") >= 1 &&
    Buffer.byteLength(value, "utf8") <= 256 && !/[\u0000-\u001f\u007f]/u.test(value);
}

function validateResyncAudit(audit, floor, transportCursor, label) {
  strictKeys(audit, ["expected_transport_cursor", "accepted_floor", "gap_start",
    "gap_end", "reason"], label);
  const expected = BigInt(sequence(audit.expected_transport_cursor, `${label} expected cursor`));
  const accepted = BigInt(sequence(audit.accepted_floor, `${label} accepted floor`));
  const start = BigInt(sequence(audit.gap_start, `${label} gap start`));
  const end = BigInt(sequence(audit.gap_end, `${label} gap end`));
  const current = BigInt(sequence(transportCursor, `${label} transport cursor`));
  if (audit.accepted_floor !== floor || end !== accepted || start !== expected + 1n ||
      expected >= accepted || accepted > current || audit.reason !== "retention-gap-accepted") {
    throw new Error(`${label} is inconsistent`);
  }
  return audit;
}

export function validateResyncStatus(records, floor) {
  sequence(floor, "accepted floor");
  if (!Array.isArray(records) || records.length !== 1) {
    throw new Error("driver must emit exactly one resync status");
  }
  const status = records[0];
  strictKeys(status, ["type", "driver_generation", "transport_cursor", "audit"],
    "resync status");
  if (status.type !== "sync_resync_status" || !validDriverGeneration(status.driver_generation)) {
    throw new Error("resync status is invalid");
  }
  sequence(status.transport_cursor, "resync transport cursor");
  if (status.audit !== null) {
    validateResyncAudit(status.audit, floor, status.transport_cursor, "resync audit");
  }
  return status;
}

export function validateResyncResult(records, status, floor) {
  if (!Array.isArray(records) || records.length !== 1) {
    throw new Error("driver must emit exactly one resync result");
  }
  const result = records[0];
  strictKeys(result, ["type", "driver_generation", "expected_transport_cursor",
    "transport_cursor", "accepted_floor", "gap_start", "gap_end", "reason"],
  "resync result");
  if (result.type !== "sync_resync_result" ||
      result.driver_generation !== status.driver_generation ||
      result.transport_cursor !== floor) {
    throw new Error("resync result is invalid");
  }
  validateResyncAudit({
    expected_transport_cursor: result.expected_transport_cursor,
    accepted_floor: result.accepted_floor,
    gap_start: result.gap_start,
    gap_end: result.gap_end,
    reason: result.reason,
  }, floor, result.transport_cursor, "resync result");
  return result;
}

export function validateReadStatePage(config, value, pageLimit, pageAfter = null) {
  validateBinding(config, value);
  const floor = BigInt(sequence(value.min_available_seq, "read-state floor"));
  const current = BigInt(sequence(value.current_seq, "read-state current_seq"));
  if (floor > current || !Array.isArray(value.items) || value.items.length > pageLimit ||
      (value.has_more === true && value.items.length === 0) ||
      typeof value.has_more !== "boolean") {
    throw new Error("read-state response is invalid");
  }
  const afterKey = pageAfter === null ? null : [pageAfter.member_id,
    pageAfter.kind === "frontier" ? 0 : 1, pageAfter.wire_id ?? ""];
  let prior = afterKey;
  for (const item of value.items) {
    const fields = Object.keys(item).sort().join(",");
    if (!UUID_V7.test(item?.member_id) ||
        (item.kind === "frontier" && (fields !== "kind,member_id,server_seq" ||
          BigInt(sequence(item.server_seq, "read-state frontier")) < floor ||
          BigInt(item.server_seq) > current)) ||
        (item.kind === "exact" && (fields !== "kind,member_id,wire_id" || !UUID_V4.test(item.wire_id))) ||
        !["frontier", "exact"].includes(item.kind)) {
      throw new Error("read-state item is invalid");
    }
    const key = [item.member_id, item.kind === "frontier" ? 0 : 1, item.wire_id ?? ""];
    if (prior && (key[0] < prior[0] || (key[0] === prior[0] &&
        (key[1] < prior[1] || (key[1] === prior[1] && key[2] <= prior[2]))))) {
      throw new Error("read-state page order is not canonical");
    }
    prior = key;
  }
  const expectedNext = value.has_more && value.items.length > 0 ? (() => {
    const last = value.items.at(-1);
    return last.kind === "frontier" ? { member_id: last.member_id, kind: "frontier" } :
      { member_id: last.member_id, kind: "exact", wire_id: last.wire_id };
  })() : null;
  if (JSON.stringify(value.next_page_after) !== JSON.stringify(expectedNext)) {
    throw new Error("read-state next page key is inconsistent");
  }
  return value;
}

export async function consistentReadStateContext(config, initialCapabilities, fetcher = request) {
  let capabilities = initialCapabilities;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const roster = await fetcher(config, "/v1/members");
    const members = validateMembers(config, roster);
    if (roster.min_available_seq === capabilities.min_available_seq) {
      return { capabilities, members };
    }
    capabilities = await fetcher(config, "/v1/capabilities");
    validateCapabilities(config, capabilities);
  }
  const error = new Error("retention changed while loading the read-state context");
  error.retryable = true;
  throw error;
}

function parseCheckpoint(value) {
  const match = /^(0|[1-9][0-9]*):([0-9a-f]{64})$/u.exec(value ?? "");
  if (!match) throw new Error("age-checkpoint must be REVISION:SHA256");
  sequence(match[1], "age checkpoint revision");
  return { epoch_revision: match[1], snapshot_sha256: match[2] };
}

async function identityFiles(values) {
  const result = {};
  for (const value of values ?? []) {
    const separator = value.indexOf("=");
    const keyId = separator === -1 ? "" : value.slice(0, separator);
    const suppliedPath = separator === -1 ? "" : value.slice(separator + 1);
    if (!/^[a-z0-9][a-z0-9._-]{0,63}$/u.test(keyId) || !suppliedPath || result[keyId]) {
      throw new Error("age-identity must be a unique KEY_ID=FILE mapping");
    }
    const path = resolve(suppliedPath);
    const metadata = await stat(path);
    if (!metadata.isFile()) throw new Error(`age identity for ${keyId} is not a file`);
    if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
      throw new Error(`age identity for ${keyId} must not be group/world accessible`);
    }
    result[keyId] = path;
  }
  return result;
}

async function existingConfig(team) {
  try {
    await readStoredSyncConfig(team);
    return await loadConfig(team);
  }
  catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function configure(args) {
  const team = requireName(args.team, "team");
  if (!UUID_V7.test(args["team-id"] ?? "")) throw new Error("team-id must be a canonical UUIDv7");
  const cipherProfile = args.cipher ?? "none";
  const minimumSecurity = args["minimum-security"];
  if (!["none", "age-v1"].includes(cipherProfile)) throw new Error("cipher must be none or age-v1");
  if ((cipherProfile === "none" && minimumSecurity !== "plaintext-allowed") ||
      (cipherProfile === "age-v1" && minimumSecurity !== "e2ee-required")) {
    throw new Error(`${cipherProfile} requires its explicit matching minimum-security mode`);
  }
  const serverUrl = new URL(args.server).toString().replace(/\/$/, "");
  const binding = await readConnectedBinding(team);
  if (serverUrl !== binding.endpoint || args["team-id"] !== binding.remote_team_id) {
    throw new Error("configure binding does not match remote.sh connect");
  }
  const ready = await health(serverUrl);
  if (ready.server_instance_id !== binding.server_instance_id) {
    throw new Error("health server instance does not match remote.sh connect");
  }
  const config = {
    format_version: 1, local_team: team, server_url: serverUrl,
    server_instance_id: ready.server_instance_id, remote_team_id: args["team-id"],
    protocol_version: 1, credential_id: binding.credential_id, cipher_profile: cipherProfile,
    local_security_history: [{ local_security_revision: "0", effective_from_seq: "1",
      minimum_security_mode: minimumSecurity }],
  };
  if (cipherProfile === "age-v1") {
    if (!args["age-snapshot"] || !args["age-checkpoint"]) {
      throw new Error("age-v1 requires --age-snapshot and --age-checkpoint");
    }
    const snapshotText = await readFile(resolve(args["age-snapshot"]), "utf8");
    const snapshot = JSON.parse(snapshotText);
    if (snapshotText.trim() !== canonicalJson(snapshot)) {
      throw new Error("age snapshot must be RFC 8785 JCS without duplicate or noncanonical fields");
    }
    const checkpoint = parseCheckpoint(args["age-checkpoint"]);
    const confirmation = args["age-confirmation"];
    if (confirmation !== "operator-live") {
      throw new Error("age-v1 requires explicit --age-confirmation operator-live");
    }
    config.age_v1 = {
      epoch_snapshot: snapshot,
      checkpoint: { ...checkpoint, writer_generation: snapshot.writer_generation,
        confirmed_at: new Date().toISOString() },
      identity_files: await identityFiles(args["age-identity"]),
      age_version: ageExecutableVersion(),
    };
    validateAgeConfiguration(config);
    validateConfiguredAgeIdentities(config);
    const retained = await retainAgeCheckpoint(config, confirmation);
    config.age_v1.checkpoint.confirmed_at = retained.confirmation.confirmed_at;
  } else if (args["age-snapshot"] || args["age-checkpoint"] || args["age-confirmation"] ||
      args["age-identity"]) {
    throw new Error("age options require --cipher age-v1");
  }
  const previous = await existingConfig(team);
  if (previous && (previous.server_instance_id !== config.server_instance_id ||
      previous.remote_team_id !== config.remote_team_id || previous.cipher_profile !== config.cipher_profile)) {
    throw new Error("configure cannot replace an existing binding or cipher profile");
  }
  if (previous?.cipher_profile === "age-v1" &&
      (previous.age_v1.checkpoint.epoch_revision !== config.age_v1.checkpoint.epoch_revision ||
       previous.age_v1.checkpoint.snapshot_sha256 !== config.age_v1.checkpoint.snapshot_sha256 ||
       previous.age_v1.checkpoint.writer_generation !== config.age_v1.checkpoint.writer_generation)) {
    throw new Error("age epoch changes require the fenced cutover procedure");
  }
  const capabilities = await request(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  await writeConfig(configPath(team), config);
  await event("configured", { team, server_instance_id: config.server_instance_id,
    remote_team_id: config.remote_team_id });
}

export async function readStateCycle(config, limit, dependencies = {}) {
  const driverCall = dependencies.driverCall ?? driver;
  const requestCall = dependencies.requestCall ?? request;
  const eventCall = dependencies.eventCall ?? event;
  const localAgentsCall = dependencies.localAgentsCall ?? localAgentRoster;
  const driverCapabilities = await driverCall("capabilities", config, []);
  if (!stage2ReadStateSupported(driverCapabilities)) {
    await eventCall("read-state.skipped", { reason: "driver-capability-not-advertised" });
    return;
  }
  const initialCapabilities = await requestCall(config, "/v1/capabilities");
  validateCapabilities(config, initialCapabilities);
  const { capabilities, members } = await consistentReadStateContext(
    config, initialCapabilities, requestCall,
  );
  const localAgents = await localAgentsCall(config.local_team);
  const prepared = await driverCall("read-prepare", config, [{ type: "sync_read_context",
    min_available_seq: capabilities.min_available_seq, current_seq: capabilities.current_seq,
    members, local_agents: localAgents }]);
  const batches = readStateUpdateBatches(members, prepared);
  const pageLimit = Math.min(limit, 1000);
  let page;
  const blockedThisCycle = new Set();
  for (const updates of batches) {
    let remaining = updates.filter((update) => !blockedThisCycle.has(update.member_id));
    for (;;) {
      try {
        page = await requestCall(config, "/v1/read-state/sync", { method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ updates: remaining, page_after: null, page_limit: pageLimit }) });
        break;
      } catch (error) {
        const reportedMemberId = error?.body?.error?.details?.member_id;
        const memberId = remaining.some((update) => update.member_id === reportedMemberId)
          ? reportedMemberId
          : remaining.find((update) => update.exact_wire_ids.length > 0)?.member_id;
        if (error?.code !== "read-state-limit-exceeded" || !UUID_V7.test(reportedMemberId ?? "") ||
            !members.some((member) => member.member_id === reportedMemberId) ||
            !UUID_V7.test(memberId ?? "") || blockedThisCycle.has(memberId)) {
          throw error;
        }
        blockedThisCycle.add(memberId);
        await driverCall("read-block", config, [{ type: "sync_read_block", member_id: memberId,
          reason: "read-state-limit-exceeded" }]);
        remaining = remaining.filter((update) => update.member_id !== memberId);
        await eventCall("read-state.blocked", { member_id: memberId,
          reported_member_id: reportedMemberId, reason: "read-state-limit-exceeded" });
      }
    }
  }
  let pageAfter = null;
  let pageCount = 0;
  const seenFrontiers = new Set();
  for (;;) {
    if (pageAfter !== null) {
      page = await requestCall(config, "/v1/read-state/sync", { method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ updates: [], page_after: pageAfter, page_limit: pageLimit }) });
    }
    validateReadStatePage(config, page, pageLimit, pageAfter);
    for (const item of page.items) {
      if (item.kind === "frontier" && seenFrontiers.has(item.member_id)) {
        throw new Error("read-state stream repeated a member frontier");
      }
      if (item.kind === "frontier") seenFrontiers.add(item.member_id);
    }
    const records = [{ type: "sync_read_snapshot",
      min_available_seq: page.min_available_seq, current_seq: page.current_seq },
    ...page.items.map((item) => item.kind === "frontier" ?
      { type: "sync_read_frontier", member_id: item.member_id, server_seq: item.server_seq } :
      { type: "sync_read_exact", member_id: item.member_id, wire_id: item.wire_id })];
    const applied = await driverCall("read-apply", config, records);
    pageCount += 1;
    if (pageCount > 65_536 + members.length + 1) {
      throw new Error("read-state pagination exceeded the bounded stream size");
    }
    await eventCall("read-state.applied", { page: pageCount, item_count: page.items.length,
      result: applied[0] ?? null });
    if (!page.has_more) break;
    pageAfter = page.next_page_after;
  }
  if (seenFrontiers.size !== members.length ||
      members.some((member) => !seenFrontiers.has(member.member_id))) {
    throw new Error("read-state stream omitted a member frontier");
  }
}

async function cycle(config, limit) {
  const ready = await health(config.server_url);
  if (ready.server_instance_id !== config.server_instance_id) throw new Error("health server instance changed");
  const capabilities = await request(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  await event("capabilities", { team: config.local_team, current_seq: capabilities.current_seq,
    policy_revision: capabilities.policy_revision });

  const writeProfile = selectWriteProfile(config, capabilities);
  const prepared = await driver("prepare", config, [{ type: "sync_prepare", envelope_v: 1,
    cipher: writeProfile.profile, key_id: writeProfile.key_id ?? null,
    recipients: writeProfile.recipients ?? [], max_blob_bytes: Number(capabilities.max_blob_bytes),
    allow_new: writeProfile.eligible }], [String(limit)]);
  const state = prepared.find((record) => record.type === "sync_state");
  const candidates = prepared.filter((record) => record.type === "sync_push_candidate");
  if (!state) throw new Error("driver omitted sync_state");
  sequence(state.transport_cursor, "transport_cursor");
  await event("push.prepared", { count: candidates.length, local_positions: candidates.map((item) => item.local_position),
    wire_ids: candidates.map((item) => item.id) });

  if (!writeProfile.eligible) {
    await event("push.blocked", { reason: writeProfile.reason });
  } else if (candidates.length > 0) {
    const posted = await request(config, "/v1/messages", { method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ messages: candidates.map(({ id, envelope }) => ({ id, envelope })) }) });
    const ackRecords = validateAckMapping(candidates, posted.acks);
    await event("push.ack", { acks: ackRecords.map(({ id, server_seq, disposition }) => ({ id, server_seq, disposition })) });
    const reconciled = await driver("reconcile", config, ackRecords);
    await event("push.reconciled", { result: reconciled[0] ?? null });
  }

  let cursor = state.transport_cursor;
  let pullCapabilities = capabilities;
  for (;;) {
    const page = await request(config, `/v1/messages?after=${encodeURIComponent(cursor)}&limit=${limit}`);
    sequence(page.next_after, "next_after");
    if (!Array.isArray(page.messages) || page.messages.length > limit || typeof page.has_more !== "boolean") {
      throw new Error("pull page is invalid");
    }
    let expected = BigInt(cursor) + 1n;
    for (const message of page.messages) {
      sequence(message.server_seq, "message server_seq");
      if (BigInt(message.server_seq) !== expected) throw new Error("pull page sequence is not contiguous");
      expected += 1n;
    }
    const expectedNext = page.messages.at(-1)?.server_seq ?? cursor;
    if (page.next_after !== expectedNext || (page.has_more && page.messages.length === 0)) {
      throw new Error("pull page cursor/has_more is inconsistent");
    }
    if (BigInt(page.next_after) > BigInt(pullCapabilities.current_seq)) {
      pullCapabilities = await request(config, "/v1/capabilities");
      validateCapabilities(config, pullCapabilities);
      if (BigInt(page.next_after) > BigInt(pullCapabilities.current_seq)) {
        throw new Error("capability history does not cover the pull page");
      }
    }
    const records = [];
    for (const message of page.messages) {
      const evaluated = await evaluatePull(config, pullCapabilities, message);
      records.push({ type: "sync_pull_message", ...message, ...evaluated });
    }
    records.push({ type: "sync_pull_cursor", next_after: page.next_after });
    await event("pull.received", { after: cursor, next_after: page.next_after,
      messages: page.messages.map((message) => ({ id: message.id, server_seq: message.server_seq })) });
    const applied = await driver("apply", config, records);
    await logApplyOutcomes(config, records, applied);
    await event("pull.applied", { result: applied[0] ?? null });
    cursor = page.next_after;
    if (!page.has_more) break;
  }
  await readStateCycle(config, limit);
}

function reprocessCandidateToken(candidate) {
  return `${candidate.server_seq}:${candidate.id}`;
}

function validateReprocessDriverPage(pending, limit, requestedAfter) {
  const recordKeys = (value) => Object.keys(value).sort().join(",");
  const states = pending.filter((record) => record.type === "sync_state");
  const candidates = pending.filter((record) => record.type === "sync_reprocess_candidate");
  const pages = pending.filter((record) => record.type === "sync_reprocess_page");
  if (states.length !== 1 || pages.length !== 1 || candidates.length > limit ||
      pending.length !== states.length + candidates.length + pages.length) {
    throw new Error("driver reprocess page shape is invalid");
  }
  const page = pages[0];
  if (recordKeys(page) !== "has_more,next_after,type" || typeof page.has_more !== "boolean" ||
      (page.has_more ? typeof page.next_after !== "string" : page.next_after !== null) ||
      (page.has_more && candidates.length === 0)) {
    throw new Error("driver reprocess pagination is invalid");
  }
  let previous = requestedAfter;
  for (const candidate of candidates) {
    if (recordKeys(candidate) !==
        "envelope,id,prior_status,server_received_at,server_seq,type" ||
        candidate.type !== "sync_reprocess_candidate" || !UUID_V4.test(candidate.id) ||
        typeof candidate.server_received_at !== "string" ||
        typeof candidate.prior_status !== "string" || !candidate.envelope) {
      throw new Error("driver reprocess candidate is invalid");
    }
    sequence(candidate.server_seq, "reprocess server_seq");
    const token = reprocessCandidateToken(candidate);
    if (previous !== null) {
      const separator = previous.indexOf(":");
      const previousSequence = sequence(previous.slice(0, separator), "reprocess page server_seq");
      const previousId = previous.slice(separator + 1);
      if (separator < 1 || !UUID_V4.test(previousId) ||
          BigInt(candidate.server_seq) < BigInt(previousSequence) ||
          (candidate.server_seq === previousSequence && candidate.id <= previousId)) {
        throw new Error("driver reprocess page did not advance");
      }
    }
    previous = token;
  }
  if (page.has_more && page.next_after !== previous) {
    throw new Error("driver reprocess next page token is inconsistent");
  }
  return { state: states[0], candidates, page };
}

export async function reprocessCycle(config, limit, dependencies = {}) {
  const healthCall = dependencies.healthCall ?? health;
  const requestCall = dependencies.requestCall ?? request;
  const driverCall = dependencies.driverCall ?? driver;
  const evaluateCall = dependencies.evaluateCall ?? evaluatePull;
  const eventCall = dependencies.eventCall ?? event;
  const logApplyCall = dependencies.logApplyCall ?? logApplyOutcomes;
  const ready = await healthCall(config.server_url);
  if (ready.server_instance_id !== config.server_instance_id) throw new Error("health server instance changed");
  const capabilities = await requestCall(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  let after = null;
  let stableState = null;
  let total = 0;
  let pageCount = 0n;
  const retentionFloor = BigInt(capabilities.min_available_seq);
  // Locally retained quarantine may cover both the server-retained suffix and
  // the unavailable prefix, so the authenticated lifetime sequence space is
  // floor + (current-floor), rather than only the current retained window.
  const authenticatedSequenceSpace = retentionFloor +
    (BigInt(capabilities.current_seq) - retentionFloor);
  const seenTokens = new Set();
  const seenSequences = new Set();
  for (;;) {
    pageCount += 1n;
    if (pageCount > authenticatedSequenceSpace + 1n) {
      throw new Error("driver reprocess walk exceeds authenticated sequence space");
    }
    const extra = [String(limit), ...(after === null ? [] : [after])];
    const pending = await driverCall("reprocess", config, [], extra);
    const { state, candidates, page } = validateReprocessDriverPage(pending, limit, after);
    sequence(state.transport_cursor, "transport_cursor");
    if (stableState && (state.transport_cursor !== stableState.transport_cursor ||
        state.driver_generation !== stableState.driver_generation)) {
      throw new Error("driver reprocess state changed between pages");
    }
    stableState ??= state;
    const records = [];
    for (const candidate of candidates) {
      const token = reprocessCandidateToken(candidate);
      if (seenTokens.has(token)) throw new Error("driver reprocess repeated a candidate");
      seenTokens.add(token);
      if (candidate.server_seq === "0") {
        throw new Error("driver reprocess candidate has no canonical server sequence");
      }
      if (seenSequences.has(candidate.server_seq)) {
        throw new Error("driver reprocess mapped one server sequence to multiple wire ids");
      }
      seenSequences.add(candidate.server_seq);
      if (BigInt(seenSequences.size) > authenticatedSequenceSpace) {
        throw new Error("driver reprocess candidate count exceeds authenticated sequence space");
      }
      if (BigInt(candidate.server_seq) > BigInt(capabilities.current_seq)) {
        throw new Error("quarantine sequence exceeds authenticated server state");
      }
      const message = { server_seq: candidate.server_seq, id: candidate.id,
        server_received_at: candidate.server_received_at, envelope: candidate.envelope };
      const evaluated = await evaluateCall(config, capabilities, message);
      records.push({ type: "sync_pull_message", ...message, ...evaluated });
    }
    if (records.length > 0) {
      records.push({ type: "sync_pull_cursor", next_after: state.transport_cursor });
      const applied = await driverCall("apply", config, records);
      await logApplyCall(config, records, applied);
      total += candidates.length;
    }
    if (!page.has_more) break;
    if (seenTokens.has(page.next_after) && page.next_after === after) {
      throw new Error("driver reprocess pagination looped");
    }
    after = page.next_after;
  }
  await eventCall("reprocess.complete", { count: total,
    transport_cursor: stableState.transport_cursor });
}

function resultFromResyncAudit(status) {
  return {
    type: "sync_resync_result",
    driver_generation: status.driver_generation,
    expected_transport_cursor: status.audit.expected_transport_cursor,
    transport_cursor: status.audit.accepted_floor,
    accepted_floor: status.audit.accepted_floor,
    gap_start: status.audit.gap_start,
    gap_end: status.audit.gap_end,
    reason: status.audit.reason,
  };
}

export async function resyncCycle(config, acceptedFloor, dependencies = {}) {
  const driverCall = dependencies.driverCall ?? driver;
  const requestCall = dependencies.requestCall ?? request;
  const eventCall = dependencies.eventCall ?? event;
  const floor = sequence(acceptedFloor, "accepted floor");
  const driverCapabilities = await driverCall("capabilities", config, []);
  if (!stage1ResyncSupported(driverCapabilities)) {
    throw new Error("storage driver does not advertise stage1-resync");
  }
  const capabilities = await requestCall(config, "/v1/capabilities");
  validateCapabilities(config, capabilities);
  const status = validateResyncStatus(
    await driverCall("resync-status", config, [], [floor]), floor);
  const serverFloor = BigInt(capabilities.min_available_seq);
  const serverCurrent = BigInt(capabilities.current_seq);
  if (status.audit !== null) {
    if (BigInt(floor) > serverFloor || BigInt(status.transport_cursor) > serverCurrent) {
      throw new Error("recorded resync audit contradicts authenticated server state");
    }
    const result = resultFromResyncAudit(status);
    validateResyncResult([result], status, floor);
    await eventCall("resync.complete", { disposition: "already-accepted", result });
    return result;
  }
  if (floor !== capabilities.min_available_seq ||
      BigInt(status.transport_cursor) >= BigInt(floor) || BigInt(floor) > serverCurrent) {
    throw new Error("accepted floor does not match the active retention gap");
  }
  let retentionError;
  try {
    await requestCall(config,
      `/v1/messages?after=${encodeURIComponent(status.transport_cursor)}&limit=1`);
  } catch (error) {
    retentionError = error;
  }
  const details = retentionError?.body?.error?.details;
  if (retentionError?.status !== 410 || retentionError?.code !== "resync-required" ||
      retentionError.body?.min_available_seq !== floor ||
      details?.after !== status.transport_cursor || details?.min_available_seq !== floor) {
    throw new Error("server did not reproduce the authenticated retention gap");
  }
  const input = [{
    type: "sync_resync",
    expected_transport_cursor: status.transport_cursor,
    min_available_seq: floor,
    current_seq: capabilities.current_seq,
    reason: "retention-gap-accepted",
  }];
  const result = validateResyncResult(
    await driverCall("resync", config, input), status, floor);
  await eventCall("resync.complete", { disposition: "accepted", result });
  return result;
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const args = options(rest);
  if (!["configure", "once", "run", "reprocess", "resync", "unblock-read"].includes(command)) {
    throw new Error(usage());
  }
  if (command === "configure") { await configure(args); return; }
  const team = requireName(args.team, "team");
  const limit = Number(args.limit ?? 100);
  if (!Number.isInteger(limit) || limit < 1 || limit > 1000) throw new Error("limit must be 1..1000");
  const config = await loadConfig(team);
  if (command === "unblock-read") {
    if (!UUID_V7.test(args["member-id"] ?? "")) throw new Error("member-id must be a canonical UUIDv7");
    const result = await driver("read-unblock", config, [{
      type: "sync_read_unblock", member_id: args["member-id"],
    }]);
    await event("read-state.unblocked", { member_id: args["member-id"], result: result[0] ?? null });
    return;
  }
  if (command === "resync") {
    await resyncCycle(config, args["accept-floor"] ?? "");
    return;
  }
  if (command === "reprocess") { await reprocessCycle(config, limit); return; }
  if (command === "once") { await cycle(config, limit); return; }
  const interval = Number(args.interval ?? 5);
  if (!Number.isFinite(interval) || interval < 0.2) throw new Error("interval must be at least 0.2 seconds");
  for (;;) {
    try { await cycle(config, limit); }
    catch (error) {
      await event("cycle.error", { message: error.message, code: error.code ?? null });
      if (!isRetryable(error)) throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, interval * 1000));
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(async (error) => {
    await event("fatal", { message: error.message, code: error.code ?? null });
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
