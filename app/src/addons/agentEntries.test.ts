import { describe, expect, it } from "vitest";
import { choiceFor, visibleEntries } from "./agentEntries";
import type { MemberState } from "./source";

const e = (over: Partial<MemberState>): MemberState => ({ key: "k", addon: "o/r", team: "t", kind: "agent", name: "white", type: "claude-code", state: "running", ...over });

describe("agent entries", () => {
  it("hides the internal claimed state", () => {
    expect(visibleEntries([e({ state: "claimed" }), e({ state: "running" })]).map((x) => x.state)).toEqual(["running"]);
  });
  it("asks the person only for orphaned and unknown agents, and offers Open for a joined or failed one", () => {
    expect(choiceFor(e({ state: "orphaned", pid: 5 }))).toBe("choose");
    expect(choiceFor(e({ state: "unknown" }))).toBe("choose");
    expect(choiceFor(e({ state: "joined" }))).toBe("open");
    expect(choiceFor(e({ state: "running" }))).toBeNull();
    expect(choiceFor(e({ state: "failed", reason: "x" }))).toBe("open");
    expect(choiceFor(e({ kind: "member", state: "orphaned" }))).toBeNull();
  });
});
