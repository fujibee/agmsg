// "Only the newest answer counts" for a call that is repeated (the open-request
// rows are re-read on every new message and after every click). Each `next()`
// hands out a ticket; an answer is applied only if its ticket is still the
// newest, and `cancel()` (tab switch, unmount) makes every outstanding ticket
// stale. A slow earlier read can therefore never overwrite a newer one, and a
// read for the previous team can never land on the next.

export function latestWins() {
  let current = 0;
  return {
    next(): () => boolean {
      const mine = ++current;
      return () => mine === current;
    },
    cancel() {
      current++;
    },
  };
}
