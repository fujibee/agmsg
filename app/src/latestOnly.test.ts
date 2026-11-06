import { describe, expect, it } from "vitest";
import { createLatestOnly } from "./latestOnly";
import { mergeById } from "./App";

// The room's history load as App wires it: reset, load, then merge into the live feed if still current.
function room() {
  const gate = createLatestOnly();
  let feed: { id: string }[] = [];
  return {
    feed: () => feed,
    live: (id: string) => (feed = [...feed, { id }]),
    load(history: Promise<{ id: string }[]>) {
      const current = gate.start();
      feed = [];
      return history.then((h) => {
        if (current()) feed = mergeById(h, feed);
      });
    },
  };
}
const deferred = <T,>() => {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
};

describe("room history load", () => {
  it("team A's slow history, finishing after the switch to B, is dropped (A first, then B)", async () => {
    const r = room();
    const a = deferred<{ id: string }[]>();
    const b = deferred<{ id: string }[]>();
    const pa = r.load(a.promise);
    const pb = r.load(b.promise);
    r.live("B-live");
    a.resolve([{ id: "A-old" }]);
    await pa;
    expect(r.feed().map((m) => m.id)).toEqual(["B-live"]);
    b.resolve([{ id: "B-history" }]);
    await pb;
    expect(r.feed().map((m) => m.id)).toEqual(["B-history", "B-live"]);
  });
  it("B finishes first, then the stale A: A still changes nothing", async () => {
    const r = room();
    const a = deferred<{ id: string }[]>();
    const b = deferred<{ id: string }[]>();
    const pa = r.load(a.promise);
    const pb = r.load(b.promise);
    b.resolve([{ id: "B-history" }]);
    await pb;
    a.resolve([{ id: "A-old" }]);
    await pa;
    expect(r.feed().map((m) => m.id)).toEqual(["B-history"]);
  });
  it("a stale reload of the same team does not replace the newer one", async () => {
    const r = room();
    const first = deferred<{ id: string }[]>();
    const second = deferred<{ id: string }[]>();
    const p1 = r.load(first.promise);
    const p2 = r.load(second.promise);
    second.resolve([{ id: "new" }]);
    await p2;
    first.resolve([{ id: "stale" }]);
    await p1;
    expect(r.feed().map((m) => m.id)).toEqual(["new"]);
  });
});
