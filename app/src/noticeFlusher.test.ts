import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { createNoticeFlusher, MAX_REPORT_IDS, RETRY_MAX_MS } from "./noticeFlusher";
import { INJECT_SETTLE_MS, STARTUP_WAIT_MS, UNKNOWN_WAIT_MS, type Queues } from "./noticeQueue";

type Call = { id: string; text: string; settle: (ok: boolean) => void };

function setup(live = ["p1"]) {
  const calls: Call[] = [];
  const typed: Array<{ id: string; ids: string[]; at: number }> = [];
  const banner: number[] = [];
  const failed: number[] = [];
  const logs: string[] = [];
  let held: Queues = {};
  const f = createNoticeFlusher({
    inject: (id, text) => new Promise((resolve, reject) => calls.push({ id, text, settle: (ok) => (ok ? resolve(undefined) : reject(new Error("pty"))) })),
    livePanes: () => live,
    now: () => Date.now(),
    setTimer: (fn, ms) => void setTimeout(fn, ms),
    onHeldChange: (q) => (held = q),
    log: (l) => logs.push(l),
    onInjectFailed: (_id, attempt) => failed.push(attempt),
    onWithoutReadySignal: (n) => banner.push(n),
    onTyped: (id, ids, at) => typed.push({ id, ids, at }),
  });
  return { f, calls, banner, failed, live, logs, typed, held: () => held };
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
    await vi.advanceTimersByTimeAsync(1000);
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

  it("a pane that is working keeps waiting past the unknown cap and is typed at the startup cap", async () => {
    const { f, calls } = setup();
    f.state("p1", "working");
    f.notice("p1", "n1");
    await vi.advanceTimersByTimeAsync(STARTUP_WAIT_MS - 1000);
    expect(calls).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(1100);
    expect(calls).toHaveLength(1);
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

  it("a rejected first fallback does not end the startup hold: a later working state keeps the notice held", async () => {
    const { f, calls } = setup();
    f.notice("p1", "n1");
    await vi.advanceTimersByTimeAsync(UNKNOWN_WAIT_MS + 100);
    expect(calls).toHaveLength(1);
    calls[0].settle(false);
    await vi.advanceTimersByTimeAsync(0);
    f.state("p1", "working");
    await vi.advanceTimersByTimeAsync(60_000);
    expect(calls).toHaveLength(1);
  });

  it("a successful retry of a fallback still shows the without-ready-signal banner", async () => {
    const { f, calls, banner } = setup();
    f.notice("p1", "n1");
    await vi.advanceTimersByTimeAsync(UNKNOWN_WAIT_MS + 100);
    calls[0].settle(false);
    await vi.advanceTimersByTimeAsync(2000);
    expect(calls).toHaveLength(2);
    calls[1].settle(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(banner).toEqual([1]);
  });

  it("with every write rejected, retries back off to a cap, the failure is reported, and closing ends them", async () => {
    const { f, calls, failed, live } = setup();
    f.state("p1", "idle");
    f.notice("p1", "n1");
    for (let i = 0; i < 40; i++) {
      calls[calls.length - 1].settle(false);
      await vi.advanceTimersByTimeAsync(RETRY_MAX_MS);
    }
    expect(calls.length).toBeGreaterThanOrEqual(40);
    expect(failed.slice(0, 3)).toEqual([1, 2, 3]);
    // In 10 s of persistent failure there are only a handful of attempts, not one every 500 ms.
    const before = calls.length;
    calls[calls.length - 1].settle(false);
    await vi.advanceTimersByTimeAsync(10_000);
    expect(calls.length - before).toBeLessThanOrEqual(1);
    live.length = 0;
    calls[calls.length - 1].settle(false);
    const n = calls.length;
    await vi.advanceTimersByTimeAsync(RETRY_MAX_MS * 3);
    expect(calls.length).toBe(n);
  });

  it("after a rejection the pane recovers once a write succeeds", async () => {
    const { f, calls, held } = setup();
    f.state("p1", "idle");
    f.notice("p1", "n1");
    calls[0].settle(false);
    await vi.advanceTimersByTimeAsync(1000);
    expect(calls).toHaveLength(2);
    calls[1].settle(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(held()).toEqual({});
  });

  it("a notice dropped because its pane closed is logged", async () => {
    const live = ["p1"];
    const { f, logs } = setup(live);
    f.notice("p1", "n1");
    live.length = 0;
    f.state("p1", "idle");
    expect(logs.some((l) => l.includes("dropped") && l.includes("closed"))).toBe(true);
  });

  it("reports the ids of the notices once they were typed, with the time, and only then", async () => {
    const { f, calls, typed } = setup();
    f.state("p1", "working");
    f.notice("p1", "n1", "m1");
    f.notice("p1", "n2", "m2");
    f.notice("p1", "n3"); // a notice with no message id adds nothing to the report
    expect(typed).toEqual([]);
    vi.setSystemTime(5000);
    f.state("p1", "idle");
    expect(calls).toHaveLength(1);
    expect(typed, "not while the write is still in flight").toEqual([]);
    calls[0].settle(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(typed).toEqual([{ id: "p1", ids: ["m1", "m2"], at: 5000 }]);
  });

  it("reports nothing for a write that failed, and the retry that works reports the same ids", async () => {
    const { f, calls, typed } = setup();
    f.state("p1", "idle");
    f.notice("p1", "n1", "m1");
    calls[0].settle(false);
    await vi.advanceTimersByTimeAsync(0);
    expect(typed).toEqual([]);
    await vi.advanceTimersByTimeAsync(1000);
    expect(calls).toHaveLength(2);
    calls[1].settle(true);
    await vi.advanceTimersByTimeAsync(0);
    expect(typed.map((t) => t.ids)).toEqual([["m1"]]);
  });

  it("reports nothing for notices dropped because the pane closed", async () => {
    const { f, live, typed, calls } = setup();
    f.state("p1", "working");
    f.notice("p1", "n1", "m1");
    live.length = 0;
    f.flush();
    await vi.advanceTimersByTimeAsync(STARTUP_WAIT_MS + 1000);
    expect(calls).toHaveLength(0);
    expect(typed).toEqual([]);
  });

  it("reports a long batch in pieces the host accepts, every id once, all with the same time", async () => {
    for (const n of [MAX_REPORT_IDS - 1, MAX_REPORT_IDS, MAX_REPORT_IDS + 1, 2 * MAX_REPORT_IDS, 2 * MAX_REPORT_IDS + 1]) {
      const { f, calls, typed } = setup();
      f.state("p1", "working");
      for (let k = 0; k < n; k++) f.notice("p1", `n${k}`, `m${k}`);
      vi.setSystemTime(9000);
      f.state("p1", "idle");
      calls[0].settle(true);
      await vi.advanceTimersByTimeAsync(0);
      expect(typed.every((t) => t.ids.length > 0 && t.ids.length <= MAX_REPORT_IDS), `${n}: every piece within the limit`).toBe(true);
      expect(typed.map((t) => t.at), `${n}: one time`).toEqual(typed.map(() => 9000));
      expect(typed.flatMap((t) => t.ids), `${n}: every id once, in order`).toEqual(Array.from({ length: n }, (_, k) => `m${k}`));
      expect(typed.length).toBe(Math.ceil(n / MAX_REPORT_IDS));
    }
  });
});
