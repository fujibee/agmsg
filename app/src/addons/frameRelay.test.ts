import { describe, expect, it } from "vitest";
import { startFrameRelay, type Listen } from "./frameRelay";
import type { PortLike, PushEvent } from "./paneRelay";

const tick = () => new Promise((r) => setTimeout(r, 0));

function harness(opts: { listenDelay?: boolean } = {}) {
  const handlers: ((e: { payload: PushEvent }) => void)[] = [];
  let unlistened = 0;
  let resolveListen: (u: () => void) => void = () => {};
  const listen: Listen = (_event, handler) => {
    handlers.push(handler);
    const unlisten = () => void unlistened++;
    return opts.listenDelay ? new Promise((r) => (resolveListen = () => r(unlisten))) : Promise.resolve(unlisten);
  };
  const ports: (PortLike & { sent: unknown[]; closed: boolean })[] = [];
  const refused: string[] = [];
  let currentRefused: ((op: string, code: string) => void) | undefined = (op, code) => void refused.push(`a:${op}:${code}`);
  const calls: string[] = [];
  let gen = 0;
  const h = startFrameRelay({
    paneInstance: 7,
    wantsFeed: false,
    invoke: async (cmd) => {
      calls.push(cmd);
      return cmd === "addon_pane_loaded" ? ++gen : { agmsg: 1, type: "response", ok: false, error: { code: "not_granted", message: "m" } };
    },
    listen,
    frameWindow: () => ({ postMessage: () => {} }),
    newChannel: () => {
      const port1 = { sent: [] as unknown[], closed: false, onmessage: null as PortLike["onmessage"], postMessage(m: unknown) { port1.sent.push(m); }, close() { port1.closed = true; } };
      ports.push(port1);
      return { port1, port2: {} };
    },
    onRefused: () => currentRefused,
  });
  return { ports, h, handlers, get unlistened() { return unlistened; }, resolveListen: () => resolveListen(() => {}), refused, calls, setRefused: (f: typeof currentRefused) => (currentRefused = f) };
}

describe("startFrameRelay", () => {
  it("dispose unlistens and closes the port", async () => {
    const x = harness();
    await tick();
    await x.h.relay.onFrameLoad();
    expect(x.h.relay.generation()).toBe(1);
    x.h.dispose();
    expect(x.h.relay.generation()).toBeNull();
    expect(x.unlistened).toBe(1);
  });

  it("dispose before listen resolves still unlistens once it does", async () => {
    const x = harness({ listenDelay: true });
    x.h.dispose();
    x.resolveListen();
    await tick();
    // the listener handed back after dispose is dropped: no push reaches the relay
    x.handlers[0]({ payload: { pane: 7, generation: 1, event: {} } });
    expect(x.h.relay.generation()).toBeNull();
  });

  it("a load answered after dispose creates no port", async () => {
    const x = harness();
    const load = x.h.relay.onFrameLoad();
    x.h.dispose();
    await load;
    expect(x.h.relay.generation()).toBeNull();
  });

  it("a new onRefused callback is picked up without rebuilding the relay", async () => {
    const x = harness();
    await x.h.relay.onFrameLoad();
    x.setRefused((op, code) => void x.refused.push(`b:${op}:${code}`));
    x.ports[0].onmessage?.({ data: { agmsg: 1, type: "request", id: 1, op: "fs.list", args: {} } });
    await tick();
    expect(x.refused).toEqual(["b:fs.list:not_granted"]);
    expect(x.h.relay.generation()).toBe(1); // same relay, same port
  });
});
