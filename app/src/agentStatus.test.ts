import { describe, expect, it } from "vitest";
import { aggregateTeamStatus, applyStateChange, type PaneStatus, type PaneStatusMap } from "./agentStatus";

const status = (state: PaneStatus["state"]): PaneStatus => ({ state });

describe("applyStateChange", () => {
  it("sets the new state for a pane", () => {
    const result = applyStateChange({}, "pane", "working");
    expect(result.pane).toEqual({ state: "working" });
  });

  it("returns the same map reference when the state didn't change", () => {
    const initial: PaneStatusMap = { pane: status("working") };
    const result = applyStateChange(initial, "pane", "working");
    expect(result).toBe(initial);
  });

  it("updates only the given pane", () => {
    const initial: PaneStatusMap = { a: status("working"), b: status("idle") };
    const result = applyStateChange(initial, "a", "blocked");
    expect(result.a).toEqual({ state: "blocked" });
    expect(result.b).toEqual({ state: "idle" });
  });
});

describe("aggregateTeamStatus", () => {
  it("returns empty for a team with no panes", () => {
    expect(aggregateTeamStatus([])).toBe("empty");
  });

  it("returns unknown for a pane whose agent type isn't recognized", () => {
    expect(aggregateTeamStatus([status("unknown")])).toBe("unknown");
  });

  it("lets one blocked pane beat every other state", () => {
    expect(aggregateTeamStatus([status("working"), status("idle"), status("blocked")])).toBe("blocked");
  });

  it("prioritizes working over idle and unknown", () => {
    expect(aggregateTeamStatus([status("idle"), status("unknown"), status("working")])).toBe("working");
  });
});
