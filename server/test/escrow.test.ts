import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomBytes } from "node:crypto";
import { describe, expect, it } from "vitest";
import { originFeatures, teamFeatures } from "../src/accounts/features.js";
import { loadConfig } from "../src/config.js";
import {
  createKeyfileBackend,
  EscrowConfigError,
  loadEscrowBackend,
} from "../src/escrow.js";

const ctx = { teamId: "0196c0de-0000-7000-8000-000000000001", epoch: 1n };
const base = { DATABASE_URL: "postgresql://example/agmsg" };

describe("escrow configuration", () => {
  it("defaults to none and rejects unknown backends", () => {
    expect(loadConfig(base).escrowBackend).toBe("none");
    expect(() => loadConfig({ ...base, AGMSG_ESCROW_BACKEND: "vault" })).toThrow();
  });
  it("loads no backend for none, whatever the file setting", async () => {
    expect(await loadEscrowBackend({ backend: "none", keyfilePath: "/nonexistent" }))
      .toBeNull();
  });
  it("refuses keyfile without a path, with an unreadable file, or a short key", async () => {
    await expect(loadEscrowBackend({ backend: "keyfile", keyfilePath: null }))
      .rejects.toBeInstanceOf(EscrowConfigError);
    const dir = await mkdtemp(join(tmpdir(), "escrow-test-"));
    try {
      await expect(loadEscrowBackend({ backend: "keyfile", keyfilePath: join(dir, "missing") }))
        .rejects.toThrow(/cannot be read/);
      const short = join(dir, "short");
      await writeFile(short, randomBytes(31));
      await expect(loadEscrowBackend({ backend: "keyfile", keyfilePath: short }))
        .rejects.toThrow(/too short/);
      const good = join(dir, "good");
      await writeFile(good, randomBytes(32));
      const backend = await loadEscrowBackend({ backend: "keyfile", keyfilePath: good });
      expect(backend?.kind).toBe("keyfile");
    } finally {
      await rm(join(dir, "missing"), { force: true });
      await rm(join(dir, "short"), { force: true });
      await rm(join(dir, "good"), { force: true });
      await rm(dir, { recursive: true });
    }
  });
});

describe("keyfile backend", () => {
  const backend = createKeyfileBackend(randomBytes(32));
  it("round-trips a key", async () => {
    const key = randomBytes(40);
    const blob = await backend.wrap(key, ctx);
    expect(Buffer.from(blob).includes(key)).toBe(false);
    expect(Buffer.from(await backend.unwrap(blob, ctx)).equals(key)).toBe(true);
  });
  it("does not open under another team, epoch, or master key", async () => {
    const blob = await backend.wrap(randomBytes(40), ctx);
    await expect(backend.unwrap(blob, { ...ctx, epoch: 2n })).rejects.toThrow();
    await expect(backend.unwrap(blob, { ...ctx, teamId: "other" })).rejects.toThrow();
    await expect(createKeyfileBackend(randomBytes(32)).unwrap(blob, ctx)).rejects.toThrow();
  });
  it("rejects a tampered or truncated blob", async () => {
    const blob = Buffer.from(await backend.wrap(randomBytes(40), ctx));
    blob[blob.length - 1] = (blob[blob.length - 1] ?? 0) ^ 1;
    await expect(backend.unwrap(blob, ctx)).rejects.toThrow();
    await expect(backend.unwrap(blob.subarray(0, 10), ctx)).rejects.toThrow();
  });
  it("gives a stable public key ref that does not contain the key", () => {
    const material = randomBytes(32);
    const a = createKeyfileBackend(material);
    expect(createKeyfileBackend(material).keyRef).toBe(a.keyRef);
    expect(a.keyRef).toMatch(/^keyfile:[0-9a-f]{16}$/);
    expect(a.keyRef.includes(material.toString("hex").slice(0, 16))).toBe(false);
  });
});

describe("key-escrow feature", () => {
  it("is listed only for the accounts profile with a backend other than none", () => {
    expect(teamFeatures("accounts", "keyfile")).toContain("key-escrow");
    expect(teamFeatures("accounts", "none")).not.toContain("key-escrow");
    expect(teamFeatures("accounts")).not.toContain("key-escrow");
    expect(teamFeatures("open", "keyfile")).toEqual(["roster-snapshot"]);
    expect(originFeatures("accounts", "keyfile")).toEqual(["device-approval", "env-markers", "key-escrow"]);
    expect(originFeatures("accounts", "none")).toEqual(["device-approval", "env-markers"]);
    expect(originFeatures("accounts")).toEqual(["device-approval", "env-markers"]);
    expect(originFeatures("open", "keyfile")).toEqual([]);
  });
});
