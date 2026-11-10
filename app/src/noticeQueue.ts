import type { RawState } from "./agentStatus";

// Notices the app types into an agent's terminal. A pane the app has just opened is still working through its
// startup turn, and a notice typed then is lost. So the first notices for a pane wait for its first Idle. While the
// pane is working (or blocked on a dialog the user can see) the wait is capped at STARTUP_WAIT_MS; when its state is
// unknown, or never reported, at UNKNOWN_WAIT_MS. At the cap the notices are typed with a visible note. After the first delivery (or once
// the pane has been seen idle) notices are typed as they come, except while the pane is working: Codex keeps text typed
// then in its input box without sending it. A working pane is waited for up to STARTUP_WAIT_MS. Nothing is dropped or refused.
export const UNKNOWN_WAIT_MS = 180_000;
// A pane that is working or blocked on a dialog through its startup is given longer, but not without end.
export const STARTUP_WAIT_MS = 600_000;

export type Held = { text: string; at: number; late?: boolean; id?: string };
export type Queues = Record<string, Held[]>;

export function hold(queues: Queues, paneId: string, text: string, now: number, id?: string): Queues {
  return { ...queues, [paneId]: [...(queues[paneId] ?? []), id === undefined ? { text, at: now } : { text, at: now, id }] };
}

// What to type now into `paneId`. `released` = the pane has been seen idle, or has already been given notices.
//   idle, or released and not working -> every held notice.
//   otherwise -> nothing, until the oldest has waited UNKNOWN_WAIT_MS (unknown / no state) or STARTUP_WAIT_MS
//   (working / blocked); then every held notice, flagged
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
  const ready = state === "idle" || (released && state !== "working");
  const cap = state === undefined || state === "unknown" ? UNKNOWN_WAIT_MS : STARTUP_WAIT_MS;
  const timedOut = now - held[0].at >= cap;
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
