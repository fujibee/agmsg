#!/usr/bin/env node

import { createHash, timingSafeEqual } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const age = process.env.AGE_BIN || "age";
const manifestPath = fileURLToPath(new URL("age-v1-vectors.json", import.meta.url));
const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
const byName = new Map(manifest.vectors.map((vector) => [vector.name, vector]));
const scratch = mkdtempSync(join(tmpdir(), "agmsg-age-v1-verify."));
const identityPaths = new Map();

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function u16(value) {
  const out = Buffer.alloc(2);
  out.writeUInt16BE(value);
  return out;
}

function u32(value) {
  const out = Buffer.alloc(4);
  out.writeUInt32BE(value);
  return out;
}

function uuidBytes(value) {
  return Buffer.from(value.replaceAll("-", ""), "hex");
}

function expectedContext(binding) {
  const cipher = Buffer.from(binding.cipher, "ascii");
  const key = Buffer.from(binding.key_id, "ascii");
  return Buffer.concat([
    u32(binding.protocol_version),
    uuidBytes(binding.team_id),
    uuidBytes(binding.wire_id),
    u16(cipher.length),
    cipher,
    u16(key.length),
    key,
  ]);
}

// Independent of sync-cipher.mjs's own strict-JSON reader on purpose: this
// walks the raw text itself (rather than trusting JSON.parse, which silently
// keeps only the last of a duplicate key) so a bug shared between the two
// duplicate-key checks cannot hide behind a green verifier. Every object
// scope gets its own key set, recursively — an unknown field can carry an
// object of its own, and a duplicate inside it is just as rejectable as one
// at the top level.
function hasDuplicateKey(text) {
  let index = 0;
  const length = text.length;
  let duplicate = false;
  const skipWs = () => { while (index < length && /\s/u.test(text[index])) index += 1; };
  function skipString() {
    index += 1;
    while (index < length) {
      if (text[index] === "\\") { index += 2; continue; }
      if (text[index] === '"') { index += 1; return; }
      index += 1;
    }
    throw new Error("unterminated string");
  }
  function walkValue() {
    skipWs();
    const ch = text[index];
    if (ch === '"') { skipString(); return; }
    if (ch === "{") {
      index += 1; skipWs();
      const seen = new Set();
      if (text[index] === "}") { index += 1; return; }
      for (;;) {
        skipWs();
        if (text[index] !== '"') throw new Error("expected object key");
        const keyStart = index;
        skipString();
        const key = JSON.parse(text.slice(keyStart, index));
        if (seen.has(key)) duplicate = true;
        seen.add(key);
        skipWs();
        if (text[index] !== ":") throw new Error("expected colon");
        index += 1; walkValue(); skipWs();
        if (text[index] === ",") { index += 1; continue; }
        if (text[index] === "}") { index += 1; return; }
        throw new Error("expected , or }");
      }
    }
    if (ch === "[") {
      index += 1; skipWs();
      if (text[index] === "]") { index += 1; return; }
      for (;;) {
        walkValue(); skipWs();
        if (text[index] === ",") { index += 1; continue; }
        if (text[index] === "]") { index += 1; return; }
        throw new Error("expected , or ]");
      }
    }
    const start = index;
    while (index < length && !/[\s,}\]]/u.test(text[index])) index += 1;
    if (index === start) throw new Error("unexpected token");
  }

  walkValue();
  return duplicate;
}

// A newer sender may add a field this verifier does not know about yet; a
// message is importable once its four known fields are present strings and
// no key repeats, regardless of what else rides along or what order the
// fields are in.
function canonicalMessage(bytes) {
  const text = bytes.toString("utf8");
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    return false;
  }
  if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") return false;
  if (hasDuplicateKey(text)) return false;
  const expectedKeys = ["body", "created_at", "from_agent", "to_agent"];
  return expectedKeys.every((key) => typeof parsed[key] === "string");
}

function resolveVector(vector) {
  const source = vector.envelope_from ? byName.get(vector.envelope_from) : vector;
  if (!source?.envelope) throw new Error(`${vector.name}: missing source envelope`);
  return {
    envelope: { ...source.envelope, ...(vector.envelope_override || {}) },
    ageFileSha256: vector.age_file_sha256 || source.age_file_sha256,
    frameSha256: vector.decrypted_frame_sha256 || source.decrypted_frame_sha256,
  };
}

function classify(vector) {
  const resolved = resolveVector(vector);
  if (sha256(Buffer.from(resolved.envelope.blob, "base64")) !== resolved.ageFileSha256) {
    throw new Error(`${vector.name}: age-file SHA-256 mismatch`);
  }
  if (resolved.envelope.cipher !== "age-v1") return "unsupported_cipher";
  const trustedEpochKeyId = vector.trusted_epoch_key_id || manifest.binding.key_id;
  if (resolved.envelope.key_id !== trustedEpochKeyId) return "policy_violation";

  const identityPath = identityPaths.get(vector.identity);
  const decrypted = spawnSync(age, ["--decrypt", "--identity", identityPath], {
    input: Buffer.from(resolved.envelope.blob, "base64"),
    maxBuffer: 4 * 1024 * 1024,
  });
  if (decrypted.error) throw decrypted.error;
  if (decrypted.status !== 0) return "authentication_failed";
  if (sha256(decrypted.stdout) !== resolved.frameSha256) {
    throw new Error(`${vector.name}: decrypted-frame SHA-256 mismatch`);
  }

  const bytes = decrypted.stdout;
  const magic = Buffer.concat([Buffer.from("agmsg-age-v1", "ascii"), Buffer.alloc(4)]);
  if (bytes.length < 24 || !bytes.subarray(0, 16).equals(magic)) return "authentication_failed";
  const contextLength = bytes.readUInt32BE(16);
  if (contextLength > bytes.length - 24) return "authentication_failed";
  const contextEnd = 20 + contextLength;
  const actualContext = bytes.subarray(20, contextEnd);
  const binding = {
    ...manifest.binding,
    cipher: resolved.envelope.cipher,
    key_id: resolved.envelope.key_id,
    ...(vector.binding_override || {}),
  };
  const expected = expectedContext(binding);
  if (actualContext.length !== expected.length || !timingSafeEqual(actualContext, expected)) {
    return "authentication_failed";
  }
  const messageLength = bytes.readUInt32BE(contextEnd);
  const messageStart = contextEnd + 4;
  if (messageLength > bytes.length - messageStart) return "authentication_failed";
  const messageEnd = messageStart + messageLength;
  if (messageEnd !== bytes.length) return "authentication_failed";
  return canonicalMessage(bytes.subarray(messageStart, messageEnd)) ? "importable" : "malformed";
}

try {
  for (const [name, recipientSet] of Object.entries(manifest.recipient_sets)) {
    const path = join(scratch, `${name}.identity`);
    writeFileSync(path, `${recipientSet.identity}\n`, { mode: 0o600 });
    identityPaths.set(name, path);
  }
  for (const vector of manifest.vectors) {
    const actual = classify(vector);
    if (actual !== vector.expected_state) {
      throw new Error(`${vector.name}: expected ${vector.expected_state}, got ${actual}`);
    }
    process.stdout.write(`${vector.name}: ${actual}\n`);
  }
} finally {
  // This process created and exclusively owns scratch.
  rmSync(scratch, { recursive: true, force: true });
}
