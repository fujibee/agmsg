import type { RawState } from "./agentStatus";
import { batchText, hold, INJECT_SETTLE_MS, restore, takeReady, STARTUP_WAIT_MS, UNKNOWN_WAIT_MS, type Queues } from "./noticeQueue";

export type FlusherDeps = {
  // Types `text` and Enter into the pane. Resolves once the Enter has been written (pty_inject resolves after its
  // whole text+Enter transaction), so the next write to the pane never starts inside the previous one.
  inject: (paneId: string, text: string) => Promise<unknown>;
  livePanes: () => string[];
  now: () => number;
  setTimer: (fn: () => void, ms: number) => void;
  onHeldChange: (queues: Queues) => void;
  // Notices typed although the pane never gave a ready signal; called after the app accepted them.
  onWithoutReadySignal: (count: number) => void;
  // Typing into a pane failed; `attempt` counts consecutive failures. The notices are kept and tried again later.
  // The notice path says what it did with a notice (typed, held past a cap, dropped, failed) in one line.
  log: (line: string) => void;
  onInjectFailed: (paneId: string, attempt: number, reason: string) => void;
  // Notices were typed into the pane (the Enter was written): the ids of the messages they were about, and when.
  onTyped?: (paneId: string, ids: string[], at: number) => void;
};

// Retry delay after consecutive failures: doubles from RETRY_BASE_MS up to RETRY_MAX_MS. It never gives up while
// the pane is open, and closing the pane drops the notices, which ends the retries.
export const RETRY_BASE_MS = 1000;
export const RETRY_MAX_MS = 30_000;

// Feeds app-typed notices into panes: a new pane's first notices wait for its first idle; each pane gets one line
// per write, and is not written to again until the previous write has settled.
export function createNoticeFlusher(deps: FlusherDeps) {
  let queues: Queues = {};
  const states: Record<string, RawState> = {};
  const released = new Set<string>();
  const busy = new Set<string>();
  const failures: Record<string, number> = {};

  const setQueues = (q: Queues) => {
    if (q === queues) return;
    queues = q;
    deps.onHeldChange(q);
  };

  const flush = () => {
    const live = new Set(deps.livePanes());
    let q = queues;
    for (const id of Object.keys(q)) {
      if (!live.has(id)) {
        deps.log(`notices for ${id} dropped: the pane is closed (${q[id].length})`);
        q = { ...q };
        delete q[id];
      }
    }
    const toType: Array<{ id: string; sent: ReturnType<typeof takeReady>["send"] }> = [];
    for (const id of Object.keys(q)) {
      if (busy.has(id)) continue;
      const { send, rest } = takeReady(q, id, released.has(id), states[id], deps.now());
      if (send.length > 0) toType.push({ id, sent: send });
      q = rest;
    }
    setQueues(q);
    for (const { id, sent } of toType) {
      busy.add(id);
      deps.log(`typing ${sent.length} notice(s) into ${id}${sent.some((n) => n.late) ? " without a ready signal" : ""}`);
      deps
        .inject(id, batchText(sent))
        .then(() => {
          // Only a notice that was actually typed ends the pane's startup hold.
          released.add(id);
          delete failures[id];
          const late = sent.filter((n) => n.late).length;
          if (late > 0) deps.onWithoutReadySignal(late);
          const typed = sent.map((n) => n.id).filter((x): x is string => x !== undefined);
          if (typed.length > 0) deps.onTyped?.(id, typed, deps.now());
          deps.setTimer(() => {
            busy.delete(id);
            flush();
          }, INJECT_SETTLE_MS);
        })
        .catch((e: unknown) => {
          const attempt = (failures[id] = (failures[id] ?? 0) + 1);
          deps.log(`typing into ${id} failed (attempt ${attempt}): ${String(e)}`);
          if (deps.livePanes().includes(id)) {
            setQueues(restore(queues, id, sent));
            deps.onInjectFailed(id, attempt, String(e));
          }
          deps.setTimer(() => {
            busy.delete(id);
            flush();
          }, Math.min(RETRY_BASE_MS * 2 ** (attempt - 1), RETRY_MAX_MS));
        });
    }
  };

  return {
    flush,
    // A notice for `paneId` arrived.
    notice(paneId: string, text: string, id?: string) {
      deps.log(`notice for ${paneId} held (released=${released.has(paneId)}, state=${states[paneId] ?? "none"})`);
      setQueues(hold(queues, paneId, text, deps.now(), id));
      if (!released.has(paneId)) {
        deps.setTimer(flush, UNKNOWN_WAIT_MS + 100);
        deps.setTimer(flush, STARTUP_WAIT_MS + 100);
      }
      flush();
    },
    // The pane's agent-state changed; read synchronously by the next flush.
    state(paneId: string, state: RawState) {
      states[paneId] = state;
      if (state === "idle") released.add(paneId);
      flush();
    },
  };
}
