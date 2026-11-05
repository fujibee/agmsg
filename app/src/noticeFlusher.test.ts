import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createNoticeFlusher } from "./noticeFlusher";
import { INJECT_SETTLE_MS, UNKNOWN_WAIT_MS, type Queues } from "./noticeQueue";

type Call = { id: string; text: string; settle: (ok: boolean) => void };

function setup(live = ["p1"]) {
  const calls: Call[] = [];
  const banner: number[] = [];
  let held: Queues = {};
  const f = createNoticeFlusher({
    inject: (id, text) => new Promise((resolve, reject) => calls.push({ id, text, settle: (ok) => (ok ? resolve(undefined) : reject(new Error("pty"))) })),
    livePanes: () => live,
    now: () => Date.now(),
    setTimer: (fn, ms) => void setTimeout(fn, ms),
    onHeldChange: (q) => (held = q),
    onWithoutReadySignal: (n) => banner.push(n),
  });
  return { f, calls, banner, held: () => held };
}

describe("noticeFlusher", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("a new pane's notices are held while it works and typed as one line when it goes idle", async () => {
    const { f, calls } = setup();
    f.state("p1", "working");
    f.notice("p1", "n1");
    f.notice("p1", "n2");
    expect(calls).toHaveLength(0);
    f.state("p1", "idle");
    expect(calls).toHaveLength(1);
    expect(calls[0].text).toContain("n1");
    expect(calls[0].text).toContain("+1 more");
  });

  it("while a write is in flight and during the settle window nothing else is written; a notice arriving then goes out after", async () => {
    const { f, calls } = setup();
    f.state("p1", "idle");
    f.notice("p1", "n1");
    expect(calls).toHaveLength(1);
    f.notice("p1", "n2"); // in flight
    expect(calls).toHaveLength(1);
    calls[0].settle(true);
    await vi.advanceTimersByTimeAsync(INJECT_SETTLE_MS - 1);
    f.notice("p1", "n3"); // inside the settle window
    expect(calls).toHaveLength(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(calls).toHaveLength(2);
    expect(calls[1].text).toContain("n2");
    expect(calls[1].text).toContain("+1 more");
  });

  it("a rejected write keeps the notices in order, shows no delivered banner, and they are retried", async () => {
    const { f, calls, banner, held } = setup();
    f.state("p1", "idle");
    f.notice("p1", "n1");
    f.notice("p1", "n2");
    calls[0].settle(false);
    await vi.advanceTimersByTimeAsync(0);
    expect(banner).toEqual([]);
    expect(held().p1?.map((h) => h.text)).toEqual(["n1", "n2"]);
    await vi.advanceTimersByTimeAsync(INJECT_SETTLE_MS);
    expect(calls).toHaveLength(2);
    expect(calls[1].text).toContain("n1");
  });

  it("a pane that never reports a state gets the notice after the cap, and the banner only after it was accepted", async () => {
    const { f, calls, banner } = setup();
    f.notice("p1", "n1");
    expect(calls).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(UNKNOWN_WAIT_MS + 100);
    expect(calls).toHaveLength(1);
    expect(banner).toEqual([]);
    calls[0].settle(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(banner).toEqual([1]);
  });

  it("a pane that is working keeps waiting past the unknown cap", async () => {
    const { f, calls } = setup();
    f.state("p1", "working");
    f.notice("p1", "n1");
    await vi.advanceTimersByTimeAsync(UNKNOWN_WAIT_MS * 10);
    expect(calls).toHaveLength(0);
  });

  it("notices for a pane that has closed are dropped", async () => {
    const live = ["p1"];
    const { f, calls, held } = setup(live);
    f.notice("p1", "n1");
    live.length = 0;
    f.state("p1", "idle");
    expect(calls).toHaveLength(0);
    expect(held()).toEqual({});
  });
});
