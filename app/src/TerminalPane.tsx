import { useEffect, useRef } from "react";
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
    fit.fit();

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
          if (e.payload.id === id) term.write("\r\n\x1b[90m[process exited]\x1b[0m\r\n");
        }),
      );
      if (disposed) return;
      term.onData((data) => void invoke("pty_write", { id, data }));
      await invoke("pty_spawn", { id, cmd, args, cwd, rows: term.rows, cols: term.cols });
    })();

    const onResize = () => {
      fit.fit();
      void invoke("pty_resize", { id, rows: term.rows, cols: term.cols });
    };
    window.addEventListener("resize", onResize);

    return () => {
      disposed = true;
      window.removeEventListener("resize", onResize);
      unlisteners.forEach((u) => u());
      void invoke("pty_kill", { id });
      term.dispose();
    };
  }, [id, cmd, cwd]);

  return <div className="term-pane" ref={ref} />;
}
