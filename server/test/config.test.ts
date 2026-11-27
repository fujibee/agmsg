import { describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

describe("reference server configuration", () => {
  it("keeps automatic retention disabled when unset", () => {
    expect(loadConfig({ DATABASE_URL: "postgresql://example/agmsg" })
      .retentionMaxLiveMessages).toBeNull();
  });

  it("accepts only canonical positive signed-BIGINT retention limits", () => {
    expect(loadConfig({ DATABASE_URL: "postgresql://example/agmsg",
      AGMSG_RETENTION_MAX_LIVE_MESSAGES: "100000" })
      .retentionMaxLiveMessages).toBe(100000n);
    for (const value of ["", "0", "01", "-1", "1.0", "9223372036854775808"]) {
      expect(() => loadConfig({ DATABASE_URL: "postgresql://example/agmsg",
        AGMSG_RETENTION_MAX_LIVE_MESSAGES: value })).toThrow();
    }
  });
});

describe("accounts profile configuration", () => {
  const base = { DATABASE_URL: "postgresql://example/agmsg", AGMSG_PROFILE: "accounts" };
  const good = { ...base, AGMSG_OWNER_SECRET: "0123456789abcdef0123456789abcdef", AGMSG_PUBLIC_URL: "https://agmsg.example.com" };

  it("defaults to the open profile with no accounts settings", () => {
    const config = loadConfig({ DATABASE_URL: "postgresql://example/agmsg" });
    expect(config.profile).toBe("open");
    expect(config.ownerSecret).toBeNull();
    expect(config.publicUrl).toBeNull();
  });

  it("refuses an unknown profile", () => {
    expect(() => loadConfig({ DATABASE_URL: "postgresql://example/agmsg", AGMSG_PROFILE: "closed" })).toThrow();
  });

  it("accepts a strong owner secret and a public origin", () => {
    const config = loadConfig(good);
    expect(config.profile).toBe("accounts");
    expect(config.publicUrl).toBe("https://agmsg.example.com");
  });

  it("refuses to start without a strong owner secret, and says how to make one", () => {
    expect(() => loadConfig({ ...base, AGMSG_PUBLIC_URL: good.AGMSG_PUBLIC_URL })).toThrow(/openssl rand -hex 32/u);
    for (const weak of ["short", "a".repeat(64), "password".repeat(5), "0123456789abcdef"]) {
      expect(() => loadConfig({ ...good, AGMSG_OWNER_SECRET: weak }), weak).toThrow(/openssl rand -hex 32/u);
    }
  });

  it("needs the public origin, and only an origin", () => {
    expect(() => loadConfig({ ...base, AGMSG_OWNER_SECRET: good.AGMSG_OWNER_SECRET })).toThrow(/AGMSG_PUBLIC_URL/u);
    for (const bad of ["agmsg.example.com", "ftp://x.example", "https://x.example/path", "https://x.example/?q=1", "https://u:p@x.example"]) {
      expect(() => loadConfig({ ...good, AGMSG_PUBLIC_URL: bad }), bad).toThrow(/AGMSG_PUBLIC_URL/u);
    }
  });
});
