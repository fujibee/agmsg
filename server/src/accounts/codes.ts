import { createHash, randomBytes, randomInt } from "node:crypto";

// Device-flow code material.
//   device_code: 256-bit bearer the machine polls with; stored as sha256.
//   user_code: 8 Crockford base32 characters (no I, L, O, U) shown as XXXX-XXXX;
//   stored as a digest so a database read never yields an approvable code.
// Typing is forgiving: case, hyphens and spaces are ignored, and the characters
// people confuse with digits are folded (I, L -> 1, O -> 0).

const ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const USER_CODE_LENGTH = 8;
const NORMALIZED = /^[0-9A-HJKMNP-TV-Z]{8}$/u;

export type CodeMaterial = {
  deviceCode: string;
  deviceCodeHash: Buffer;
  userCode: string;
  userCodeDigest: Buffer;
};

function sha256(value: string): Buffer {
  return createHash("sha256").update(value, "utf8").digest();
}

export function normalizeUserCode(input: string): string {
  return input.toUpperCase().replace(/[\s-]/gu, "").replace(/[IL]/gu, "1").replace(/O/gu, "0");
}

// The lookup digest for a typed code, or null when it cannot be a code at all
// (nothing is read from the database for those).
export function userCodeDigestOf(input: string): Buffer | null {
  const normalized = normalizeUserCode(input);
  return NORMALIZED.test(normalized) ? sha256(normalized) : null;
}

export function deviceCodeHashOf(deviceCode: string): Buffer {
  return sha256(deviceCode);
}

export function generateCodes(): CodeMaterial {
  const deviceCode = randomBytes(32).toString("base64url");
  let raw = "";
  for (let i = 0; i < USER_CODE_LENGTH; i += 1) raw += ALPHABET[randomInt(ALPHABET.length)];
  const userCode = `${raw.slice(0, 4)}-${raw.slice(4)}`;
  return {
    deviceCode,
    deviceCodeHash: sha256(deviceCode),
    userCode,
    userCodeDigest: sha256(raw),
  };
}
