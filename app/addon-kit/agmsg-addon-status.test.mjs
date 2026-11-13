// The status event, the init flag and agents.status arrive over the port exactly as protocol.d.ts says, and not otherwise.
import { describe, expect, it } from "vitest";
import { connect } from "./agmsg-addon.js";

function appWithPort(options = {}) {
  let onWindow = null;
  const sent = [];
  const parent = {};
  globalThis.window = { parent, addEventListener: (_t, fn) => (onWindow = fn), removeEventListener() {} };
  const app = connect({ sample: false, errorOverlay: false, ...options });
  const port = { postMessage: (m) => sent.push(m), start() {}, onmessage: null };
  onWindow({ source: parent, data: { agmsg: 1, type: "port" }, ports: [port] });
  const push = (data) => port.onmessage({ data: { agmsg: 1, ...data } });
  return { app, push, sent };
}

describe("kit agent status", () => {
  it("is off until init says the app reports status, and off for an older app", () => {
    const { app, push } = appWithPort();
    expect(app.canReportStatus).toBe(false);
    push({ type: "init", team: "t", members: [], messages: [] });
    expect(app.canReportStatus).toBe(false);
    push({ type: "init", team: "t", members: [], messages: [], status: true });
    expect(app.canReportStatus).toBe(true);
    push({ type: "init", team: "t", members: [], messages: [], status: "yes" });
    expect(app.canReportStatus).toBe(false);
  });

  it("calls onStatus with the member, the state and the time, and nothing else", () => {
    const seen = [];
    const { push } = appWithPort({ onStatus: (s) => seen.push(s) });
    push({ type: "init", team: "t", members: [], messages: [], status: true });
    push({ type: "status", name: "white", state: "working", at: 1234, pane: "p-7", cwd: "/must/not/pass" });
    push({ type: "status", name: "black", state: "closed", at: 5 });
    expect(seen).toEqual([
      { name: "white", state: "working", at: 1234 },
      { name: "black", state: "closed", at: 5 },
    ]);
  });

  it("ignores a status event without a name or a state", () => {
    const seen = [];
    const { push } = appWithPort({ onStatus: (s) => seen.push(s) });
    push({ type: "status", state: "idle", at: 1 });
    push({ type: "status", name: "white", at: 1 });
    push({ type: "status", name: 5, state: "idle", at: 1 });
    expect(seen).toEqual([]);
  });

  it("an add-on that does not listen is not troubled by a status event", () => {
    const { push } = appWithPort();
    expect(() => push({ type: "status", name: "white", state: "idle", at: 1 })).not.toThrow();
  });

  it("agents.status asks the app for agents.status and returns its answer", async () => {
    const { app, push, sent } = appWithPort();
    const answer = app.agents.status();
    await new Promise((r) => setTimeout(r, 0)); // the request is posted once the port is ready
    expect(sent.at(-1)).toMatchObject({ type: "request", op: "agents.status", args: {} });
    push({ type: "response", id: sent.at(-1).id, ok: true, result: { agents: [{ name: "white", type: "codex", state: "idle", since: 9 }] } });
    expect(await answer).toEqual({ agents: [{ name: "white", type: "codex", state: "idle", since: 9 }] });
  });

  it("agents.status rejects with the app's code when it is refused", async () => {
    const { app, push, sent } = appWithPort();
    const answer = app.agents.status();
    await new Promise((r) => setTimeout(r, 0)); // the request is posted once the port is ready
    push({ type: "response", id: sent.at(-1).id, ok: false, error: { code: "not_granted", message: "no" } });
    await expect(answer).rejects.toMatchObject({ code: "not_granted" });
  });
});
