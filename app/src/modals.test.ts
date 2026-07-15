import { describe, expect, it } from "vitest";
import { sanitizeNumberDraft, shouldCloseOnEscape, stepFontSize } from "./modals";

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

describe("sanitizeNumberDraft", () => {
  it("passes plain digits through unchanged", () => {
    expect(sanitizeNumberDraft("12")).toBe("12");
  });

  it("strips letters and symbols WKWebView can let slip into a number input", () => {
    expect(sanitizeNumberDraft("1a2b")).toBe("12");
    expect(sanitizeNumberDraft("1e5")).toBe("15");
    expect(sanitizeNumberDraft("!@#12$%")).toBe("12");
  });

  it("keeps a single leading minus sign", () => {
    expect(sanitizeNumberDraft("-12")).toBe("-12");
  });

  it("drops a minus sign anywhere but the first character", () => {
    expect(sanitizeNumberDraft("1-2")).toBe("12");
    expect(sanitizeNumberDraft("12-")).toBe("12");
    expect(sanitizeNumberDraft("--12")).toBe("-12");
  });

  it("keeps only the first decimal point", () => {
    expect(sanitizeNumberDraft("1.2.3")).toBe("1.23");
    expect(sanitizeNumberDraft("1..2")).toBe("1.2");
  });

  it("allows a bare decimal point mid-edit (e.g. typing '12.' before the fraction)", () => {
    expect(sanitizeNumberDraft("12.")).toBe("12.");
  });

  it("returns an empty string for entirely non-numeric input", () => {
    expect(sanitizeNumberDraft("abc")).toBe("");
  });

  it("passes an already-empty string through unchanged", () => {
    expect(sanitizeNumberDraft("")).toBe("");
  });
});

describe("stepFontSize", () => {
  it("steps up by 1 from a valid draft", () => {
    expect(stepFontSize("12", 12, 1, 8, 24)).toBe(13);
  });

  it("steps down by 1 from a valid draft", () => {
    expect(stepFontSize("12", 12, -1, 8, 24)).toBe(11);
  });

  it("falls back to the committed value when the draft doesn't parse (e.g. empty, mid-edit)", () => {
    expect(stepFontSize("", 12, 1, 8, 24)).toBe(13);
    expect(stepFontSize("-", 12, 1, 8, 24)).toBe(13);
    expect(stepFontSize(".", 12, -1, 8, 24)).toBe(11);
  });

  it("clamps at the maximum", () => {
    expect(stepFontSize("24", 24, 1, 8, 24)).toBe(24);
  });

  it("clamps at the minimum", () => {
    expect(stepFontSize("8", 8, -1, 8, 24)).toBe(8);
  });

  it("steps from a decimal draft and can land on a non-integer", () => {
    expect(stepFontSize("12.5", 12.5, 1, 8, 24)).toBe(13.5);
  });
});
