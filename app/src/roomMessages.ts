export type Message = {
  // Opaque. api.sh's contract: "Every id (message ids included) is a JSON
  // string, never a bare number." Event-log ids are UUIDs; only the legacy
  // table's were integers. Used as a React key and as the paging cursor,
  // neither of which needs it to be ordered or numeric.
  id: string;
  team: string;
  from: string;
  to: string;
  body: string;
  created_at: string;
};

type Rfc3339ZTimestamp = { second: string; fraction: string };
type Unlisten = () => void;

const RFC3339_Z_TIMESTAMP = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?Z$/;

function isLeapYear(year: number): boolean {
  return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) return isLeapYear(year) ? 29 : 28;
  return month === 4 || month === 6 || month === 9 || month === 11 ? 30 : 31;
}

function parseRfc3339ZTimestamp(value: string): Rfc3339ZTimestamp | null {
  const match = RFC3339_Z_TIMESTAMP.exec(value);
  if (!match) return null;
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  if (
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth(year, month) ||
    hour > 23 ||
    minute > 59 ||
    second > 59
  ) {
    return null;
  }
  return { second: value.slice(0, 19), fraction: match[7] ?? "" };
}

function compareFractions(left: string, right: string): number {
  for (let index = 0; index < left.length || index < right.length; index += 1) {
    const leftDigit = index < left.length ? left.charCodeAt(index) : 48;
    const rightDigit = index < right.length ? right.charCodeAt(index) : 48;
    if (leftDigit !== rightDigit) return leftDigit < rightDigit ? -1 : 1;
  }
  return 0;
}

function compareRfc3339ZTimestamp(left: Rfc3339ZTimestamp, right: Rfc3339ZTimestamp): number {
  if (left.second !== right.second) return left.second < right.second ? -1 : 1;
  return compareFractions(left.fraction, right.fraction);
}

// Combines a history page and live events without treating identical text as
// the same message. Ids are opaque and only scoped to their team, so (team,
// id) is the one identity this UI can safely use.
export function mergeRoomMessages(primary: readonly Message[], secondary: readonly Message[]): Message[] {
  const seenIdsByTeam = new Map<string, Set<string>>();
  const merged: Message[] = [];
  for (const message of [...primary, ...secondary]) {
    let seenIds = seenIdsByTeam.get(message.team);
    if (!seenIds) {
      seenIds = new Set();
      seenIdsByTeam.set(message.team, seenIds);
    }
    if (seenIds.has(message.id)) continue;
    seenIds.add(message.id);
    merged.push(message);
  }

  // Storage emits both whole-second and fractional RFC3339-Z timestamps.
  // Validate the calendar fields and compare every fractional digit: sorting
  // text would put `...00.123Z` before `...00Z`, while Date.parse collapses
  // fractions smaller than one millisecond. Invalid timestamps follow dated
  // messages while retaining source order; equal instants do the same.
  return merged
    .map((message, index) => {
      return { message, index, timestamp: parseRfc3339ZTimestamp(message.created_at) };
    })
    .sort((a, b) => {
      if (a.timestamp === null) return b.timestamp === null ? a.index - b.index : 1;
      if (b.timestamp === null) return -1;
      return compareRfc3339ZTimestamp(a.timestamp, b.timestamp) || a.index - b.index;
    })
    .map(({ message }) => message);
}

export function isMessageForCurrentRoom(
  message: Pick<Message, "team">,
  currentTeam: string,
  loadedRoomTeam: string,
): boolean {
  return message.team === currentTeam && message.team === loadedRoomTeam;
}

export function roomHistoryResponseIsCurrent(
  currentTeam: string,
  latestRequest: number,
  requestTeam: string,
  request: number,
): boolean {
  return currentTeam === requestTeam && latestRequest === request;
}

// Applies an initial history response only while the room it was requested
// for is still active. Keeping this pure lets the async ordering contract stay
// covered without a live Tauri backend.
export function mergeCurrentRoomHistory(
  current: Message[],
  history: readonly Message[],
  currentTeam: string,
  latestRequest: number,
  requestTeam: string,
  request: number,
): Message[] {
  if (!roomHistoryResponseIsCurrent(currentTeam, latestRequest, requestTeam, request)) return current;
  return mergeRoomMessages(history, current);
}

export function captureRoomMessageIds(messages: readonly Message[]): Map<string, Set<string>> {
  const idsByTeam = new Map<string, Set<string>>();
  for (const message of messages) {
    let ids = idsByTeam.get(message.team);
    if (!ids) {
      ids = new Set();
      idsByTeam.set(message.team, ids);
    }
    ids.add(message.id);
  }
  return idsByTeam;
}

// A refresh keeps the prior snapshot visible while its request is pending.
// Once it succeeds, replace that snapshot with authoritative history but
// retain messages that arrived through the live listener after the refresh
// began.
export function mergeRefreshedRoomHistory(
  history: readonly Message[],
  current: readonly Message[],
  idsBeforeRefresh: ReadonlyMap<string, ReadonlySet<string>>,
): Message[] {
  const liveDuringRefresh = current.filter((message) => !idsBeforeRefresh.get(message.team)?.has(message.id));
  return mergeRoomMessages(history, liveDuringRefresh);
}

export function scheduleRoomHistoryRetry(
  delayMs: number,
  schedule: (callback: () => void, delay: number) => unknown,
  clear: (timer: unknown) => void,
  isCurrent: () => boolean,
  retry: () => void,
): () => void {
  let cancelled = false;
  const timer = schedule(() => {
    if (!cancelled && isCurrent()) retry();
  }, delayMs);
  return () => {
    if (cancelled) return;
    cancelled = true;
    clear(timer);
  };
}

// Starts a room snapshot only after a listener is ready. The App uses this
// for both the first snapshot and later team changes, so they share the same
// delivery boundary.
export function startCurrentRoomSnapshot(
  team: string,
  listenerReady: boolean,
  loadHistory: (team: string) => unknown,
): void {
  if (listenerReady && team) void loadHistory(team);
}

// Installs the live-message and history-refresh listeners before starting the
// initial history snapshot. The app keeps them across team changes; it reads
// the current team through refs, so a transition does not create an
// unsubscribe/resubscribe gap. The signal makes partial registration cleanup
// explicit: an acquired listener is disposed immediately on abort or if the
// other registration fails, and a later registration disposes itself.
export async function subscribeThenLoadRoomHistory(
  subscribeToMessages: (onMessage: (message: Message) => void) => Promise<Unlisten>,
  subscribeToHistoryRefreshes: (onHistoryRefresh: (team: string) => void) => Promise<Unlisten>,
  currentTeam: () => string,
  markReady: () => void,
  loadHistory: (team: string) => unknown,
  onMessage: (message: Message) => void,
  onHistoryRefresh: (team: string) => void,
  isActive: () => boolean,
  signal: AbortSignal,
): Promise<Unlisten | null> {
  let unlistenMessages: Unlisten | null = null;
  let unlistenHistoryRefreshes: Unlisten | null = null;
  let disposed = false;
  const cleanup = (unlisten: Unlisten | null) => {
    try {
      unlisten?.();
    } catch {
      // A failed cleanup must not keep the other listener registered.
    }
  };
  const dispose = () => {
    if (disposed) return;
    disposed = true;
    const cleanups = [unlistenMessages, unlistenHistoryRefreshes];
    unlistenMessages = null;
    unlistenHistoryRefreshes = null;
    for (const unlisten of cleanups) cleanup(unlisten);
  };
  if (signal.aborted) return null;
  signal.addEventListener("abort", dispose, { once: true });

  const register = (subscribe: () => Promise<Unlisten>, capture: (unlisten: Unlisten) => void): Promise<void> => {
    try {
      return subscribe().then((unlisten) => {
        if (disposed) cleanup(unlisten);
        else capture(unlisten);
      });
    } catch (error) {
      return Promise.reject(error);
    }
  };
  const messageRegistration = register(
    () => subscribeToMessages(onMessage),
    (unlisten) => {
      unlistenMessages = unlisten;
    },
  );
  const historyRefreshRegistration = register(
    () => subscribeToHistoryRefreshes(onHistoryRefresh),
    (unlisten) => {
      unlistenHistoryRefreshes = unlisten;
    },
  );
  try {
    await Promise.all([messageRegistration, historyRefreshRegistration]);
  } catch (error) {
    dispose();
    throw error;
  }
  if (signal.aborted || !isActive()) {
    dispose();
    return null;
  }
  markReady();
  if (signal.aborted || !isActive()) {
    dispose();
    return null;
  }
  startCurrentRoomSnapshot(currentTeam(), true, loadHistory);
  return dispose;
}
