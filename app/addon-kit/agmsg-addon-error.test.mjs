// An error in the page reaches the app over the port with its own message and stack, once, and a guarded callback
// reports instead of dying as an opaque "Script error.".
import { describe, expect, it } from "vitest";
import { connect, guard } from "./agmsg-addon.js";

function appWithPort() {
  let onWindow = null;
  const parent = {};
  globalThis.window = { parent, addEventListener: (_t, fn) => (onWindow = fn), removeEventListener() {} };
  globalThis.document = { body: null };
  connect({ sample: false, errorOverlay: false });
  const sent = [];
  const port = { postMessage: (m) => sent.push(m), start() {}, onmessage: null };
  onWindow({ source: parent, data: { agmsg: 1, type: "port" }, ports: [port] });
  return sent;
}

describe("kit error reports", () => {
  it("a guarded callback that throws is reported with its message and stack, and does not throw", () => {
    const sent = appWithPort();
    const f = guard(() => { throw new Error("boom-guard"); });
    expect(() => f()).not.toThrow();
    expect(sent).toHaveLength(1);
    expect(sent[0]).toMatchObject({ agmsg: 1, type: "error", message: "boom-guard" });
    expect(sent[0].stack).toContain("boom-guard");
  });

  it("a guarded async callback that rejects is reported too, and the value passes through otherwise", async () => {
    const sent = appWithPort();
    await guard(async () => { throw new Error("late-guard"); })();
    expect(sent.map((m) => m.message)).toContain("late-guard");
    expect(guard((a, b) => a + b)(2, 3)).toBe(5);
  });

  it("the message and the stack are cut", () => {
    const sent = appWithPort();
    const e = new Error("y".repeat(5000));
    e.stack = "s".repeat(9000);
    guard(() => { throw e; })();
    const m = sent.find((x) => x.message.startsWith("yyyy"));
    expect(m.message).toHaveLength(500);
    expect(m.stack).toHaveLength(2000);
  });

  it("the same message is reported once and the number of reports is capped", () => {
    const sent = appWithPort();
    const f = guard(() => { throw new Error("same-guard"); });
    f(); f(); f();
    expect(sent.filter((m) => m.message === "same-guard")).toHaveLength(1);
    for (let i = 0; i < 60; i++) guard(() => { throw new Error(`cap-${i}`); })();
    expect(sent.length).toBeLessThanOrEqual(20);
  });
});
