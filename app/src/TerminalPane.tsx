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
export function TerminalPane({ id, cmd, args = [], cwd }: Props) {
  const ref = useRef<HTMLDivElement>(null);
  const { t } = useTranslation();

  useEffect(() => {
    let disposed = false;
    const term = new Terminal({
      fontSize: 12,
      fontFamily: "Menlo, Monaco, 'Courier New', monospace",
      cursorBlink: true,
      theme: { background: "#0b0e14", foreground: "#c5c8c6" },
    });
    const fit = new FitAddon();
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
      }
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
    };
  }, [id, cmd, cwd]);

  return <div className="term-pane" ref={ref} />;
}
