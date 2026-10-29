// A short-lived notice (a refusal shown in the pane's bar). Each occurrence has its own number, so the
// same words arriving again is a new notice: its timer starts over, and an older timer cannot remove it.

export type Notice = { seq: number; text: string };

/** A counter that only goes up, owned by whoever shows notices (not derived from what is on screen, so clearing never rewinds it). */
export function counter(): () => number {
  let n = 0;
  return () => ++n;
}

/** A new notice with the given number: the same words again are still a different notice. */
export function raise(seq: number, text: string): Notice {
  return { seq, text };
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
