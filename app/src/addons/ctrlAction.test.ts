import { describe, expect, it } from "vitest";
import { runCtrlAction, type CtrlActionDeps } from "./ctrlAction";
import { latestWins } from "./latestWins";
import type { CtrlOpened } from "./ctrl";

const opened: CtrlOpened = { requestId: "r1", from: "alice", addonId: "builtin:diffview", pane: "diffview", openArgs: { path: "/p" } };
const deferred = <T>() => {
  let resolve!: (v: T) => void;
  const promise = new Promise<T>((r) => (resolve = r));
  return { promise, resolve };
};
const harness = () => {
  const scope = latestWins();
  const log: string[] = [];
  const open = deferred<{ ok: true; value: CtrlOpened } | { ok: false; error: { code: string; message: string } }>();
  const dismiss = deferred<{ ok: true; value: null } | { ok: false; error: { code: string; message: string } }>();
  const deps: CtrlActionDeps = {
    current: scope.snapshot(),
    open: () => open.promise,
    dismiss: () => dismiss.promise,
    onOpened: (o) => log.push(`opened ${o.pane}`),
    setError: (e) => log.push(`error ${e.code}`),
    refresh: async () => void log.push("refresh"),
  };
  return { scope, log, open, dismiss, deps };
};

describe("runCtrlAction", () => {
  it("in the same scope: opens the pane, then re-reads the rows", async () => {
    const h = harness();
    const run = runCtrlAction(true, h.deps);
    h.open.resolve({ ok: true, value: opened });
    await run;
    expect(h.log).toEqual(["opened diffview", "refresh"]);
  });
  it("a refusal is shown and the rows are re-read", async () => {
    const h = harness();
    const run = runCtrlAction(false, h.deps);
    h.dismiss.resolve({ ok: false, error: { code: "not_found", message: "gone" } });
    await run;
    expect(h.log).toEqual(["error not_found", "refresh"]);
  });
  it("Open answered after a team switch or add-ons off does nothing", async () => {
    const h = harness();
    const run = runCtrlAction(true, h.deps);
    h.scope.cancel();
    h.open.resolve({ ok: true, value: opened });
    await run;
    expect(h.log).toEqual([]);
  });
  it("Dismiss answered after a team switch (or A -> B -> A) neither sets a message nor re-reads the old team", async () => {
    const h = harness();
    const run = runCtrlAction(false, h.deps);
    h.scope.cancel();
    h.scope.cancel();
    h.dismiss.resolve({ ok: false, error: { code: "x", message: "y" } });
    await run;
    expect(h.log).toEqual([]);
  });
});
