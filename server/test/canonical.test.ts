import { describe, expect, it } from "vitest";
import { canonicalJson, snapshotDigest } from "../src/canonical.js";
// The client's own rule (an untyped .mjs); the server must write the same bytes.
// @ts-expect-error TS7016: no declaration file
import { ageSnapshotDigest, canonicalJson as clientCanonicalJson } from "../../scripts/internal/remote-sync.mjs";

describe("canonical JSON", () => {
  const sample = {
    b: [1, "x", null, true, { z: 1, a: "é \"" }], a: { y: [], x: {} }, "é": "1", "10": 2, "9": 1,
  };

  it("writes the same bytes and digest as the client's rule", () => {
    expect(canonicalJson(sample)).toBe(clientCanonicalJson(sample));
    expect(snapshotDigest(sample)).toBe(ageSnapshotDigest(sample));
  });

  it("refuses a lone surrogate and a non-finite number", () => {
    expect(() => canonicalJson("\ud800")).toThrow();
    expect(() => canonicalJson({ n: Infinity })).toThrow();
  });
});
