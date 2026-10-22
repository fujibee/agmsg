import { describe, expect, it } from "vitest";
import { createPaneRelay, type ChannelLike, type Invoke, type PortLike } from "./paneRelay";

function fakePort(): PortLike & { sent: unknown[]; closed: boolean } {
  const p = {
    sent: [] as unknown[],
    closed: false,
    onmessage: null as PortLike["onmessage"],
    postMessage(m: unknown) {
      p.sent.push(m);
    },
    close() {
      p.closed = true;
    },
  };
  return p;
}

function setup(opts: { wantsFeed?: boolean; handler?: (cmd: string, args: Record<string, unknown>) => unknown } = {}) {
  const calls: [string, Record<string, unknown>][] = [];
  const ports: ReturnType<typeof fakePort>[] = [];
  const posted: { msg: unknown; target: string; transfer: unknown[] }[] = [];
  let gen = 0;
  const invoke: Invoke = async (cmd, args = {}) => {
    calls.push([cmd, args]);
    if (opts.handler) {
      const r = opts.handler(cmd, args);
      if (r !== undefined) return r;
    }
    if (cmd === "addon_pane_loaded") return ++gen;
    if (cmd === "addon_feed_init") return { init: { agmsg: 1, type: "init" }, queued: [{ agmsg: 1, type: "message", n: 1 }] };
    return { agmsg: 1, type: "response", ok: true, result: {} };
  };
  const refused: [string, string][] = [];
  const relay = createPaneRelay({
    id: 7,
    invoke,
    wantsFeed: opts.wantsFeed ?? true,
    frameWindow: () => ({ postMessage: (msg, target, transfer) => void posted.push({ msg, target, transfer }) }),
    newChannel: (): ChannelLike => {
      const port1 = fakePort();
      ports.push(port1);
      return { port1, port2: { tag: "port2" } };
    },
    onRefused: (op, code) => refused.push([op, code]),
  });
  return { relay, calls, ports, posted, refused };
}

const send = (port: PortLike, data: unknown) => port.onmessage?.({ data });
const tick = () => new Promise((r) => setTimeout(r, 0));

describe("pane relay", () => {
  it("hands over one port per load, then feeds init and the queued events in order", async () => {
    const s = setup();
    await s.relay.onFrameLoad();
    expect(s.posted).toHaveLength(1);
    expect(s.posted[0].msg).toEqual({ agmsg: 1, type: "port" });
    expect(s.posted[0].target).toBe("*");
    expect(s.posted[0].transfer).toHaveLength(1);
    expect(s.ports[0].sent).toEqual([{ agmsg: 1, type: "init" }, { agmsg: 1, type: "message", n: 1 }]);
    expect(s.relay.generation()).toBe(1);
  });

  it("does not ask for a feed when the pane does not declare messages:read", async () => {
    const s = setup({ wantsFeed: false });
    await s.relay.onFrameLoad();
    expect(s.calls.map((c) => c[0])).toEqual(["addon_pane_loaded"]);
  });

  it("takes pane and generation from the port, never from the request", async () => {
    const s = setup();
    await s.relay.onFrameLoad();
    send(s.ports[0], { agmsg: 1, type: "request", id: 5, op: "fs.list", args: { path: ".", id: 99, generation: 99 } });
    await tick();
    const req = s.calls.find((c) => c[0] === "addon_request")!;
    expect(req[1]).toMatchObject({ id: 7, generation: 1, op: "fs.list" });
    expect(s.ports[0].sent.slice(-1)[0]).toMatchObject({ agmsg: 1, type: "response", id: 5, ok: true });
  });

  it("answers with bytes as an ArrayBuffer and the buffer in the transfer list", async () => {
    const s = setup({
      handler: (cmd) =>
        cmd === "addon_request" ? { agmsg: 1, type: "response", ok: true, result: { bytesBase64: "AQID", size: 3, eof: true } } : undefined,
    });
    await s.relay.onFrameLoad();
    send(s.ports[0], { agmsg: 1, type: "request", id: 1, op: "fs.read", args: { path: "a" } });
    await tick();
    const m = s.ports[0].sent.slice(-1)[0] as { result: { bytes: ArrayBuffer; bytesBase64?: string } };
    expect(m.result.bytes).toBeInstanceOf(ArrayBuffer);
    expect(new Uint8Array(m.result.bytes)).toEqual(new Uint8Array([1, 2, 3]));
    expect("bytesBase64" in m.result).toBe(false);
  });

  it("ignores messages that are not well-formed requests", async () => {
    const s = setup();
    await s.relay.onFrameLoad();
    for (const bad of [null, "x", { agmsg: 1, type: "request", op: "fs.list" }, { agmsg: 2, type: "request", id: 1, op: "x" }, { agmsg: 1, type: "request", id: "1", op: "x" }]) {
      send(s.ports[0], bad);
    }
    await tick();
    expect(s.calls.some((c) => c[0] === "addon_request")).toBe(false);
  });

  it("a reload closes the old port, binds a new generation, and drops the old port's answers", async () => {
    let release: (v: unknown) => void = () => {};
    const slow = new Promise((r) => (release = r));
    const s = setup({ handler: (cmd) => (cmd === "addon_request" ? (slow as never) : undefined) });
    await s.relay.onFrameLoad();
    send(s.ports[0], { agmsg: 1, type: "request", id: 1, op: "fs.list", args: {} });
    await tick();
    await s.relay.onFrameLoad();
    expect(s.ports[0].closed).toBe(true);
    expect(s.relay.generation()).toBe(2);
    release({ agmsg: 1, type: "response", ok: true, result: {} });
    await tick();
    expect(s.ports[0].sent.filter((m) => (m as { type: string }).type === "response")).toEqual([]);
    expect(s.ports[1].sent.filter((m) => (m as { type: string }).type === "response")).toEqual([]);
  });

  it("a load superseded while Rust answers creates no port", async () => {
    let first = true;
    let releaseFirst: (g: number) => void = () => {};
    const s = setup({
      handler: (cmd) => {
        if (cmd === "addon_pane_loaded" && first) {
          first = false;
          return new Promise<number>((r) => (releaseFirst = r));
        }
        return undefined;
      },
    });
    const a = s.relay.onFrameLoad();
    const b = s.relay.onFrameLoad();
    await b;
    releaseFirst(41);
    await a;
    expect(s.ports).toHaveLength(1);
  });

  it("push events reach the port only for the current generation of this pane", async () => {
    const s = setup({ wantsFeed: false });
    await s.relay.onFrameLoad();
    s.relay.onPush({ pane: 7, generation: 1, event: { n: "ok" } });
    s.relay.onPush({ pane: 7, generation: 0, event: { n: "stale" } });
    s.relay.onPush({ pane: 8, generation: 1, event: { n: "other pane" } });
    expect(s.ports[0].sent).toEqual([{ n: "ok" }]);
  });

  it("a rejected request becomes an error response and reports the refusal", async () => {
    const s = setup({ handler: (cmd) => (cmd === "addon_request" ? Promise.reject("boom") : undefined) });
    await s.relay.onFrameLoad();
    send(s.ports[0], { agmsg: 1, type: "request", id: 2, op: "fs.list", args: {} });
    await tick();
    expect(s.ports[0].sent.slice(-1)[0]).toMatchObject({ id: 2, ok: false, error: { code: "error" } });
    expect(s.refused).toEqual([["fs.list", "error"]]);
  });

  it("closePort stops delivery until the next load", async () => {
    const s = setup({ wantsFeed: false });
    await s.relay.onFrameLoad();
    s.relay.closePort();
    s.relay.onPush({ pane: 7, generation: 1, event: { n: 1 } });
    expect(s.ports[0].closed).toBe(true);
    expect(s.ports[0].sent).toEqual([]);
    expect(s.relay.generation()).toBeNull();
  });
});

const deferred = <T>() => {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
};

describe("pane relay: close during a pending load", () => {
  it("a load that answers after closePort creates no port and leaves generation null", async () => {
    const d = deferred<number>();
    const s = setup({ handler: (cmd) => (cmd === "addon_pane_loaded" ? (d.promise as never) : undefined) });
    const load = s.relay.onFrameLoad();
    s.relay.closePort();
    d.resolve(1);
    await load;
    expect(s.ports).toHaveLength(0);
    expect(s.posted).toHaveLength(0);
    expect(s.relay.generation()).toBeNull();
  });

  it("a load that answers long after closePort still creates no port", async () => {
    const d = deferred<number>();
    const s = setup({ handler: (cmd) => (cmd === "addon_pane_loaded" ? (d.promise as never) : undefined) });
    const load = s.relay.onFrameLoad();
    s.relay.closePort();
    await tick();
    d.resolve(1);
    await load;
    expect(s.ports).toHaveLength(0);
    expect(s.relay.generation()).toBeNull();
  });

  it("a load started after closePort works again", async () => {
    const s = setup({ wantsFeed: false });
    s.relay.closePort();
    await s.relay.onFrameLoad();
    expect(s.ports).toHaveLength(1);
    expect(s.relay.generation()).toBe(1);
  });
});

describe("pane relay: pushes while init is being fetched", () => {
  const msg = (id: string) => ({ agmsg: 1, type: "message", message: { id } });

  it("posts init, then queued, then buffered pushes, in that order", async () => {
    const d = deferred<unknown>();
    const s = setup({ handler: (cmd) => (cmd === "addon_feed_init" ? (d.promise as never) : undefined) });
    const load = s.relay.onFrameLoad();
    await tick();
    s.relay.onPush({ pane: 7, generation: 1, event: msg("live1") });
    s.relay.onPush({ pane: 7, generation: 1, event: msg("live2") });
    expect(s.ports[0].sent).toEqual([]); // nothing before init
    d.resolve({ init: { agmsg: 1, type: "init", messages: [{ id: "h1" }] }, queued: [msg("q1")] });
    await load;
    expect(s.ports[0].sent).toEqual([{ agmsg: 1, type: "init", messages: [{ id: "h1" }] }, msg("q1"), msg("live1"), msg("live2")]);
    // and live from then on
    s.relay.onPush({ pane: 7, generation: 1, event: msg("live3") });
    expect(s.ports[0].sent.slice(-1)[0]).toEqual(msg("live3"));
  });

  it("does not post a message twice when init, the queue and a push all carry it", async () => {
    const d = deferred<unknown>();
    const s = setup({ handler: (cmd) => (cmd === "addon_feed_init" ? (d.promise as never) : undefined) });
    const load = s.relay.onFrameLoad();
    await tick();
    s.relay.onPush({ pane: 7, generation: 1, event: msg("h1") });
    s.relay.onPush({ pane: 7, generation: 1, event: msg("q1") });
    d.resolve({ init: { agmsg: 1, type: "init", messages: [{ id: "h1" }] }, queued: [msg("q1")] });
    await load;
    const ids = s.ports[0].sent.map((m) => (m as { message?: { id: string } }).message?.id).filter(Boolean);
    expect(ids).toEqual(["q1"]);
  });

  it("drops pushes buffered for a frame that was replaced before init answered", async () => {
    const d = deferred<unknown>();
    let first = true;
    const s = setup({
      handler: (cmd) => {
        if (cmd === "addon_feed_init" && first) {
          first = false;
          return d.promise as never;
        }
        return undefined;
      },
    });
    const load = s.relay.onFrameLoad();
    await tick();
    s.relay.onPush({ pane: 7, generation: 1, event: msg("old") });
    await s.relay.onFrameLoad(); // reload: generation 2, its own init
    d.resolve({ init: { agmsg: 1, type: "init" }, queued: [] });
    await load;
    expect(s.ports[0].sent).toEqual([]);
    expect(s.ports[1].sent.some((m) => (m as { message?: { id: string } }).message?.id === "old")).toBe(false);
  });

  it("a failed init does not leave the relay buffering forever", async () => {
    const s = setup({ handler: (cmd) => (cmd === "addon_feed_init" ? Promise.reject({ code: "not_granted" }) : undefined) });
    await s.relay.onFrameLoad();
    s.relay.onPush({ pane: 7, generation: 1, event: msg("x") });
    expect(s.ports[0].sent).toEqual([msg("x")]);
  });
});
