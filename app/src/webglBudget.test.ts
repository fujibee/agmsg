import { describe, expect, it, vi } from "vitest";
import { createWebglBudget, WEBGL_PANE_LIMIT } from "./webglBudget";

// A fake clock that never moves: the budget must still order "least recently used" strictly.
const still = () => 1000;
const spy = () => vi.fn<() => void>();
type Spy = ReturnType<typeof spy>;

describe("webglBudget", () => {
  it("keeps the limit under the page's own limit (about 16) and leaves room for add-on panes", () => {
    expect(WEBGL_PANE_LIMIT).toBeLessThanOrEqual(8);
  });

  it("gives slots out up to the limit without releasing anyone", () => {
    const b = createWebglBudget(3, still);
    const rel = [spy(), spy(), spy()];
    rel.forEach((r, i) => b.claim("p" + i, r));
    expect(b.size()).toBe(3);
    rel.forEach((r) => expect(r).not.toHaveBeenCalled());
  });

  it("releases the least recently used pane when a new one claims past the limit", () => {
    const b = createWebglBudget(3, still);
    const rel: Record<string, Spy> = { a: spy(), b: spy(), c: spy(), d: spy() };
    for (const k of ["a", "b", "c"]) b.claim(k, rel[k]);
    b.claim("d", rel.d);
    expect(rel.a).toHaveBeenCalledTimes(1);
    expect(rel.b).not.toHaveBeenCalled();
    expect(b.size()).toBe(3);
  });

  it("a touched pane is not the next to go", () => {
    const b = createWebglBudget(3, still);
    const rel: Record<string, Spy> = { a: spy(), b: spy(), c: spy(), d: spy() };
    for (const k of ["a", "b", "c"]) b.claim(k, rel[k]);
    b.touch("a");
    b.claim("d", rel.d);
    expect(rel.a).not.toHaveBeenCalled();
    expect(rel.b).toHaveBeenCalledTimes(1);
  });

  it("a freed slot is reused without releasing anyone", () => {
    const b = createWebglBudget(2, still);
    const rel: Record<string, Spy> = { a: spy(), b: spy(), c: spy() };
    b.claim("a", rel.a);
    b.claim("b", rel.b);
    b.free("a");
    b.claim("c", rel.c);
    expect(rel.a).not.toHaveBeenCalled();
    expect(rel.b).not.toHaveBeenCalled();
    expect(b.size()).toBe(2);
  });

  it("a pane that asks again takes its own slot, never releasing itself", () => {
    const b = createWebglBudget(2, still);
    const a = spy();
    b.claim("a", a);
    b.claim("a", a);
    expect(a).not.toHaveBeenCalled();
    expect(b.size()).toBe(1);
  });

  it("touch and free on a pane without a slot change nothing", () => {
    const b = createWebglBudget(1, still);
    b.touch("ghost");
    b.free("ghost");
    expect(b.size()).toBe(0);
  });

  it("20 panes asking in turn never hold more than the limit, and the last ones hold the slots", () => {
    const b = createWebglBudget(WEBGL_PANE_LIMIT, still);
    const holding = new Set<string>();
    for (let i = 0; i < 20; i++) {
      const id = "p" + i;
      b.claim(id, () => holding.delete(id));
      holding.add(id);
      expect(holding.size).toBeLessThanOrEqual(WEBGL_PANE_LIMIT);
      expect(b.size()).toBe(holding.size);
    }
    expect([...holding]).toEqual(Array.from({ length: WEBGL_PANE_LIMIT }, (_, k) => "p" + (20 - WEBGL_PANE_LIMIT + k)));
  });
});
