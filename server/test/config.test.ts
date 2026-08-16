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
