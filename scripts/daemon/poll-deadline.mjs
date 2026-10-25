// Deadlines abandon asynchronous work; expired scopes cannot publish late writes.
import { AsyncLocalStorage } from 'node:async_hooks';

const scopes = new AsyncLocalStorage();
export const SEAT_DEADLINE_MS = 15_000;
export const CHANNEL_DEADLINE_MS = 30_000;
export const CYCLE_DEADLINE_MS = 60_000;
export const STOP_DEADLINE_MS = 1500;

export class PollDeadlineError extends Error {
  constructor(reason) { super(reason); this.name = 'PollDeadlineError'; }
}
export function pollSignal() { return scopes.getStore()?.signal; }
export function assertPollActive() { pollSignal()?.throwIfAborted(); }

export function withDeadline(work, { timeoutMs, signal = pollSignal(), reason = 'poll_deadline' }) {
  const controller = new AbortController();
  let timer;
  let onAbort;
  const aborted = new Promise((_, reject) => {
    onAbort = () => {
      const error = signal?.reason ?? new PollDeadlineError(reason);
      controller.abort(error);
      reject(error);
    };
    signal?.addEventListener('abort', onAbort, { once: true });
    timer = setTimeout(() => {
      const error = new PollDeadlineError(reason);
      controller.abort(error);
      reject(error);
    }, timeoutMs);
  });
  if (signal?.aborted) onAbort();
  const operation = scopes.run(controller, async () => {
    assertPollActive();
    return work(controller.signal);
  });
  return Promise.race([operation, aborted]).finally(() => {
    clearTimeout(timer);
    signal?.removeEventListener('abort', onAbort);
  });
}
