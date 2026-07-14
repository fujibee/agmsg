import { useEffect, useRef } from "react";
import { useTranslation } from "react-i18next";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import "@xterm/xterm/css/xterm.css";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

type Props = {
  /** Stable session id; also the key the backend stores the PTY under. */
  id: string;
  cmd: string;
  args?: string[];
  cwd?: string;
  fontSize?: number;
  onAgentState?: (id: string, state: "idle" | "working" | "blocked" | "unknown") => void;
  /** Reported on every fit — the pane's current cell size in CSS px, so a
   * divider drag elsewhere can snap to whole terminal rows/cols. */
  onCellSize?: (widthPx: number, heightPx: number) => void;
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
export function TerminalPane({ id, cmd, args = [], cwd, fontSize = 12, onAgentState, onCellSize }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  // Live handles to the current terminal/fit addon, for the font-size effect
  // below to reach — that effect must NOT be a dependency of the main effect
  // (a fontSize change would otherwise kill and respawn the PTY, losing the
  // running process).
  const termRef = useRef<Terminal | null>(null);
  const fitRef = useRef<FitAddon | null>(null);
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

    const unlisteners: Array<() => void> = [];
    (async () => {
      // Register listeners BEFORE spawning so no early output is missed.
      unlisteners.push(
        await listen<{ id: string; b64: string }>("pty-output", (e) => {
          if (e.payload.id === id) term.write(b64ToBytes(e.payload.b64));
        }),
      );
      unlisteners.push(
        await listen<{ id: string }>("pty-exit", (e) => {
          if (e.payload.id === id) term.write(`\r\n\x1b[90m${t("terminal.processExited")}\x1b[0m\r\n`);
        }),
      );
      if (disposed) return;
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

  return <div className="term-pane" ref={ref} />;
}
