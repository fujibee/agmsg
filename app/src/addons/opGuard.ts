// One async operation at a time for a pane's grant flow (a grant call or the
// folder dialog), bound to the pane attempt it started under. A second start
// while one is running is refused ("busy"); an operation that finishes after
// the attempt was replaced or closed reports "stale" and must change nothing.

export type OpResult<T> = { kind: "busy" } | { kind: "stale" } | { kind: "done"; value: T };

export function createOpGuard() {
  let epoch = 0;
  let busy = false;
  return {
    /** The pane is opened again, reloaded or gone: whatever is in flight no longer counts. */
    invalidate() {
      epoch += 1;
      busy = false;
    },
    isBusy: () => busy,
    /**
     * `fn` gets `stale()`: true once the attempt was replaced or closed. A step
     * with a side effect (saving a consent) must check it after every await
     * and stop, not only rely on the result being dropped at the end.
     */
    async run<T>(fn: (ctx: { stale: () => boolean }) => Promise<T>): Promise<OpResult<T>> {
      if (busy) return { kind: "busy" };
      const mine = epoch;
      busy = true;
      try {
        const value = await fn({ stale: () => mine !== epoch });
        return mine === epoch ? { kind: "done", value } : { kind: "stale" };
      } catch (e) {
        if (mine !== epoch) return { kind: "stale" };
        throw e;
      } finally {
        if (mine === epoch) busy = false;
      }
    },
  };
}
