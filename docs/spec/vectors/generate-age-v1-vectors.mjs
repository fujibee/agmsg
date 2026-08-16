#!/usr/bin/env node

import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";

const age = process.env.AGE_BIN || "age";
const teamARecipient = "age1mmqjrejftea4f6xh47lhpc0jn4vw0yuhz349sw2e3sfl22k5gcjsv6xcvp";
const teamAIdentity = "AGE-SECRET-KEY-1WWJJYKYVUUQNL8ZX7Y6NYRTEW79LHTF0H28EYC0CFYN5A7WECDHQMT4S0V";
const teamBRecipient = "age1ykvctct4aklx4f4mnjd8rmzqs7p2le9ufg4faydljsk5mvcy0pls27mu64";
const teamBIdentity = "AGE-SECRET-KEY-14Z7XMNPZTPEMMM6DG2FSKEH042L7UMU79T645GAQJKU2LLJGPM2S7GWNLQ";

const binding = {
  protocol_version: 1,
  team_id: "018f3f7e-0000-7000-8000-000000000001",
  wire_id: "550e8400-e29b-41d4-a716-446655440000",
  cipher: "age-v1",
  key_id: "epoch-1",
};
const message = {
  body: "Run the test suite",
  created_at: "2026-07-20T06:30:00.000000Z",
  from_agent: "leader",
  to_agent: "worker-1",
};
const messageBytes = Buffer.from(JSON.stringify(message), "utf8");
const magic = Buffer.concat([Buffer.from("agmsg-age-v1", "ascii"), Buffer.alloc(4)]);

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exit(1);
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function uuidBytes(value) {
  return Buffer.from(value.replaceAll("-", ""), "hex");
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

function canonicalContext({ truncateKey = false, reorder = false } = {}) {
  const protocol = u32(binding.protocol_version);
  const team = uuidBytes(binding.team_id);
  const wire = uuidBytes(binding.wire_id);
  const cipher = Buffer.from(binding.cipher, "ascii");
  const key = Buffer.from(truncateKey ? binding.key_id.slice(0, -1) : binding.key_id, "ascii");
  return Buffer.concat([
    protocol,
    ...(reorder ? [wire, team] : [team, wire]),
    u16(cipher.length),
    cipher,
    u16(key.length),
    key,
  ]);
}

function frame({ context = canonicalContext(), message = messageBytes,
  contextLength = context.length, messageLength = message.length, trailing = Buffer.alloc(0) } = {}) {
  return Buffer.concat([magic, u32(contextLength), context, u32(messageLength), message, trailing]);
}

function encrypt(plaintext) {
  const result = spawnSync(age, ["-r", teamARecipient], { input: plaintext, maxBuffer: 4 * 1024 * 1024 });
  if (result.error) fail(`age invocation failed: ${result.error.message}`);
  if (result.status !== 0) fail(result.stderr.toString("utf8"));
  const ageFile = result.stdout;
  return {
    envelope: { v: 1, cipher: "age-v1", key_id: binding.key_id, blob: ageFile.toString("base64") },
    age_file_sha256: sha256(ageFile),
    decrypted_frame_sha256: sha256(plaintext),
  };
}

function encryptedVector(name, plaintext, expectedState) {
  return { name, ...encrypt(plaintext), identity: "team_a", expected_state: expectedState };
}

const version = spawnSync(age, ["--version"], { encoding: "utf8" });
if (version.error || version.status !== 0) fail("unable to read age version");

const canonicalFrame = frame();
const valid = encryptedVector("valid", canonicalFrame, "importable");
function fromValid(name, fields) {
  return {
    name,
    envelope_from: "valid",
    age_file_sha256: valid.age_file_sha256,
    decrypted_frame_sha256: valid.decrypted_frame_sha256,
    ...fields,
  };
}
const duplicateMessage = Buffer.from(
  '{"body":"Run the test suite","body":"changed","created_at":"2026-07-20T06:30:00.000000Z","from_agent":"leader","to_agent":"worker-1"}',
  "utf8",
);
const unknownMessage = Buffer.from(
  '{"body":"Run the test suite","created_at":"2026-07-20T06:30:00.000000Z","extra":true,"from_agent":"leader","to_agent":"worker-1"}',
  "utf8",
);
const noncanonicalMessage = Buffer.from(
  '{"to_agent":"worker-1","from_agent":"leader","created_at":"2026-07-20T06:30:00.000000Z","body":"Run the test suite"}',
  "utf8",
);
const shortCipherLengthContext = Buffer.from(canonicalContext());
shortCipherLengthContext.writeUInt16BE(5, 36);
const shortKeyLengthContext = Buffer.from(canonicalContext());
shortKeyLengthContext.writeUInt16BE(6, 44);

const output = {
  format_version: 1,
  profile: "age-v1",
  profile_document: "../age-v1-profile.md",
  warning: "PUBLIC TEST KEYS. NEVER USE THESE IDENTITIES OUTSIDE TESTS.",
  generated_with: {
    implementation: "filippo.io/age/cmd/age",
    version: version.stdout.trim(),
  },
  binding,
  recipient_sets: {
    team_a: { recipient: teamARecipient, identity: teamAIdentity },
    team_b: { recipient: teamBRecipient, identity: teamBIdentity },
  },
  canonical_message: message,
  canonical_message_utf8_base64: messageBytes.toString("base64"),
  canonical_context_hex: canonicalContext().toString("hex"),
  canonical_plaintext_hex: canonicalFrame.toString("hex"),
  vectors: [
    valid,
    fromValid("wrong-team-identity", { identity: "team_b", expected_state: "authentication_failed" }),
    fromValid("team-id-substitution", { identity: "team_a",
      binding_override: { team_id: "018f3f7e-0000-7000-8000-000000000002" },
      expected_state: "authentication_failed" }),
    fromValid("wire-id-substitution", { identity: "team_a",
      binding_override: { wire_id: "550e8400-e29b-41d4-a716-446655440001" },
      expected_state: "authentication_failed" }),
    fromValid("protocol-version-substitution", { identity: "team_a",
      binding_override: { protocol_version: 2 }, expected_state: "authentication_failed" }),
    fromValid("key-id-substitution", { identity: "team_a",
      envelope_override: { key_id: "epoch-2" }, expected_state: "policy_violation" }),
    fromValid("key-id-context-substitution", { identity: "team_a",
      envelope_override: { key_id: "epoch-2" }, trusted_epoch_key_id: "epoch-2",
      expected_state: "authentication_failed" }),
    fromValid("cipher-substitution", { identity: "team_a",
      envelope_override: { cipher: "age-v2" }, expected_state: "unsupported_cipher" }),
    encryptedVector("truncated-context", frame({ context: canonicalContext({ truncateKey: true }) }),
      "authentication_failed"),
    encryptedVector("reordered-context-fields", frame({ context: canonicalContext({ reorder: true }) }),
      "authentication_failed"),
    encryptedVector("cipher-length-substitution", frame({ context: shortCipherLengthContext }),
      "authentication_failed"),
    encryptedVector("key-id-length-substitution", frame({ context: shortKeyLengthContext }),
      "authentication_failed"),
    encryptedVector("context-length-overflow",
      Buffer.concat([magic, u32(0xffffffff), Buffer.from([0])]), "authentication_failed"),
    encryptedVector("zero-message-length", frame({ message: Buffer.alloc(0) }), "malformed"),
    encryptedVector("message-length-overflow", frame({ message: Buffer.from([0]), messageLength: 0xffffffff }),
      "authentication_failed"),
    encryptedVector("trailing-frame-byte", frame({ trailing: Buffer.from([0]) }), "authentication_failed"),
    encryptedVector("duplicate-message-key", frame({ message: duplicateMessage }), "malformed"),
    encryptedVector("unknown-message-key", frame({ message: unknownMessage }), "malformed"),
    encryptedVector("noncanonical-message", frame({ message: noncanonicalMessage }), "malformed"),
  ],
};

process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
