import { describe, expect, it } from "vitest";
import { batchText, heldCount, hold, restore, takeReady, UNKNOWN_WAIT_MS } from "./noticeQueue";

describe("noticeQueue", () => {
  it("a fresh pane working through its startup turn holds the notice until its first idle", () => {
    const q = hold({}, "p1", "n1", 0);
    const w = takeReady(q, "p1", false, "working", 1000);
    expect(w.send).toEqual([]);
    expect(heldCount(w.rest, "p1")).toBe(1);
    const i = takeReady(w.rest, "p1", false, "idle", 2000);
    expect(i.send.map((s) => [s.text, s.late])).toEqual([["n1", false]]);
    expect(heldCount(i.rest, "p1")).toBe(0);
  });
  it("a pane with no state yet waits for its first idle", () => {
    const q = hold({}, "p1", "n1", 0);
    expect(takeReady(q, "p1", false, undefined, 5000).send).toEqual([]);
    expect(UNKNOWN_WAIT_MS).toBe(180_000);
  });
  it("a working or blocked fresh pane is never cut short, however long it takes", () => {
    const q = hold({}, "p1", "n1", 0);
    for (const st of ["working", "blocked"] as const) {
      expect(takeReady(q, "p1", false, st, UNKNOWN_WAIT_MS * 100).send).toEqual([]);
    }
  });
  it("an unknown or silent fresh pane gets the notice after the cap, flagged as without a ready signal", () => {
    const q = hold({}, "p1", "n1", 0);
    for (const st of ["unknown", undefined] as const) {
      expect(takeReady(q, "p1", false, st, UNKNOWN_WAIT_MS - 1).send).toEqual([]);
      const r = takeReady(q, "p1", false, st, UNKNOWN_WAIT_MS);
      expect(r.send.map((x) => [x.text, x.late])).toEqual([["n1", true]]);
      expect(heldCount(r.rest, "p1")).toBe(0);
    }
  });
  it("once released, notices go out at once whatever the state", () => {
    const q = hold({}, "p1", "n1", 0);
    for (const st of ["working", "blocked", "unknown", undefined] as const) {
      expect(takeReady(q, "p1", true, st, 1).send.map((s) => s.late)).toEqual([false]);
    }
  });
  it("panes are independent", () => {
    const q = hold(hold({}, "a", "x", 0), "b", "y", 0);
    const r = takeReady(q, "a", false, "idle", 1);
    expect(r.send).toHaveLength(1);
    expect(heldCount(r.rest, "b")).toBe(1);
  });
  it("two ready notices become one submission, so no second write can interleave with the first", () => {
    const q = hold(hold({}, "p1", "n1", 0), "p1", "n2", 1);
    const r = takeReady(q, "p1", false, "idle", 2);
    expect(r.send).toHaveLength(2);
    const text = batchText(r.send);
    expect(text.startsWith("n1")).toBe(true);
    expect(text).toContain("+1 more");
    expect(text).not.toContain("n2");
    expect(batchText([{ text: "solo" }])).toBe("solo");
  });
  it("notices whose typing was rejected go back to the front of the pane's queue, in order", () => {
    const q = hold(hold({}, "p1", "n1", 0), "p1", "n2", 1);
    const r = takeReady(q, "p1", false, "idle", 2);
    const later = hold(r.rest, "p1", "n3", 3);
    const back = restore(later, "p1", r.send);
    expect(back.p1.map((h) => h.text)).toEqual(["n1", "n2", "n3"]);
    expect(takeReady(back, "p1", true, "working", 4).send).toHaveLength(3);
  });
});
