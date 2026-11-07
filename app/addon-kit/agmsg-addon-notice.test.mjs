// The notice event and the delivery flag arrive over the port exactly as protocol.d.ts says, and not otherwise.
import { describe, expect, it } from "vitest";
import { connect } from "./agmsg-addon.js";

function appWithPort(options = {}) {
  let onWindow = null;
  const parent = {};
  globalThis.window = { parent, addEventListener: (_t, fn) => (onWindow = fn), removeEventListener() {} };
  const app = connect({ sample: false, errorOverlay: false, ...options });
  const port = { postMessage() {}, start() {}, onmessage: null };
  onWindow({ source: parent, data: { agmsg: 1, type: "port" }, ports: [port] });
  const push = (data) => port.onmessage({ data: { agmsg: 1, ...data } });
  return { app, push };
}

describe("kit delivery reports", () => {
  it("is off until init says the app reports delivery, and off for an older app", () => {
    const { app, push } = appWithPort();
    expect(app.canReportDelivery).toBe(false);
    push({ type: "init", team: "t", members: [], messages: [] });
    expect(app.canReportDelivery).toBe(false);
    push({ type: "init", team: "t", members: [], messages: [], notice: true });
    expect(app.canReportDelivery).toBe(true);
    push({ type: "init", team: "t", members: [], messages: [], notice: "yes" });
    expect(app.canReportDelivery).toBe(false);
  });

  it("calls onNotice with the member, the time and the ids, and nothing else", () => {
    const seen = [];
    const { push } = appWithPort({ onNotice: (n) => seen.push(n) });
    push({ type: "init", team: "t", members: [], messages: [], notice: true });
    push({ type: "notice", name: "white", at: 1234, ids: ["m1", "m2"], body: "must not pass through" });
    push({ type: "notice", name: "black", at: 5 });
    expect(seen).toEqual([
      { name: "white", at: 1234, ids: ["m1", "m2"] },
      { name: "black", at: 5, ids: [] },
    ]);
  });

  it("an add-on that does not listen is not troubled by a notice", () => {
    const { push } = appWithPort();
    expect(() => push({ type: "notice", name: "white", at: 1, ids: ["m"] })).not.toThrow();
  });
});
