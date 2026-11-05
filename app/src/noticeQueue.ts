import type { RawState } from "./agentStatus";

// Notices the app types into an agent's terminal. Typing one while the agent is in the middle of a turn loses it,
// so a notice waits here until the pane has shown it is ready for input. Nothing is dropped or refused: a notice
// that never gets a ready signal is typed anyway after UNKNOWN_WAIT_MS, and says so.
export const UNKNOWN_WAIT_MS = 30_000;

export type Held = { text: string; at: number };
export type Queues = Record<string, Held[]>;

export function hold(queues: Queues, paneId: string, text: string, now: number): Queues {
  return { ...queues, [paneId]: [...(queues[paneId] ?? []), { text, at: now }] };
}

// What to type now into `paneId`, given its latest state (undefined = no state seen yet, which is the case for a
// fresh pane until its first Idle).
//   idle    -> every held notice, in order.
//   working / blocked -> nothing; the notices stay held (blocked is shown to the user as a count).
//   unknown / no state -> the notices held for UNKNOWN_WAIT_MS or longer, flagged `late` (no ready signal).
export function takeReady(
  queues: Queues,
  paneId: string,
  state: RawState | undefined,
  now: number,
): { send: Array<Held & { late: boolean }>; rest: Queues } {
  const held = queues[paneId] ?? [];
  if (held.length === 0) return { send: [], rest: queues };
  let send: Array<Held & { late: boolean }> = [];
  let keep: Held[] = held;
  if (state === "idle") {
    send = held.map((h) => ({ ...h, late: false }));
    keep = [];
  } else if (state === undefined || state === "unknown") {
    send = held.filter((h) => now - h.at >= UNKNOWN_WAIT_MS).map((h) => ({ ...h, late: true }));
    keep = held.filter((h) => now - h.at < UNKNOWN_WAIT_MS);
  }
  if (send.length === 0) return { send, rest: queues };
  const rest = { ...queues };
  if (keep.length === 0) delete rest[paneId];
  else rest[paneId] = keep;
  return { send, rest };
}

export function heldCount(queues: Queues, paneId: string): number {
  return queues[paneId]?.length ?? 0;
}
