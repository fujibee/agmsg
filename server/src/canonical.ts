import { createHash } from "node:crypto";

// The canonical JSON the client signs and hashes: object keys sorted, strings
// and numbers as JSON.stringify writes them. The server must produce the same
// bytes as the client's own rule, because a digest is compared across them.

// With the u flag a surrogate pair is one code point, so only a lone one matches.
const LONE_SURROGATE = /[\uD800-\uDFFF]/u;

function requireScalars(value: string): void {
  if (LONE_SURROGATE.test(value)) throw new Error("value contains a lone surrogate");
}

export function canonicalJson(value: unknown): string {
  if (value === null || typeof value === "boolean") return JSON.stringify(value);
  if (typeof value === "string") {
    requireScalars(value);
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new Error("value is a non-finite number");
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (typeof value === "object") {
    const record = value as Record<string, unknown>;
    return `{${Object.keys(record).sort().map((key) => {
      requireScalars(key);
      return `${JSON.stringify(key)}:${canonicalJson(record[key])}`;
    }).join(",")}}`;
  }
  throw new Error("value is not JSON");
}

export function snapshotDigest(snapshot: unknown): string {
  return createHash("sha256").update(canonicalJson(snapshot), "utf8").digest("hex");
}
