import { describe, expect, it } from "vitest";
import { createOpGuard } from "./opGuard";

const deferred = <T>() => {
  let resolve!: (v: T) => void;
  let reject!: (e: unknown) => void;
  const promise = new Promise<T>((res, rej) => ((resolve = res), (reject = rej)));
  return { promise, resolve, reject };
};

describe("op guard", () => {
  it("refuses a second start while one is running, accepts again after it finishes", async () => {
    const g = createOpGuard();
    const d = deferred<number>();
    const first = g.run(() => d.promise);
    expect(await g.run(async () => 2)).toEqual({ kind: "busy" });
    d.resolve(1);
    expect(await first).toEqual({ kind: "done", value: 1 });
    expect(await g.run(async () => 3)).toEqual({ kind: "done", value: 3 });
  });
  it("a result that arrives after invalidate is stale, success or failure, and does not block the new attempt", async () => {
    const g = createOpGuard();
    const ok = deferred<number>();
    const bad = deferred<number>();
    const a = g.run(() => ok.promise);
    g.invalidate();
    const b = g.run(() => bad.promise); // the new attempt starts its own operation
    ok.resolve(1);
    expect(await a).toEqual({ kind: "stale" });
    expect(g.isBusy()).toBe(true); // the old one finishing must not clear the new one's busy flag
    bad.resolve(2);
    expect(await b).toEqual({ kind: "done", value: 2 });
    const c = deferred<number>();
    const stale = g.run(() => c.promise);
    g.invalidate();
    c.reject(new Error("late"));
    expect(await stale).toEqual({ kind: "stale" });
  });
  it("a current failure is rethrown and frees the guard", async () => {
    const g = createOpGuard();
    await expect(g.run(async () => Promise.reject(new Error("x")))).rejects.toThrow("x");
    expect(g.isBusy()).toBe(false);
  });
});
