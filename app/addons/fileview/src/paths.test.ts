import { describe, expect, it } from "vitest";
import { resolveRelative } from "./paths";

describe("resolveRelative", () => {
  it("resolves against the folder", () => {
    expect(resolveRelative("docs", "img/a.png")).toBe("docs/img/a.png");
    expect(resolveRelative("docs", "../README.md#top")).toBe("README.md");
    expect(resolveRelative(".", "./a%20b.md")).toBe("a b.md");
  });
  it("refuses links that leave the root or point elsewhere", () => {
    expect(resolveRelative("docs", "../../x")).toBeNull();
    expect(resolveRelative(".", "https://example.com/a")).toBeNull();
    expect(resolveRelative(".", "//example.com/a")).toBeNull();
    expect(resolveRelative(".", "/etc/passwd")).toBeNull();
    expect(resolveRelative(".", "#top")).toBeNull();
  });
});
