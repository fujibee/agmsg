#!/usr/bin/env node

import { createPrivateKey, createPublicKey, timingSafeEqual } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";

const UUID_V7 = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const UUID_V4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/u;
const TIMESTAMP = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$/u;
const KEY_ID = /^[a-z0-9][a-z0-9._-]{0,63}$/u;
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

function parseCanonicalMessage(bytes) {
  let text;
  let value;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    value = JSON.parse(text);
  } catch {
    malformed("message is not valid UTF-8 JSON");
  }
  const canonical = canonicalMessage(value);
  if (!canonical.equals(bytes)) malformed("message is not canonical JCS");
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
  const message = canonicalMessage(projection);
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
    const metadata = statSync(path);
    if (!metadata.isFile() || (process.platform !== "win32" && (metadata.mode & 0o077) !== 0)) {
      throw new Error("identity file is not private");
    }
    return nativeAgeIdentity(readFileSync(path));
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
  const scratch = mkdtempSync(join(tmpdir(), "agmsg-age-open."));
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
  const message = canonicalMessage(input.projection);
  return profile.seal(input, message);
}

function openNone(envelope, maxBlobBytes) {
  if (envelope.v !== 1 || envelope.key_id !== null) malformed("none envelope metadata is invalid");
  return parseCanonicalMessage(canonicalBlob(envelope.blob, maxBlobBytes));
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
  return parseCanonicalMessage(bytes.subarray(messageStart));
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

async function cli() {
  if (process.argv[2] !== "seal") throw new Error("usage: sync-cipher.mjs seal");
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const value = JSON.parse(input);
  process.stdout.write(`${JSON.stringify(sealEnvelope(value))}\n`);
}

if (process.argv[2] === "seal") {
  cli().catch((error) => {
    process.stderr.write(`${error.state ? `${error.state}: ` : ""}${error.message}\n`);
    process.exitCode = 1;
  });
}
