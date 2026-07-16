// Coalesces frequently-arriving byte chunks into a single flush, bounded
// two ways so it can never stall or grow unbounded (see issue #383's PR for
// the motivating case — batching term.write() calls per animation frame):
//
// - requestAnimationFrame alone is not enough: it throttles to ~1fps or
//   stops entirely in a backgrounded/occluded webview, and agmsg mounts
//   panes while hidden (display:none) and can run agents in the background
//   for long stretches — output would accumulate unbounded until the pane
//   became visible again (memory spike, then one giant write).
// - maxLatencyMs is a timer fallback that guarantees a flush within that
//   window regardless of whether the animation frame ever fires. Whichever
//   of the two fires first flushes and cancels the other.
// - maxPendingBytes is a hard cap: crossing it flushes immediately,
//   synchronously, inside push() — bounds worst-case memory even if the
//   frame/timer scheduling itself is somehow delayed further.

export type WriteBatcherOptions = {
  onFlush: (data: Uint8Array) => void;
  maxPendingBytes?: number;
  maxLatencyMs?: number;
  // Injectable for testing; default to the real browser globals.
  requestFrame?: (cb: () => void) => number;
  cancelFrame?: (handle: number) => void;
  setTimer?: (cb: () => void, ms: number) => ReturnType<typeof setTimeout>;
  clearTimer?: (handle: ReturnType<typeof setTimeout>) => void;
};

export type WriteBatcher = {
  push: (chunk: Uint8Array) => void;
  /** Flush whatever is pending right now, bypassing any scheduled wait. */
  flushNow: () => void;
  /** Cancel any pending schedule and drop buffered data without flushing —
   * for teardown, where writing to an about-to-be-disposed target is wrong. */
  dispose: () => void;
};

const DEFAULT_MAX_PENDING_BYTES = 256 * 1024;
const DEFAULT_MAX_LATENCY_MS = 100;

export function createWriteBatcher(options: WriteBatcherOptions): WriteBatcher {
  const maxPendingBytes = options.maxPendingBytes ?? DEFAULT_MAX_PENDING_BYTES;
  const maxLatencyMs = options.maxLatencyMs ?? DEFAULT_MAX_LATENCY_MS;
  const requestFrame = options.requestFrame ?? requestAnimationFrame;
  const cancelFrame = options.cancelFrame ?? cancelAnimationFrame;
  const setTimer = options.setTimer ?? setTimeout;
  const clearTimer = options.clearTimer ?? clearTimeout;

  let pending: Uint8Array[] = [];
  let pendingBytes = 0;
  let frameHandle: number | null = null;
  let timerHandle: ReturnType<typeof setTimeout> | null = null;
  // Permanent, not a "reset": once disposed, push/flushNow must stay no-ops
  // forever. Without this, a push() arriving after teardown (a real race —
  // see TerminalPane.tsx, where Tauri listener registration is async and
  // can resolve after the owning effect's cleanup already ran) would
  // resurrect scheduling and eventually call onFlush again, writing into
  // whatever the caller tore down (e.g. a disposed xterm instance).
  let disposed = false;

  function cancelScheduled() {
    if (frameHandle !== null) {
      cancelFrame(frameHandle);
      frameHandle = null;
    }
    if (timerHandle !== null) {
      clearTimer(timerHandle);
      timerHandle = null;
    }
  }

  function flushNow() {
    if (disposed) return;
    cancelScheduled();
    if (pending.length === 0) return;
    const merged = new Uint8Array(pendingBytes);
    let offset = 0;
    for (const chunk of pending) {
      merged.set(chunk, offset);
      offset += chunk.length;
    }
    pending = [];
    pendingBytes = 0;
    options.onFlush(merged);
  }

  function schedule() {
    if (disposed) return;
    if (frameHandle !== null || timerHandle !== null) return;
    frameHandle = requestFrame(() => {
      frameHandle = null;
      flushNow();
    });
    timerHandle = setTimer(() => {
      timerHandle = null;
      flushNow();
    }, maxLatencyMs);
  }

  function push(chunk: Uint8Array) {
    if (disposed) return;
    pending.push(chunk);
    pendingBytes += chunk.length;
    if (pendingBytes >= maxPendingBytes) {
      flushNow();
      return;
    }
    schedule();
  }

  function dispose() {
    disposed = true;
    cancelScheduled();
    pending = [];
    pendingBytes = 0;
  }

  return { push, flushNow, dispose };
}
