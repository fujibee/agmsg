export type RawState = "idle" | "working" | "blocked" | "unknown";
export type DisplayState = RawState | "done";
export type PaneStatus = { state: RawState; seen: boolean; changedAt: number };
export type PaneStatusMap = Record<string, PaneStatus>;

export function applyStateChange(
  map: PaneStatusMap,
  paneId: string,
  newState: RawState,
  isPaneFocused: boolean,
  now: number,
): PaneStatusMap {
  const previous = map[paneId];
  const completed =
    (previous?.state === "working" || previous?.state === "blocked") && newState === "idle";
  const seen = isPaneFocused ? true : completed ? false : (previous?.seen ?? true);
  const changedAt = previous?.state === newState ? (previous?.changedAt ?? now) : now;

  if (
    previous &&
    previous.state === newState &&
    previous.seen === seen &&
    previous.changedAt === changedAt
  ) {
    return map;
  }

  return { ...map, [paneId]: { state: newState, seen, changedAt } };
}

export function displayPaneStatus(status: PaneStatus | undefined): DisplayState {
  if (!status) return "unknown";
  return status.state === "idle" && !status.seen ? "done" : status.state;
}

export function aggregateTeamStatus(statuses: PaneStatus[]): DisplayState {
  const priority: Record<DisplayState, number> = {
    blocked: 4,
    done: 3,
    working: 2,
    idle: 1,
    unknown: 0,
  };
  return statuses.reduce<DisplayState>((aggregate, status) => {
    const candidate = displayPaneStatus(status);
    return priority[candidate] > priority[aggregate] ? candidate : aggregate;
  }, "unknown");
}
