import { describe, expect, it } from "vitest";
import { createLiveSource, toCommandError, type Invoke } from "./source";

const recorder = (answers: Record<string, unknown> = {}) => {
  const calls: [string, Record<string, unknown> | undefined][] = [];
  const invoke: Invoke = async (cmd, args) => {
    calls.push([cmd, args]);
    const a = answers[cmd];
    if (a instanceof Error || (typeof a === "object" && a !== null && "__reject" in a)) throw (a as { __reject: unknown }).__reject ?? a;
    return a;
  };
  return { invoke, calls };
};
const reject = (e: unknown) => ({ __reject: e });

describe("live source", () => {
  it("engine: enabled -> ok, disabled -> reasons, failure -> off with the message", async () => {
    expect(await createLiveSource(recorder({ addon_gate_status: { enabled: true, reasons: [] } }).invoke).engine()).toEqual({ ok: true });
    expect(await createLiveSource(recorder({ addon_gate_status: { enabled: false, reasons: ["a", "b"] } }).invoke).engine()).toEqual({ ok: false, reasons: ["a", "b"] });
    expect(await createLiveSource(recorder({ addon_gate_status: reject("no gate") }).invoke).engine()).toEqual({ ok: false, reasons: ["no gate"] });
  });

  const pane = { id: 3, url: "http://127.0.0.1:1/t/", port: 1, title: "Diff view", permissions: ["files:read"], network: "" };

  it("sends the commands with the names and argument shapes Rust expects", async () => {
    const r = recorder({ addon_pane_add: pane, addon_grant_root: "/real" });
    const s = createLiveSource(r.invoke);
    expect(await s.addPane({ addonId: "builtin:diffview", pane: "diffview", openArgs: { path: "/p" } })).toEqual(pane);
    await s.grantTeam(3, "agmsg");
    expect(await s.grantRoot(3, "/p")).toEqual({ ok: true, realPath: "/real" });
    await s.revokeTeam(3);
    await s.revokeRoot(3);
    await s.removePane(3);
    expect(r.calls).toEqual([
      ["addon_pane_add", { spec: { addonId: "builtin:diffview", pane: "diffview", openArgs: { path: "/p" } } }],
      ["addon_grant_team", { id: 3, team: "agmsg" }],
      ["addon_grant_root", { id: 3, path: "/p" }],
      ["addon_revoke_team", { id: 3 }],
      ["addon_revoke_root", { id: 3 }],
      ["addon_pane_remove", { id: 3 }],
    ]);
  });

  it("grantRoot passes a denied_path refusal through with its ready-to-show message", async () => {
    const e = { code: "denied_path", message: "/Users/me/.ssh is on agmsg's list of protected locations." };
    const r = await createLiveSource(recorder({ addon_grant_root: reject(e) }).invoke).grantRoot(1, "/Users/me/.ssh");
    expect(r).toEqual({ ok: false, error: e });
  });

  it("a plain string error becomes code 'error'", () => {
    expect(toCommandError("add-ons are off on this computer: x")).toEqual({ code: "error", message: "add-ons are off on this computer: x" });
    expect(toCommandError(new Error("boom"))).toEqual({ code: "error", message: "boom" });
  });

  it("addPane lets Rust's refusal (gate off) reach the caller", async () => {
    const s = createLiveSource(recorder({ addon_pane_add: reject("add-ons are off on this computer: probe failed") }).invoke);
    await expect(s.addPane({ addonId: "a", pane: "b", openArgs: {} })).rejects.toBe("add-ons are off on this computer: probe failed");
  });

  it("list maps addon_list rows: built-in vs installed, network text, permissions, opens, digestOk", async () => {
    const raw = [
      { id: "builtin:fileview", kind: "builtin", source: "agmsg", commit: "1.2.3", title: "File view", digestOk: true, enabled: true, problems: [],
        panes: [{ name: "fileview", title: "File view", entry: "index.html", permissions: ["files:read"], network: "", opens: ["path"], why: { "files:read": "Lists." } }] },
      { id: "o/r", kind: "installed", source: "o/r", commit: "a".repeat(40), title: "R", digestOk: false, enabled: true, problems: ["p: bad"],
        panes: [{ name: "p", title: "P", entry: "index.html", permissions: ["network", "bogus"], network: "https://a.test,https://b.test", opens: [], why: {} },
                { name: "q", title: "Q", entry: "index.html", permissions: ["network"], network: "*", opens: ["url", "path"], why: {} }] },
    ];
    const list = await createLiveSource(recorder({ addon_list: raw }).invoke).list();
    expect(list[0]).toMatchObject({ id: "builtin:fileview", builtin: true, sha: "", digestOk: true });
    expect(list[0].panes[0]).toMatchObject({ permissions: ["files:read"], network: { kind: "none" }, opens: "path" });
    expect(list[1]).toMatchObject({ id: "o/r", builtin: false, sha: "a".repeat(40), digestOk: false, problems: ["p: bad"] });
    expect(list[1].panes[0]).toMatchObject({ permissions: ["network"], network: { kind: "origins", origins: ["https://a.test", "https://b.test"] }, opens: "" });
    expect(list[1].panes[1]).toMatchObject({ network: { kind: "any" }, opens: "url" });
  });
});
