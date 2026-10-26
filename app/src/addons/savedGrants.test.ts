import { describe, expect, it } from "vitest";
import { pickSavedRoot, pickSavedTeam } from "./savedGrants";

const saved = [
  { permission: "files:read", scope: "/Users/a/proj" },
  { permission: "messages:read", scope: "agmsg" },
  { permission: "files:read", scope: "/Users/a/other/" },
];

describe("saved grants", () => {
  it("a saved folder covers itself and what is below it, not a sibling with the same prefix", () => {
    expect(pickSavedRoot(saved, "/Users/a/proj")).toBe("/Users/a/proj");
    expect(pickSavedRoot(saved, "/Users/a/proj/src")).toBe("/Users/a/proj");
    expect(pickSavedRoot(saved, "/Users/a/proj2")).toBeUndefined();
    expect(pickSavedRoot(saved, "/Users/a/other")).toBe("/Users/a/other/");
    expect(pickSavedRoot(saved, "/Users/b")).toBeUndefined();
  });
  it("with no requested path (opened from the menu) no saved folder is applied, so the picker shows", () => {
    expect(pickSavedRoot(saved)).toBeUndefined();
    expect(pickSavedRoot(saved, "")).toBeUndefined();
    expect(pickSavedRoot([{ permission: "messages:read", scope: "t" }])).toBeUndefined();
  });
  it("a team grant is replayed only for that same team", () => {
    expect(pickSavedTeam(saved, "agmsg")).toBe("agmsg");
    expect(pickSavedTeam(saved, "other")).toBeUndefined();
  });
});
