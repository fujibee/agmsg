import { describe, expect, it } from "vitest";
import { engineOffText, isChecking, offersRecheck, reasonKeys } from "./recheck";

describe("Check again", () => {
  it("is offered after a timeout or a failed check", () => {
    expect(offersRecheck(["check-timeout"])).toBe(true);
    expect(offersRecheck(["probe-csp"])).toBe(true);
    expect(offersRecheck(["check-start-failed"])).toBe(true);
  });
  it("is not offered when asking again cannot change the answer", () => {
    expect(offersRecheck(["not-verified"])).toBe(false);
    expect(offersRecheck(["platform-unsupported"])).toBe(false);
  });
  it("is offered when such a reason comes with a real one", () => {
    expect(offersRecheck(["check-timeout", "not-verified"])).toBe(true);
  });
  it("is not offered while a check runs or before it has run, and not without reasons", () => {
    expect(offersRecheck(["checking"])).toBe(false);
    expect(offersRecheck(["check-pending"])).toBe(false);
    expect(offersRecheck([])).toBe(false);
    expect(isChecking(["checking"])).toBe(true);
    expect(isChecking(["check-pending"])).toBe(true);
    expect(isChecking(["check-timeout"])).toBe(false);
  });
});

describe("engine off text", () => {
  const t = (k: string) => `[${k}]`;
  it("says Checking while a check runs, else the localized reasons", () => {
    expect(engineOffText(["checking"], t)).toBe("[addons.checking]");
    expect(engineOffText(["check-pending"], t)).toBe("[addons.checking]");
    expect(engineOffText(["frame-guard", "webrtc-udp"], t)).toBe("[addons.reason.navigation] [addons.reason.network]");
  });
});

describe("reason messages", () => {
  it("maps codes to message keys, once each, in order", () => {
    expect(reasonKeys(["webrtc-udp", "webrtc-available", "frame-guard"])).toEqual(["addons.reason.network", "addons.reason.navigation"]);
  });
  it("gives an unknown or unavailable code the general message", () => {
    expect(reasonKeys(["unavailable", "something-new"])).toEqual(["addons.reason.generic"]);
  });
});
