import { describe, expect, it } from "vitest";
import {
  aggregateTeamStatus,
  applyStateChange,
  displayPaneStatus,
  type PaneStatus,
  type PaneStatusMap,
} from "./agentStatus";

const status = (state: PaneStatus["state"], seen = true): PaneStatus => ({
  state,
  seen,
  changedAt: 1,
});

describe("applyStateChange", () => {
  it("marks a background completion unseen", () => {
    const initial: PaneStatusMap = { pane: status("working") };
    const result = applyStateChange(initial, "pane", "idle", false, 2);
    expect(result.pane).toEqual({ state: "idle", seen: false, changedAt: 2 });
    expect(displayPaneStatus(result.pane)).toBe("done");
  });

  it("marks a focused completion seen", () => {
    const initial: PaneStatusMap = { pane: status("blocked") };
    const result = applyStateChange(initial, "pane", "idle", true, 2);
    expect(result.pane).toEqual({ state: "idle", seen: true, changedAt: 2 });
  });

  it("marks an existing unseen completion seen when focused", () => {
    const initial: PaneStatusMap = { pane: status("idle", false) };
    const result = applyStateChange(initial, "pane", "idle", true, 2);
    expect(result.pane.seen).toBe(true);
    expect(result.pane.changedAt).toBe(1);
  });

  it("does not treat an initial idle state as a completion", () => {
    const result = applyStateChange({}, "pane", "idle", false, 2);
    expect(result.pane.seen).toBe(true);
  });
});

describe("aggregateTeamStatus", () => {
  it("returns unknown for an empty set", () => {
    expect(aggregateTeamStatus([])).toBe("unknown");
  });

  it("lets one blocked pane beat every other state", () => {
    expect(
      aggregateTeamStatus([
        status("working"),
        status("idle", false),
        status("blocked"),
      ]),
    ).toBe("blocked");
  });

  it("prioritizes unseen completion over working", () => {
    expect(aggregateTeamStatus([status("working"), status("idle", false)])).toBe("done");
  });

  it("prioritizes working over seen idle and unknown", () => {
    expect(aggregateTeamStatus([status("idle"), status("unknown"), status("working")])).toBe(
      "working",
    );
  });
});
