export type RawState = "idle" | "working" | "blocked" | "unknown";
export type PaneStatus = { state: RawState };
export type PaneStatusMap = Record<string, PaneStatus>;
// A team's aggregate is either one of the pane states, or "empty" — no
// agent has ever been started for that team. "unknown" (a pane exists but
// classify() doesn't recognize its agent type) is deliberately a distinct
// value from "empty" (no pane exists at all): #406 made "unknown" render
// green like idle, since an unhandled type isn't an anomaly, but a team
// nobody has started anything in isn't "idle" — it should read as inert
// gray instead of implying live, healthy agents.
export type TeamAggregateState = RawState | "empty";

export function applyStateChange(map: PaneStatusMap, paneId: string, newState: RawState): PaneStatusMap {
  if (map[paneId]?.state === newState) return map;
  return { ...map, [paneId]: { state: newState } };
}

export function aggregateTeamStatus(statuses: PaneStatus[]): TeamAggregateState {
  if (statuses.length === 0) return "empty";
  const priority: Record<RawState, number> = {
    blocked: 3,
    working: 2,
    idle: 1,
    unknown: 0,
  };
  return statuses.reduce<RawState>(
    (aggregate, status) => (priority[status.state] > priority[aggregate] ? status.state : aggregate),
    "unknown",
  );
}
