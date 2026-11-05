import type { RawState } from "./agentStatus";
import { batchText, hold, INJECT_SETTLE_MS, restore, takeReady, UNKNOWN_WAIT_MS, type Queues } from "./noticeQueue";

export type FlusherDeps = {
  // Types `text` and Enter into the pane. Resolves once the app accepted the request (pty_inject's ack is the start
  // of its writer thread, not the end of the write: the Enter follows about 300 ms later).
  inject: (paneId: string, text: string) => Promise<unknown>;
  livePanes: () => string[];
  now: () => number;
  setTimer: (fn: () => void, ms: number) => void;
  onHeldChange: (queues: Queues) => void;
  // Notices typed although the pane never gave a ready signal; called after the app accepted them.
  onWithoutReadySignal: (count: number) => void;
};

// Feeds app-typed notices into panes: a new pane's first notices wait for its first idle; each pane gets one line
// per write, and is not written to again until the previous write has settled.
export function createNoticeFlusher(deps: FlusherDeps) {
  let queues: Queues = {};
  const states: Record<string, RawState> = {};
  const released = new Set<string>();
  const busy = new Set<string>();

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
        q = { ...q };
        delete q[id];
      }
    }
    const toType: Array<{ id: string; sent: ReturnType<typeof takeReady>["send"] }> = [];
    for (const id of Object.keys(q)) {
      if (busy.has(id)) continue;
      const { send, rest } = takeReady(q, id, released.has(id), states[id], deps.now());
      if (send.length > 0) {
        released.add(id);
        toType.push({ id, sent: send });
      }
      q = rest;
    }
    setQueues(q);
    for (const { id, sent } of toType) {
      busy.add(id);
      deps
        .inject(id, batchText(sent))
        .then(() => {
          const late = sent.filter((n) => n.late).length;
          if (late > 0) deps.onWithoutReadySignal(late);
        })
        .catch(() => {
          if (deps.livePanes().includes(id)) setQueues(restore(queues, id, sent));
        })
        .finally(() => {
          deps.setTimer(() => {
            busy.delete(id);
            flush();
          }, INJECT_SETTLE_MS);
        });
    }
  };

  return {
    flush,
    // A notice for `paneId` arrived.
    notice(paneId: string, text: string) {
      setQueues(hold(queues, paneId, text, deps.now()));
      if (!released.has(paneId)) deps.setTimer(flush, UNKNOWN_WAIT_MS + 100);
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
