#!/usr/bin/env node

import { createPrivateKey, createPublicKey, timingSafeEqual } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
// Namespace import, not `{ tmpdir, availableParallelism }`: availableParallelism
// only exists from Node 18.14, and a missing NAMED export is a link error that
// would break every seal, not just the batch path. Looked up defensively below.
import * as nodeOs from "node:os";
import { join } from "node:path";
import process from "node:process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import { Worker, isMainThread, parentPort, threadId, workerData } from "node:worker_threads";

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/u;
const KEY_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/u;
const EPOCH_REVISION = /^(0|[1-9][0-9]*)$/u;
const AGE_RECIPIENT = /^age1[0-9a-z]{58}$/u;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/u;
const MAGIC = Buffer.concat([Buffer.from("agmsg-age-v1", "ascii"), Buffer.alloc(4)]);
const MAX_BLOB_BYTES = 1_048_576;
const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

export class CipherStateError extends Error {
  constructor(state, message) {
    super(message);
    this.name = "CipherStateError";
    this.state = state;
  }
}

function malformed(message) {
  throw new CipherStateError("malformed", message);
}

function authenticationFailed(message) {
  throw new CipherStateError("authentication_failed", message);
}

function requireUnicodeScalars(value, label) {
  if (typeof value !== "string") malformed(`${label} is not a string`);
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff) {
      const next = value.charCodeAt(index + 1);
      if (index + 1 >= value.length || next < 0xdc00 || next > 0xdfff) {
        malformed(`${label} contains a lone surrogate`);
      }
      index += 1;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      malformed(`${label} contains a lone surrogate`);
    }
  }
  return value;
}

function validTimestamp(value) {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})Z$/u.exec(value ?? "");
  if (!match) return false;
  const [, year, month, day, hour, minute, second, micros] = match.map(Number);
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59) return false;
  const instant = new Date(0);
  instant.setUTCFullYear(year, month - 1, day);
  instant.setUTCHours(hour, minute, second, Math.floor(micros / 1000));
  return instant.getUTCFullYear() === year && instant.getUTCMonth() === month - 1 &&
    instant.getUTCDate() === day && instant.getUTCHours() === hour &&
    instant.getUTCMinutes() === minute && instant.getUTCSeconds() === second;
}

function requireName(value, label) {
  requireUnicodeScalars(value, label);
  const scalarLength = [...value].length;
  if (scalarLength < 1 || scalarLength > 128 ||
      value.startsWith("-") || value === "." || value === ".." ||
      /[./\\"\[\]\u0000-\u001f\u007f]/u.test(value) || value !== value.normalize("NFC")) {
    malformed(`${label} is invalid`);
  }
  return value;
}

function canonicalMessage(projection) {
  if (!projection || Array.isArray(projection) || typeof projection !== "object" ||
      typeof projection.body !== "string" || Buffer.byteLength(projection.body) < 1 ||
      Buffer.byteLength(projection.body) > 1_000_000 ||
      typeof projection.created_at !== "string" || !TIMESTAMP.test(projection.created_at) ||
      !validTimestamp(projection.created_at)) {
    malformed("message projection is invalid");
  }
  requireUnicodeScalars(projection.body, "body");
  requireName(projection.from_agent, "from_agent");
  requireName(projection.to_agent, "to_agent");
  return Buffer.from(JSON.stringify({
    body: projection.body,
    created_at: projection.created_at,
    from_agent: projection.from_agent,
    to_agent: projection.to_agent,
  }), "utf8");
}

function canonicalRosterMutation(projection) {
  if (!projection || Array.isArray(projection) || typeof projection !== "object" ||
      !["member_joined", "member_left", "member_renamed", "key_rotated"].includes(projection.kind) ||
      !UUID_V7.test(projection.mutation_id ?? "") ||
      typeof projection.occurred_at !== "string" ||
      !TIMESTAMP.test(projection.occurred_at) || !validTimestamp(projection.occurred_at)) {
    malformed("roster mutation projection is invalid");
  }
  if (projection.kind === "key_rotated") {
    if (!EPOCH_REVISION.test(projection.epoch ?? "") ||
        !KEY_ID.test(projection.key_id ?? "") ||
        typeof projection.fingerprint !== "string" ||
        !/^[0-9a-f]{64}$/u.test(projection.fingerprint)) {
      malformed("key rotation projection is invalid");
    }
    return Buffer.from(JSON.stringify({
      kind: projection.kind,
      mutation_id: projection.mutation_id,
      epoch: projection.epoch,
      key_id: projection.key_id,
      fingerprint: projection.fingerprint,
      occurred_at: projection.occurred_at,
    }), "utf8");
  }
  if (!UUID_V7.test(projection.member_id ?? "")) {
    malformed("roster mutation projection is invalid");
  }
  if (projection.kind === "member_renamed") {
    requireName(projection.from, "from");
    requireName(projection.to, "to");
    if (projection.from === projection.to) malformed("roster rename is a no-op");
    return Buffer.from(JSON.stringify({
      kind: projection.kind,
      mutation_id: projection.mutation_id,
      member_id: projection.member_id,
      from: projection.from,
      to: projection.to,
      occurred_at: projection.occurred_at,
    }), "utf8");
  }
  requireName(projection.name, "name");
  return Buffer.from(JSON.stringify({
    kind: projection.kind,
    mutation_id: projection.mutation_id,
    member_id: projection.member_id,
    name: projection.name,
    occurred_at: projection.occurred_at,
  }), "utf8");
}

// Legacy message plaintext has no discriminator and remains canonical forever.
// Only new union branches carry `kind`; requiring it for messages would make
// every existing sealed blob unreadable.
function canonicalProjection(projection) {
  return projection?.kind === undefined ?
    canonicalMessage(projection) : canonicalRosterMutation(projection);
}

function parseCanonicalProjection(bytes) {
  let text;
  let value;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    value = JSON.parse(text);
  } catch {
    malformed("message is not valid UTF-8 JSON");
  }
  const canonical = canonicalProjection(value);
  if (!canonical.equals(bytes)) malformed("projection is not canonical JCS");
  return value;
}

function canonicalBlob(blob, maxBlobBytes = MAX_BLOB_BYTES) {
  if (typeof blob !== "string" || blob.length < 1 || !BASE64.test(blob)) malformed("blob is not canonical base64");
  const bytes = Buffer.from(blob, "base64");
  if (bytes.length < 1 || bytes.length > maxBlobBytes || bytes.length > MAX_BLOB_BYTES ||
      bytes.toString("base64") !== blob) {
    malformed("blob is outside the canonical size limit");
  }
  return bytes;
}

function u16(value) {
  const result = Buffer.alloc(2);
  result.writeUInt16BE(value);
  return result;
}

function u32(value) {
  const result = Buffer.alloc(4);
  result.writeUInt32BE(value);
  return result;
}

function uuidBytes(value, pattern, label) {
  if (typeof value !== "string" || !pattern.test(value)) malformed(`${label} is invalid`);
  return Buffer.from(value.replaceAll("-", ""), "hex");
}

export function ageBindingContext({ protocol_version: protocolVersion, team_id: teamId,
  wire_id: wireId, cipher = "age-v1", key_id: keyId }) {
  if (!Number.isInteger(protocolVersion) || protocolVersion < 0 || protocolVersion > 0xffff_ffff ||
      cipher !== "age-v1" || typeof keyId !== "string" || !KEY_ID.test(keyId)) {
    malformed("age-v1 binding metadata is invalid");
  }
  const cipherBytes = Buffer.from(cipher, "ascii");
  const keyBytes = Buffer.from(keyId, "ascii");
  return Buffer.concat([
    u32(protocolVersion),
    uuidBytes(teamId, UUID_V7, "team_id"),
    uuidBytes(wireId, UUID_V4, "wire_id"),
    u16(cipherBytes.length), cipherBytes,
    u16(keyBytes.length), keyBytes,
  ]);
}

export function agePlaintextFrame(binding, projection) {
  const context = ageBindingContext(binding);
  const message = canonicalProjection(projection);
  return Buffer.concat([MAGIC, u32(context.length), context, u32(message.length), message]);
}

const MAX_AGE_HEADER_BYTES = 65_536;
const MAX_AGE_STANZAS = 512;
const MAX_AGE_X25519_STANZAS = 256;

export function validateAgeHeader(ageFile) {
  let offset = 0;
  let totalStanzaCount = 0;
  let x25519StanzaCount = 0;
  let insideStanza = false;
  let stanzaHasBody = false;
  let stanzaIsGrease = false;
  let stanzaBodyBytes = 0;
  let greaseBodyBase64 = "";
  let greaseShortBodySeen = false;
  function finishStanza() {
    if (!insideStanza || !stanzaHasBody) malformed("age recipient stanza header is invalid");
    if (stanzaIsGrease) {
      const canonical = Buffer.from(greaseBodyBase64, "base64")
        .toString("base64").replace(/=+$/u, "");
      if (canonical !== greaseBodyBase64) {
        malformed("age GREASE stanza body is not canonical base64");
      }
    }
  }
  function line() {
    const end = ageFile.indexOf(0x0a, offset);
    if (end === -1 || end - offset > 4096) malformed("age header is incomplete");
    const value = ageFile.subarray(offset, end).toString("ascii");
    if (!/^[\x20-\x7e]*$/u.test(value)) malformed("age header is not canonical ASCII");
    offset = end + 1;
    if (offset > MAX_AGE_HEADER_BYTES) malformed("age header size limit exceeded");
    return value;
  }
  if (line() !== "age-encryption.org/v1") malformed("blob is not an age v1 file");
  while (offset < ageFile.length) {
    const value = line();
    if (value.startsWith("-> ")) {
      const fields = value.split(" ");
      if (insideStanza) finishStanza();
      if (fields.length < 2 || fields.some((field) => field.length < 1)) {
        malformed("age recipient stanza header is invalid");
      }
      totalStanzaCount += 1;
      if (totalStanzaCount > MAX_AGE_STANZAS) malformed("age total stanza limit exceeded");
      if (fields[1] === "X25519") {
        if (fields.length !== 3) malformed("age X25519 stanza header is invalid");
        x25519StanzaCount += 1;
        if (x25519StanzaCount > MAX_AGE_X25519_STANZAS) {
          malformed("age-v1 X25519 stanza limit exceeded");
        }
        stanzaIsGrease = false;
      } else {
        const activeType = fields[1] === "scrypt" || fields[1] === "ssh-rsa" ||
          fields[1] === "ssh-ed25519" || fields[1].startsWith("plugin-");
        stanzaIsGrease = !activeType && /^[!-~]{1,8}-grease$/u.test(fields[1]) &&
          fields.length <= 6 && fields.slice(2).every((field) => /^[!-~]{1,8}$/u.test(field));
        if (!stanzaIsGrease) malformed("age-v1 rejects active non-X25519 recipient stanzas");
      }
      insideStanza = true;
      stanzaHasBody = false;
      stanzaBodyBytes = 0;
      greaseBodyBase64 = "";
      greaseShortBodySeen = false;
    } else if (value.startsWith("--- ")) {
      finishStanza();
      if (x25519StanzaCount < 1 || value.split(" ").length !== 2 || offset >= ageFile.length) {
        malformed("age header footer is invalid");
      }
      return { totalStanzaCount, x25519StanzaCount };
    } else if (!insideStanza ||
        !(stanzaIsGrease ? /^[A-Za-z0-9+/]*$/u : /^[A-Za-z0-9+/]+={0,2}$/u).test(value)) {
      malformed("age recipient stanza body is invalid");
    } else {
      stanzaHasBody = true;
      if (stanzaIsGrease) {
        if (value.length > 64 || value.length % 4 === 1 || greaseShortBodySeen) {
          malformed("age GREASE stanza body framing is invalid");
        }
        stanzaBodyBytes += Math.floor(value.length * 3 / 4);
        if (stanzaBodyBytes > 100) malformed("age GREASE stanza body limit exceeded");
        greaseBodyBase64 += value;
        greaseShortBodySeen = value.length < 64;
      }
    }
  }
  malformed("age header footer is missing");
}

function bech32Polymod(values) {
  const generators = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let checksum = 1;
  for (const value of values) {
    const top = checksum >>> 25;
    checksum = ((checksum & 0x1ffffff) << 5) ^ value;
    for (let bit = 0; bit < 5; bit += 1) if ((top >>> bit) & 1) checksum ^= generators[bit];
  }
  return checksum >>> 0;
}

function bech32HrpExpand(hrp) {
  return [...hrp].map((character) => character.charCodeAt(0) >>> 5)
    .concat([0], [...hrp].map((character) => character.charCodeAt(0) & 31));
}

function convertBits(values, fromBits, toBits, pad) {
  let accumulator = 0;
  let bits = 0;
  const result = [];
  const maxValue = (1 << toBits) - 1;
  for (const value of values) {
    if (value < 0 || value >>> fromBits !== 0) malformed("age identity bech32 data is invalid");
    accumulator = (accumulator << fromBits) | value;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      result.push((accumulator >>> bits) & maxValue);
    }
  }
  if (pad) {
    if (bits > 0) result.push((accumulator << (toBits - bits)) & maxValue);
  } else if (bits >= fromBits || ((accumulator << (toBits - bits)) & maxValue) !== 0) {
    malformed("age identity bech32 padding is invalid");
  }
  return result;
}

function decodeAgeSecretKey(value) {
  if (value !== value.toUpperCase() || !value.startsWith("AGE-SECRET-KEY-1")) {
    malformed("age identity is not a native X25519 secret key");
  }
  const lower = value.toLowerCase();
  const separator = lower.lastIndexOf("1");
  const hrp = lower.slice(0, separator);
  const encoded = [...lower.slice(separator + 1)].map((character) => BECH32_CHARSET.indexOf(character));
  if (hrp !== "age-secret-key-" || encoded.length < 7 || encoded.some((item) => item < 0) ||
      bech32Polymod(bech32HrpExpand(hrp).concat(encoded)) !== 1) {
    malformed("age identity checksum is invalid");
  }
  const raw = Buffer.from(convertBits(encoded.slice(0, -6), 5, 8, false));
  if (raw.length !== 32) malformed("age identity key length is invalid");
  return raw;
}

function bech32Encode(hrp, bytes) {
  const data = convertBits(bytes, 8, 5, true);
  const values = bech32HrpExpand(hrp).concat(data, [0, 0, 0, 0, 0, 0]);
  const polymod = bech32Polymod(values) ^ 1;
  const checksum = Array.from({ length: 6 }, (_, index) => (polymod >>> (5 * (5 - index))) & 31);
  return `${hrp}1${data.concat(checksum).map((item) => BECH32_CHARSET[item]).join("")}`;
}

export function nativeAgeIdentity(bytes) {
  let text;
  try { text = new TextDecoder("utf-8", { fatal: true }).decode(bytes); }
  catch { malformed("age identity is not UTF-8"); }
  const identities = [];
  for (const rawLine of text.split(/\r?\n/u)) {
    if (rawLine === "" || rawLine.startsWith("#")) continue;
    if (rawLine !== rawLine.trim()) malformed("age identity line has surrounding whitespace");
    identities.push(rawLine);
  }
  if (identities.length !== 1) malformed("age identity file must contain exactly one native key");
  const privateBytes = decodeAgeSecretKey(identities[0]);
  const privateKey = createPrivateKey({ key: Buffer.concat([
    Buffer.from("302e020100300506032b656e04220420", "hex"), privateBytes,
  ]), format: "der", type: "pkcs8" });
  const publicDer = createPublicKey(privateKey).export({ format: "der", type: "spki" });
  const prefix = Buffer.from("302a300506032b656e032100", "hex");
  if (!publicDer.subarray(0, prefix.length).equals(prefix) || publicDer.length !== prefix.length + 32) {
    malformed("age identity did not derive an X25519 public key");
  }
  return { bytes: Buffer.from(bytes), recipient: bech32Encode("age", publicDer.subarray(prefix.length)) };
}

export function readNativeAgeIdentity(path) {
  try {
    // These reasons are raised as CipherStateError so they SURVIVE the catch
    // below.
    //
    // What that catch collapses is a PLAIN Error: the stat and read failures.
    // The parser's own CipherStateError already passed through it untouched on
    // the way in, and still does -- an unparseable identity was never one of
    // the failures that lost its reason, and the test below pins that it stays
    // that way.
    //
    // What DID lose its reason was a missing file, a directory, an unreadable
    // one, and a mode this platform may never have checked: on win32 that test
    // does not run at all, so "not private" was the one thing a Windows
    // operator could not act on -- and did (#781).
    let metadata;
    try {
      metadata = statSync(path);
    } catch (error) {
      // Every stat failure names itself, not just the common one. Leaving the
      // rest to the generic sentence would keep this defect alive for EACCES
      // and EPERM, which is where a permissions claim would at least be about
      // something -- and still not about what happened.
      const reason = error?.code === "ENOENT"
        ? "was not found"
        : `could not be read (${error?.code ?? "unknown error"})`;
      throw new CipherStateError("pending_key", `age identity ${reason}: ${path}`);
    }
    if (!metadata.isFile()) {
      throw new CipherStateError("pending_key", `age identity must be a regular file: ${path}`);
    }
    // Last, so nothing above it can be mistaken for a permission problem.
    if (process.platform !== "win32" && (metadata.mode & 0o077) !== 0) {
      throw new CipherStateError("pending_key",
        `age identity must not be readable or writable by group or others: ${path}`);
    }
    let bytes;
    try {
      bytes = readFileSync(path);
    } catch (error) {
      throw new CipherStateError("pending_key",
        `age identity could not be read (${error?.code ?? "unknown error"}): ${path}`);
    }
    return nativeAgeIdentity(bytes);
  } catch (error) {
    if (error instanceof CipherStateError) throw error;
    throw new CipherStateError("pending_key", "age identity is not securely readable");
  }
}

function runAge(args, input) {
  const age = process.env.AGMSG_AGE_BIN || "age";
  const result = spawnSync(age, args, { input, maxBuffer: 4 * 1024 * 1024 });
  if (result.error?.code === "ENOENT") {
    throw new CipherStateError("unsupported_cipher", "age executable is unavailable");
  }
  if (result.error) throw result.error;
  return result;
}

function runAgeWithIdentity(ageFile, identityBytes) {
  const scratch = mkdtempSync(join(nodeOs.tmpdir(), "agmsg-age-open."));
  const ciphertextPath = join(scratch, "message.age");
  try {
    writeFileSync(ciphertextPath, ageFile, { mode: 0o600, flag: "wx" });
    return runAge(["--decrypt", "--identity", "-", ciphertextPath], identityBytes);
  } finally {
    rmSync(scratch, { recursive: true });
  }
}

export function ageExecutableVersion() {
  const result = runAge(["--version"], Buffer.alloc(0));
  if (result.status !== 0) throw new CipherStateError("unsupported_cipher", "age executable failed preflight");
  return result.stdout.toString("utf8").trim();
}

function sealNone(input, message) {
  if (input.key_id !== null) malformed("none requires null key_id");
  if (message.length > input.max_blob_bytes || message.length > MAX_BLOB_BYTES) {
    malformed("plaintext exceeds max_blob_bytes");
  }
  return { v: 1, cipher: "none", key_id: null, blob: message.toString("base64") };
}

function sealAge(input) {
  if (typeof input.key_id !== "string" || !KEY_ID.test(input.key_id) || !Array.isArray(input.recipients) ||
      input.recipients.length < 1 || input.recipients.length > 256 ||
      input.recipients.some((recipient) => typeof recipient !== "string" || !AGE_RECIPIENT.test(recipient)) ||
      new Set(input.recipients).size !== input.recipients.length) {
    malformed("age-v1 recipient manifest is invalid");
  }
  const frame = agePlaintextFrame({
    protocol_version: input.protocol_version,
    team_id: input.team_id,
    wire_id: input.wire_id,
    cipher: "age-v1",
    key_id: input.key_id,
  }, input.projection);
  const args = input.recipients.flatMap((recipient) => ["--recipient", recipient]);
  const result = runAge(args, frame);
  if (result.status !== 0) throw new Error(`age encryption failed: ${result.stderr.toString("utf8").trim()}`);
  if (result.stdout.length > input.max_blob_bytes || result.stdout.length > MAX_BLOB_BYTES) {
    malformed("encrypted age file exceeds max_blob_bytes");
  }
  if (validateAgeHeader(result.stdout).x25519StanzaCount !== input.recipients.length) {
    malformed("age recipient stanza count differs from the manifest");
  }
  return { v: 1, cipher: "age-v1", key_id: input.key_id, blob: result.stdout.toString("base64") };
}

export const cipherProfiles = Object.freeze({
  none: Object.freeze({
    seal: sealNone,
    open: ({ envelope, max_blob_bytes: maxBlobBytes }) => openNone(envelope, maxBlobBytes),
  }),
  "age-v1": Object.freeze({ seal: sealAge, open: openAge }),
});

export function sealEnvelope(input) {
  if (!input || input.type !== "sync_seal" || input.envelope_v !== 1 ||
      !Number.isInteger(input.max_blob_bytes) || input.max_blob_bytes < 1 ||
      input.max_blob_bytes > MAX_BLOB_BYTES || !UUID_V4.test(input.wire_id ?? "") ||
      !UUID_V7.test(input.team_id ?? "") || input.protocol_version !== 1) {
    malformed("seal request is invalid");
  }
  const profile = cipherProfiles[input.cipher];
  if (!profile) throw new CipherStateError("unsupported_cipher", `unsupported cipher ${input.cipher}`);
  const message = canonicalProjection(input.projection);
  return profile.seal(input, message);
}

// --- bulk sealing -----------------------------------------------------------
//
// A first connect / reconnect / retention backfill seals a whole page at once,
// and sealing is dominated by the per-message `age` fork. Bulk callers hand the
// entire page to `seal-batch`, which fans the SAME sealEnvelope out over worker
// threads. Threads, not a second implementation: each worker imports this file
// and calls sealEnvelope, so there is exactly one crypto path and the bytes a
// batch produces are the bytes `seal` produces.
//
// Steady-state sends never take the parallel path: sealBatchParallelism returns
// 1 below MIN_REQUESTS_PER_WORKER, and 1 means "seal on this thread", which is
// the pre-existing sequential code down to the call.
const MAX_BATCH_REQUESTS = 10_000;
const MIN_REQUESTS_PER_WORKER = 8;
// How much of a streamed batch the helper holds at once. The count keeps a
// typical page (small bodies) in one window so the pool never drains mid-page;
// the byte bound takes over when bodies are large, which is exactly when
// holding the page would cost the most.
const WINDOW_REQUESTS = 1_000;
const WINDOW_BYTES = 8 * 1_048_576;
// A task is re-dispatched once after the worker holding it dies. Bounded so a
// request that kills workers (rather than throwing) cannot take the whole pool
// down one thread at a time — after the last attempt it becomes an error result
// and the batch keeps going.
const MAX_ATTEMPTS = 2;
const PROGRESS_MIN_TOTAL = 50;
const PROGRESS_STEPS = 20;

function hostParallelism() {
  // uv_available_parallelism honours the affinity mask; cpus() is the fallback
  // for Node < 18.14 and reports every core the host has.
  const reported = typeof nodeOs.availableParallelism === "function" ?
    nodeOs.availableParallelism() : nodeOs.cpus().length;
  return Number.isInteger(reported) && reported > 0 ? reported : 1;
}

// Workers to use for `count` requests. One worker per MIN_REQUESTS_PER_WORKER
// requests, capped at the core count — a short page is not worth a thread, and
// past the cap the age forks only contend.
export function sealBatchParallelism(count, cores = hostParallelism()) {
  if (!Number.isInteger(count) || count < 1) return 1;
  return Math.max(1, Math.min(cores, Math.floor(count / MIN_REQUESTS_PER_WORKER)));
}

// `worker` is the thread that sealed the request — 0 on the main thread, the
// worker's threadId otherwise. It is how a caller can tell a batch that really
// fanned out from one that quietly ran everything on one thread, and it names
// the thread to look at when one worker's results go wrong.
function sealOne(index, request) {
  try {
    return { index, worker: threadId, status: "ok", envelope: sealEnvelope(request) };
  } catch (error) {
    return { index, worker: threadId, status: "error", state: error?.state ?? null,
      message: String(error?.message ?? error) };
  }
}

const SEAL_WORKER_ROLE = "agmsg-seal-worker";

function spawnSealWorker() {
  return new Worker(fileURLToPath(import.meta.url), { workerData: { role: SEAL_WORKER_ROLE } });
}

// One task in flight per worker. A worker that dies rejects the task it held so
// the scheduler can re-dispatch it; every later seal() on that client rejects
// immediately, which drops the client out of the pool without losing work.
function sealWorkerClient(spawn) {
  const worker = spawn();
  let pending = null;
  let dead = null;
  const die = (error) => {
    dead = dead ?? (error ?? new Error("seal worker exited"));
    const settled = pending;
    pending = null;
    settled?.reject(dead);
  };
  worker.on("message", (result) => {
    const settled = pending;
    pending = null;
    settled?.resolve(result);
  });
  worker.on("error", die);
  worker.on("exit", () => die(new Error("seal worker exited")));
  return {
    seal(index, request) {
      if (dead) return Promise.reject(dead);
      return new Promise((resolve, reject) => {
        pending = { resolve, reject };
        worker.postMessage({ index, request });
      });
    },
    stop() { worker.terminate(); },
  };
}

// Seal `requests` and hand every result to onResult as it completes — in
// COMPLETION order, each tagged with its input index, so a caller can commit
// incrementally and keep whatever it committed if the run is interrupted.
//
// Contract: exactly one result per request, always, with status "ok" or
// "error". Requests whose worker died are re-dispatched, and if the whole pool
// dies the remainder is sealed on this thread. A batch never silently drops a
// message; an "error" result simply leaves that message unsealed for the next
// cycle to retry.
export async function runSealBatch(requests, options = {}) {
  const total = requests.length;
  const onResult = options.onResult ?? (() => {});
  const onProgress = options.onProgress ?? (() => {});
  let completed = 0;
  const emit = (result) => {
    completed += 1;
    onResult(result);
    onProgress(completed, total);
  };

  const parallelism = options.parallelism ?? sealBatchParallelism(total);
  if (total === 0) return;
  if (parallelism <= 1) {
    for (let index = 0; index < total; index += 1) emit(sealOne(index, requests[index]));
    return;
  }

  const attempts = new Array(total).fill(0);
  const requeued = [];
  let next = 0;
  const take = () => {
    if (requeued.length > 0) return requeued.shift();
    return next < total ? next++ : -1;
  };

  const spawn = options.spawnWorker ?? spawnSealWorker;
  const clients = [];

  const drive = async (client) => {
    for (let index = take(); index !== -1; index = take()) {
      attempts[index] += 1;
      let result;
      try {
        result = await client.seal(index, requests[index]);
      } catch (error) {
        // This client is gone. Put the task back for a surviving client (or the
        // main-thread sweep below) and retire the client.
        if (attempts[index] < MAX_ATTEMPTS) requeued.unshift(index);
        else emit({ index, worker: null, status: "error", state: "worker_failed",
          message: `seal worker died: ${String(error?.message ?? error)}` });
        return;
      }
      emit(result);
    }
  };

  try {
    // Spawning belongs inside this boundary. A thread that cannot be created —
    // the process is out of them, the system is out of memory — must leave the
    // workers already spawned terminable and must still reach the main-thread
    // sweep below. Whatever was created is the pool; zero is a valid pool.
    for (let worker = 0; worker < parallelism; worker += 1) {
      try { clients.push(sealWorkerClient(spawn)); } catch { break; }
    }
    await Promise.all(clients.map((client) => drive(client)));
  } finally {
    // Unconditional: a throw out of onResult must not leave live threads
    // holding the process open.
    for (const client of clients) client.stop();
  }
  // Re-dispatched work can outlive the pool — a client that had already drained
  // the queue exits before another one dies and requeues. Whatever is left has
  // no worker to run on, so it runs here rather than going missing.
  for (let index = take(); index !== -1; index = take()) emit(sealOne(index, requests[index]));
}

function sealWorkerMain() {
  parentPort.on("message", ({ index, request }) => {
    parentPort.postMessage(sealOne(index, request));
  });
}

function openNone(envelope, maxBlobBytes) {
  if (envelope.v !== 1 || envelope.key_id !== null) malformed("none envelope metadata is invalid");
  return parseCanonicalProjection(canonicalBlob(envelope.blob, maxBlobBytes));
}

async function openAge({ envelope, protocol_version: protocolVersion, team_id: teamId, wire_id: wireId,
  identity_file: identityFile, expected_recipients: expectedRecipients,
  max_blob_bytes: maxBlobBytes = MAX_BLOB_BYTES }) {
  if (envelope.v !== 1 || typeof envelope.key_id !== "string" || !KEY_ID.test(envelope.key_id)) {
    malformed("age-v1 envelope metadata is invalid");
  }
  if (!identityFile) throw new CipherStateError("pending_key", "age identity is not installed");
  if (!Array.isArray(expectedRecipients) || expectedRecipients.length < 1 || expectedRecipients.length > 256 ||
      expectedRecipients.some((recipient) => typeof recipient !== "string" || !AGE_RECIPIENT.test(recipient))) {
    malformed("expected age recipient manifest is invalid");
  }
  const identity = readNativeAgeIdentity(identityFile);
  if (!expectedRecipients.includes(identity.recipient)) {
    authenticationFailed("age identity does not match the expected recipient manifest");
  }
  const ageFile = canonicalBlob(envelope.blob, maxBlobBytes);
  if (validateAgeHeader(ageFile).x25519StanzaCount !== expectedRecipients.length) {
    authenticationFailed("age recipient stanza count differs from the manifest");
  }
  const result = runAgeWithIdentity(ageFile, identity.bytes);
  if (result.status !== 0) authenticationFailed("age decryption failed");
  const bytes = result.stdout;
  if (bytes.length < 24 || !bytes.subarray(0, 16).equals(MAGIC)) authenticationFailed("age frame magic is invalid");
  const contextLength = bytes.readUInt32BE(16);
  if (contextLength < 47 || contextLength > 110 || contextLength > bytes.length - 24) {
    authenticationFailed("age binding context length is invalid");
  }
  const contextEnd = 20 + contextLength;
  const actualContext = bytes.subarray(20, contextEnd);
  const expectedContext = ageBindingContext({ protocol_version: protocolVersion, team_id: teamId,
    wire_id: wireId, cipher: "age-v1", key_id: envelope.key_id });
  if (actualContext.length !== expectedContext.length || !timingSafeEqual(actualContext, expectedContext)) {
    authenticationFailed("age binding context mismatch");
  }
  const messageLength = bytes.readUInt32BE(contextEnd);
  const messageStart = contextEnd + 4;
  if (messageLength > bytes.length - messageStart || messageStart + messageLength !== bytes.length) {
    authenticationFailed("age plaintext frame length is invalid");
  }
  return parseCanonicalProjection(bytes.subarray(messageStart));
}

export async function openEnvelope(input) {
  const envelope = input?.envelope;
  if (!envelope || typeof envelope !== "object" || typeof envelope.cipher !== "string") {
    malformed("envelope is missing");
  }
  const profile = cipherProfiles[envelope.cipher];
  if (!profile) throw new CipherStateError("unsupported_cipher", `unsupported cipher ${envelope.cipher}`);
  return profile.open(input);
}

async function readStdin() {
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  return input;
}

// Human-facing progress for the bulk path only. A steady-state page is a
// handful of messages and reporting on it would be noise, so anything under
// PROGRESS_MIN_TOTAL stays silent. stdout carries the results, so this goes to
// stderr. `total` is what the caller said it would send — the batch is read as
// a stream, so the helper itself never knows the count up front.
function progressReporter(total) {
  if (!Number.isInteger(total) || total < PROGRESS_MIN_TOTAL) return () => {};
  const step = Math.max(1, Math.floor(total / PROGRESS_STEPS));
  let done = 0;
  return () => {
    done += 1;
    if (done % step !== 0 && done !== total) return;
    const percent = Math.min(100, Math.floor((done / total) * 100));
    process.stderr.write(`agmsg: sealing ${done}/${total} (${percent}%)\n`);
  };
}

// Requests are read as a stream and sealed a window at a time. A page is only
// bounded by its message count, and a message body is legal up to
// max_blob_bytes, so holding the whole batch would mean holding a gigabyte for
// input a caller is entitled to send. The scheduler has to keep a request until
// its result is out — it re-dispatches the ones a dying worker was holding — so
// what is bounded here is how much it is ever asked to keep at once.
export async function* sealBatchWindows(lines, limits = {}) {
  const maxRequests = limits.requests ?? WINDOW_REQUESTS;
  const maxBytes = limits.bytes ?? WINDOW_BYTES;
  let window = [];
  let bytes = 0;
  for await (const line of lines) {
    if (!line) continue;
    window.push(JSON.parse(line));
    // Bytes, not code units: a body of non-ASCII text is up to three times its
    // string length, so counting units would let the window grow past the bound
    // by that factor on exactly the input the bound exists for.
    bytes += Buffer.byteLength(line, "utf8");
    if (window.length >= maxRequests || bytes >= maxBytes) {
      yield window;
      window = [];
      bytes = 0;
    }
  }
  if (window.length > 0) yield window;
}

async function cli() {
  if (process.argv[2] === "seal") {
    process.stdout.write(`${JSON.stringify(sealEnvelope(JSON.parse(await readStdin())))}\n`);
    return;
  }
  if (process.argv[2] !== "seal-batch") {
    throw new Error("usage: sync-cipher.mjs seal | seal-batch [expected-count]");
  }
  const expected = process.argv[3] === undefined ? null : Number(process.argv[3]);
  if (expected !== null && (!Number.isInteger(expected) || expected < 0 ||
      expected > MAX_BATCH_REQUESTS)) {
    throw new Error(`seal-batch accepts at most ${MAX_BATCH_REQUESTS} requests`);
  }
  const onProgress = progressReporter(expected);
  let base = 0;
  // Per-request failures are results, not an exit code: the caller commits the
  // envelopes that succeeded and retries the rest on its next cycle.
  for await (const window of sealBatchWindows(
    createInterface({ input: process.stdin, crlfDelay: Infinity }))) {
    if (base + window.length > MAX_BATCH_REQUESTS) {
      throw new Error(`seal-batch accepts at most ${MAX_BATCH_REQUESTS} requests`);
    }
    const offset = base;
    await runSealBatch(window, {
      // The window is an implementation detail of how much is held at once;
      // callers index results against what they sent.
      onResult: (result) => process.stdout.write(`${JSON.stringify(
        { type: "sync_seal_result", ...result, index: offset + result.index })}\n`),
      onProgress,
    });
    base += window.length;
  }
}

if (!isMainThread && workerData?.role === SEAL_WORKER_ROLE) {
  sealWorkerMain();
} else if (isMainThread && ["seal", "seal-batch"].includes(process.argv[2])) {
  cli().catch((error) => {
    process.stderr.write(`${error.state ? `${error.state}: ` : ""}${error.message}\n`);
    process.exitCode = 1;
  });
}
