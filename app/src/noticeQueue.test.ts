import { describe, expect, it } from "vitest";
import { heldCount, hold, takeReady, UNKNOWN_WAIT_MS } from "./noticeQueue";

describe("noticeQueue", () => {
  it("a notice typed while the pane is working is held, then delivered when it goes idle", () => {
    const q = hold({}, "p1", "n1", 0);
    const w = takeReady(q, "p1", "working", 1000);
    expect(w.send).toEqual([]);
    expect(heldCount(w.rest, "p1")).toBe(1);
    const i = takeReady(w.rest, "p1", "idle", 2000);
    expect(i.send.map((s) => [s.text, s.late])).toEqual([["n1", false]]);
    expect(heldCount(i.rest, "p1")).toBe(0);
  });
  it("a fresh pane (no state yet) waits for its first idle", () => {
    const q = hold({}, "p1", "n1", 0);
    expect(takeReady(q, "p1", undefined, 5000).send).toEqual([]);
    expect(takeReady(q, "p1", "idle", 5000).send).toHaveLength(1);
  });
  it("a blocked pane keeps its notices and the count is visible", () => {
    let q = hold({}, "p1", "n1", 0);
    q = hold(q, "p1", "n2", 1);
    const r = takeReady(q, "p1", "blocked", UNKNOWN_WAIT_MS * 10);
    expect(r.send).toEqual([]);
    expect(heldCount(r.rest, "p1")).toBe(2);
  });
  it("an unknown pane gets the notice after the wait, flagged as without a ready signal", () => {
    const q = hold({}, "p1", "n1", 0);
    expect(takeReady(q, "p1", "unknown", UNKNOWN_WAIT_MS - 1).send).toEqual([]);
    const r = takeReady(q, "p1", "unknown", UNKNOWN_WAIT_MS);
    expect(r.send.map((s) => [s.text, s.late])).toEqual([["n1", true]]);
    expect(heldCount(r.rest, "p1")).toBe(0);
  });
  it("a working pane is never fed by the timeout", () => {
    const q = hold({}, "p1", "n1", 0);
    expect(takeReady(q, "p1", "working", UNKNOWN_WAIT_MS * 10).send).toEqual([]);
  });
  it("panes are independent", () => {
    const q = hold(hold({}, "a", "x", 0), "b", "y", 0);
    const r = takeReady(q, "a", "idle", 1);
    expect(r.send).toHaveLength(1);
    expect(heldCount(r.rest, "b")).toBe(1);
  });
});
