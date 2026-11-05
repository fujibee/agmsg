// Only the most recently started request may apply its result: a slower earlier one (another team, or a stale
// reload of the same team) is dropped when it finishes.
export function createLatestOnly() {
  let generation = 0;
  return {
    // Start a request: returns whether a result for `token` is still the current one.
    start(): () => boolean {
      const token = ++generation;
      return () => token === generation;
    },
  };
}
