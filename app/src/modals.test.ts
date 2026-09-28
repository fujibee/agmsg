import { describe, expect, it } from "vitest";
import { membersRemainCount, sanitizeNumberDraft, shouldCloseOnEscape, stepFontSize } from "./modals";

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

describe("membersRemainCount", () => {
  // #1493: an app-created team always has an app-user member, so a plain
  // --delete on it always fails this way — DeleteTeamModal switches from
  // the plain confirm to the "remove members, then delete" one based on
  // this, and needs the count to phrase its translated body (#1484 review,
  // round 3: don't show the CLI's raw English refusal for this one case).
  it("recognizes team.sh's members-remain refusal for --delete and extracts the count", () => {
    expect(
      membersRemainCount(
        "Team 'my-team' still has 3 member(s); refusing --delete.\nRun leave.sh for each remaining member first, or pass --force to remove them and delete the team in one step.",
      ),
    ).toBe(3);
  });

  it("returns null for an unrelated refusal (active remote binding)", () => {
    expect(
      membersRemainCount(
        "Team 'my-team' is actively synced; refusing to delete or purge its data.\nDisconnect the sync binding first.",
      ),
    ).toBeNull();
  });

  it("returns null for the jsonl-storage refusal", () => {
    expect(
      membersRemainCount(
        "Team 'my-team' uses the jsonl storage driver; --purge-messages is not\nsupported yet for jsonl.",
      ),
    ).toBeNull();
  });

  it("returns null for an active-remote refusal even if the team NAME contains the substring 'refusing --delete'", () => {
    // Regression (#1484 review, round 2): team names can contain spaces and
    // hyphens, so a bare `message.includes("refusing --delete")` check
    // would trivially match here too — the team's own name, not anything
    // team.sh actually decided, is what put that text in the message. The
    // active-binding refusal always says "refusing to delete", never
    // "still has N member(s); refusing --delete", so this must stay null
    // regardless of the name.
    expect(
      membersRemainCount(
        "Team 'refusing --delete' is actively synced; refusing to delete or purge its data.\nDisconnect the sync binding first.",
      ),
    ).toBeNull();
  });
});
