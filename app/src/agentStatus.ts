export type RawState = "idle" | "working" | "blocked" | "unknown";
export type PaneStatus = { state: RawState };
export type PaneStatusMap = Record<string, PaneStatus>;

export function applyStateChange(map: PaneStatusMap, paneId: string, newState: RawState): PaneStatusMap {
  if (map[paneId]?.state === newState) return map;
  return { ...map, [paneId]: { state: newState } };
}

export function aggregateTeamStatus(statuses: PaneStatus[]): RawState {
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
