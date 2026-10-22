import { describe, expect, it } from "vitest";
import { listenPaneFailed, type PaneFailedEvent } from "./paneFailed";

const harness = () => {
  let handler: ((e: { payload: PaneFailedEvent }) => void) | null = null;
  let resolveListen!: (u: () => void) => void;
  const state = { unlistened: 0 };
  const listen = (_: string, h: (e: { payload: PaneFailedEvent }) => void) => {
    handler = h;
    return new Promise<() => void>((r) => (resolveListen = r));
  };
  return { listen, state, fire: (e: PaneFailedEvent) => handler?.({ payload: e }), ready: () => resolveListen(() => void state.unlistened++) };
};

describe("listenPaneFailed", () => {
  it("reports only this pane's failure", async () => {
    const h = harness();
    const seen: string[] = [];
    listenPaneFailed(h.listen, 7, (r) => seen.push(r));
    h.ready();
    h.fire({ pane: 8, reason: "other" });
    h.fire({ pane: 7, reason: "mine" });
    expect(seen).toEqual(["mine"]);
  });
  it("drops an event after dispose, and unlistens at once when the registration resolves late", async () => {
    const h = harness();
    const seen: string[] = [];
    const dispose = listenPaneFailed(h.listen, 7, (r) => seen.push(r));
    dispose(); // cleanup before listen() resolved
    h.fire({ pane: 7, reason: "old pane after retry" });
    h.ready();
    await Promise.resolve();
    await Promise.resolve();
    expect(seen).toEqual([]);
    expect(h.state.unlistened).toBe(1);
  });
  it("dispose after registration unlistens once", async () => {
    const h = harness();
    const dispose = listenPaneFailed(h.listen, 7, () => {});
    h.ready();
    await Promise.resolve();
    await Promise.resolve();
    dispose();
    dispose();
    expect(h.state.unlistened).toBe(1);
  });
});
