import { beforeAll, describe, expect, it } from "vitest";

// The pane tests run without a DOM, so this is the smallest stand-in for what busy.ts touches.
class FakeEl {
  attrs = new Map<string, string>();
  kids: (FakeEl | string)[] = [];
  parent: FakeEl | null = null;
  disabled = false;
  className = "";
  constructor(public tag: string) {}
  setAttribute(k: string, v: string) { this.attrs.set(k, v); }
  getAttribute(k: string) { return this.attrs.get(k) ?? null; }
  removeAttribute(k: string) { this.attrs.delete(k); }
  append(...c: (FakeEl | string)[]) { for (const x of c) { if (x instanceof FakeEl) x.parent = this; this.kids.push(x); } }
  remove() { if (this.parent) this.parent.kids = this.parent.kids.filter((k) => k !== this); this.parent = null; }
  querySelector(sel: string) { return sel === ":scope > .spinner" ? (this.kids.find((k) => k instanceof FakeEl && k.className === "spinner") as FakeEl | undefined) ?? null : null; }
}

let busy: typeof import("../../_shared/busy");
beforeAll(async () => {
  (globalThis as unknown as { document: unknown }).document = { createElement: (t: string) => new FakeEl(t), createTextNode: (s: string) => s };
  busy = await import("../../_shared/busy");
});
const button = () => new FakeEl("button") as unknown as HTMLButtonElement;
const hasSpinner = (b: HTMLButtonElement) => (b as unknown as FakeEl).querySelector(":scope > .spinner") !== null;

describe("pane busy buttons", () => {
  it("withBusy: disabled, aria-busy and a spinner while the work runs, all gone after", async () => {
    const b = button();
    let release!: () => void;
    const run = busy.withBusy(b, () => new Promise<void>((r) => (release = r)));
    expect(b.disabled).toBe(true);
    expect(b.getAttribute("aria-busy")).toBe("true");
    expect(hasSpinner(b)).toBe(true);
    release();
    await run;
    expect(b.disabled).toBe(false);
    expect(b.getAttribute("aria-busy")).toBeNull();
    expect(hasSpinner(b)).toBe(false);
  });
  it("a failure ends the busy state too, and still reaches the caller", async () => {
    const b = button();
    await expect(busy.withBusy(b, () => Promise.reject(new Error("boom")))).rejects.toThrow("boom");
    expect(b.disabled).toBe(false);
    expect(b.getAttribute("aria-busy")).toBeNull();
    expect(hasSpinner(b)).toBe(false);
  });
  it("a click while busy is ignored", async () => {
    const b = button();
    let n = 0;
    let release!: () => void;
    const first = busy.withBusy(b, () => new Promise<void>((r) => ((n += 1), (release = r))));
    expect(await busy.withBusy(b, async () => void (n += 10))).toBeUndefined();
    release();
    await first;
    expect(n).toBe(1);
  });
  it("setBusy is idempotent: one spinner however often it is turned on", () => {
    const b = button();
    busy.setBusy(b, true);
    busy.setBusy(b, true);
    expect((b as unknown as FakeEl).kids.length).toBe(1);
    busy.setBusy(b, false);
    busy.setBusy(b, false);
    expect((b as unknown as FakeEl).kids.length).toBe(0);
  });
  it("a loading view is a status with a spinner and its text", () => {
    const v = busy.loadingView("Loading…") as unknown as FakeEl;
    expect(v.getAttribute("role")).toBe("status");
    expect(v.kids.some((k) => k instanceof FakeEl && k.className === "spinner")).toBe(true);
  });
});
