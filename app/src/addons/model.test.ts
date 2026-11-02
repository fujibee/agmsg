import { describe, expect, it } from "vitest";
import { addonNetwork, canSendWhatItReads, declaredPermissions, grantText, installErrorText, parseRepoInput, permissionRow, reachesAgents } from "./model";
import { mockInstallErrors, mockSnapshot } from "./mock";

describe("parseRepoInput", () => {
  it("accepts owner/repo and owner/repo@ref", () => {
    expect(parseRepoInput("a/b")).toEqual({ owner: "a", repo: "b", ref: null });
    expect(parseRepoInput(" shinshin86/agmsg-office@v1.0 ")).toEqual({ owner: "shinshin86", repo: "agmsg-office", ref: "v1.0" });
  });
  it("rejects anything else", () => {
    for (const bad of ["", "a", "a/", "/b", "a/b/c", "https://github.com/a/b", "a/..", "a b/c", "a/b@"]) {
      expect(parseRepoInput(bad), bad).toBeNull();
    }
  });
});

describe("permissions", () => {
  const office = mockSnapshot.addons.find((a) => a.id === "shinshin86/agmsg-office")!;
  it("lists declared permissions in the fixed order", () => {
    expect(declaredPermissions(office)).toEqual(["messages:read", "network"]);
  });
  it("names the hosts, or any site", () => {
    expect(permissionRow("network", addonNetwork(office))).toEqual({
      key: "addons.permission.network",
      params: { hosts: "fonts.example.com" },
    });
    expect(permissionRow("network", { kind: "any" }).key).toBe("addons.permission.networkAny");
  });
  it("warns only when a read permission meets network", () => {
    expect(canSendWhatItReads({ permissions: ["messages:read", "network"] })).toBe(true);
    expect(canSendWhatItReads({ permissions: ["files:read"] })).toBe(false);
    expect(canSendWhatItReads({ permissions: ["network"] })).toBe(false);
  });
});

describe("grantText", () => {
  const t = (key: string, o?: Record<string, unknown>) => `${key}|${o?.scope ?? ""}`;
  it("marks remembered file grants only", () => {
    const [msg, files] = mockSnapshot.grants;
    expect(grantText(t, msg)).toBe("addons.grant.messages|agmsg");
    expect(grantText(t, files)).toContain("addons.grant.remembered");
  });
});

describe("installErrorText", () => {
  it("has a distinct key for every failure and every unsafe-entry kind", () => {
    const keys = mockInstallErrors.map((e) => installErrorText(e).key);
    expect(new Set(keys).size).toBe(keys.length);
    expect(installErrorText({ code: "unsafe_entry", what: "hardlink", path: "p" }).key).toBe(
      "addons.installError.unsafe_entry.hardlink",
    );
  });
});

describe("agent powers", () => {
  it("names a row for each new permission", () => {
    const none = { kind: "none" } as const;
    expect(permissionRow("team:join", none).key).toBe("addons.permission.teamJoin");
    expect(permissionRow("messages:send", none).key).toBe("addons.permission.messagesSend");
    expect(permissionRow("agents:spawn", none).key).toBe("addons.permission.agentsSpawn");
  });
  it("reachesAgents is true only for send and spawn", () => {
    expect(reachesAgents(["messages:read", "team:join"])).toEqual({ send: false, spawn: false });
    expect(reachesAgents(["messages:send"])).toEqual({ send: true, spawn: false });
    expect(reachesAgents(["agents:spawn"])).toEqual({ send: false, spawn: true });
  });
});
