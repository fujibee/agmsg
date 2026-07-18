import { describe, expect, it } from "vitest";
import { shouldShowOutdatedBanner } from "./App";

describe("shouldShowOutdatedBanner", () => {
  it("shows when outdated, not updating, and not dismissed", () => {
    expect(shouldShowOutdatedBanner({ installed: "1.1.0", pinned: "1.1.8" }, false, false)).toBe(true);
  });

  it("hides when not outdated (null)", () => {
    expect(shouldShowOutdatedBanner(null, false, false)).toBe(false);
  });

  it("hides while an update is in flight", () => {
    expect(shouldShowOutdatedBanner({ installed: "1.1.0", pinned: "1.1.8" }, true, false)).toBe(false);
  });

  it("hides once dismissed, independent of updatingCore", () => {
    expect(shouldShowOutdatedBanner({ installed: "1.1.0", pinned: "1.1.8" }, false, true)).toBe(false);
  });
});
