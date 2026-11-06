import { describe, expect, it } from "vitest";
import { isAddonMember } from "./addonMember";

describe("isAddonMember", () => {
  it("is true only for a member whose every type is app-addon", () => {
    expect(isAddonMember({ types: ["app-addon"] })).toBe(true);
    expect(isAddonMember({ types: ["claude-code"] })).toBe(false);
    expect(isAddonMember({ types: ["app-addon", "claude-code"] })).toBe(false);
    expect(isAddonMember({ types: [] })).toBe(false);
  });
});
