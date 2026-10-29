import { afterEach, describe, expect, it, vi } from "vitest";
import { clearIf, expireAfter, raise, type Notice } from "./notice";

// What the pane host does with a refusal: raise it, start its timer, clear by number.
const rig = () => {
  let cur: Notice | undefined;
  let cancel: (() => void) | undefined;
  let seq: number | undefined;
  const sync = () => {
    // the host's effect: depends on the notice's number only
    if (cur?.seq === seq) return;
    cancel?.();
    seq = cur?.seq;
    cancel = seq === undefined ? undefined : expireAfter(seq, 6000, (n) => (cur = clearIf(cur, n)));
  };
  return {
    raise: (text: string) => {
      cur = raise(cur, text);
      sync();
    },
    close: () => {
      cur = clearIf(cur, cur?.seq ?? -1);
      sync();
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
    const old = raise(undefined, "a");
    const newer = raise(old, "a");
    expect(newer.seq).not.toBe(old.seq);
    expect(clearIf(newer, old.seq)).toBe(newer);
    expect(clearIf(newer, newer.seq)).toBeUndefined();
    expect(clearIf(undefined, 1)).toBeUndefined();
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
