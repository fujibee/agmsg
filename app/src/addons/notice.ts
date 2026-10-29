// A short-lived notice (a refusal shown in the pane's bar). Each occurrence has its own number, so the
// same words arriving again is a new notice: its timer starts over, and an older timer cannot remove it.

export type Notice = { seq: number; text: string };

/** The notice after `text` happens again (or for the first time): always a new one. */
export function raise(current: Notice | undefined, text: string): Notice {
  return { seq: (current?.seq ?? 0) + 1, text };
}

/** Clears the notice only if it is still the one that was meant (the timer's or the × 's own). */
export function clearIf(current: Notice | undefined, seq: number): Notice | undefined {
  return current && current.seq === seq ? undefined : current;
}

/** Starts the timer for one notice; the returned function cancels it. */
export function expireAfter(seq: number, ms: number, clear: (seq: number) => void): () => void {
  const id = setTimeout(() => clear(seq), ms);
  return () => clearTimeout(id);
}
