import { describe, expect, it } from "vitest";
import { pickSavedPowers, pickSavedRoot, pickSavedTeam, replayPickedFolder, replaySavedPowers } from "./savedGrants";

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

describe("pickSavedPowers", () => {
  const rows = [
    { permission: "team:join", scope: "t1" },
    { permission: "agents:spawn", scope: "t1" },
    { permission: "messages:send", scope: "t2" },
  ];
  it("counts a power only for exactly the same team", () => {
    expect(pickSavedPowers(rows, "t1")).toEqual({ join: true, send: false, spawn: true });
    expect(pickSavedPowers(rows, "t2")).toEqual({ join: false, send: true, spawn: false });
    expect(pickSavedPowers(rows, "t3")).toEqual({ join: false, send: false, spawn: false });
  });
});

describe("replaySavedPowers", () => {
  const all = ["team:join", "messages:send", "agents:spawn"] as const;
  const rows = all.map((permission) => ({ permission, scope: "t1" }));
  const fake = (failOn?: string) => {
    const calls: string[] = [];
    return {
      calls,
      grantTeam: async (id: number, team: string) => (calls.push(`team:${id}:${team}`), { ok: true }),
      setPower: async (_id: number, power: string, on: boolean) => (calls.push(`${power}:${on}`), { ok: power !== failOn }),
    };
  };
  it("grants the team and sets every remembered power again, so the card is not asked", async () => {
    const f = fake();
    expect(await replaySavedPowers(f, 7, "t1", [...all], rows)).toBe(true);
    expect(f.calls).toEqual(["team:7:t1", "team:join:true", "messages:send:true", "agents:spawn:true"]);
  });
  it("asks when a power was not remembered, when it was remembered for another team, or when one fails", async () => {
    const f = fake();
    expect(await replaySavedPowers(f, 7, "t1", [...all], rows.slice(0, 2))).toBe(false);
    expect(await replaySavedPowers(f, 7, "t2", [...all], rows)).toBe(false);
    expect(f.calls).toEqual([]);
    expect(await replaySavedPowers(fake("messages:send"), 7, "t1", [...all], rows)).toBe(false);
  });
  it("replays only what the add-on declares", async () => {
    const f = fake();
    expect(await replaySavedPowers(f, 7, "t1", ["team:join"], rows.slice(0, 1))).toBe(true);
    expect(f.calls).toEqual(["team:7:t1", "team:join:true"]);
  });
});
