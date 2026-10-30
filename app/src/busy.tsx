import { useCallback, useEffect, useRef, useState, type ButtonHTMLAttributes, type ReactNode } from "react";

// "Something is running" for buttons and panes. A busy button is disabled, says aria-busy and shows a
// small spinner; the spinner only becomes visible after BUSY_DELAY_MS (in CSS, see .busy-spinner), so work
// that ends at once does not flicker. A failure must end the busy state too: BusyTracker clears it in
// `finally`, whatever the work did.

export const BUSY_DELAY_MS = 150;

/** The spinner element; decorative, the button or the status text beside it says what is happening. */
export function Spinner() {
  return <span className="busy-spinner" aria-hidden="true" />;
}

export function BusyButton(props: ButtonHTMLAttributes<HTMLButtonElement> & { busy?: boolean; children?: ReactNode }) {
  const { busy, children, disabled, ...rest } = props;
  return (
    <button {...rest} disabled={disabled || busy} aria-busy={busy ? true : undefined}>
      {children}
      {busy && <Spinner />}
    </button>
  );
}

/** A pane that is waiting: a spinner and a line saying what for. */
export function LoadingView(props: { text: string }) {
  return (
    <div className="addon-loading" role="status" aria-live="polite">
      <Spinner />
      <span>{props.text}</span>
    </div>
  );
}

/** Keys of the things running now. `run` sets the key, awaits the work, and always clears it again. */
export class BusyTracker {
  private keys = new Set<string>();
  constructor(private onChange: (keys: ReadonlySet<string>) => void) {}
  has(key: string): boolean {
    return this.keys.has(key);
  }
  /** Runs `work` with `key` busy. If `key` is already busy the call is ignored (undefined). */
  async run<T>(key: string, work: () => Promise<T>): Promise<T | undefined> {
    if (this.keys.has(key)) return undefined;
    this.keys.add(key);
    this.onChange(new Set(this.keys));
    try {
      return await work();
    } finally {
      this.keys.delete(key);
      this.onChange(new Set(this.keys));
    }
  }
}

/** React side of BusyTracker: the set of busy keys, and `run`. Updates stop after unmount. */
export function useBusy(): { busy: ReadonlySet<string>; run: <T>(key: string, work: () => Promise<T>) => Promise<T | undefined> } {
  const [busy, setBusy] = useState<ReadonlySet<string>>(new Set());
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);
  const tracker = useRef<BusyTracker | null>(null);
  if (!tracker.current) tracker.current = new BusyTracker((k) => alive.current && setBusy(k));
  const run = useCallback(<T,>(key: string, work: () => Promise<T>) => tracker.current!.run(key, work), []);
  return { busy, run };
}

/**
 * What a dialog's answer may close: only the dialog it was started for. A reply that arrives after another
 * dialog was opened leaves that one alone (`same` compares the operation / staging id / add-on id).
 */
export function closeIfStill<T>(current: T | null, mine: T, same: (a: T, b: T) => boolean): T | null {
  return current !== null && same(current, mine) ? null : current;
}
