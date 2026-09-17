import { describe, expect, it } from "vitest";
import { resolveActiveTab } from "./tabMemory";

describe("resolveActiveTab", () => {
  it("lands on Team Room on first visit (no remembered tab) when it's shown", () => {
    expect(resolveActiveTab(undefined, true, [])).toBe("room");
  });

  it("lands on the first open window on first visit when Team Room is hidden", () => {
    expect(resolveActiveTab(undefined, false, ["w1", "w2"])).toBe("w1");
  });

  it("falls back to Team Room on first visit when hidden but no windows exist", () => {
    expect(resolveActiveTab(undefined, false, [])).toBe("room");
  });

  it("restores a remembered window that's still open", () => {
    expect(resolveActiveTab("w2", true, ["w1", "w2"])).toBe("w2");
  });

  it("falls back when the remembered window was closed while away", () => {
    expect(resolveActiveTab("w2", true, ["w1"])).toBe("room");
  });

  it("falls back to the first open window when the remembered window was closed and Team Room is hidden", () => {
    expect(resolveActiveTab("w2", false, ["w1"])).toBe("w1");
  });

  it("restores remembered Team Room when it's still shown", () => {
    expect(resolveActiveTab("room", true, ["w1"])).toBe("room");
  });

  it("does not restore remembered Team Room when it's since been hidden — falls back to first window", () => {
    expect(resolveActiveTab("room", false, ["w1"])).toBe("w1");
  });

  it("falls back to Team Room when remembered Team Room is hidden and there are no windows", () => {
    expect(resolveActiveTab("room", false, [])).toBe("room");
  });
});
