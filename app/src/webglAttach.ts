// WebGL-context attach/detach logic for TerminalPane's `active`-scoped
// renderer effect (see #383), pulled out into a pure-ish function so the
// throw/dispose paths are unit-testable without a real WebGL context —
// tests inject a mock addon instead. Kept structurally minimal (only the
// methods this code actually calls, plus `activate` purely so real
// Terminal/WebglAddon instances stay assignable to these types — this
// module never calls it itself, xterm does internally via loadAddon).
import type { Terminal } from "@xterm/xterm";

export type MinimalWebglAddon = {
  dispose: () => void;
  onContextLoss: (callback: () => void) => void;
  activate: (terminal: Terminal) => void;
};

export type MinimalTerminal = {
  loadAddon: (addon: MinimalWebglAddon) => void;
};

// Attaches a fresh WebGL addon to `term` and returns a cleanup function that
// detaches it — or `undefined` if attaching failed, in which case there's
// nothing to clean up. `ref` is the caller's live-handle ref (so a real
// GPU/driver context-loss event, which can fire independently of React's
// effect lifecycle, can null it out without going through React at all).
//
// `createAddon` is injected (rather than calling `new WebglAddon()`
// directly) purely for testability.
export function attachWebglAddon(
  term: MinimalTerminal,
  createAddon: () => MinimalWebglAddon,
  ref: { current: MinimalWebglAddon | null },
): (() => void) | undefined {
  const webgl = createAddon();
  // Real GPU/driver context loss (as opposed to this function's own
  // cleanup return value, used for a proactive detach) — falls back to
  // whatever renderer the terminal reverts to; no retry here.
  webgl.onContextLoss(() => {
    webgl.dispose();
    if (ref.current === webgl) ref.current = null;
  });
  try {
    term.loadAddon(webgl);
    ref.current = webgl;
  } catch {
    // loadAddon/activate can throw not just immediately (e.g. "WebGL2
    // unavailable") but after partially acquiring renderer/context/GPU
    // resources — always dispose to release whatever was allocated, or
    // repeated failures (e.g. a flaky/unstable GPU across tab switches,
    // each one calling this function again) would leak resources instead
    // of just falling back cleanly.
    try {
      webgl.dispose();
    } catch {
      // dispose() on a partially-initialized addon could itself throw —
      // nothing more to do, the addon is being discarded either way.
    }
    return undefined;
  }
  return () => {
    // Guards against double-dispose if onContextLoss already fired and
    // cleared the ref for this exact addon instance.
    if (ref.current === webgl) {
      webgl.dispose();
      ref.current = null;
    }
  };
}
