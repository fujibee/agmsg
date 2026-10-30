// A pane's frame has to finish loading within FRAME_LOAD_TIMEOUT_MS; past that the pane says so with its
// "did not load" card and Reload, instead of a "Loading" cover that never goes away. This is only about the
// frame's document: the relay's own handshake and the guard are not touched or relaxed by it.

export const FRAME_LOAD_TIMEOUT_MS = 15_000;

/** The key of one frame instance: the pane instance and its reload count, so a new one is never mistaken for the old. */
export const frameKey = (paneInstance: number, reloadKey: number): string => `${paneInstance}:${reloadKey}`;

/** Whether a load deadline should be running now: a frame is mounted, it has not loaded, and the pane is showing it. */
export function watchLoad(mounted: string, loaded: string, paneState: string): boolean {
  return mounted !== "" && mounted !== loaded && paneState === "frame";
}
