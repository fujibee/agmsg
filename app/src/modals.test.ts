import { describe, expect, it } from "vitest";
import { shouldCloseOnEscape } from "./modals";

function esc(overrides: Partial<{ isComposing: boolean; keyCode: number; defaultPrevented: boolean }> = {}) {
  return {
    key: "Escape",
    isComposing: false,
    keyCode: 27,
    defaultPrevented: false,
    ...overrides,
  };
}

describe("shouldCloseOnEscape", () => {
  it("closes on a plain Escape", () => {
    expect(shouldCloseOnEscape(esc())).toBe(true);
  });

  it("ignores non-Escape keys", () => {
    expect(shouldCloseOnEscape({ ...esc(), key: "Enter" })).toBe(false);
  });

  it("does not close while an IME composition is in progress", () => {
    expect(shouldCloseOnEscape(esc({ isComposing: true }))).toBe(false);
  });

  it("does not close on the WKWebView IME keyCode 229 fallback", () => {
    expect(shouldCloseOnEscape(esc({ keyCode: 229 }))).toBe(false);
  });

  it("does not close when a child already consumed the event", () => {
    expect(shouldCloseOnEscape(esc({ defaultPrevented: true }))).toBe(false);
  });
});
