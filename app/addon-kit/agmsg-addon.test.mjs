// The kit's agent helpers send exactly the frame shapes protocol.d.ts names, and nothing else.
import { describe, expect, it } from "vitest";
import { connect } from "./agmsg-addon.js";

function appWithPort() {
  const posted = [];
  let onWindow = null;
  const parent = {};
  globalThis.window = { parent, addEventListener: (_t, fn) => (onWindow = fn), removeEventListener() {} };
  const app = connect({ sample: false, errorOverlay: false });
  const port = { postMessage: (m) => posted.push(m), start() {}, onmessage: null };
  onWindow({ source: parent, data: { agmsg: 1, type: "port" }, ports: [port] });
  const answer = (i, result) => port.onmessage({ data: { agmsg: 1, type: "response", id: posted[i].id, ok: true, result } });
  return { app, posted, answer };
}

describe("kit agent ops", () => {
  it("sends only the fields the protocol names", async () => {
    const { app, posted, answer } = appWithPort();
    const calls = [
      [app.team.join(), "team.join", {}],
      [app.messages.send("white", "hi"), "messages.send", { to: "white", body: "hi" }],
      [app.agents.types(), "agents.types", {}],
      [app.agents.spawn("claude-code", "white", { model: "m" }), "agents.spawn", { type: "claude-code", name: "white", model: "m" }],
      [app.agents.list(), "agents.list", {}],
    ];
    await new Promise((r) => setTimeout(r, 0));
    calls.forEach(([, op, args], i) => {
      expect(posted[i].op).toBe(op);
      expect(posted[i].args).toEqual(args);
      answer(i, { ok: i });
    });
    for (const [p, , ] of calls) await p;
  });
});
