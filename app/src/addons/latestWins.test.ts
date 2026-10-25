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
});
