import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebglAddon } from "@xterm/addon-webgl";
import "@xterm/xterm/css/xterm.css";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { createWriteBatcher } from "./writeBatcher";
import { attachWebglAddon } from "./webglAttach";

type Props = {
  /** Stable session id; also the key the backend stores the PTY under. */
  id: string;
  cmd: string;
  args?: string[];
  cwd?: string;
  fontSize?: number;
  /** Whether this pane is the currently visible one. Every pane across
   * every tab/team stays mounted for its whole session (see the .stage
   * comment in App.tsx), so this drives WebGL context attach/detach — see
   * the dedicated effect below — rather than mount/unmount. */
  active: boolean;
  onAgentState?: (id: string, state: "idle" | "working" | "blocked" | "unknown") => void;
  /** Reported on every fit — the pane's current cell size in CSS px, so a
   * divider drag elsewhere can snap to whole terminal rows/cols. */
  onCellSize?: (widthPx: number, heightPx: number) => void;
  /** Fired when this pane's terminal actually receives keyboard focus (a
   * click inside it, or Tab-focus) — xterm.js's hidden input textarea is a
   * focusable descendant of the container div below, so a plain onFocus
   * there catches it via the bubbled focusin React normalizes to. Lets the
   * app track "which pane in this tab was last actually used" for the
   * external file-drop fallback target (prefer the focused pane over
   * just the tab's first one). */
  onFocusPane?: (id: string) => void;
};

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

/**
 * One embedded agent terminal: an xterm.js view bound to a backend PTY session.
 * Output streams in via `pty-output` events; keystrokes go back via `pty_write`.
 */
export function TerminalPane({
  id,
  cmd,
  args = [],
  cwd,
  fontSize = 12,
  active,
  onAgentState,
  onCellSize,
  onFocusPane,
}: Props) {
  const ref = useRef<HTMLDivElement>(null);
  // Live handles to the current terminal/fit addon, for the font-size effect
  // below to reach — that effect must NOT be a dependency of the main effect
  // (a fontSize change would otherwise kill and respawn the PTY, losing the
  // running process).
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
  // Set only while a WebGL context is actually attached (see the `active`
  // effect below) — null whenever this pane is on the default DOM renderer,
  // whether because it's inactive or because WebGL was never attached/lost.
  const webglAddonRef = useRef<WebglAddon | null>(null);
  const idRef = useRef(id);
  idRef.current = id;
  const { t } = useTranslation();

  useEffect(() => {
    let disposed = false;
    const term = new Terminal({
      fontSize,
      fontFamily: "Menlo, Monaco, 'Courier New', monospace",
      cursorBlink: true,
      theme: { background: "#0b0e14", foreground: "#c5c8c6" },
    });
    termRef.current = term;
    const fit = new FitAddon();
    fitRef.current = fit;
    term.loadAddon(fit);
    term.open(ref.current!);

    // Fit to the container's CURRENT size and tell the PTY — but only when the
    // pane is actually laid out. A pane that mounts while its tab is inactive
    // (or before first layout) has 0 size; fitting then would size the terminal
    // to ~1 column. We keep xterm's 80x24 default until a real size arrives,
    // and a ResizeObserver re-fits when the pane gets/changes its size (initial
    // layout, tab switch from display:none, window resize).
    let lastRows = 0;
    let lastCols = 0;
    const fitNow = () => {
      const el = ref.current;
      if (!el || el.offsetWidth === 0 || el.offsetHeight === 0) return;
      try {
        fit.fit();
      } catch {
        return;
      }
      if (term.rows !== lastRows || term.cols !== lastCols) {
        lastRows = term.rows;
        lastCols = term.cols;
        void invoke("pty_resize", { id, rows: term.rows, cols: term.cols });
      }
      // Every pane uses the same fixed font today, so any one of them
      // reporting its cell size is representative of them all — a divider
      // drag doesn't need to know which specific panes it's between.
      onCellSize?.(el.offsetWidth / term.cols, el.offsetHeight / term.rows);
    };

    // Coalesce PTY output into at most one term.write() per animation frame
    // instead of one per backend event. The Rust reader thread emits an
    // event per raw PTY read (unbatched, no debounce) — a chatty CLI (issue
    // #383: Codex's title-escape-driven spinner churns very frequently)
    // can fire far more of these than the browser can usefully paint
    // between frames. Unverified hypothesis behind this change: each
    // term.write() resets xterm's cursor blink phase, so writing many
    // times within a single frame is a plausible source of the reported
    // visible flicker/jitter — batching bounds that to once per frame
    // regardless of how bursty the backend is. See writeBatcher.ts for why
    // this isn't just a bare requestAnimationFrame (it stalls in a
    // backgrounded/occluded webview, and agmsg mounts panes while hidden).
    const writeBatcher = createWriteBatcher({ onFlush: (data) => term.write(data) });

    const unlisteners: Array<() => void> = [];
    (async () => {
      // Register listeners BEFORE spawning so no early output is missed.
      // `listen()` is async — if this effect's cleanup runs while one of
      // these awaits is still in flight (a fast unmount/remount, or React
      // re-running the effect), the listener resolves into a component
      // that's already torn down. Each registration below checks `disposed`
      // right after its own await and, if already torn down, unregisters
      // itself immediately instead of joining `unlisteners` — otherwise the
      // Tauri listener would keep firing this closure's stale term/
      // writeBatcher forever (a real listener leak), and — before
      // writeBatcher.dispose() became permanent (see writeBatcher.ts) —
      // could even resurrect its scheduling after teardown. The `disposed`
      // check inside each callback body is defense in depth for an event
      // already queued at the moment unlisten() runs.
      const unlistenOutput = await listen<{ id: string; b64: string }>("pty-output", (e) => {
        if (disposed) return;
        if (e.payload.id === id) writeBatcher.push(b64ToBytes(e.payload.b64));
      });
      if (disposed) {
        unlistenOutput();
        return;
      }
      unlisteners.push(unlistenOutput);

      const unlistenExit = await listen<{ id: string }>("pty-exit", (e) => {
        if (disposed) return;
        if (e.payload.id !== id) return;
        // Flush synchronously first — any output still waiting for its
        // batched write must land before the exit banner, or the banner
        // could render above the process's own final lines.
        writeBatcher.flushNow();
        term.write(`\r\n\x1b[90m${t("terminal.processExited")}\x1b[0m\r\n`);
      });
      if (disposed) {
        unlistenExit();
        return;
      }
      unlisteners.push(unlistenExit);
      term.onData((data) => void invoke("pty_write", { id, data }));
      fitNow(); // size the PTY to the pane if it's already laid out
      try {
        await invoke("pty_spawn", { id, cmd, args, cwd, rows: term.rows, cols: term.cols });
      } catch (err) {
        // A failed spawn (missing CLI on PATH, bad cwd, ...) would otherwise
        // leave this pane blank forever with zero indication anything went
        // wrong. Write the failure straight into the terminal — it's already
        // the visible surface for this pane, no extra UI needed.
        term.write(`\r\n\x1b[91m${t("terminal.failedToStart", { cmd, error: String(err) })}\x1b[0m\r\n`);
        return;
      }
      void invoke<"idle" | "working" | "blocked" | "unknown">("agent_state", { id })
        .then((state) => onAgentState?.(id, state))
        .catch(() => {});
    })();

    // Re-fit whenever the pane's box changes — covers initial layout, switching
    // back to this tab (display:none -> block), and window resizes. Also
    // fires continuously while a divider is being dragged (issue #317):
    // debounced here rather than reacting to every single event, since
    // fitNow's fit.fit() + pty_resize is expensive and can spam some CLIs
    // with rapid SIGWINCH in a way that garbles their redraw — the dragged
    // pane's own CSS size still tracks the cursor live (that's just the
    // browser reflowing .pane-cell's inline style), only the actual PTY
    // resize + xterm reflow is throttled.
    let resizeTimer: ReturnType<typeof setTimeout> | null = null;
    const ro = new ResizeObserver(() => {
      if (resizeTimer) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(fitNow, 75);
    });
    if (ref.current) ro.observe(ref.current);

    return () => {
      disposed = true;
      if (resizeTimer) clearTimeout(resizeTimer);
      writeBatcher.dispose();
      ro.disconnect();
      unlisteners.forEach((u) => u());
      void invoke("pty_kill", { id });
      term.dispose();
      termRef.current = null;
      fitRef.current = null;
    };
  }, [id, cmd, cwd, onAgentState, onCellSize]);

  // Apply a fontSize change live, without recreating the terminal (which
  // would kill and respawn the PTY). Skips its very first run — at that
  // point termRef was *just* created above with this same fontSize value
  // (passed to the Terminal constructor), so re-fitting would be a no-op
  // re-resize racing the pty_spawn call still in flight in the effect above.
  const skipInitialFontSizeEffect = useRef(true);
  useEffect(() => {
    if (skipInitialFontSizeEffect.current) {
      skipInitialFontSizeEffect.current = false;
      return;
    }
    const term = termRef.current;
    const fit = fitRef.current;
    const el = ref.current;
    if (!term || !fit || !el || el.offsetWidth === 0 || el.offsetHeight === 0) return;
    term.options.fontSize = fontSize;
    try {
      fit.fit();
    } catch {
      return;
    }
    void invoke("pty_resize", { id: idRef.current, rows: term.rows, cols: term.cols });
    // A font size change resizes xterm's internal cell geometry without
    // resizing the .term-pane container itself, so the ResizeObserver in
    // the main effect above never fires for it — re-report cell size here,
    // or divider snap/gap sizing (see onCellSize's doc comment) silently
    // stays pinned to whatever font was active on last container resize.
    onCellSize?.(el.offsetWidth / term.cols, el.offsetHeight / term.rows);
  }, [fontSize, onCellSize]);

  // WebGL-accelerated rendering, attached only while this pane is the
  // visible one (see the `active` prop doc above). Issue #383: xterm's
  // default DOM renderer does a full replaceChildren() DOM-node rebuild of
  // an entire row on every content update — its own source calls this
  // renderer "not meant to be particularly fast" and describes it as "a
  // fallback for when the webgl addon is slow" (i.e. WebGL is the intended
  // fast path, DOM is the fallback, and we'd been running the fallback
  // unconditionally). A CLI's animated status text (frequent same-line SGR
  // recoloring) forces that expensive rebuild repeatedly, which is the
  // likely source of the reported render flicker.
  //
  // Scoped to `active`, not mount/unmount: every pane in every tab across
  // every team stays mounted for its whole session, so eagerly attaching
  // WebGL to every mounted pane would exhaust the browser's concurrent-
  // context cap (Chromium: ~8-16) well before a typical multi-pane,
  // multi-tab session's real pane count — multi-pane is this team's normal
  // usage, not an edge case. Backgrounding a pane releases its context
  // immediately rather than waiting for the browser to force-evict the
  // oldest one.
  useEffect(() => {
    const term = termRef.current;
    if (!term || !active) return;
    // Throw/dispose/context-loss edge cases live in attachWebglAddon
    // (webglAttach.ts) so they're unit-testable without a real WebGL
    // context — see that file for the failure-path reasoning.
    return attachWebglAddon(term, () => new WebglAddon(), webglAddonRef);
  }, [active]);

  return <div className="term-pane" ref={ref} onFocus={() => onFocusPane?.(idRef.current)} />;
}
