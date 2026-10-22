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

  it("sends the commands with the names and argument shapes Rust expects", async () => {
    const r = recorder({ addon_pane_add: { id: 3, url: "http://127.0.0.1:1/t/", port: 1 }, addon_grant_root: "/real" });
    const s = createLiveSource(r.invoke);
    expect(await s.addPane({ addon: "diffview", name: "diffview", openArgs: { path: "/p" } })).toEqual({ id: 3, url: "http://127.0.0.1:1/t/", port: 1 });
    await s.grantTeam(3, "agmsg");
    expect(await s.grantRoot(3, "/p")).toEqual({ ok: true, realPath: "/real" });
    await s.revokeTeam(3);
    await s.revokeRoot(3);
    await s.removePane(3);
    expect(r.calls).toEqual([
      ["addon_pane_add", { spec: { addon: "diffview", name: "diffview", openArgs: { path: "/p" } } }],
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
    await expect(s.addPane({ addon: "a", name: "b", openArgs: {} })).rejects.toBe("add-ons are off on this computer: probe failed");
  });
});
