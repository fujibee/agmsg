import { afterEach, describe, expect, it, vi } from "vitest";
import { clearIf, counter, expireAfter, raise, type Notice } from "./notice";

// What the pane host does with a refusal: raise it, start its timer, clear by number.
const rig = () => {
  let cur: Notice | undefined;
  let cancel: (() => void) | undefined;
  let seq: number | undefined;
  const next = counter();
  const sync = () => {
    // the host's effect: depends on the notice's number only
    if (cur?.seq === seq) return;
    cancel?.();
    seq = cur?.seq;
    cancel = seq === undefined ? undefined : expireAfter(seq, 6000, (n) => (cur = clearIf(cur, n)));
  };
  return {
    raise: (text: string) => {
      cur = raise(next(), text);
      sync();
    },
    // × as the host wires it: the number of the notice that was on screen when it was drawn
    close: () => {
      const shown = cur?.seq;
      if (shown !== undefined) cur = clearIf(cur, shown);
      sync();
    },
    // an old timer fired by hand, as a late timer would
    fireOld: (n: number) => {
      cur = clearIf(cur, n);
      sync();
    },
    get seq() {
      return cur?.seq;
    },
    get text() {
      return cur?.text;
    },
  };
};

afterEach(() => vi.useRealTimers());

describe("a short-lived notice", () => {
  it("the same words again are a new notice, so its 6 s start over", () => {
    vi.useFakeTimers();
    const r = rig();
    r.raise("read (denied)");
    vi.advanceTimersByTime(5900);
    r.raise("read (denied)");
    vi.advanceTimersByTime(200); // t = 6.1 s: the first timer would have fired
    expect(r.text).toBe("read (denied)");
    vi.advanceTimersByTime(5700); // t = 11.8 s: just under 6 s after the second
    expect(r.text).toBe("read (denied)");
    vi.advanceTimersByTime(200);
    expect(r.text).toBeUndefined();
  });
  it("different words replace the text and also restart the timer", () => {
    vi.useFakeTimers();
    const r = rig();
    r.raise("read (denied)");
    vi.advanceTimersByTime(5000);
    r.raise("list (denied)");
    expect(r.text).toBe("list (denied)");
    vi.advanceTimersByTime(5000);
    expect(r.text).toBe("list (denied)");
    vi.advanceTimersByTime(1000);
    expect(r.text).toBeUndefined();
  });
  it("an old timer, even if it fires, never removes a newer notice", () => {
    const next = counter();
    const old = raise(next(), "a");
    const newer = raise(next(), "a");
    expect(newer.seq).not.toBe(old.seq);
    expect(clearIf(newer, old.seq)).toBe(newer);
    expect(clearIf(newer, newer.seq)).toBeUndefined();
    expect(clearIf(undefined, 1)).toBeUndefined();
  });
  it("raise, ×, raise, then the old timer fires: the new notice stays (numbers do not restart after a clear)", () => {
    const r = rig();
    r.raise("a");
    const first = r.seq!;
    r.close();
    r.raise("b");
    expect(r.seq).not.toBe(first);
    r.fireOld(first);
    expect(r.text).toBe("b");
  });
  it("the counter only goes up, whatever is cleared", () => {
    const next = counter();
    const seen = [next(), next(), next()];
    expect(seen).toEqual([1, 2, 3]);
    expect(clearIf(raise(seen[2], "x"), seen[0])?.text).toBe("x");
  });
  it("× clears the current notice, and its timer does nothing afterwards", () => {
    vi.useFakeTimers();
    const r = rig();
    r.raise("read (denied)");
    r.close();
    expect(r.text).toBeUndefined();
    r.raise("write (denied)");
    vi.advanceTimersByTime(5000);
    expect(r.text).toBe("write (denied)");
  });
});
