import { describe, expect, it } from "vitest";
import { latestWins } from "./latestWins";

describe("latestWins", () => {
  it("only the newest ticket is current", () => {
    const l = latestWins();
    const a = l.next();
    const b = l.next();
    expect(a()).toBe(false);
    expect(b()).toBe(true);
  });
  it("cancel makes every outstanding ticket stale", () => {
    const l = latestWins();
    const a = l.next();
    l.cancel();
    expect(a()).toBe(false);
    expect(l.next()()).toBe(true);
  });
  it("a snapshot goes stale on cancel but does not disturb tickets", () => {
    const l = latestWins();
    const ticket = l.next();
    const snap = l.snapshot();
    expect(snap()).toBe(true);
    expect(ticket()).toBe(true);
    l.cancel();
    expect(snap()).toBe(false);
  });
});
