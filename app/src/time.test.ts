import { describe, expect, it } from "vitest";
import { AUTO_TIMEZONE, formatMessageTime, isValidTimeZone, resolveTimeZone } from "./time";

describe("formatMessageTime", () => {
  it("converts a UTC timestamp to the given IANA zone", () => {
    // 2026-07-14T20:23:55Z -> 05:23:55 the next day in Tokyo (UTC+9)
    expect(formatMessageTime("2026-07-14T20:23:55Z", "Asia/Tokyo")).toBe("05:23:55");
  });

  it("is a no-op conversion for UTC itself", () => {
    expect(formatMessageTime("2026-07-14T20:23:55Z", "UTC")).toBe("20:23:55");
  });

  it("handles a negative-offset zone crossing midnight backwards", () => {
    // 2026-07-14T02:00:00Z -> 2026-07-13 22:00:00 in New York (UTC-4, EDT in July)
    expect(formatMessageTime("2026-07-14T02:00:00Z", "America/New_York")).toBe("22:00:00");
  });

  it("falls back to the raw slice on an unparseable timestamp", () => {
    expect(formatMessageTime("not-a-date", "UTC")).toBe("not-a-date".slice(11, 19));
  });

  it("falls back to the raw slice on an invalid timezone", () => {
    const createdAt = "2026-07-14T20:23:55Z";
    expect(formatMessageTime(createdAt, "Not/AZone")).toBe(createdAt.slice(11, 19));
  });

  it("renders midnight as 00:00:00, not 24:00:00", () => {
    // hour12: false is documented to yield the 24-hour "0-23" cycle rather
    // than the "1-24" cycle some locales default to for a bare hour: "2-digit".
    expect(formatMessageTime("2026-07-14T00:00:00Z", "UTC")).toBe("00:00:00");
  });
});

describe("isValidTimeZone", () => {
  it("accepts a real IANA zone", () => {
    expect(isValidTimeZone("Asia/Tokyo")).toBe(true);
  });

  it("rejects a made-up zone name", () => {
    expect(isValidTimeZone("Not/AZone")).toBe(false);
  });
});

describe("resolveTimeZone", () => {
  it("passes a valid explicit zone through unchanged", () => {
    expect(resolveTimeZone("Europe/Paris")).toBe("Europe/Paris");
  });

  it("resolves the auto sentinel to a real zone, not the sentinel itself", () => {
    expect(resolveTimeZone(AUTO_TIMEZONE)).not.toBe(AUTO_TIMEZONE);
    expect(typeof resolveTimeZone(AUTO_TIMEZONE)).toBe("string");
  });

  it("falls back to the auto-detected zone for an invalid stored value", () => {
    expect(resolveTimeZone("Not/AZone")).toBe(resolveTimeZone(AUTO_TIMEZONE));
  });
});
