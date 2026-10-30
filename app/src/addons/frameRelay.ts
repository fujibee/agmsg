// Starts a pane relay together with its push-event listener and returns one
// dispose. Split from AddonFrame so cleanup and unmount races are testable
// without a DOM: dispose closes the port, cancels a pending load, and drops the
// listener even when `listen` resolves after dispose.

import { createPaneRelay, type ChannelLike, type FrameWindowLike, type Invoke, type PaneRelay, type PushEvent } from "./paneRelay";

export type Listen = (event: string, handler: (e: { payload: PushEvent }) => void) => Promise<() => void>;

export function startFrameRelay(deps: {
  paneInstance: number;
  wantsFeed: boolean;
  invoke: Invoke;
  listen: Listen;
  frameWindow: () => FrameWindowLike | null;
  newChannel?: () => ChannelLike;
  /** Read at call time, so a new callback identity never rebuilds the relay. */
  onRefused: () => ((op: string, code: string) => void) | undefined;
  onFeedFailed?: () => ((code: string, message: string) => void) | undefined;
}): { relay: PaneRelay; dispose: () => void } {
  const relay = createPaneRelay({
    id: deps.paneInstance,
    invoke: deps.invoke,
    frameWindow: deps.frameWindow,
    wantsFeed: deps.wantsFeed,
    newChannel: deps.newChannel,
    onRefused: (op, code) => deps.onRefused()?.(op, code),
    onFeedFailed: (code, message) => deps.onFeedFailed?.()?.(code, message),
  });
  let disposed = false;
  let unlisten: (() => void) | null = null;
  void deps.listen("addon-push", (e) => {
    if (!disposed) relay.onPush(e.payload);
  }).then((u) => {
    if (disposed) u();
    else unlisten = u;
  });
  return {
    relay,
    dispose() {
      disposed = true;
      unlisten?.();
      unlisten = null;
      relay.closePort();
    },
  };
}
