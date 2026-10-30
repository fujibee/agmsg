import { describe, expect, it } from "vitest";
import { isChecking, offersRecheck } from "./recheck";

describe("Check again", () => {
  it("is offered after a timeout or a failed check", () => {
    expect(offersRecheck(["the startup check did not finish (timeout)"])).toBe(true);
    expect(offersRecheck(["the pane CSP is not in force in the probe frame"])).toBe(true);
    expect(offersRecheck(["the startup check could not be started"])).toBe(true);
  });
  it("is not offered when the only reason is that this engine is not verified yet", () => {
    expect(offersRecheck(["add-ons are not verified on WebView2 yet"])).toBe(false);
  });
  it("is offered when that reason comes with a real one", () => {
    expect(offersRecheck(["the startup check did not finish (timeout)", "add-ons are not verified on WebView2 yet"])).toBe(true);
  });
  it("is not offered while a check runs or before it has run, and not without reasons", () => {
    expect(offersRecheck(["checking again: asked by the user"])).toBe(false);
    expect(offersRecheck(["checking again: page load"])).toBe(false);
    expect(offersRecheck(["the startup check has not run yet"])).toBe(false);
    expect(offersRecheck([])).toBe(false);
    expect(isChecking(["checking again: startup"])).toBe(true);
    expect(isChecking(["the startup check did not finish (timeout)"])).toBe(false);
  });
});
