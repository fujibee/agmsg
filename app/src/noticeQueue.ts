import type { RawState } from "./agentStatus";

// Notices the app types into an agent's terminal. A pane the app has just opened is still working through its
// startup turn, and a notice typed then is lost. So the first notices for a pane wait for its first Idle. While the
// pane is working (or blocked on a dialog the user can see) there is no cap: the startup turn ends by itself. When
// its state is unknown, or never reported, the wait is capped at UNKNOWN_WAIT_MS. After the first delivery (or once
// the pane has been seen idle) notices are typed as they come, whatever the state. Nothing is dropped or refused.
export const UNKNOWN_WAIT_MS = 180_000;

export type Held = { text: string; at: number; late?: boolean };
export type Queues = Record<string, Held[]>;

export function hold(queues: Queues, paneId: string, text: string, now: number): Queues {
  return { ...queues, [paneId]: [...(queues[paneId] ?? []), { text, at: now }] };
}

// What to type now into `paneId`. `released` = the pane has been seen idle, or has already been given notices.
//   released or idle -> every held notice.
//   working / blocked -> nothing.
//   unknown / no state -> nothing, until the oldest has waited UNKNOWN_WAIT_MS; then every held notice, flagged
//   `late` (typed without a ready signal).
export function takeReady(
  queues: Queues,
  paneId: string,
  released: boolean,
  state: RawState | undefined,
  now: number,
): { send: Held[]; rest: Queues } {
  const held = queues[paneId] ?? [];
  if (held.length === 0) return { send: [], rest: queues };
  const ready = released || state === "idle";
  const timedOut = (state === undefined || state === "unknown") && now - held[0].at >= UNKNOWN_WAIT_MS;
  if (!ready && !timedOut) return { send: [], rest: queues };
  const rest = { ...queues };
  delete rest[paneId];
  return { send: held.map((h) => ({ ...h, late: !ready })), rest };
}

export function heldCount(queues: Queues, paneId: string): number {
  return queues[paneId]?.length ?? 0;
}

// One line for a batch of ready notices. Each notice already tells the agent to read its inbox, so a batch is the
// first notice plus the number of others: one typed submission per pane instead of several racing each other.
export function batchText(sent: ReadonlyArray<Pick<Held, "text">>): string {
  if (sent.length <= 1) return sent[0]?.text ?? "";
  return `${sent[0].text} (+${sent.length - 1} more message(s) waiting in the same inbox)`;
}

// Put notices back at the front of a pane's queue, e.g. when typing them failed.
export function restore(queues: Queues, paneId: string, items: ReadonlyArray<Held>): Queues {
  return { ...queues, [paneId]: [...items, ...(queues[paneId] ?? [])] };
}

// pty_inject returns once its writer thread has started; the thread then waits this long before the Enter. A pane
// is not written to again before that is over.
export const INJECT_SETTLE_MS = 500;
