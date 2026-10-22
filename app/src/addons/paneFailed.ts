// Listens for `addon-pane-failed` for one pane instance. The returned dispose
// is final: an event that arrives after it (or before a late `listen` has
// resolved) is dropped, and a registration that resolves after dispose is
// unlistened at once, the same discipline as frameRelay.

export type PaneFailedEvent = { pane: number; reason: string };
export type PaneFailedListen = (event: string, handler: (e: { payload: PaneFailedEvent }) => void) => Promise<() => void>;

export function listenPaneFailed(listen: PaneFailedListen, paneId: number, onFailed: (reason: string) => void): () => void {
  let disposed = false;
  let unlisten: (() => void) | null = null;
  void listen("addon-pane-failed", (e) => {
    if (disposed || e.payload.pane !== paneId) return;
    onFailed(e.payload.reason);
  }).then((u) => {
    if (disposed) u();
    else unlisten = u;
  });
  return () => {
    disposed = true;
    unlisten?.();
    unlisten = null;
  };
}
