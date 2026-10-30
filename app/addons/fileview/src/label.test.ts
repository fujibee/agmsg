import { describe, expect, it } from "vitest";
import { rootLabel } from "../../_shared/format";

describe("rootLabel", () => {
  it("a path given at open time is used as it is", () => {
    expect(rootLabel("/Users/me/proj", "proj", ".")).toBe("/Users/me/proj");
  });
  it("a folder chosen in the dialog (no path) is called by the root's name, not '.'", () => {
    expect(rootLabel(undefined, "proj", ".")).toBe("proj");
    expect(rootLabel("", "proj", ".")).toBe("proj");
  });
  it("a root with no name falls back", () => {
    expect(rootLabel(undefined, "", ".")).toBe(".");
    expect(rootLabel(undefined, undefined, "repository")).toBe("repository");
  });
});
