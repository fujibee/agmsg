import { describe, expect, it } from "vitest";
import { pickSavedRoot, pickSavedTeam, replayPickedFolder } from "./savedGrants";

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

describe("a folder picked from the menu", () => {
  const ok = <T,>(value: T) => ({ ok: true as const, value });
  const pane = { addonId: "builtin:fileview", paneName: "fileview", paneId: 7 };
  const mk = (savedList: { permission: string; scope: string }[], real = (p: string) => p.replace(/\/+$/, "")) => {
    const granted: string[] = [];
    return {
      granted,
      source: {
        savedGrants: async () => ok(savedList),
        resolveFolder: async (p: string) => ok(real(p)),
        grantRoot: async (_id: number, p: string) => (granted.push(p), { ok: true as const, realPath: p }),
      },
    };
  };
  it("the same folder as a saved grant is granted again without a card", async () => {
    const m = mk([{ permission: "files:read", scope: "/Users/a/proj" }]);
    expect(await replayPickedFolder(m.source, pane, "/Users/a/proj/")).toEqual({ realPath: "/Users/a/proj" });
    expect(m.granted).toEqual(["/Users/a/proj"]);
  });
  it("the choice is compared by its real path (a link to the saved folder matches)", async () => {
    const m = mk([{ permission: "files:read", scope: "/Users/a/proj" }], () => "/Users/a/proj");
    expect(await replayPickedFolder(m.source, pane, "/tmp/link")).toEqual({ realPath: "/Users/a/proj" });
  });
  it("a different folder, or one below the saved folder, asks (card)", async () => {
    const m = mk([{ permission: "files:read", scope: "/Users/a/proj" }]);
    expect(await replayPickedFolder(m.source, pane, "/Users/a/other")).toBeNull();
    expect(await replayPickedFolder(m.source, pane, "/Users/a/proj/src")).toBeNull();
    expect(m.granted).toEqual([]);
  });
  it("after Revoke nothing is saved, so it asks", async () => {
    const m = mk([]);
    expect(await replayPickedFolder(m.source, pane, "/Users/a/proj")).toBeNull();
    expect(m.granted).toEqual([]);
  });
  it("a refused resolve, saved read or grant asks (card)", async () => {
    const saved = [{ permission: "files:read", scope: "/p" }];
    const m = mk(saved);
    expect(await replayPickedFolder({ ...m.source, resolveFolder: async () => ({ ok: false as const }) }, pane, "/p")).toBeNull();
    expect(await replayPickedFolder({ ...m.source, savedGrants: async () => ({ ok: false as const }) }, pane, "/p")).toBeNull();
    expect(await replayPickedFolder({ ...m.source, grantRoot: async () => ({ ok: false as const }) }, pane, "/p")).toBeNull();
  });
});
