import {
  createCipheriv,
  createDecipheriv,
  createHash,
  hkdfSync,
  randomBytes,
} from "node:crypto";
import { readFile } from "node:fs/promises";

// Key escrow seam. The server can hold a wrapped copy of a team's key so it can
// hand that key to the next approved device. WHO can open the wrap is the whole
// point of the setting:
//
//   none     the server holds nothing it could open (the default).
//   keyfile  a master key in a file on the server host. Whoever can read that
//            file, and the database, can open every wrapped key.
//

export const ESCROW_BACKENDS = ["none", "keyfile"] as const;
export type EscrowBackendName = (typeof ESCROW_BACKENDS)[number];

export const WRAP_KINDS = ["keyfile"] as const;
export type WrapKind = (typeof WRAP_KINDS)[number];

/** Binds a wrapped key to the row it belongs to: a blob cannot be moved. */
export type EscrowContext = { teamId: string; epoch: bigint };

export interface EscrowBackend {
  readonly kind: WrapKind;
  /** Public identifier of the master key, recorded per row. Not secret. */
  readonly keyRef: string;
  wrap(key: Uint8Array, context: EscrowContext): Promise<Uint8Array>;
  unwrap(blob: Uint8Array, context: EscrowContext): Promise<Uint8Array>;
}

export const MIN_MASTER_KEY_BYTES = 32;
const BLOB_VERSION = 1;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;

export class EscrowConfigError extends Error {}

function aad(context: EscrowContext): Buffer {
  return Buffer.from(`agmsg-escrow-v1\0keyfile\0${context.teamId}\0${context.epoch}`);
}

export function createKeyfileBackend(material: Uint8Array): EscrowBackend {
  if (material.length < MIN_MASTER_KEY_BYTES) {
    throw new EscrowConfigError(
      `escrow key file is too short: ${material.length} bytes, need at least ${MIN_MASTER_KEY_BYTES}`,
    );
  }
  const derive = (info: string): Buffer =>
    Buffer.from(hkdfSync("sha256", material, Buffer.alloc(0), info, 32));
  const wrapKey = derive("agmsg-escrow-v1 wrap");
  // Derived with its own label so the identifier reveals nothing about the key.
  const keyRef = `keyfile:${createHash("sha256")
    .update(derive("agmsg-escrow-v1 ref")).digest("hex").slice(0, 16)}`;
  return {
    kind: "keyfile",
    keyRef,
    async wrap(key, context) {
      const nonce = randomBytes(NONCE_BYTES);
      const cipher = createCipheriv("aes-256-gcm", wrapKey, nonce);
      cipher.setAAD(aad(context));
      const body = Buffer.concat([cipher.update(key), cipher.final()]);
      return Buffer.concat([Buffer.from([BLOB_VERSION]), nonce, body, cipher.getAuthTag()]);
    },
    async unwrap(blob, context) {
      const bytes = Buffer.from(blob);
      if (bytes.length < 1 + NONCE_BYTES + TAG_BYTES || bytes[0] !== BLOB_VERSION) {
        throw new Error("wrapped key is not in a recognised format");
      }
      const nonce = bytes.subarray(1, 1 + NONCE_BYTES);
      const tag = bytes.subarray(bytes.length - TAG_BYTES);
      const body = bytes.subarray(1 + NONCE_BYTES, bytes.length - TAG_BYTES);
      const decipher = createDecipheriv("aes-256-gcm", wrapKey, nonce);
      decipher.setAAD(aad(context));
      decipher.setAuthTag(tag);
      try {
        return Buffer.concat([decipher.update(body), decipher.final()]);
      } catch {
        throw new Error("wrapped key could not be opened with this master key and context");
      }
    },
  };
}

/**
 * Builds the configured backend, or null for "none". Throws EscrowConfigError
 * when the keyfile is missing, unreadable or too short, so the server does not
 * start with escrow half set up.
 */
export async function loadEscrowBackend(settings: {
  backend: EscrowBackendName;
  keyfilePath: string | null;
}): Promise<EscrowBackend | null> {
  if (settings.backend === "none") return null;
  if (settings.keyfilePath === null) {
    throw new EscrowConfigError("AGMSG_ESCROW_BACKEND=keyfile needs AGMSG_ESCROW_KEYFILE");
  }
  let material: Buffer;
  try {
    material = await readFile(settings.keyfilePath);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code ?? "unknown";
    throw new EscrowConfigError(
      `escrow key file cannot be read (${code}): ${settings.keyfilePath}`,
    );
  }
  return createKeyfileBackend(material);
}
